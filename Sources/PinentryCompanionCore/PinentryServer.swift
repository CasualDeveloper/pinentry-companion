import Darwin
import Foundation

protocol PassphraseCache {
    func password(identity: KeychainIdentity, reason: String) throws -> String
    func store(identity: KeychainIdentity, password: String) throws
    func delete(identity: KeychainIdentity) throws
}

protocol FallbackPinentryClient {
    func getPIN(settings: PinentrySettings) throws -> String
    func confirm(settings: PinentrySettings) throws
    func message(settings: PinentrySettings) throws
}

protocol PinentryServerOutput {
    func writeLine(_ command: String, _ parameters: String)
    func writeData(_ value: String)
    func writeError(_ error: Assuan.ProtocolError)
}

struct AssuanPinentryServerOutput: PinentryServerOutput {
    func writeLine(_ command: String, _ parameters: String = "") {
        Assuan.writeLine(command, parameters)
    }

    func writeData(_ value: String) {
        Assuan.writeData(value)
    }

    func writeError(_ error: Assuan.ProtocolError) {
        Assuan.writeError(error)
    }
}

final class PinentryServer {
    private var settings = PinentrySettings()
    private let cache: any PassphraseCache
    private let makeFallback: () throws -> any FallbackPinentryClient
    private let output: any PinentryServerOutput

    init(
        cache: any PassphraseCache = KeychainStore(),
        fallbackFactory: @escaping () throws -> any FallbackPinentryClient = { try FallbackPinentry() },
        output: any PinentryServerOutput = AssuanPinentryServerOutput()
    ) {
        self.cache = cache
        makeFallback = fallbackFactory
        self.output = output
    }

    func run() {
        output.writeLine("OK", "Hi from pinentry-companion!")

        while let rawLine = readLine(strippingNewline: true) {
            if process(rawLine) { return }
        }
    }

    @discardableResult
    func process(_ rawLine: String) -> Bool {
        do {
            guard let command = try Assuan.parse(rawLine) else { return false }
            var shouldExit = false
            try handle(command, shouldExit: &shouldExit)
            return shouldExit
        } catch let error as Assuan.ProtocolError {
            output.writeError(error)
        } catch let error as FallbackPinentryError {
            output.writeError(error.protocolError ?? cancelError(error.description))
        } catch {
            output.writeError(cancelError(error.localizedDescription))
        }

        return false
    }

