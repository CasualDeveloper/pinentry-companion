import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleAdapterTests: XCTestCase {
    func testFileSystemTargetRoundTripsExactStates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("gnupg")
        let config = home.appendingPathComponent("gpg-agent.conf")
        let target = FileSystemLifecycleTarget()

        XCTAssertEqual(
            try target.snapshot(canonicalHomePath: home.path, configPath: config.path),
            LifecycleTargetSnapshot(home: .missing, config: .missing)
        )

        try target.applyHome(.directory(mode: 0o700), canonicalHomePath: home.path)
        let expected = LifecycleFileState.file(data: Data("pinentry-program /bin/test\n".utf8), mode: 0o640)
        try target.applyConfig(expected, configPath: config.path)
        XCTAssertEqual(
            try target.snapshot(canonicalHomePath: home.path, configPath: config.path),
            LifecycleTargetSnapshot(home: .directory(mode: 0o700), config: expected)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["gpg-agent.conf"])

        try target.applyConfig(.missing, configPath: config.path)
        try target.applyHome(.missing, canonicalHomePath: home.path)
        XCTAssertEqual(
            try target.snapshot(canonicalHomePath: home.path, configPath: config.path),
            LifecycleTargetSnapshot(home: .missing, config: .missing)
        )
    }

    func testFileSystemTargetRefusesSymlinkedHome() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("real")
        let linkedHome = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)

        XCTAssertThrowsError(
            try FileSystemLifecycleTarget().snapshot(
                canonicalHomePath: linkedHome.path,
                configPath: linkedHome.appendingPathComponent("gpg-agent.conf").path
            )
        ) { error in
            XCTAssertEqual(error as? LifecycleFileSystemError, .symlink(linkedHome.path))
        }
    }

    func testFileSystemTargetRefusesSymlinkedConfig() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("gnupg")
        let config = home.appendingPathComponent("gpg-agent.conf")
        let target = FileSystemLifecycleTarget()
        try target.applyHome(.directory(mode: 0o700), canonicalHomePath: home.path)
        let destination = root.appendingPathComponent("outside")
        try Data("do not touch".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: destination)

        XCTAssertThrowsError(
            try target.snapshot(canonicalHomePath: home.path, configPath: config.path)
        ) { error in
            XCTAssertEqual(error as? LifecycleFileSystemError, .symlink(config.path))
        }
        XCTAssertThrowsError(
            try target.applyConfig(.file(data: Data("replacement".utf8), mode: 0o600), configPath: config.path)
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "do not touch")
    }

    func testFileSystemTargetRejectsConfigOutsideManagedHome() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("gnupg")
        let outside = root.appendingPathComponent("gpg-agent.conf")

        XCTAssertThrowsError(
            try FileSystemLifecycleTarget().snapshot(
                canonicalHomePath: home.path,
                configPath: outside.path
            )
        ) { error in
            XCTAssertEqual(error as? LifecycleFileSystemError, .invalidPaths)
        }
    }

    func testFileSystemTargetRefusesRootLifecycleMutationContext() throws {
        XCTAssertThrowsError(
            try FileSystemLifecycleTarget(effectiveUserID: 0).snapshot(
                canonicalHomePath: "/Users/example/.gnupg",
                configPath: "/Users/example/.gnupg/gpg-agent.conf"
            )
        ) { error in
            XCTAssertEqual(error as? LifecycleFileSystemError, .rootUser)
        }
    }

    func testPreferenceAdapterWritesSynchronizesAndVerifies() throws {
        let backend = RecordingPreferenceBackend(state: .absent)
        let adapter = LifecyclePreferenceStore(backend: backend)

        try adapter.apply(.boolean(true))
        XCTAssertEqual(backend.writes, [true])
        XCTAssertEqual(try adapter.read(), .boolean(true))

        try adapter.apply(.absent)
        XCTAssertEqual(backend.writes, [true, nil])
        XCTAssertEqual(try adapter.read(), .absent)
    }

    func testPreferenceAdapterRejectsUnsupportedWritesAndFailedSynchronization() throws {
        let backend = RecordingPreferenceBackend(state: .absent)
        let adapter = LifecyclePreferenceStore(backend: backend)
        XCTAssertThrowsError(try adapter.apply(.unsupported(type: "String", description: "yes")))

        backend.synchronizeResult = false
        XCTAssertThrowsError(try adapter.apply(.boolean(true))) { error in
            XCTAssertEqual(error as? LifecyclePreferenceError, .synchronizeFailed)
        }
    }

    func testBinaryIdentityHashesResolvedArtifact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("pinentry-companion")
        try Data("binary bytes".utf8).write(to: binary)

        let identity = try LifecycleBinaryIdentity.read(invokedPath: binary.path)

        XCTAssertEqual(identity.invokedPath, binary.path)
        XCTAssertEqual(identity.resolvedPath, binary.resolvingSymlinksInPath().path)
        XCTAssertEqual(identity.sha256, SHA256Digest.hex(Data("binary bytes".utf8)))
        XCTAssertThrowsError(
            try LifecycleBinaryIdentity.read(
                invokedPath: binary.path,
                expectedResolvedPath: "/different/pinentry-companion"
            )
        ) { error in
            XCTAssertEqual(error as? LifecycleBinaryIdentityError, .doesNotMatchRunningBinary)
        }
    }

    func testAgentReloaderUsesExactGPGConfInvocation() throws {
        let runner = RecordingProcessRunner(result: LifecycleProcessResult(status: 0, standardError: ""))
        let reloader = GPGAgentReloader(executablePath: "/opt/homebrew/bin/gpgconf", runner: runner)

        try reloader.reload()

        XCTAssertEqual(runner.invocations, [
            RecordingProcessRunner.Invocation(
                executablePath: "/opt/homebrew/bin/gpgconf",
                arguments: ["--kill", "gpg-agent"]
            ),
        ])
    }

    func testAgentReloaderFailsOnNonzeroExit() throws {
        let runner = RecordingProcessRunner(
            result: LifecycleProcessResult(status: 2, standardError: "reload failed\n")
        )
        let reloader = GPGAgentReloader(executablePath: "/opt/homebrew/bin/gpgconf", runner: runner)

        XCTAssertThrowsError(try reloader.reload()) { error in
            XCTAssertEqual(
                error as? LifecycleAgentError,
                .unsuccessful(status: 2, detail: "reload failed")
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporaryPath, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("pinentry-lifecycle-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }
}

private final class RecordingPreferenceBackend: LifecyclePreferenceBacking {
    var state: LifecyclePreferenceState
    var writes: [Bool?] = []
    var synchronizeResult = true

    init(state: LifecyclePreferenceState) {
        self.state = state
    }

    func read() -> LifecyclePreferenceState { state }

    func write(_ value: Bool?) {
        writes.append(value)
        state = value.map(LifecyclePreferenceState.boolean) ?? .absent
    }

    func synchronize() -> Bool { synchronizeResult }
}

private final class RecordingProcessRunner: LifecycleProcessRunning {
    struct Invocation: Equatable {
        var executablePath: String
        var arguments: [String]
    }

    var result: LifecycleProcessResult
    var invocations: [Invocation] = []

    init(result: LifecycleProcessResult) {
        self.result = result
    }

    func run(executablePath: String, arguments: [String]) throws -> LifecycleProcessResult {
        invocations.append(Invocation(executablePath: executablePath, arguments: arguments))
        return result
    }
}
