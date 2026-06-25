import Darwin
import Foundation

enum ExecutableLookup {
    static func find(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = paths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        for directory in candidates {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func findFirst(_ names: [String]) -> (name: String, path: String)? {
        for name in names {
            if let path = find(name) { return (name, path) }
        }
        return nil
    }

    static func gpgconfPinentryPath() -> String? {
        guard let gpgconf = find("gpgconf") else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gpgconf)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0] == "pinentry" {
                return String(parts[2])
            }
        }
        return nil
    }

    static func execFallback(_ name: String) throws -> Never {
        try execFallback([name])
    }

    static func execFallback(_ names: [String]) throws -> Never {
        guard let found = findFirst(names) else {
            let joined = names.joined(separator: ", ")
            throw Assuan.ProtocolError(
                source: .pinentry,
                code: .noPinentry,
                sourceName: "pinentry",
                message: "Unable to find fallback \(joined)"
            )
        }

        try exec(path: found.path, name: found.name)
    }

    private static func exec(path: String, name: String) throws -> Never {
        let args = CommandLine.arguments.map { strdup($0) } + [nil]
        defer { args.compactMap { $0 }.forEach { free($0) } }

        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count)
        defer { argv.deallocate() }
        for (index, arg) in args.enumerated() { argv[index] = arg }

        execv(path, argv)
        throw Assuan.ProtocolError(
            source: .pinentry,
            code: .noPinentry,
            sourceName: name,
            message: "Unable to execute fallback \(name): \(String(cString: strerror(errno)))"
        )
    }
}
