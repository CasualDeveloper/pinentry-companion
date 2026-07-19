import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleManagerTests: XCTestCase {
    func testSetupRecordsOwnershipAndAppliesExpectedState() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o755)
        fixture.target.config = .missing
        fixture.preference.state = .absent

        let result = try fixture.manager.setup(fixture.request())

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(fixture.target.home, .directory(mode: 0o755))
        XCTAssertEqual(fixture.target.config, fixture.expectedConfig)
        XCTAssertEqual(fixture.preference.state, .boolean(true))
        XCTAssertEqual(fixture.agent.reloadCount, 1)
        XCTAssertEqual(fixture.state.records.map(\.phase), [
            .prepared, .configApplied, .preferenceApplied, .agentReloaded, .complete,
        ])
        XCTAssertEqual(fixture.state.current?.originalConfig, .missing)
        XCTAssertEqual(fixture.state.current?.originalHome, .directory(mode: 0o755))
        XCTAssertEqual(fixture.state.current?.expectedHome, .directory(mode: 0o755))
        XCTAssertEqual(fixture.state.current?.originalPreference, .absent)
    }

    func testRepeatedSetupIsIdempotent() throws {
        let fixture = Fixture()
        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .changed)
        let operationCount = fixture.target.operations.count
        let reloadCount = fixture.agent.reloadCount

        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .unchanged)
        XCTAssertEqual(fixture.target.operations.count, operationCount)
        XCTAssertEqual(fixture.agent.reloadCount, reloadCount)
    }

    func testForeignPinentryRequiresExplicitTakeover() throws {
        let fixture = Fixture()
        fixture.target.config = .file(
            data: Data("pinentry-program /usr/local/bin/foreign\n".utf8),
            mode: 0o600
        )

        XCTAssertThrowsError(try fixture.manager.setup(fixture.request())) { error in
            XCTAssertEqual(error as? LifecycleError, .foreignConfiguration)
        }
        XCTAssertTrue(fixture.target.operations.isEmpty)
        XCTAssertTrue(fixture.state.records.isEmpty)

        XCTAssertEqual(try fixture.manager.setup(fixture.request(takeOver: true)), .changed)
        XCTAssertEqual(fixture.target.config, fixture.expectedConfig)
        XCTAssertEqual(
            fixture.state.current?.originalConfig,
            .file(data: Data("pinentry-program /usr/local/bin/foreign\n".utf8), mode: 0o600)
        )
    }

    func testUnsupportedPreferenceTypeBlocksBeforeMutation() throws {
        let fixture = Fixture()
        fixture.preference.state = .unsupported(type: "CFString", description: "yes")

        XCTAssertThrowsError(try fixture.manager.setup(fixture.request())) { error in
            XCTAssertEqual(error as? LifecycleError, .unsupportedPreference)
        }
        XCTAssertTrue(fixture.target.operations.isEmpty)
        XCTAssertTrue(fixture.preference.operations.isEmpty)
        XCTAssertTrue(fixture.state.records.isEmpty)
    }

    func testPreferenceFailureRollsBackConfigAndHome() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o755)
        fixture.target.config = .missing
        fixture.preference.state = .absent
        fixture.preference.failNextApply = true

        XCTAssertThrowsError(try fixture.manager.setup(fixture.request())) { error in
            XCTAssertEqual(error as? LifecycleError, .operationFailed("preference write failed"))
        }
        XCTAssertEqual(fixture.target.home, .directory(mode: 0o755))
        XCTAssertEqual(fixture.target.config, .missing)
        XCTAssertEqual(fixture.preference.state, .absent)
        XCTAssertEqual(fixture.state.current?.phase, .rolledBack)
        XCTAssertEqual(fixture.agent.reloadCount, 1)
    }

    func testReloadFailureRollsBackAndReloadsOriginalState() throws {
        let fixture = Fixture()
        fixture.agent.failuresRemaining = 1

        XCTAssertThrowsError(try fixture.manager.setup(fixture.request())) { error in
            XCTAssertEqual(error as? LifecycleError, .operationFailed("agent reload failed"))
        }
        XCTAssertEqual(fixture.target.config, .missing)
        XCTAssertEqual(fixture.preference.state, .absent)
        XCTAssertEqual(fixture.state.current?.phase, .rolledBack)
        XCTAssertEqual(fixture.agent.reloadCount, 2)
    }

    func testRestoreUsesCompareAndSwapAndIsIdempotent() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o755)
        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .changed)

        XCTAssertEqual(
            try fixture.manager.restore(canonicalHomePath: fixture.homePath),
            .restored
        )
        XCTAssertEqual(fixture.target.home, .directory(mode: 0o755))
        XCTAssertEqual(fixture.target.config, .missing)
        XCTAssertEqual(fixture.preference.state, .absent)
        XCTAssertEqual(fixture.state.current?.phase, .restored)
        let operationCount = fixture.target.operations.count

        XCTAssertEqual(
            try fixture.manager.restore(canonicalHomePath: fixture.homePath),
            .unchanged
        )
        XCTAssertEqual(fixture.target.operations.count, operationCount)
    }

    func testNoOpRestoreStillFinalizesLifecycleOwnership() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o700)
        fixture.target.config = fixture.expectedConfig
        fixture.preference.state = .boolean(true)

        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .unchanged)
        XCTAssertEqual(fixture.state.current?.phase, .complete)
        XCTAssertEqual(
            try fixture.manager.previewRestore(canonicalHomePath: fixture.homePath),
            .unchanged
        )

        XCTAssertEqual(
            try fixture.manager.restore(canonicalHomePath: fixture.homePath),
            .restored
        )
        XCTAssertEqual(fixture.state.current?.phase, .restored)
    }

    func testUninstallPreparationBlocksOriginalConfigurationThatStillUsesManagedBinary() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o700)
        fixture.target.config = fixture.expectedConfig
        fixture.preference.state = .boolean(true)
        let removingBinary = fixture.request().binary
        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .unchanged)
        let saveCount = fixture.state.saveCallCount

        XCTAssertThrowsError(try fixture.manager.previewUninstallPreparation(
            canonicalHomePath: fixture.homePath,
            removingBinary: removingBinary
        )) { error in
            XCTAssertEqual(
                error as? LifecycleError,
                .uninstallWouldLeaveActiveConfiguration
            )
        }
        XCTAssertThrowsError(try fixture.manager.prepareUninstall(
            canonicalHomePath: fixture.homePath,
            removingBinary: removingBinary
        )) { error in
            XCTAssertEqual(
                error as? LifecycleError,
                .uninstallWouldLeaveActiveConfiguration
            )
        }
        XCTAssertEqual(fixture.state.saveCallCount, saveCount)
        XCTAssertEqual(fixture.state.current?.phase, .complete)
    }

    func testUninstallPreparationRestoresForeignOriginalConfiguration() throws {
        let fixture = Fixture()
        let foreign = LifecycleFileState.file(
            data: Data("pinentry-program /usr/local/bin/foreign-pinentry\n".utf8),
            mode: 0o600
        )
        fixture.target.config = foreign
        let removingBinary = fixture.request().binary
        XCTAssertEqual(try fixture.manager.setup(fixture.request(takeOver: true)), .changed)

        XCTAssertEqual(
            try fixture.manager.previewUninstallPreparation(
                canonicalHomePath: fixture.homePath,
                removingBinary: removingBinary
            ),
            .restored
        )
        XCTAssertEqual(
            try fixture.manager.prepareUninstall(
                canonicalHomePath: fixture.homePath,
                removingBinary: removingBinary
            ),
            .restored
        )
        XCTAssertEqual(fixture.target.config, foreign)
        XCTAssertEqual(fixture.state.current?.phase, .restored)
    }

    func testRestoreRefusesConfigurationDriftWithoutWriting() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        fixture.target.config = .file(data: Data("# user changed this\n".utf8), mode: 0o600)
        let operationCount = fixture.target.operations.count

        XCTAssertThrowsError(try fixture.manager.restore(canonicalHomePath: fixture.homePath)) { error in
            XCTAssertEqual(error as? LifecycleError, .drift("gpg-agent.conf"))
        }
        XCTAssertEqual(fixture.target.operations.count, operationCount)
        XCTAssertEqual(fixture.state.current?.phase, .complete)
    }

    func testRestorePreviewIsReadOnlyAndUsesTheSameDriftGate() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        let recordCount = fixture.state.records.count
        let operationCount = fixture.target.operations.count
        let reloadCount = fixture.agent.reloadCount

        XCTAssertEqual(
            try fixture.manager.previewRestore(canonicalHomePath: fixture.homePath),
            .restored
        )
        XCTAssertEqual(fixture.state.records.count, recordCount)
        XCTAssertEqual(fixture.target.operations.count, operationCount)
        XCTAssertEqual(fixture.agent.reloadCount, reloadCount)

        fixture.target.config = .file(data: Data("# drift\n".utf8), mode: 0o600)
        XCTAssertThrowsError(try fixture.manager.previewRestore(canonicalHomePath: fixture.homePath)) { error in
            XCTAssertEqual(error as? LifecycleError, .drift("gpg-agent.conf"))
        }
        XCTAssertEqual(fixture.state.records.count, recordCount)
    }

    func testSetupPersistenceFailureStillRollsBackWhenRollbackMarkerAlsoFails() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o755)
        fixture.state.failOnSaveCalls = [2, 3]

        XCTAssertThrowsError(try fixture.manager.setup(fixture.request())) { error in
            XCTAssertEqual(error as? LifecycleError, .operationFailed("state save failed"))
        }
        XCTAssertEqual(fixture.target.home, .directory(mode: 0o755))
        XCTAssertEqual(fixture.target.config, .missing)
        XCTAssertEqual(fixture.preference.state, .absent)
        XCTAssertEqual(fixture.state.current?.phase, .rolledBack)
    }

    func testRestoreFailureRollsBackToManagedState() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        fixture.preference.failNextApply = true

        XCTAssertThrowsError(try fixture.manager.restore(canonicalHomePath: fixture.homePath)) { error in
            XCTAssertEqual(error as? LifecycleError, .operationFailed("preference write failed"))
        }
        XCTAssertEqual(fixture.target.config, fixture.expectedConfig)
        XCTAssertEqual(fixture.preference.state, .boolean(true))
        XCTAssertEqual(fixture.state.current?.phase, .complete)
    }

    func testRestorePersistenceFailureRollsBackToManagedState() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        fixture.state.failOnSaveCalls = [fixture.state.saveCallCount + 2]

        XCTAssertThrowsError(try fixture.manager.restore(canonicalHomePath: fixture.homePath)) { error in
            XCTAssertEqual(error as? LifecycleError, .operationFailed("state save failed"))
        }
        XCTAssertEqual(fixture.target.config, fixture.expectedConfig)
        XCTAssertEqual(fixture.preference.state, .boolean(true))
        XCTAssertEqual(fixture.state.current?.phase, .complete)
    }

    func testInterruptedSetupIsRecoveredBeforeRetry() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        var interrupted = try XCTUnwrap(fixture.state.current)
        interrupted.phase = .configApplied
        fixture.state.records = [interrupted]
        fixture.target.config = interrupted.expectedConfig
        fixture.preference.state = interrupted.originalPreference

        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .changed)
        XCTAssertEqual(fixture.target.config, fixture.expectedConfig)
        XCTAssertEqual(fixture.preference.state, .boolean(true))
        XCTAssertEqual(fixture.state.current?.phase, .complete)
    }

    func testInterruptedRestoreIsResumed() throws {
        let fixture = Fixture()
        fixture.target.home = .directory(mode: 0o755)
        _ = try fixture.manager.setup(fixture.request())
        var interrupted = try XCTUnwrap(fixture.state.current)
        interrupted.phase = .configRestored
        fixture.state.records = [interrupted]
        fixture.target.config = interrupted.originalConfig

        XCTAssertEqual(
            try fixture.manager.restore(canonicalHomePath: fixture.homePath),
            .restored
        )
        XCTAssertEqual(fixture.target.home, interrupted.originalHome)
        XCTAssertEqual(fixture.target.config, interrupted.originalConfig)
        XCTAssertEqual(fixture.preference.state, interrupted.originalPreference)
        XCTAssertEqual(fixture.state.current?.phase, .restored)
    }

    func testManagedBinaryUpgradePreservesTheOriginalRestorePoint() throws {
        let fixture = Fixture()
        let originalConfig = LifecycleFileState.file(
            data: Data("# original\n".utf8),
            mode: 0o640
        )
        fixture.target.config = originalConfig
        _ = try fixture.manager.setup(fixture.request())

        let upgraded = fixture.request(
            invokedPath: "/usr/local/bin/pinentry-companion",
            resolvedPath: "/usr/local/Cellar/pinentry-companion/0.3.0/bin/pinentry-companion",
            digest: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(try fixture.manager.setup(upgraded), .changed)
        XCTAssertEqual(fixture.state.current?.originalConfig, originalConfig)

        XCTAssertEqual(try fixture.manager.restore(canonicalHomePath: fixture.homePath), .restored)
        XCTAssertEqual(fixture.target.config, originalConfig)
    }

    func testFailedManagedBinaryUpgradeRollsBackToPreviousManagedBinary() throws {
        let fixture = Fixture()
        _ = try fixture.manager.setup(fixture.request())
        let previousManagedConfig = fixture.target.config
        fixture.agent.failuresRemaining = 1

        let upgraded = fixture.request(
            invokedPath: "/usr/local/bin/pinentry-companion",
            resolvedPath: "/usr/local/Cellar/pinentry-companion/0.3.0/bin/pinentry-companion",
            digest: String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(try fixture.manager.setup(upgraded))
        XCTAssertEqual(fixture.target.config, previousManagedConfig)
        XCTAssertEqual(fixture.preference.state, .boolean(true))
        XCTAssertEqual(fixture.state.current?.phase, .rolledBack)
        XCTAssertEqual(fixture.state.current?.transactionBaseConfig, previousManagedConfig)
    }

    func testAdditionalHomeInheritsGlobalPreferenceBaselineAndDoesNotRestoreItEarly() throws {
        let firstHome = "/Users/example/.gnupg"
        let secondHome = "/Users/example/.gnupg-work"
        let firstRecord = managedRecord(
            homePath: firstHome,
            originalPreference: .absent,
            phase: .complete
        )
        let state = SuiteStateStore(records: [firstRecord])
        let target = RecordingTarget()
        let preference = RecordingPreference()
        preference.state = .boolean(true)
        let agent = RecordingAgent()
        let manager = LifecycleManager(
            target: target,
            preference: preference,
            agent: agent,
            state: state,
            locks: RecordingLockProvider(),
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let request = LifecycleSetupRequest(
            canonicalHomePath: secondHome,
            configPath: "\(secondHome)/gpg-agent.conf",
            binary: LifecycleBinaryIdentity(
                invokedPath: "/opt/homebrew/bin/pinentry-companion",
                resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
                sha256: String(repeating: "b", count: 64)
            ),
            takeOver: false
        )

        XCTAssertEqual(try manager.setup(request), .changed)
        let secondRecord = try XCTUnwrap(state.recordsByHome[secondHome])
        XCTAssertEqual(secondRecord.originalPreference, .absent)
        XCTAssertEqual(secondRecord.transactionBasePreference, .boolean(true))

        XCTAssertEqual(try manager.restore(canonicalHomePath: secondHome), .restored)
        XCTAssertEqual(preference.state, .boolean(true))
        XCTAssertEqual(state.recordsByHome[secondHome]?.phase, .restored)

        let firstTarget = RecordingTarget()
        firstTarget.home = firstRecord.expectedHome
        firstTarget.config = firstRecord.expectedConfig
        let firstManager = LifecycleManager(
            target: firstTarget,
            preference: preference,
            agent: agent,
            state: state,
            locks: RecordingLockProvider(),
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )

        XCTAssertEqual(try firstManager.restore(canonicalHomePath: firstHome), .restored)
        XCTAssertEqual(preference.state, .absent)
    }

    func testSetupAfterCompletedRestoreStartsANewRestoreEpoch() throws {
        let fixture = Fixture()
        fixture.target.config = .file(data: Data("# first baseline\n".utf8), mode: 0o600)
        _ = try fixture.manager.setup(fixture.request())
        _ = try fixture.manager.restore(canonicalHomePath: fixture.homePath)

        let newBaseline = LifecycleFileState.file(data: Data("# new baseline\n".utf8), mode: 0o640)
        fixture.target.config = newBaseline
        fixture.preference.state = .boolean(false)

        XCTAssertEqual(try fixture.manager.setup(fixture.request()), .changed)
        XCTAssertEqual(fixture.state.current?.originalConfig, newBaseline)
        XCTAssertEqual(fixture.state.current?.originalPreference, .boolean(false))
    }

    private func managedRecord(
        homePath: String,
        originalPreference: LifecyclePreferenceState,
        phase: LifecyclePhase
    ) -> LifecycleRecord {
        LifecycleRecord(
            schemaVersion: 1,
            componentVersion: ComponentVersion.current,
            canonicalHomePath: homePath,
            configPath: "\(homePath)/gpg-agent.conf",
            binary: LifecycleBinaryIdentity(
                invokedPath: "/opt/homebrew/bin/pinentry-companion",
                resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
                sha256: String(repeating: "a", count: 64)
            ),
            originalConfig: .missing,
            expectedConfig: .file(
                data: Data("pinentry-program /opt/homebrew/bin/pinentry-companion\n".utf8),
                mode: 0o600
            ),
            originalHome: .directory(mode: 0o700),
            expectedHome: .directory(mode: 0o700),
            originalPreference: originalPreference,
            expectedPreference: .boolean(true),
            transactionBaseConfig: .missing,
            transactionBaseHome: .directory(mode: 0o700),
            transactionBasePreference: originalPreference,
            phase: phase,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class Fixture {
    let homePath = "/Users/example/.gnupg"
    let configPath = "/Users/example/.gnupg/gpg-agent.conf"
    let target = RecordingTarget()
    let preference = RecordingPreference()
    let agent = RecordingAgent()
    let state = RecordingStateStore()
    let locks = RecordingLockProvider()
    lazy var manager = LifecycleManager(
        target: target,
        preference: preference,
        agent: agent,
        state: state,
        locks: locks,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    var expectedConfig: LifecycleFileState {
        .file(
            data: Data("pinentry-program /opt/homebrew/bin/pinentry-companion\n".utf8),
            mode: 0o600
        )
    }

    func request(
        takeOver: Bool = false,
        invokedPath: String = "/opt/homebrew/bin/pinentry-companion",
        resolvedPath: String = "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
        digest: String = String(repeating: "a", count: 64)
    ) -> LifecycleSetupRequest {
        LifecycleSetupRequest(
            canonicalHomePath: homePath,
            configPath: configPath,
            binary: LifecycleBinaryIdentity(
                invokedPath: invokedPath,
                resolvedPath: resolvedPath,
                sha256: digest
            ),
            takeOver: takeOver
        )
    }
}

private final class RecordingTarget: LifecycleTargetManaging {
    var home: LifecycleHomeState = .missing
    var config: LifecycleFileState = .missing
    var operations: [String] = []

    func snapshot(canonicalHomePath: String, configPath: String) throws -> LifecycleTargetSnapshot {
        LifecycleTargetSnapshot(home: home, config: config)
    }

    func applyHome(_ state: LifecycleHomeState, canonicalHomePath: String) throws {
        operations.append("home")
        home = state
    }

    func applyConfig(_ state: LifecycleFileState, configPath: String) throws {
        operations.append("config")
        config = state
    }
}

private final class RecordingPreference: LifecyclePreferenceManaging {
    var state: LifecyclePreferenceState = .absent
    var operations: [LifecyclePreferenceState] = []
    var failNextApply = false

    func read() throws -> LifecyclePreferenceState { state }

    func apply(_ newState: LifecyclePreferenceState) throws {
        operations.append(newState)
        if failNextApply {
            failNextApply = false
            throw LifecycleTestFailure("preference write failed")
        }
        state = newState
    }
}

private final class RecordingAgent: LifecycleAgentReloading {
    var reloadCount = 0
    var failuresRemaining = 0

    func reload() throws {
        reloadCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw LifecycleTestFailure("agent reload failed")
        }
    }
}

private final class RecordingStateStore: LifecycleStatePersisting {
    var records: [LifecycleRecord] = []
    var current: LifecycleRecord? { records.last }
    var failOnSaveCalls: Set<Int> = []
    var saveCallCount = 0

    func load(canonicalHomePath: String) throws -> LifecycleRecord? { current }
    func loadAll() throws -> [LifecycleRecord] { current.map { [$0] } ?? [] }
    func save(_ record: LifecycleRecord) throws {
        saveCallCount += 1
        if failOnSaveCalls.contains(saveCallCount) {
            throw LifecycleTestFailure("state save failed")
        }
        records.append(record)
    }
}

private final class SuiteStateStore: LifecycleStatePersisting {
    var recordsByHome: [String: LifecycleRecord]

    init(records: [LifecycleRecord]) {
        recordsByHome = Dictionary(uniqueKeysWithValues: records.map { ($0.canonicalHomePath, $0) })
    }

    func load(canonicalHomePath: String) throws -> LifecycleRecord? {
        recordsByHome[canonicalHomePath]
    }

    func loadAll() throws -> [LifecycleRecord] {
        Array(recordsByHome.values)
    }

    func save(_ record: LifecycleRecord) throws {
        recordsByHome[record.canonicalHomePath] = record
    }
}

private final class RecordingLockProvider: LifecycleLockProviding {
    func acquire(canonicalHomePath: String) throws -> any LifecycleLockHolding {
        RecordingLock()
    }
}

private final class RecordingLock: LifecycleLockHolding {}

private struct LifecycleTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
