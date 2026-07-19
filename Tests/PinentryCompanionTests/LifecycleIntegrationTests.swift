import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleIntegrationTests: XCTestCase {
    func testRealFileStateAndLockAdaptersSetupThenRestoreWithoutExternalEffects() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("gnupg", isDirectory: true)
        let config = home.appendingPathComponent("gpg-agent.conf")
        let stateRoot = root.appendingPathComponent("lifecycle-state", isDirectory: true)
        let preference = IntegrationPreference()
        let agent = IntegrationAgent()
        let manager = LifecycleManager(
            target: FileSystemLifecycleTarget(),
            preference: preference,
            agent: agent,
            state: LifecycleStateStore(rootURL: stateRoot),
            locks: LifecycleLockProvider(rootURL: stateRoot),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let request = LifecycleSetupRequest(
            canonicalHomePath: home.path,
            configPath: config.path,
            binary: LifecycleBinaryIdentity(
                invokedPath: "/opt/homebrew/bin/pinentry-companion",
                resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
                sha256: String(repeating: "a", count: 64)
            ),
            takeOver: false
        )

        XCTAssertEqual(try manager.setup(request), .changed)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            "pinentry-program /opt/homebrew/bin/pinentry-companion\n"
        )
        XCTAssertEqual(preference.state, .boolean(true))
        XCTAssertEqual(agent.reloadCount, 1)
        XCTAssertEqual(
            try LifecycleStateStore(rootURL: stateRoot).load(canonicalHomePath: home.path)?.phase,
            .complete
        )

        XCTAssertEqual(try manager.restore(canonicalHomePath: home.path), .restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertEqual(preference.state, .absent)
        XCTAssertEqual(agent.reloadCount, 2)
        XCTAssertEqual(
            try LifecycleStateStore(rootURL: stateRoot).load(canonicalHomePath: home.path)?.phase,
            .restored
        )
    }

    private func temporaryDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporaryPath, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("pinentry-lifecycle-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return root
    }
}

private final class IntegrationPreference: LifecyclePreferenceManaging {
    var state: LifecyclePreferenceState = .absent
    func read() throws -> LifecyclePreferenceState { state }
    func apply(_ state: LifecyclePreferenceState) throws { self.state = state }
}

private final class IntegrationAgent: LifecycleAgentReloading {
    var reloadCount = 0
    func reload() throws { reloadCount += 1 }
}
