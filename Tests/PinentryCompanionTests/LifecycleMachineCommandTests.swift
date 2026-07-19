import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleMachineCommandTests: XCTestCase {
    func testSetupRequiresExplicitConfirmationWithoutCallingRunner() throws {
        let runner = RecordingLifecycleMachineRunner(result: .changed)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertEqual(envelope.operation, "setup")
        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.changed, false)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["invocation.confirmationRequired"])
        XCTAssertEqual(envelope.state.transactionState, .notCommitted)
        XCTAssertEqual(envelope.state.safety, .noMutationCommitted)
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-confirmation-required.json")
    }

    func testStrictSetupInvocationForwardsExplicitTakeover() {
        let runner = RecordingLifecycleMachineRunner(result: .changed)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--take-over", "--yes", "--format", "json"],
            runner: runner
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(runner.requests, [.setup(takeOver: true)])
    }

    func testStrictRestoreAndUninstallInvocationsRemainDistinct() {
        let runner = RecordingLifecycleMachineRunner(result: .restored)

        let restore = LifecycleMachineCommand.run(
            arguments: ["restore", "--yes", "--format", "json"],
            runner: runner
        )
        let uninstall = LifecycleMachineCommand.run(
            arguments: ["uninstall", "--prepare", "--yes", "--format", "json"],
            runner: runner
        )

        XCTAssertEqual(restore.status, 0)
        XCTAssertEqual(uninstall.status, 0)
        XCTAssertEqual(runner.requests, [.restore, .uninstall])
    }

    func testNonCanonicalArgumentOrderIsRejectedWithoutMutation() throws {
        let runner = RecordingLifecycleMachineRunner(result: .changed)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--format", "json", "--yes"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["invocation.invalid"])
    }

    func testChangedSetupMatchesGoldenFixture() throws {
        let runner = RecordingLifecycleMachineRunner(result: .changed)
        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--yes", "--format", "json"],
            runner: runner
        )

        XCTAssertEqual(result.status, 0)
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-changed.json")
    }

    func testUnchangedSetupIsSuccessfulAndReportsNoChange() throws {
        let runner = RecordingLifecycleMachineRunner(result: .unchanged)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(envelope.outcome, .ok)
        XCTAssertFalse(envelope.changed)
        XCTAssertEqual(envelope.state.transactionState, .unchanged)
        XCTAssertEqual(envelope.state.safety, .exactRestoreStateRecorded)
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-unchanged.json")
    }

    func testRestoredResultMatchesRestoreAndUninstallGoldenFixtures() throws {
        let runner = RecordingLifecycleMachineRunner(result: .restored)

        let restore = LifecycleMachineCommand.run(
            arguments: ["restore", "--yes", "--format", "json"],
            runner: runner
        )
        let uninstall = LifecycleMachineCommand.run(
            arguments: ["uninstall", "--prepare", "--yes", "--format", "json"],
            runner: runner
        )

        try assertJSON(restore.data, matchesFixture: "lifecycle/restore-restored.json")
        try assertJSON(uninstall.data, matchesFixture: "lifecycle/uninstall-restored.json")
    }

    func testForeignConfigurationIsATypedConflict() throws {
        let runner = RecordingLifecycleMachineRunner(error: LifecycleError.foreignConfiguration)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(envelope.outcome, .conflict)
        XCTAssertFalse(envelope.changed)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["lifecycle.foreignConfiguration"])
        XCTAssertEqual(envelope.state.transactionState, .notCommitted)
        XCTAssertEqual(envelope.state.safety, .noMutationCommitted)
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-foreign-conflict.json")
    }

    func testRollbackFailureRequiresManualRecoveryWithoutLeakingDetails() throws {
        let runner = RecordingLifecycleMachineRunner(error: LifecycleError.rollbackFailed(
            primary: "/Users/example/private primary",
            rollback: "/Users/example/private rollback"
        ))

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)
        let output = String(decoding: result.data, as: UTF8.self)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["lifecycle.rollbackFailed"])
        XCTAssertEqual(envelope.state.transactionState, .rollbackFailed)
        XCTAssertEqual(envelope.state.safety, .manualRecoveryRequired)
        XCTAssertFalse(output.contains("/Users/example"))
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-rollback-failed.json")
    }

    func testOperationalErrorsAreGenericAndDoNotLeakPrivatePaths() throws {
        let runner = RecordingLifecycleMachineRunner(error: LifecycleError.operationFailed(
            "failed at /Users/example/private"
        ))

        let result = LifecycleMachineCommand.run(
            arguments: ["restore", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)
        let output = String(decoding: result.data, as: UTF8.self)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["lifecycle.operationFailed"])
        XCTAssertFalse(output.contains("/Users/example"))
    }

    func testOnlyJSONLifecycleInvocationsEnterMachineMode() {
        XCTAssertTrue(LifecycleMachineCommand.isRequested(
            arguments: ["setup", "--format", "json"]
        ))
        XCTAssertTrue(LifecycleMachineCommand.isRequested(
            arguments: ["uninstall", "--prepare", "--yes", "--format", "json"]
        ))
        XCTAssertFalse(LifecycleMachineCommand.isRequested(arguments: ["setup", "--yes"]))
        XCTAssertFalse(LifecycleMachineCommand.isRequested(
            arguments: ["setup", "--yes", "--format", "yaml"]
        ))
        XCTAssertFalse(LifecycleMachineCommand.isRequested(
            arguments: ["cache", "purge", "--yes", "--format", "json"]
        ))
    }

    func testEncodingFailureDocumentRemainsInLifecycleSchema() throws {
        let data = LifecycleMachineCommand.encodingFailureData(operation: "restore")
        let envelope = try decode(data)

        XCTAssertEqual(envelope.operation, "restore")
        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.state.transactionState, .notCommitted)
        XCTAssertEqual(envelope.state.safety, .noMutationCommitted)
    }

    func testPostMutationEncodingFailureRequiresInspection() throws {
        let data = LifecycleMachineCommand.encodingFailureData(
            operation: "setup",
            state: LifecycleMutationState(
                transactionState: .indeterminate,
                safety: .inspectionRequired
            )
        )
        let envelope = try decode(data)

        XCTAssertEqual(envelope.outcome, .error)
        XCTAssertEqual(envelope.state.transactionState, .indeterminate)
        XCTAssertEqual(envelope.state.safety, .inspectionRequired)
    }

    func testImpossibleLifecycleResultDoesNotClaimRollback() throws {
        let runner = RecordingLifecycleMachineRunner(result: .restored)

        let result = LifecycleMachineCommand.run(
            arguments: ["setup", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(envelope.diagnostics.map(\.code), ["contract.unexpectedLifecycleResult"])
        XCTAssertEqual(envelope.state.transactionState, .indeterminate)
        XCTAssertEqual(envelope.state.safety, .inspectionRequired)
        try assertJSON(result.data, matchesFixture: "lifecycle/setup-indeterminate.json")
    }

    func testUninstallThatWouldLeaveRemovedBinaryActiveIsATypedConflict() throws {
        let runner = RecordingLifecycleMachineRunner(
            error: LifecycleError.uninstallWouldLeaveActiveConfiguration
        )

        let result = LifecycleMachineCommand.run(
            arguments: ["uninstall", "--prepare", "--yes", "--format", "json"],
            runner: runner
        )
        let envelope = try decode(result.data)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(envelope.outcome, .conflict)
        XCTAssertEqual(
            envelope.diagnostics.map(\.code),
            ["lifecycle.uninstall.activeConfiguration"]
        )
        XCTAssertEqual(envelope.state.transactionState, .notCommitted)
        try assertJSON(result.data, matchesFixture: "lifecycle/uninstall-active-conflict.json")
    }

    private func decode(_ data: Data) throws -> ManagementEnvelope<LifecycleMutationState> {
        try JSONDecoder().decode(ManagementEnvelope<LifecycleMutationState>.self, from: data)
    }

    private func assertJSON(_ data: Data, matchesFixture relativePath: String) throws {
        let actual = try canonicalJSON(data)
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

private final class RecordingLifecycleMachineRunner: LifecycleMachineRunning {
    private let result: LifecycleOperationResult?
    private let error: (any Error)?
    var requests: [LifecycleMachineRequest] = []

    init(result: LifecycleOperationResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func run(_ request: LifecycleMachineRequest) throws -> LifecycleOperationResult {
        requests.append(request)
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}
