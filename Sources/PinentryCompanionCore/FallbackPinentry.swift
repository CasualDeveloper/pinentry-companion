import Foundation

enum FallbackPinentryError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case invalidBanner(String)
    case unexpectedResponse(String)
    case protocolError(Assuan.ProtocolError)
    case eof
    case lineTooLong

    var description: String {
        switch self {
        case .executableNotFound(let name): return "\(name) not found"
        case .invalidBanner(let banner): return "unexpected pinentry banner: \(banner)"
        case .unexpectedResponse(let response): return "unexpected pinentry response: \(response)"
        case .protocolError(let error): return error.description
        case .eof: return "pinentry closed the connection"
        case .lineTooLong: return "pinentry protocol line exceeds the 1000-byte limit"
        }
    }
}

enum FallbackRequest {
    case getPIN
    case confirm
    case message
}

enum FallbackCommand: Equatable {
    case set(String, String)
    case option(String)
}

struct FallbackLineBuffer {
    private(set) var data = Data()
    private var byteCount = 0

    mutating func consume(_ byte: UInt8) throws -> Bool {
        byteCount += 1
        if byte == 10 {
            guard byteCount <= Assuan.maxLineLength else { throw FallbackPinentryError.lineTooLong }
            return true
        }
        guard byteCount < Assuan.maxLineLength else { throw FallbackPinentryError.lineTooLong }
        if byte != 13 { data.append(byte) }
        return false
    }

    var line: String { String(decoding: data, as: UTF8.self) }
}

enum FallbackCommandPlanner {
    static func commands(for request: FallbackRequest, settings: PinentrySettings) -> [FallbackCommand] {
        var commands: [FallbackCommand] = []
        let defaultTitle = request == .getPIN
            ? "pinentry-companion PIN Prompt"
            : "pinentry-companion"
        commands.append(.set("TITLE", settings.title.isEmpty ? defaultTitle : settings.title))
        appendSet("DESC", settings.description.replacingOccurrences(of: "\n", with: "\\n"), to: &commands)
        appendSet("KEYINFO", settings.keyInfo, to: &commands)
        appendSet("ERROR", settings.error, to: &commands)
        appendSet("OK", settings.okButton, to: &commands)
        appendSet("NOTOK", settings.notOkButton, to: &commands)
        appendSet("CANCEL", settings.cancelButton, to: &commands)
        if settings.timeoutSeconds > 0 {
            commands.append(.set("TIMEOUT", String(settings.timeoutSeconds)))
        }

        if request == .getPIN {
            commands.append(.set("PROMPT", settings.prompt.isEmpty ? "PIN" : settings.prompt))
            appendSet("REPEAT", settings.repeatPrompt, to: &commands)
            appendSet("REPEATERROR", settings.repeatError, to: &commands)
            appendSet("REPEATOK", settings.repeatOK, to: &commands)
            // Quality and generated-passphrase controls require relaying Assuan
            // inquiries to gpg-agent. Do not expose controls that cannot complete.
        }

        if let grab = settings.options.grab {
            commands.append(.option(grab ? "grab" : "no-grab"))
        }
        if settings.options.allowEmacsPrompt { commands.append(.option("allow-emacs-prompt")) }
        for key in settings.options.defaultLabels.keys.sorted() {
            appendOption(key, settings.options.defaultLabels[key] ?? "", to: &commands)
        }
        appendOption("display", settings.options.display, to: &commands)
        appendOption("ttytype", settings.options.ttyType, to: &commands)
        appendOption("ttyname", settings.options.ttyName, to: &commands)
        appendOption("ttyalert", settings.options.ttyAlert, to: &commands)
        appendOption("lc-ctype", settings.options.lcCType, to: &commands)
        appendOption("lc-messages", settings.options.lcMessages, to: &commands)
        appendOption("owner", settings.options.owner, to: &commands)
        appendOption("touch-file", settings.options.touchFile, to: &commands)
        appendOption("parent-wid", settings.options.parentWID, to: &commands)
        appendOption("invisible-char", settings.options.invisibleChar, to: &commands)
        if settings.options.formattedPassphrase { commands.append(.option("formatted-passphrase")) }
        appendOption("formatted-passphrase-hint", settings.options.formattedPassphraseHint, to: &commands)
        return commands
    }

    private static func appendSet(
        _ key: String,
        _ value: String,
        to commands: inout [FallbackCommand]
    ) {
        if !value.isEmpty { commands.append(.set(key, value)) }
    }

    private static func appendOption(
        _ key: String,
        _ value: String,
        to commands: inout [FallbackCommand]
    ) {
        if !value.isEmpty { commands.append(.option("\(key)=\(value)")) }
    }
}

final class FallbackPinentry {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    init(name: String? = nil) throws {
        let candidates = name.map { [$0] } ?? FallbackPinentryNames.preferred()
        guard let found = ExecutableLookup.findFirst(candidates) else {
            throw FallbackPinentryError.executableNotFound(candidates.joined(separator: ", "))
        }

        process = Process()
        process.executableURL = URL(fileURLWithPath: found.path)

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError

        try process.run()

        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading

        do {
            let banner = try readLine()
            guard banner.hasPrefix("OK") else { throw FallbackPinentryError.invalidBanner(banner) }
        } catch {
            input.closeFile()
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    deinit {
        try? sendRaw("BYE\n")
        input.closeFile()
        if process.isRunning { process.terminate() }
    }

    func getPIN(settings: PinentrySettings) throws -> String {
        try apply(request: .getPIN, settings: settings)

        try sendRaw("GETPIN\n")
        var value = ""

        while true {
            let line = try readLine()
            if line == "OK" { return value }
            if line.hasPrefix("D ") {
                value += try Assuan.unescape(String(line.dropFirst(2)))
                continue
            }
            if line.hasPrefix("S ") || line.hasPrefix("#") { continue }
            if let error = Assuan.parseErrorLine(line) { throw FallbackPinentryError.protocolError(error) }
            throw FallbackPinentryError.unexpectedResponse(line)
        }
    }

    func confirm(settings: PinentrySettings) throws {
        try apply(request: .confirm, settings: settings)
        try sendRaw(Assuan.encodedLine("CONFIRM", settings.confirmParameters))
        try expectOK()
    }

    func message(settings: PinentrySettings) throws {
        try apply(request: .message, settings: settings)
        try sendRaw("MESSAGE\n")
        try expectOK()
    }

    private func set(_ key: String, _ value: String) throws {
        try sendRaw(Assuan.encodedLine("SET\(key)", value))
        try expectOK()
    }

    private func apply(request: FallbackRequest, settings: PinentrySettings) throws {
        for command in FallbackCommandPlanner.commands(for: request, settings: settings) {
            switch command {
            case .set(let key, let value): try set(key, value)
            case .option(let value):
                try sendRaw(Assuan.encodedLine("OPTION", value))
                try expectOK()
            }
        }
    }

    private func expectOK() throws {
        let response = try readLine()
        if response == "OK" { return }
        if let error = Assuan.parseErrorLine(response) { throw FallbackPinentryError.protocolError(error) }
        throw FallbackPinentryError.unexpectedResponse(response)
    }

    private func sendRaw(_ line: String) throws {
        guard line.utf8.count <= Assuan.maxLineLength else {
            throw FallbackPinentryError.lineTooLong
        }
        input.write(Data(line.utf8))
    }

    private func readLine() throws -> String {
        var buffer = FallbackLineBuffer()
        while true {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty { throw FallbackPinentryError.eof }
            if try buffer.consume(byte[0]) { return buffer.line }
        }
    }
}

extension FallbackPinentry: FallbackPinentryClient {}
