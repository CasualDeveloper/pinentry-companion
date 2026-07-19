import CoreFoundation
import Darwin
import Foundation

enum LifecyclePreferenceError: Error, Equatable, CustomStringConvertible {
    case unsupportedWrite
    case synchronizeFailed
    case verificationFailed

    var description: String {
        switch self {
        case .unsupportedWrite: return "refusing to write an unsupported DisableKeychain value"
        case .synchronizeFailed: return "could not synchronize the DisableKeychain preference"
        case .verificationFailed: return "DisableKeychain preference verification failed"
        }
    }
}

protocol LifecyclePreferenceBacking: AnyObject {
    func read() -> LifecyclePreferenceState
    func write(_ value: Bool?)
    func synchronize() -> Bool
}

final class LifecyclePreferenceStore: LifecyclePreferenceManaging {
    private let backend: any LifecyclePreferenceBacking

    init(backend: any LifecyclePreferenceBacking = CFPreferencesLifecycleBackend()) {
        self.backend = backend
    }

    func read() throws -> LifecyclePreferenceState { backend.read() }

    func apply(_ state: LifecyclePreferenceState) throws {
        let value: Bool?
        switch state {
        case .absent: value = nil
        case .boolean(let boolean): value = boolean
        case .unsupported: throw LifecyclePreferenceError.unsupportedWrite
        }
        backend.write(value)
        guard backend.synchronize() else { throw LifecyclePreferenceError.synchronizeFailed }
        guard backend.read() == state else { throw LifecyclePreferenceError.verificationFailed }
    }
}

final class CFPreferencesLifecycleBackend: LifecyclePreferenceBacking {
    private let domain = "org.gpgtools.common" as CFString
    private let key = "DisableKeychain" as CFString

    func read() -> LifecyclePreferenceState {
        guard let value = CFPreferencesCopyAppValue(key, domain) else { return .absent }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            return .unsupported(
                type: String(describing: type(of: value)),
                description: "non-boolean value"
            )
        }
        return .boolean(boolean)
    }

    func write(_ value: Bool?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
    }

    func synchronize() -> Bool { CFPreferencesAppSynchronize(domain) }
}

enum LifecycleBinaryIdentityError: Error, Equatable, CustomStringConvertible {
    case invalidPath
    case notRegularFile(String)
    case doesNotMatchRunningBinary
    case fileSystem(path: String, message: String)

    var description: String {
        switch self {
        case .invalidPath: return "binary path must be absolute and canonical"
        case .notRegularFile(let path): return "binary is not a regular file: \(path)"
        case .doesNotMatchRunningBinary: return "invoked binary path does not resolve to this running executable"
        case .fileSystem(let path, let message): return "could not identify binary at \(path): \(message)"
        }
    }
}

extension LifecycleBinaryIdentity {
    static func read(
        invokedPath: String,
        expectedResolvedPath: String? = nil
    ) throws -> LifecycleBinaryIdentity {
        guard LifecyclePath.isCanonicalAbsolute(invokedPath) else {
            throw LifecycleBinaryIdentityError.invalidPath
        }
        let invokedURL = URL(fileURLWithPath: invokedPath)
        let resolvedPath = invokedURL.resolvingSymlinksInPath().path
        if let expectedResolvedPath,
           URL(fileURLWithPath: expectedResolvedPath).resolvingSymlinksInPath().path != resolvedPath {
            throw LifecycleBinaryIdentityError.doesNotMatchRunningBinary
        }
        let descriptor = open(resolvedPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LifecycleBinaryIdentityError.fileSystem(
                path: resolvedPath,
                message: String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw LifecycleBinaryIdentityError.fileSystem(
                path: resolvedPath,
                message: String(cString: strerror(errno))
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw LifecycleBinaryIdentityError.notRegularFile(resolvedPath)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw LifecycleBinaryIdentityError.fileSystem(
                    path: resolvedPath,
                    message: String(cString: strerror(errno))
                )
            }
            data.append(buffer, count: count)
        }
        return LifecycleBinaryIdentity(
            invokedPath: invokedPath,
            resolvedPath: resolvedPath,
            sha256: SHA256Digest.hex(data)
        )
    }
}

struct LifecycleProcessResult: Equatable {
    var status: Int32
    var standardError: String
}

protocol LifecycleProcessRunning {
    func run(executablePath: String, arguments: [String]) throws -> LifecycleProcessResult
}

enum LifecycleAgentError: Error, Equatable, CustomStringConvertible {
    case invalidExecutablePath
    case processFailed(String)
    case unsuccessful(status: Int32, detail: String)

    var description: String {
        switch self {
        case .invalidExecutablePath: return "gpgconf path must be absolute"
        case .processFailed(let detail): return "could not launch gpgconf: \(detail)"
        case .unsuccessful(let status, let detail):
            return detail.isEmpty
                ? "gpgconf exited with status \(status)"
                : "gpgconf exited with status \(status): \(detail)"
        }
    }
}

final class GPGAgentReloader: LifecycleAgentReloading {
    private let executablePath: String
    private let runner: any LifecycleProcessRunning

    init(
        executablePath: String,
        runner: any LifecycleProcessRunning = FoundationLifecycleProcessRunner()
    ) {
        self.executablePath = executablePath
        self.runner = runner
    }

    func reload() throws {
        guard executablePath.hasPrefix("/") else { throw LifecycleAgentError.invalidExecutablePath }
        let result: LifecycleProcessResult
        do {
            result = try runner.run(
                executablePath: executablePath,
                arguments: ["--kill", "gpg-agent"]
            )
        } catch {
            throw LifecycleAgentError.processFailed(String(describing: error))
        }
        guard result.status == 0 else {
            throw LifecycleAgentError.unsuccessful(
                status: result.status,
                detail: DiagnosticRedactor.redact(result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

struct FoundationLifecycleProcessRunner: LifecycleProcessRunning {
    func run(executablePath: String, arguments: [String]) throws -> LifecycleProcessResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LifecycleProcessResult(
            status: process.terminationStatus,
            standardError: String(data: data.prefix(8_192), encoding: .utf8) ?? "unreadable stderr"
        )
    }
}