    private func handle(_ command: Assuan.Command, shouldExit: inout Bool) throws {
        switch command.name {
        case "BYE":
            output.writeLine("OK", "")
            shouldExit = true
        case "NOP":
            output.writeLine("OK", "")
        case "RESET":
            settings.reset()
            output.writeLine("OK", "")
        case "OPTION":
            try setOption(command.parameters)
            output.writeLine("OK", "")
        case "HELP":
            writeHelp(command.parameters)
        case "GETINFO":
            try writeInfo(command.parameters)
        case "CANCEL", "END":
            output.writeLine("OK", "")
        case "SETDESC", "SETKEYDESC": settings.description = command.parameters; output.writeLine("OK", "")
        case "SETPROMPT": settings.prompt = command.parameters; output.writeLine("OK", "")
        case "SETREPEAT": settings.repeatPrompt = command.parameters; output.writeLine("OK", "")
        case "SETREPEATERROR": settings.repeatError = command.parameters; output.writeLine("OK", "")
        case "SETREPEATOK": settings.repeatOK = command.parameters; output.writeLine("OK", "")
        case "SETERROR": settings.error = command.parameters; output.writeLine("OK", "")
        case "SETOK": settings.okButton = command.parameters; output.writeLine("OK", "")
        case "SETNOTOK": settings.notOkButton = command.parameters; output.writeLine("OK", "")
        case "SETCANCEL": settings.cancelButton = command.parameters; output.writeLine("OK", "")
        case "SETQUALITYBAR": settings.qualityBar = command.parameters; output.writeLine("OK", "")
        case "SETQUALITYBAR_TT": settings.qualityBarTooltip = command.parameters; output.writeLine("OK", "")
        case "SETGENPIN": settings.generatePINLabel = command.parameters; output.writeLine("OK", "")
        case "SETGENPIN_TT": settings.generatePINTooltip = command.parameters; output.writeLine("OK", "")
        case "SETTITLE": settings.title = command.parameters; output.writeLine("OK", "")
        case "SETTIMEOUT":
            guard let timeout = Int(command.parameters), timeout >= 0 else {
                throw Assuan.ProtocolError(
                    source: .assuan,
                    code: .invalidValue,
                    sourceName: "assuan",
                    message: "SETTIMEOUT requires a non-negative integer"
                )
            }
            settings.timeoutSeconds = timeout
            output.writeLine("OK", "")
        case "SETKEYINFO": settings.keyInfo = command.parameters == "--clear" ? "" : command.parameters; output.writeLine("OK", "")
        case "CLEARPASSPHRASE":
            let identity = try KeychainIdentity(keyInfo: command.parameters)
            try cache.delete(identity: identity)
            output.writeLine("OK", "")
        case "GETPIN":
            defer { settings.error = "" }
            let result = try getPIN()
            if result.fromCache { output.writeLine("S", "PASSWORD_FROM_CACHE") }
            if !settings.repeatPrompt.isEmpty { output.writeLine("S", "PIN_REPEATED") }
            output.writeData(result.value)
            output.writeLine("OK", "")
        case "CONFIRM":
            defer { settings.error = "" }
            var confirmSettings = settings
            confirmSettings.confirmParameters = command.parameters
            try makeFallback().confirm(settings: confirmSettings)
            output.writeLine("OK", "")
        case "MESSAGE":
            try makeFallback().message(settings: settings)
            output.writeLine("OK", "")
        default:
            throw Assuan.ProtocolError(
                source: .assuan,
                code: .unknownCommand,
                sourceName: "assuan",
                message: "unknown IPC command"
            )
        }
    }

    private struct PINResult {
        var value: String
        var fromCache: Bool
    }

    private func getPIN() throws -> PINResult {
        guard let identity = authorizedCacheIdentity else {
            return PINResult(value: try promptForPIN(), fromCache: false)
        }
        if settings.isBadPassphraseRetry {
            settings.cacheAttempted = true
            try? cache.delete(identity: identity)
            return try promptAndStore(identity: identity)
        }
        guard !settings.cacheAttempted else { return try promptAndStore(identity: identity) }
        settings.cacheAttempted = true
        return try getPINUsingCache(identity: identity)
    }

    private var authorizedCacheIdentity: KeychainIdentity? {
        guard settings.repeatPrompt.isEmpty,
              settings.options.allowExternalPasswordCache,
              !settings.keyInfo.isEmpty
        else { return nil }
        return try? KeychainIdentity(keyInfo: settings.keyInfo)
    }

    private func getPINUsingCache(identity: KeychainIdentity) throws -> PINResult {
        do {
            return PINResult(
                value: try cache.password(identity: identity, reason: authenticationReason(for: identity)),
                fromCache: true
            )
        } catch KeychainStoreError.notFound {
            return try promptAndStore(identity: identity)
        }
    }

    private func promptAndStore(identity: KeychainIdentity) throws -> PINResult {
        let pin = try promptForPIN()
        try? cache.store(identity: identity, password: pin)
        return PINResult(value: pin, fromCache: false)
    }

    private func promptForPIN() throws -> String {
        let pin = try makeFallback().getPIN(settings: settings)
        guard !pin.isEmpty else { throw cancelError("fallback pinentry didn't return a password") }
        return pin
    }

    private func authenticationReason(for identity: KeychainIdentity) -> String {
        AuthenticationReason.reason(identity: identity, settings: settings)
    }

    private func setOption(_ option: String) throws {
        try PinentryOptionParser.apply(option, to: &settings)
    }

