import Foundation
import Darwin

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
        for line in logicalLines(contents) {
            guard let value = pinentryProgramValue(in: line) else { continue }
            return value
        }
        return nil
    }

    public static func updatedContents(_ contents: String, pinentryPath: String) throws -> String {
        guard !pinentryPath.contains("\n"), !pinentryPath.contains("\r"), !pinentryPath.isEmpty else {
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
                return "pinentry path is empty or contains a newline"
            }
        }
    }
}

struct GPGAgentConfigSnapshot {
    var contents: String
    var exists: Bool
    var mode: mode_t
}

enum GPGAgentConfigFile {
    static func validateHomeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try itemMetadata(url)
        guard metadata.isDirectory else { throw FileError.notDirectory(url.path) }
        try validateUserOwned(metadata, path: url.path)
    }

    static func prepareHome(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try validateHomeIfPresent(url)
            if chmod(url.path, S_IRWXU) != 0 { throw FileError.chmodFailed(url.path, errnoMessage()) }
            return
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
        )
        if chmod(url.path, S_IRWXU) != 0 { throw FileError.chmodFailed(url.path, errnoMessage()) }
    }

    static func read(_ url: URL) throws -> GPGAgentConfigSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return GPGAgentConfigSnapshot(contents: "", exists: false, mode: S_IRUSR | S_IWUSR)
        }

        let metadata = try itemMetadata(url)
        guard !metadata.isDirectory else { throw FileError.isDirectory(url.path) }
        try validateUserOwned(metadata, path: url.path)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileError.readFailed(url.path, error.localizedDescription)
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            throw FileError.invalidUTF8(url.path)
        }

        return GPGAgentConfigSnapshot(contents: contents, exists: true, mode: metadata.mode)
    }

    static func backup(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = URL(fileURLWithPath: "\(url.path).bak.\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            throw FileError.backupFailed(url.path, backup.path, error.localizedDescription)
        }
        return backup
    }

    static func write(_ contents: String, to url: URL, preserving snapshot: GPGAgentConfigSnapshot) throws {
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
        } catch {
            throw FileError.writeFailed(url.path, error.localizedDescription)
        }

        let mode = snapshot.exists ? snapshot.mode & 0o777 : S_IRUSR | S_IWUSR
        if chmod(url.path, mode) != 0 { throw FileError.chmodFailed(url.path, errnoMessage()) }
    }

    private struct Metadata {
        var uid: uid_t
        var mode: mode_t

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
    }

    private static func itemMetadata(_ url: URL) throws -> Metadata {
        var info = stat()
        if lstat(url.path, &info) != 0 { throw FileError.statFailed(url.path, errnoMessage()) }
        let metadata = Metadata(uid: info.st_uid, mode: info.st_mode)
        if metadata.isSymlink { throw FileError.symlink(url.path) }
        return metadata
    }

    private static func validateUserOwned(_ metadata: Metadata, path: String) throws {
        let uid = geteuid()
        guard uid != 0 else { throw FileError.rootUser }
        guard metadata.uid == uid else { throw FileError.notOwnedByCurrentUser(path) }
    }

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }

    enum FileError: Error, CustomStringConvertible {
        case rootUser
        case symlink(String)
        case notDirectory(String)
        case isDirectory(String)
        case notOwnedByCurrentUser(String)
        case invalidUTF8(String)
        case statFailed(String, String)
        case readFailed(String, String)
        case writeFailed(String, String)
        case backupFailed(String, String, String)
        case chmodFailed(String, String)

        var description: String {
            switch self {
            case .rootUser:
                return "refusing to run setup as root"
            case .symlink(let path):
                return "refusing to use symlinked path: \(path)"
            case .notDirectory(let path):
                return "GnuPG home is not a directory: \(path)"
            case .isDirectory(let path):
                return "gpg-agent.conf is a directory: \(path)"
            case .notOwnedByCurrentUser(let path):
                return "refusing to modify path not owned by the current user: \(path)"
            case .invalidUTF8(let path):
                return "gpg-agent.conf is not valid UTF-8: \(path)"
            case .statFailed(let path, let message):
                return "could not inspect \(path): \(message)"
            case .readFailed(let path, let message):
                return "could not read \(path): \(message)"
            case .writeFailed(let path, let message):
                return "could not write \(path): \(message)"
            case .backupFailed(let path, let backup, let message):
                return "could not back up \(path) to \(backup): \(message)"
            case .chmodFailed(let path, let message):
                return "could not set permissions on \(path): \(message)"
            }
        }
    }
}
