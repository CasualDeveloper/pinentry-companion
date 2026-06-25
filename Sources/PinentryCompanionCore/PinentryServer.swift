import Foundation

final class PinentryServer {
    private var settings = PinentrySettings()
    private let keychain = KeychainStore()

    func run() {
        Assuan.writeLine("OK", "Hi from pinentry-companion!")

        while let rawLine = readLine(strippingNewline: true) {
            do {
                guard let command = try Assuan.parse(rawLine) else { continue }
                var shouldExit = false
                try handle(command, shouldExit: &shouldExit)
                if shouldExit { return }
            } catch let error as Assuan.ProtocolError {
                Assuan.writeError(error)
            } catch let error as FallbackPinentryError {
                Assuan.writeError(error.protocolError ?? cancelError(error.description))
            } catch {
                Assuan.writeError(cancelError(error.localizedDescription))
            }
        }
    }

    private func handle(_ command: Assuan.Command, shouldExit: inout Bool) throws {
        switch command.name {
        case "BYE":
            Assuan.writeLine("OK")
            shouldExit = true
        case "NOP":
            Assuan.writeLine("OK")
        case "RESET":
            settings.reset()
            Assuan.writeLine("OK")
        case "OPTION":
            try setOption(command.parameters)
            Assuan.writeLine("OK")
        case "HELP":
            writeHelp(command.parameters)
        case "GETINFO":
            try writeInfo(command.parameters)
        case "CANCEL", "END":
            Assuan.writeLine("OK")
        case "SETDESC", "SETKEYDESC": settings.description = command.parameters; Assuan.writeLine("OK")
        case "SETPROMPT": settings.prompt = command.parameters; Assuan.writeLine("OK")
        case "SETREPEAT": settings.repeatPrompt = command.parameters; Assuan.writeLine("OK")
        case "SETREPEATERROR": settings.repeatError = command.parameters; Assuan.writeLine("OK")
        case "SETERROR": settings.error = command.parameters; Assuan.writeLine("OK")
        case "SETOK": settings.okButton = command.parameters; Assuan.writeLine("OK")
        case "SETNOTOK": settings.notOkButton = command.parameters; Assuan.writeLine("OK")
        case "SETCANCEL": settings.cancelButton = command.parameters; Assuan.writeLine("OK")
        case "SETQUALITYBAR": settings.qualityBar = command.parameters; Assuan.writeLine("OK")
        case "SETTITLE": settings.title = command.parameters; Assuan.writeLine("OK")
        case "SETTIMEOUT": settings.timeoutSeconds = Int(command.parameters) ?? 0; Assuan.writeLine("OK")
        case "SETKEYINFO": settings.keyInfo = command.parameters == "--clear" ? "" : command.parameters; Assuan.writeLine("OK")
        case "GETPIN":
            let pin = try getPIN()
            Assuan.writeData(pin)
            Assuan.writeLine("OK")
        case "CONFIRM":
            try FallbackPinentry().confirm(settings: settings)
            Assuan.writeLine("OK")
        case "MESSAGE":
            try FallbackPinentry().message(settings: settings)
            Assuan.writeLine("OK")
        default:
            throw Assuan.ProtocolError(
                source: .assuan,
                code: .unknownCommand,
                sourceName: "assuan",
                message: "unknown IPC command"
            )
        }
    }

    private func getPIN() throws -> String {
        if let identity = keychainIdentity, shouldUseKeychainPath {
            return try getPINUsingKeychain(identity: identity)
        }
        return try promptViaFallbackAndRepairKeychainIfNeeded()
    }

    private var shouldUseKeychainPath: Bool {
        settings.repeatPrompt.isEmpty &&
            settings.options.allowExternalPasswordCache &&
            !settings.keyInfo.isEmpty
    }

    private var keychainIdentity: KeychainIdentity? {
        try? KeychainIdentity(keyInfo: settings.keyInfo)
    }

    private func getPINUsingKeychain(identity: KeychainIdentity) throws -> String {
        if settings.isBadPassphraseRetry {
            try? keychain.delete(identity: identity)
            return try promptAndStore(identity: identity)
        }

        do {
            return try keychain.password(identity: identity, reason: authenticationReason(for: identity))
        } catch KeychainStoreError.notFound {
            return try promptAndStore(identity: identity)
        }
    }

    private func promptViaFallbackAndRepairKeychainIfNeeded() throws -> String {
        if settings.isBadPassphraseRetry, let identity = keychainIdentity {
            try? keychain.delete(identity: identity)
            return try promptAndStore(identity: identity)
        }
        return try FallbackPinentry().getPIN(settings: settings)
    }

    private func promptAndStore(identity: KeychainIdentity) throws -> String {
        let pin = try FallbackPinentry().getPIN(settings: settings)
        guard !pin.isEmpty else { throw cancelError("pinentry-mac didn't return a password") }

        try keychain.store(identity: identity, password: pin)
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
            ["NOP", "OPTION", "CANCEL", "BYE", "RESET", "END", "HELP", "GETINFO", "SETDESC", "SETKEYDESC", "GETPIN", "CONFIRM", "MESSAGE"].forEach {
                Assuan.writeLine("#", $0)
            }
        }
        Assuan.writeLine("OK")
    }

    private func writeInfo(_ name: String) throws {
        let value = try PinentryInfo.value(for: name)
        Assuan.writeData(value)
        Assuan.writeLine("OK")
    }

    private func cancelError(_ message: String) -> Assuan.ProtocolError {
        Assuan.ProtocolError(source: .pinentry, code: .canceled, sourceName: "pinentry", message: message)
    }
}

public enum PinentryInfo {
    public static let flavor = "companion"
    public static let version = "devel"

    public static func value(for name: String, environment: [String: String] = ProcessInfo.processInfo.environment, parentProcessID: Int32 = getppid()) throws -> String {
        switch name {
        case "flavor":
            return flavor
        case "version":
            return version
        case "pid":
            return String(ProcessInfo.processInfo.processIdentifier)
        case "ttyinfo":
            return ttyInfo(environment: environment, parentProcessID: parentProcessID)
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

    private static func ttyInfo(environment: [String: String], parentProcessID: Int32) -> String {
        [
            environment["GPG_TTY"] ?? "",
            String(parentProcessID),
            environment["TERM"] ?? "",
        ]
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
