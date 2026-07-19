import Foundation

public enum GPGAgentConfig {
    public static func homeURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["GNUPGHOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gnupg", isDirectory: true)
    }

    public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeURL(environment: environment).appendingPathComponent("gpg-agent.conf")
    }

    public static func activePinentryProgram(in contents: String) -> String? {
        activePinentryPrograms(in: contents).first
    }

    public static func activePinentryPrograms(in contents: String) -> [String] {
        logicalLines(contents).compactMap(pinentryProgramValue)
    }

    public static func updatedContents(_ contents: String, pinentryPath: String) throws -> String {
        guard !pinentryPath.contains("\0"),
              !pinentryPath.contains("\n"),
              !pinentryPath.contains("\r"),
              !pinentryPath.isEmpty else {
            throw ConfigError.invalidPinentryPath
        }

        let directive = "pinentry-program \(pinentryPath)"
        var output: [String] = []
        var replaced = false

        for line in logicalLines(contents) {
            if pinentryProgramValue(in: line) != nil {
                if !replaced {
                    output.append(directive)
                    replaced = true
                }
                continue
            }
            output.append(line)
        }

        if !replaced {
            output.append(directive)
        }

        return output.joined(separator: "\n") + "\n"
    }

    private static func logicalLines(_ contents: String) -> [String] {
        guard !contents.isEmpty else { return [] }
        let lines = contents.components(separatedBy: "\n")
        return contents.hasSuffix("\n") ? Array(lines.dropLast()) : lines
    }

    private static func pinentryProgramValue(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(maxSplits: 1) { $0 == " " || $0 == "\t" }
        guard parts.first == "pinentry-program" else { return nil }
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case invalidPinentryPath

        public var description: String {
            switch self {
            case .invalidPinentryPath:
                return "pinentry path is empty or contains a control separator"
            }
        }
    }
}
