import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class PassiveManagementTests: XCTestCase {
    func testVersionIsSharedByGETINFOAndManagementEnvelope() throws {
        let envelope = PassiveStatusBuilder.build(snapshot: configuredSnapshot())
        let infoVersion = try PinentryInfo.value(for: "version")

        XCTAssertEqual(ComponentVersion.current, "0.2.0")
        XCTAssertEqual(infoVersion, ComponentVersion.current)
        XCTAssertEqual(envelope.componentVersion, ComponentVersion.current)
    }

    func testConfiguredStatusMatchesGoldenFixture() throws {
        let envelope = PassiveStatusBuilder.build(snapshot: configuredSnapshot())
        try assertJSON(envelope, matchesFixture: "status/configured.json")
    }

    func testMissingStatusMatchesGoldenFixture() throws {
        let snapshot = PassiveSnapshot(
            invokedPath: "/opt/homebrew/bin/pinentry-companion",
            resolvedPath: "/opt/homebrew/bin/pinentry-companion",
            architecture: "arm64",
            userHomePath: "/Users/example",
            homePath: "/Users/example/.gnupg",
            configPath: "/Users/example/.gnupg/gpg-agent.conf",
            configContents: .missing,
            dependencyPaths: [:],
            preferenceState: .absent,
            authenticationPolicyMode: "companion/biometry, with device-owner fallback"
        )

        try assertJSON(PassiveStatusBuilder.build(snapshot: snapshot), matchesFixture: "status/missing.json")
    }

    func testNoChangePlanMatchesGoldenFixture() throws {
        try assertJSON(PassivePlanBuilder.build(snapshot: configuredSnapshot()), matchesFixture: "plan/no-change.json")
    }

    func testNoChangeDirectivePlanPreservesEquivalentConfiguredPath() throws {
        let configuredPath = "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion"
        let contents = "pinentry-program \(configuredPath)\n"

        let plan = try GPGDirectivePlanner.plan(
            contents: contents,
            exists: true,
            invokedPath: "/opt/homebrew/opt/pinentry-companion/bin/pinentry-companion",
            resolvedPath: configuredPath,
            allowTakeover: false
        )

        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.updatedContents, contents)
    }

    func testNoChangePlanReportsThePreservedEquivalentPath() {
        var snapshot = configuredSnapshot()
        let configuredPath = "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion"
        snapshot.invokedPath = "/opt/homebrew/opt/pinentry-companion/bin/pinentry-companion"
        snapshot.resolvedPath = configuredPath
        snapshot.configContents = .readable("pinentry-program \(configuredPath)\n")

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.state.gpgConfiguration.action, .none)
        XCTAssertFalse(envelope.state.changeRequired)
        XCTAssertEqual(envelope.state.gpgConfiguration.afterValue, configuredPath)
    }

    func testCreatePlanMatchesGoldenFixture() throws {
        var snapshot = configuredSnapshot()
        snapshot.resolvedPath = "/opt/homebrew/bin/pinentry-companion"
        snapshot.configContents = .missing
        snapshot.dependencyPaths = [:]
        snapshot.preferenceState = .absent

        try assertJSON(PassivePlanBuilder.build(snapshot: snapshot), matchesFixture: "plan/create.json")
    }

    func testForeignPlanMatchesGoldenFixture() throws {
        var snapshot = configuredSnapshot()
        snapshot.resolvedPath = "/opt/homebrew/bin/pinentry-companion"
        snapshot.configContents = .readable("pinentry-program /usr/local/bin/foreign-pinentry\n")
        snapshot.preferenceState = .disabled

        try assertJSON(PassivePlanBuilder.build(snapshot: snapshot), matchesFixture: "plan/foreign-conflict.json")
    }

    func testDuplicateCurrentDirectivesPlanDeduplication() {
        var snapshot = configuredSnapshot()
        snapshot.configContents = .readable("""
        pinentry-program /opt/homebrew/bin/pinentry-companion
        pinentry-program /opt/homebrew/bin/pinentry-companion
        """)

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .warning)
        XCTAssertEqual(envelope.state.gpgConfiguration.action, .deduplicate)
        XCTAssertEqual(envelope.state.gpgConfiguration.beforeOccurrenceCount, 2)
        XCTAssertEqual(envelope.state.gpgConfiguration.afterOccurrenceCount, 1)
    }

    func testWrongTypePreferenceBlocksPlan() {
        var snapshot = configuredSnapshot()
        snapshot.preferenceState = .wrongType

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .conflict)
        XCTAssertEqual(envelope.state.applicability, .blocked)
        XCTAssertEqual(envelope.state.disableKeychainPreference.action, .blocked)
        XCTAssertEqual(envelope.state.conflicts.map(\.code), ["preferenceWrongType"])
    }

    func testFirstSetupPlanRecordsThatRestoreStateWillBeCreated() {
        var snapshot = configuredSnapshot()
        snapshot.configContents = .missing
        snapshot.preferenceState = .absent

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertTrue(envelope.state.gpgConfiguration.reversible.supported)
        XCTAssertEqual(
            envelope.state.gpgConfiguration.reversible.reason,
            "ownershipRecordWillBeCreated"
        )
        XCTAssertEqual(
            envelope.state.disableKeychainPreference.reversible,
            envelope.state.gpgConfiguration.reversible
        )
    }

    func testPreferenceOnlyChangeReportsRequiredReload() {
        var snapshot = configuredSnapshot()
        snapshot.preferenceState = .disabled

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.state.gpgConfiguration.action, .none)
        XCTAssertEqual(envelope.state.disableKeychainPreference.action, .set)
        XCTAssertTrue(envelope.state.gpgConfiguration.requiresReload)
    }

    func testMissingApplyDependenciesBlockAChangingPlan() {
        var snapshot = configuredSnapshot()
        snapshot.configContents = .missing
        snapshot.preferenceState = .absent
        snapshot.dependencyPaths = [:]

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .conflict)
        XCTAssertEqual(envelope.state.applicability, .blocked)
        XCTAssertEqual(
            envelope.state.conflicts.map(\.code),
            ["gpgconfMissing", "fallbackPinentryMissing"]
        )
        XCTAssertEqual(
            envelope.diagnostics.map(\.code),
            ["dependency.gpgconf.missing", "dependency.fallbackPinentry.missing"]
        )
    }

    func testStatusReportsMissingRuntimeAndLifecycleDependencies() {
        var snapshot = configuredSnapshot()
        snapshot.dependencyPaths = [:]

        let envelope = PassiveStatusBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertTrue(envelope.diagnostics.contains { $0.code == "dependency.gpgconf.missing" })
        XCTAssertTrue(envelope.diagnostics.contains { $0.code == "dependency.fallbackPinentry.missing" })
    }

    func testManagedStatusReportsOwnershipRecoveryAndExactDriftState() {
        var snapshot = configuredSnapshot()
        let record = managedRecord(
            config: "pinentry-program /opt/homebrew/bin/pinentry-companion\n"
        )
        snapshot.lifecycle = .tracked(
            record: record,
            current: LifecycleTargetSnapshot(
                home: record.expectedHome,
                config: record.expectedConfig
            )
        )

        let envelope = PassiveStatusBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.state.gpgConfiguration.ownership, "managed")
        XCTAssertEqual(envelope.state.gpgConfiguration.drift, "inSync")
        XCTAssertTrue(envelope.state.gpgConfiguration.recoveryAvailable)
    }

    func testManagedBinaryUpgradePlanIsReversibleAndNotAForeignConflict() {
        var snapshot = configuredSnapshot()
        let oldConfig = "pinentry-program /opt/homebrew/bin/pinentry-companion\n"
        let record = managedRecord(config: oldConfig)
        snapshot.invokedPath = "/usr/local/bin/pinentry-companion"
        snapshot.resolvedPath = "/usr/local/Cellar/pinentry-companion/0.3.0/bin/pinentry-companion"
        snapshot.configContents = .readable(oldConfig)
        snapshot.lifecycle = .tracked(
            record: record,
            current: LifecycleTargetSnapshot(home: record.expectedHome, config: record.expectedConfig)
        )

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.state.gpgConfiguration.action, .replace)
        XCTAssertTrue(envelope.state.conflicts.isEmpty)
        XCTAssertTrue(envelope.state.gpgConfiguration.reversible.supported)
        XCTAssertEqual(
            envelope.state.gpgConfiguration.reversible.reason,
            "ownershipRecordAvailable"
        )
    }

    func testManagedStatusReportsUnrecognizedDriftAsError() {
        var snapshot = configuredSnapshot()
        let record = managedRecord(
            config: "pinentry-program /opt/homebrew/bin/pinentry-companion\n"
        )
        snapshot.lifecycle = .tracked(
            record: record,
            current: LifecycleTargetSnapshot(
                home: record.expectedHome,
                config: .file(data: Data("# user edit\n".utf8), mode: 0o600)
            )
        )

        let envelope = PassiveStatusBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.state.gpgConfiguration.drift, "drifted")
        XCTAssertTrue(envelope.diagnostics.contains { $0.code == "lifecycle.managedStateDrifted" })
    }

    func testRestoredStatusAcceptsManagedPreferenceOwnedByAnotherHome() {
        var snapshot = configuredSnapshot()
        var record = managedRecord(
            config: "pinentry-program /opt/homebrew/bin/pinentry-companion\n"
        )
        record.phase = .restored
        snapshot.configContents = .missing
        snapshot.preferenceState = .enabled
        snapshot.lifecycle = .tracked(
            record: record,
            current: LifecycleTargetSnapshot(home: record.originalHome, config: record.originalConfig)
        )
        snapshot.otherHomeRequiresManagedPreference = true

        let envelope = PassiveStatusBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.state.gpgConfiguration.ownership, "released")
        XCTAssertEqual(envelope.state.gpgConfiguration.drift, "inSync")
    }

    func testUnreadableOwnershipRecordBlocksPlan() {
        var snapshot = configuredSnapshot()
        snapshot.lifecycle = .unreadable

        let envelope = PassivePlanBuilder.build(snapshot: snapshot)

        XCTAssertEqual(envelope.outcome, .conflict)
        XCTAssertEqual(envelope.state.applicability, .blocked)
        XCTAssertEqual(envelope.state.gpgConfiguration.action, .blocked)
        XCTAssertEqual(envelope.state.conflicts.map(\.code), ["ownershipRecordUnreadable"])
        XCTAssertEqual(
            envelope.state.gpgConfiguration.reversible.reason,
            "ownershipRecordUnreadable"
        )
    }

    func testPassiveCommandsReadOnceAndEncodeOneDocument() throws {
        let reader = RecordingSnapshotReader(snapshot: configuredSnapshot())

        for operation in [PassiveOperation.status, .plan] {
            let result = PassiveCommand.run(operation: operation, reader: reader)
            let object = try JSONSerialization.jsonObject(with: result.data)

            XCTAssertTrue(object is [String: Any])
            XCTAssertEqual(result.status, 0)
        }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testLiveReaderDoesNotExecuteDependencySentinelOrReadRealPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinentry-passive-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let gpgHome = root.appendingPathComponent("gnupg", isDirectory: true)
        let sentinel = root.appendingPathComponent("launched")
        let executable = bin.appendingPathComponent("gpgconf")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gpgHome, withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch \"\(sentinel.path)\"\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, S_IRWXU), 0)
        try Data("pinentry-program /opt/homebrew/bin/pinentry-companion\n".utf8)
            .write(to: gpgHome.appendingPathComponent("gpg-agent.conf"))
        defer { try? FileManager.default.removeItem(at: root) }

        let preference = RecordingPreferenceReader(state: .enabled)
        let reader = LivePassiveSnapshotReader(
            executablePath: "/opt/homebrew/bin/pinentry-companion",
            environment: [
                "HOME": root.path,
                "GNUPGHOME": gpgHome.path,
                "PATH": bin.path,
            ],
            preferenceReader: preference,
            lifecycleStateRootURL: root.appendingPathComponent("state-v1")
        )

        _ = reader.read()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(preference.readCount, 1)
    }

    func testEncodingFailureDocumentsRemainOperationSchemas() throws {
        let status = try JSONSerialization.jsonObject(
            with: PassiveCommand.encodingFailureData(operation: .status)
        ) as? [String: Any]
        let plan = try JSONSerialization.jsonObject(
            with: PassiveCommand.encodingFailureData(operation: .plan)
        ) as? [String: Any]

        XCTAssertEqual(status?["operation"] as? String, "status")
        XCTAssertEqual(Set((status?["state"] as? [String: Any])?.keys.map { $0 } ?? []), Set([
            "binary", "gpgConfiguration", "dependencies", "localAuthentication", "cache", "disableKeychainPreference",
        ]))
        XCTAssertEqual(plan?["operation"] as? String, "plan")
        XCTAssertEqual(Set((plan?["state"] as? [String: Any])?.keys.map { $0 } ?? []), Set([
            "applicability", "changeRequired", "gpgConfiguration", "disableKeychainPreference", "conflicts",
        ]))
    }

    private func configuredSnapshot() -> PassiveSnapshot {
        PassiveSnapshot(
            invokedPath: "/opt/homebrew/bin/pinentry-companion",
            resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
            architecture: "arm64",
            userHomePath: "/Users/example",
            homePath: "/Users/example/.gnupg",
            configPath: "/Users/example/.gnupg/gpg-agent.conf",
            configContents: .readable("pinentry-program /opt/homebrew/bin/pinentry-companion\n"),
            dependencyPaths: [
                "gpgconf": "/opt/homebrew/bin/gpgconf",
                "pinentry-mac": "/opt/homebrew/bin/pinentry-mac",
            ],
            preferenceState: .enabled,
            authenticationPolicyMode: "companion/biometry, with device-owner fallback"
        )
    }

    private func managedRecord(config: String) -> LifecycleRecord {
        LifecycleRecord(
            schemaVersion: 1,
            componentVersion: ComponentVersion.current,
            canonicalHomePath: "/Users/example/.gnupg",
            configPath: "/Users/example/.gnupg/gpg-agent.conf",
            binary: LifecycleBinaryIdentity(
                invokedPath: "/opt/homebrew/bin/pinentry-companion",
                resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
                sha256: String(repeating: "a", count: 64)
            ),
            originalConfig: .missing,
            expectedConfig: .file(data: Data(config.utf8), mode: 0o600),
            originalHome: .directory(mode: 0o700),
            expectedHome: .directory(mode: 0o700),
            originalPreference: .absent,
            expectedPreference: .boolean(true),
            transactionBaseConfig: .missing,
            transactionBaseHome: .directory(mode: 0o700),
            transactionBasePreference: .absent,
            phase: .complete,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func assertJSON<T: Encodable>(_ value: T, matchesFixture relativePath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let actual = try canonicalJSON(encoder.encode(value))
        let expected = try canonicalJSON(Data(contentsOf: fixtureURL(relativePath)))
        XCTAssertEqual(actual, expected)
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contracts/Fixtures/\(relativePath)")
    }
}

private final class RecordingSnapshotReader: PassiveSnapshotReading {
    private let snapshot: PassiveSnapshot
    var readCount = 0

    init(snapshot: PassiveSnapshot) {
        self.snapshot = snapshot
    }

    func read() -> PassiveSnapshot {
        readCount += 1
        return snapshot
    }
}

private final class RecordingPreferenceReader: PassivePreferenceReading {
    private let state: PreferenceState
    var readCount = 0

    init(state: PreferenceState) {
        self.state = state
    }

    func readDisableKeychainPreference() -> PreferenceState {
        readCount += 1
        return state
    }
}
