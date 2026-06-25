import Foundation

enum FallbackPinentryError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case invalidBanner(String)
    case unexpectedResponse(String)
    case protocolError(Assuan.ProtocolError)
    case eof

    var description: String {
        switch self {
        case .executableNotFound(let name): return "\(name) not found"
        case .invalidBanner(let banner): return "unexpected pinentry banner: \(banner)"
        case .unexpectedResponse(let response): return "unexpected pinentry response: \(response)"
        case .protocolError(let error): return error.description
        case .eof: return "pinentry closed the connection"
        }
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

        let banner = try readLine()
        guard banner.hasPrefix("OK") else { throw FallbackPinentryError.invalidBanner(banner) }
    }

    deinit {
        try? sendRaw("BYE\n")
        input.closeFile()
        if process.isRunning { process.terminate() }
    }

    func getPIN(settings: PinentrySettings) throws -> String {
        try set("TITLE", settings.title.isEmpty ? "pinentry-companion PIN Prompt" : settings.title)
        try set("DESC", settings.description.replacingOccurrences(of: "\n", with: "\\n"))
        if !settings.keyInfo.isEmpty { try set("KEYINFO", settings.keyInfo) }
        try set("PROMPT", settings.prompt.isEmpty ? "PIN" : settings.prompt)
        if !settings.repeatPrompt.isEmpty { try set("REPEAT", settings.repeatPrompt) }
        if !settings.repeatError.isEmpty { try set("REPEATERROR", settings.repeatError) }
        if !settings.error.isEmpty { try set("ERROR", settings.error) }

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
        try apply(settings: settings)
        try sendRaw("CONFIRM\n")
        try expectOK()
    }

    func message(settings: PinentrySettings) throws {
        try apply(settings: settings)
        try sendRaw("MESSAGE\n")
        try expectOK()
    }

    private func set(_ key: String, _ value: String) throws {
        try sendRaw("SET\(key) \(Assuan.escape(value))\n")
        try expectOK()
    }

    private func apply(settings: PinentrySettings) throws {
        try set("TITLE", settings.title.isEmpty ? "pinentry-companion" : settings.title)
        if !settings.description.isEmpty { try set("DESC", settings.description.replacingOccurrences(of: "\n", with: "\\n")) }
        if !settings.keyInfo.isEmpty { try set("KEYINFO", settings.keyInfo) }
        if !settings.error.isEmpty { try set("ERROR", settings.error) }
    }

    private func expectOK() throws {
        let response = try readLine()
        if response == "OK" { return }
        if let error = Assuan.parseErrorLine(response) { throw FallbackPinentryError.protocolError(error) }
        throw FallbackPinentryError.unexpectedResponse(response)
    }

    private func sendRaw(_ line: String) throws {
        input.write(Data(line.utf8))
    }

    private func readLine() throws -> String {
        var data = Data()
        while true {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty { throw FallbackPinentryError.eof }
            if byte[0] == 10 { break }
            if byte[0] != 13 { data.append(byte) }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
