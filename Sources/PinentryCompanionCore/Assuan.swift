import Foundation

public enum Assuan {
    public static let maxLineLength = 1000

    public struct Command {
        public var name: String
        public var parameters: String
    }

    public enum Source: Int, Sendable {
        case pinentry = 5
        case assuan = 15
    }

    public enum Code: Int, Sendable {
        case canceled = 99
        case noPinentry = 85
        case notImplemented = 69
        case unknownCommand = 175
        case unknownOption = 174
        case invalidValue = 55
        case notFound = 58
    }

    public struct ProtocolError: Error, CustomStringConvertible {
        public var source: Source
        public var code: Code
        public var sourceName: String
        public var message: String
        public var rawCode: Int? = nil

        public init(source: Source, code: Code, sourceName: String, message: String, rawCode: Int? = nil) {
            self.source = source
            self.code = code
            self.sourceName = sourceName
            self.message = message
            self.rawCode = rawCode
        }

        public var description: String { "\(sourceName): \(message)" }
    }

    public static func errorCode(source: Source, code: Code) -> Int {
        ((source.rawValue & 127) << 24) | (code.rawValue & 65_535)
    }

    public static func parse(_ line: String) throws -> Command? {
        guard line.utf8.count < maxLineLength else {
            throw ProtocolError(
                source: .assuan,
                code: .invalidValue,
                sourceName: "assuan",
                message: "IPC line exceeds the 1000-byte protocol limit"
            )
        }
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if line.hasPrefix("#") || line.hasPrefix("S ") { return nil }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = parts[0].uppercased()
        let parameters = parts.count > 1 ? try unescape(String(parts[1])) : ""
        return Command(name: command, parameters: parameters)
    }

    public static func escape(_ value: String) -> String {
        escapedTokens(value).joined()
    }

    public static func unescape(_ value: String) throws -> String {
        guard let result = value.removingPercentEncoding else {
            throw ProtocolError(
                source: .assuan,
                code: .invalidValue,
                sourceName: "assuan",
                message: "invalid percent encoding"
            )
        }
        return result
    }

    static func writeLine(_ command: String, _ parameters: String = "") {
        FileHandle.standardOutput.write(Data(encodedLine(command, parameters).utf8))
    }

    static func encodedLine(_ command: String, _ parameters: String = "") -> String {
        let command = command.uppercased()
        guard !parameters.isEmpty else { return "\(command)\n" }

        let maximumPayloadBytes = max(0, maxLineLength - command.utf8.count - 2)
        var payload = ""
        var payloadBytes = 0
        for token in escapedTokens(parameters) {
            let tokenBytes = token.utf8.count
            guard payloadBytes + tokenBytes <= maximumPayloadBytes else { break }
            payload += token
            payloadBytes += tokenBytes
        }
        return payload.isEmpty ? "\(command)\n" : "\(command) \(payload)\n"
    }

    static func writeError(_ error: ProtocolError) {
        let code = error.rawCode ?? errorCode(source: error.source, code: error.code)
        writeLine("ERR", "\(code) \(error.message) <\(error.sourceName)>")
    }

    public static func parseErrorLine(_ line: String) -> ProtocolError? {
        guard line.hasPrefix("ERR ") else { return nil }

        let body = line.dropFirst(4)
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawCodeText = parts.first, let rawCode = Int(rawCodeText) else { return nil }

        var message = parts.count > 1 ? String(parts[1]) : "pinentry error"
        var sourceName = "pinentry"

        if let start = message.lastIndex(of: "<"), let end = message.lastIndex(of: ">"), start < end {
            sourceName = String(message[message.index(after: start)..<end])
            message = String(message[..<start]).trimmingCharacters(in: .whitespaces)
        }

        let codeValue = rawCode & 65_535
        let sourceValue = (rawCode >> 24) & 127
        let source = Source(rawValue: sourceValue) ?? .pinentry
        let code = Code(rawValue: codeValue) ?? .canceled

        return ProtocolError(
            source: source,
            code: code,
            sourceName: sourceName,
            message: message.isEmpty ? "pinentry error" : message,
            rawCode: rawCode
        )
    }

    static func writeData(_ value: String) {
        for line in dataLines(value) {
            FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        }
    }

    static func dataLines(_ value: String) -> [String] {
        let maximumPayloadBytes = maxLineLength - 3
        var lines: [String] = []
        var payload = ""
        var payloadBytes = 0

        for token in escapedTokens(value) {
            let tokenBytes = token.utf8.count
            if payloadBytes + tokenBytes > maximumPayloadBytes, !payload.isEmpty {
                lines.append("D \(payload)")
                payload = ""
                payloadBytes = 0
            }
            payload += token
            payloadBytes += tokenBytes
        }
        if !payload.isEmpty { lines.append("D \(payload)") }
        return lines
    }

    private static func escapedTokens(_ value: String) -> [String] {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x25: return "%25"
            case 0x5C: return "%5C"
            case 0x0D: return "%0D"
            case 0x0A: return "%0A"
            default: return String(scalar)
            }
        }
    }
}