    private func writeHelp(_ command: String) {
        if command.isEmpty {
            [
                "NOP", "OPTION", "CANCEL", "BYE", "RESET", "END", "HELP", "GETINFO",
                "SETDESC", "SETKEYDESC", "SETPROMPT", "SETREPEAT", "SETREPEATERROR",
                "SETREPEATOK", "SETERROR", "SETOK", "SETNOTOK", "SETCANCEL", "SETTITLE",
                "SETTIMEOUT", "SETKEYINFO", "SETQUALITYBAR", "SETQUALITYBAR_TT", "SETGENPIN",
                "SETGENPIN_TT", "CLEARPASSPHRASE", "GETPIN", "CONFIRM", "MESSAGE",
            ].forEach {
                output.writeLine("#", $0)
            }
        }
        output.writeLine("OK", "")
    }

    private func writeInfo(_ name: String) throws {
        let value = try PinentryInfo.value(for: name, options: settings.options)
        output.writeData(value)
        output.writeLine("OK", "")
    }

    private func cancelError(_ message: String) -> Assuan.ProtocolError {
        Assuan.ProtocolError(source: .pinentry, code: .canceled, sourceName: "pinentry", message: message)
    }
}

public enum PinentryInfo {
    public static let flavor = "companion"
    public static let version = ComponentVersion.current

    public static func value(for name: String, options: PinentryOptions = PinentryOptions()) throws -> String {
        switch name {
        case "flavor":
            return flavor
        case "version":
            return version
        case "pid":
            return String(ProcessInfo.processInfo.processIdentifier)
        case "ttyinfo":
            return ttyInfo(options: options)
        case "":
            throw Assuan.ProtocolError(
                source: .assuan,
                code: .invalidValue,
                sourceName: "assuan",
                message: "missing argument"
            )
        default:
            throw Assuan.ProtocolError(
                source: .assuan,
                code: .notFound,
                sourceName: "assuan",
                message: "unknown value"
            )
        }
    }

    private static func ttyInfo(options: PinentryOptions) -> String {
        [
            options.ttyName.isEmpty ? "-" : options.ttyName,
            options.ttyType.isEmpty ? "-" : options.ttyType,
            options.display.isEmpty ? "-" : options.display,
            deviceStat(for: options.ttyName),
            "\(geteuid())/\(getegid())",
            "-",
        ]
        .joined(separator: " ")
    }

    private static func deviceStat(for path: String) -> String {
        guard !path.isEmpty else { return "-" }
        var info = stat()
        guard stat(path, &info) == 0 else { return "?" }
        return String(info.st_mode, radix: 8) + "/\(info.st_uid)/\(info.st_gid)"
    }
}

public enum PinentryProtocolCheck {
    public struct Result {
        public var passed: Bool
        public var detail: String
    }

    public static let smokeInput = "SETKEYDESC doctor%20protocol%20check\nGETINFO flavor\nGETINFO version\nGETINFO pid\nGETINFO ttyinfo\nBYE\n"

    public static func validate(output: String, status: Int32) -> Result {
        guard status == 0 else {
            return Result(passed: false, detail: "protocol process exited with status \(status)")
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "OK Hi from pinentry-companion!" else {
            return Result(passed: false, detail: "missing protocol greeting")
        }
        if lines.contains(where: { $0.hasPrefix("ERR ") }) {
            return Result(passed: false, detail: "protocol smoke returned an error")
        }

        let dataLines = lines.compactMap { line -> String? in
            line.hasPrefix("D ") ? String(line.dropFirst(2)) : nil
        }
        guard dataLines.contains(PinentryInfo.flavor) else {
            return Result(passed: false, detail: "GETINFO flavor did not return \(PinentryInfo.flavor)")
        }
        guard dataLines.contains(PinentryInfo.version) else {
            return Result(passed: false, detail: "GETINFO version did not return \(PinentryInfo.version)")
        }
        guard dataLines.contains(where: { Int($0) != nil }) else {
            return Result(passed: false, detail: "GETINFO pid did not return a process id")
        }
        guard dataLines.count >= 4 else {
            return Result(passed: false, detail: "missing GETINFO ttyinfo response")
        }

        return Result(passed: true, detail: "GETINFO flavor/version/pid/ttyinfo OK")
    }
}

private extension FallbackPinentryError {
    var protocolError: Assuan.ProtocolError? {
        if case .protocolError(let error) = self { return error }
        return nil
    }
}
