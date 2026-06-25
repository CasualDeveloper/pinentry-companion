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
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if line.hasPrefix("#") || line.hasPrefix("S ") { return nil }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = parts[0].uppercased()
        let parameters = parts.count > 1 ? try unescape(String(parts[1])) : ""
        return Command(name: command, parameters: parameters)
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
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
        var line = command.uppercased()
        if !parameters.isEmpty {
            line += " " + escape(parameters)
        }
        line += "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
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
        let encoded = escape(value)
        let chunkLength = maxLineLength - 3
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: chunkLength, limitedBy: encoded.endIndex) ?? encoded.endIndex
            FileHandle.standardOutput.write(Data("D \(encoded[index..<end])\n".utf8))
            index = end
        }
    }
}
