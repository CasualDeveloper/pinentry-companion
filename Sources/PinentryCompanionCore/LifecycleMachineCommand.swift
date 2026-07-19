import Foundation

enum LifecycleMachineRequest: Equatable {
    case setup(takeOver: Bool)
    case restore
    case uninstall

    var operation: String {
        switch self {
        case .setup: return "setup"
        case .restore: return "restore"
        case .uninstall: return "uninstall"
        }
    }
}

protocol LifecycleMachineRunning: AnyObject {
    func run(_ request: LifecycleMachineRequest) throws -> LifecycleOperationResult
}

enum LifecycleTransactionState: String, Codable, Equatable {
    case committed
    case unchanged
    case restored
    case notCommitted
    case rollbackFailed
    case indeterminate
}

enum LifecycleMutationSafety: String, Codable, Equatable {
    case exactRestoreStateRecorded
    case compareAndSwapVerified
    case noMutationCommitted
    case manualRecoveryRequired
    case inspectionRequired
}

struct LifecycleMutationState: Codable, Equatable {
    var transactionState: LifecycleTransactionState
    var safety: LifecycleMutationSafety
}

enum LifecycleMachineRuntimeError: Error, Equatable {
    case fallbackPinentryMissing
    case gpgconfMissing
    case runningExecutableUnavailable
    case binaryIdentityUnavailable
    case unexpectedResult
}

enum LifecycleMachineCommand {
    struct Result {
        var data: Data
        var status: Int32
    }

    static func isRequested(arguments: [String]) -> Bool {
        guard let command = arguments.first,
              ["setup", "restore", "uninstall"].contains(command) else {
            return false
        }
        return arguments.indices.contains { index in
            arguments[index] == "--format" &&
                arguments.indices.contains(index + 1) &&
                arguments[index + 1] == "json"
        }
    }

    static func run(
        arguments: [String],
        runner: any LifecycleMachineRunning
    ) -> Result {
        let operation = arguments.first.flatMap(MachineOperation.init(rawValue:)) ?? .setup
        switch parse(arguments: arguments) {
        case .failure(let error):
            return encode(
                envelope(
                    operation: operation.rawValue,
                    outcome: .error,
                    diagnostic: diagnostic(for: error),
                    transactionState: .notCommitted,
                    safety: .noMutationCommitted
                ),
                operation: operation.rawValue,
                status: 2
            )
        case .success(let request):
            do {
                return try success(request: request, result: runner.run(request))
            } catch {
                return failure(operation: request.operation, error: error)
            }
        }
    }

    private enum MachineOperation: String {
        case setup
        case restore
        case uninstall
    }

    private enum InvocationError: Error {
        case confirmationRequired
        case invalid
    }

    private static func parse(
        arguments: [String]
    ) -> Swift.Result<LifecycleMachineRequest, InvocationError> {
        switch arguments {
        case ["setup", "--yes", "--format", "json"]:
            return .success(.setup(takeOver: false))
        case ["setup", "--take-over", "--yes", "--format", "json"]:
            return .success(.setup(takeOver: true))
        case ["restore", "--yes", "--format", "json"]:
            return .success(.restore)
        case ["uninstall", "--prepare", "--yes", "--format", "json"]:
            return .success(.uninstall)
        default:
            return .failure(arguments.contains("--yes") ? .invalid : .confirmationRequired)
        }
    }

    private static func success(
        request: LifecycleMachineRequest,
        result: LifecycleOperationResult
    ) throws -> Result {
        let transactionState: LifecycleTransactionState
        let safety: LifecycleMutationSafety
        let changed: Bool
        let code: String
        let message: String

        switch (request, result) {
        case (.setup, .changed):
            transactionState = .committed
            safety = .exactRestoreStateRecorded
            changed = true
            code = "lifecycle.setup.applied"
            message = "GPG configuration was transactionally configured."
        case (.setup, .unchanged):
            transactionState = .unchanged
            safety = .exactRestoreStateRecorded
            changed = false
            code = "lifecycle.setup.unchanged"
            message = "GPG configuration and lifecycle ownership were already current."
        case (.restore, .restored), (.uninstall, .restored):
            transactionState = .restored
            safety = .compareAndSwapVerified
            changed = true
            code = request == .restore
                ? "lifecycle.restore.applied"
                : "lifecycle.uninstall.prepared"
            message = request == .restore
                ? "Recorded GPG configuration was restored."
                : "Recorded GPG configuration was restored before binary removal."
        case (.restore, .unchanged), (.uninstall, .unchanged):
            transactionState = .unchanged
            safety = .compareAndSwapVerified
            changed = false
            code = request == .restore
                ? "lifecycle.restore.unchanged"
                : "lifecycle.uninstall.alreadyPrepared"
            message = "Recorded original GPG configuration was already present."
        case (.setup, .restored), (.restore, .changed), (.uninstall, .changed):
            throw LifecycleMachineRuntimeError.unexpectedResult
        }

        return encode(
            ManagementEnvelope(
                operation: request.operation,
                outcome: .ok,
                changed: changed,
                diagnostics: [ManagementDiagnostic(
                    code: code,
                    severity: .info,
                    message: message,
                    remediation: nil
                )],
                state: LifecycleMutationState(
                    transactionState: transactionState,
                    safety: safety
                )
            ),
            operation: request.operation,
            status: 0,
            encodingFailureState: LifecycleMutationState(
                transactionState: .indeterminate,
                safety: .inspectionRequired
            )
        )
    }

    private static func failure(operation: String, error: any Error) -> Result {
        let mapped = diagnostic(for: error)
        let indeterminate = (error as? LifecycleMachineRuntimeError) == .unexpectedResult
        return encode(
            envelope(
                operation: operation,
                outcome: mapped.outcome,
                diagnostic: mapped.diagnostic,
                transactionState: indeterminate
                    ? .indeterminate
                    : (mapped.rollbackFailed ? .rollbackFailed : .notCommitted),
                safety: indeterminate
                    ? .inspectionRequired
                    : (mapped.rollbackFailed ? .manualRecoveryRequired : .noMutationCommitted)
            ),
            operation: operation,
            status: 1
        )
    }

    private static func envelope(
        operation: String,
        outcome: ManagementOutcome,
        diagnostic: ManagementDiagnostic,
        transactionState: LifecycleTransactionState,
        safety: LifecycleMutationSafety
    ) -> ManagementEnvelope<LifecycleMutationState> {
        ManagementEnvelope(
            operation: operation,
            outcome: outcome,
            diagnostics: [diagnostic],
            state: LifecycleMutationState(
                transactionState: transactionState,
                safety: safety
            )
        )
    }

    private static func diagnostic(for error: InvocationError) -> ManagementDiagnostic {
        switch error {
        case .confirmationRequired:
            return ManagementDiagnostic(
                code: "invocation.confirmationRequired",
                severity: .error,
                message: "Machine lifecycle mutations require the literal --yes option.",
                remediation: "Use the documented canonical argument sequence after reviewing the passive plan."
            )
        case .invalid:
            return ManagementDiagnostic(
                code: "invocation.invalid",
                severity: .error,
                message: "The machine lifecycle command did not match a canonical invocation.",
                remediation: "Use the documented command and argument order exactly."
            )
        }
    }

    private static func diagnostic(
        for error: any Error
    ) -> (outcome: ManagementOutcome, diagnostic: ManagementDiagnostic, rollbackFailed: Bool) {
        if let runtime = error as? LifecycleMachineRuntimeError {
            return diagnostic(for: runtime)
        }
        guard let lifecycle = error as? LifecycleError else {
            return operationalFailure()
        }

        switch lifecycle {
        case .foreignConfiguration:
            return conflict(
                code: "lifecycle.foreignConfiguration",
                message: "A foreign pinentry-program directive blocks automatic ownership.",
                remediation: "Review the passive plan, then use --take-over only if replacement is intentional."
            )
        case .unsupportedPreference:
            return conflict(
                code: "lifecycle.unsupportedPreference",
                message: "DisableKeychain has an unsupported preference type."
            )
        case .notManaged:
            return conflict(
                code: "lifecycle.notManaged",
                message: "No lifecycle ownership record exists for the current GNUPGHOME."
            )
        case .uninstallWouldLeaveActiveConfiguration:
            return conflict(
                code: "lifecycle.uninstall.activeConfiguration",
                message: "The recorded original configuration still invokes the binary being removed.",
                remediation: "Configure a retained fallback pinentry, then retry uninstall preparation."
            )
        case .incompleteTransaction:
            return conflict(
                code: "lifecycle.transactionIncomplete",
                message: "The recorded lifecycle transaction requires recovery before this operation."
            )
        case .drift(let target):
            return conflict(
                code: "lifecycle.managedStateDrifted",
                message: "Managed state drift was detected at \(target).",
                remediation: "Inspect status and reconcile the user change before retrying."
            )
        case .invalidConfiguration:
            return conflict(
                code: "lifecycle.invalidConfiguration",
                message: "The GPG agent configuration cannot be safely managed."
            )
        case .rollbackFailed:
            return (
                .error,
                ManagementDiagnostic(
                    code: "lifecycle.rollbackFailed",
                    severity: .error,
                    message: "The lifecycle operation failed and automatic rollback did not complete.",
                    remediation: "Stop further mutations and inspect passive status before manual recovery."
                ),
                true
            )
        case .operationFailed:
            return operationalFailure()
        }
    }

    private static func diagnostic(
        for error: LifecycleMachineRuntimeError
    ) -> (outcome: ManagementOutcome, diagnostic: ManagementDiagnostic, rollbackFailed: Bool) {
        let diagnostic: ManagementDiagnostic
        switch error {
        case .fallbackPinentryMissing:
            diagnostic = ManagementDiagnostic(
                code: "dependency.fallbackPinentry.missing",
                severity: .error,
                message: "A supported fallback pinentry is required before activation.",
                remediation: "Install pinentry-mac, pinentry-curses, or pinentry-tty."
            )
        case .gpgconfMissing:
            diagnostic = ManagementDiagnostic(
                code: "dependency.gpgconf.missing",
                severity: .error,
                message: "gpgconf is required for a safe GPG agent reload.",
                remediation: "Install GnuPG before retrying."
            )
        case .runningExecutableUnavailable, .binaryIdentityUnavailable:
            diagnostic = ManagementDiagnostic(
                code: "binary.identityUnavailable",
                severity: .error,
                message: "The running binary identity could not be verified.",
                remediation: nil
            )
        case .unexpectedResult:
            diagnostic = ManagementDiagnostic(
                code: "contract.unexpectedLifecycleResult",
                severity: .error,
                message: "The lifecycle engine returned a result that is invalid for this operation.",
                remediation: nil
            )
        }
        return (.error, diagnostic, false)
    }

    private static func conflict(
        code: String,
        message: String,
        remediation: String? = nil
    ) -> (outcome: ManagementOutcome, diagnostic: ManagementDiagnostic, rollbackFailed: Bool) {
        (
            .conflict,
            ManagementDiagnostic(
                code: code,
                severity: .error,
                message: message,
                remediation: remediation
            ),
            false
        )
    }

    private static func operationalFailure(
    ) -> (outcome: ManagementOutcome, diagnostic: ManagementDiagnostic, rollbackFailed: Bool) {
        (
            .error,
            ManagementDiagnostic(
                code: "lifecycle.operationFailed",
                severity: .error,
                message: "The lifecycle operation failed without committing a mutation.",
                remediation: "Inspect passive status before retrying."
            ),
            false
        )
    }

    private static func encode(
        _ envelope: ManagementEnvelope<LifecycleMutationState>,
        operation: String,
        status: Int32,
        encodingFailureState: LifecycleMutationState? = nil
    ) -> Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else {
            return Result(
                data: encodingFailureData(
                    operation: operation,
                    state: encodingFailureState ?? envelope.state
                ),
                status: 1
            )
        }
        return Result(data: data, status: status)
    }

    static func encodingFailureData(
        operation: String,
        state: LifecycleMutationState = LifecycleMutationState(
            transactionState: .notCommitted,
            safety: .noMutationCommitted
        )
    ) -> Data {
        Data("{\"changed\":false,\"component\":\"pinentry-companion\",\"componentVersion\":\"\(ComponentVersion.current)\",\"diagnostics\":[{\"code\":\"contract.encodingFailed\",\"message\":\"The machine response could not be encoded.\",\"severity\":\"error\"}],\"operation\":\"\(operation)\",\"outcome\":\"error\",\"schemaVersion\":1,\"state\":{\"safety\":\"\(state.safety.rawValue)\",\"transactionState\":\"\(state.transactionState.rawValue)\"}}".utf8)
    }
}

final class LiveLifecycleMachineRunner: LifecycleMachineRunning {
    func run(_ request: LifecycleMachineRequest) throws -> LifecycleOperationResult {
        let homeURL = GPGAgentConfig.homeURL()
        let configURL = GPGAgentConfig.configURL()

        switch request {
        case .setup(let takeOver):
            guard ExecutableLookup.find("pinentry-mac") != nil ||
                    ExecutableLookup.findFirst(
                        FallbackPinentryNames.preferred().filter { $0 != "pinentry-mac" }
                    ) != nil else {
                throw LifecycleMachineRuntimeError.fallbackPinentryMissing
            }
            guard let gpgconfPath = ExecutableLookup.find("gpgconf") else {
                throw LifecycleMachineRuntimeError.gpgconfMissing
            }
            let identity = try RunningLifecycleBinaryIdentity.read()
            return try makeManager(gpgconfPath: gpgconfPath).setup(LifecycleSetupRequest(
                canonicalHomePath: homeURL.path,
                configPath: configURL.path,
                binary: identity,
                takeOver: takeOver
            ))

        case .restore:
            guard let gpgconfPath = ExecutableLookup.find("gpgconf") else {
                throw LifecycleMachineRuntimeError.gpgconfMissing
            }
            return try makeManager(gpgconfPath: gpgconfPath)
                .restore(canonicalHomePath: homeURL.path)

        case .uninstall:
            let identity = try RunningLifecycleBinaryIdentity.read()
            guard let gpgconfPath = ExecutableLookup.find("gpgconf") else {
                throw LifecycleMachineRuntimeError.gpgconfMissing
            }
            return try makeManager(gpgconfPath: gpgconfPath).prepareUninstall(
                canonicalHomePath: homeURL.path,
                removingBinary: identity
            )
        }
    }

    private func makeManager(gpgconfPath: String) -> LifecycleManager {
        let root = LifecycleStateStore.defaultRootURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
        return LifecycleManager(
            target: FileSystemLifecycleTarget(),
            preference: LifecyclePreferenceStore(),
            agent: GPGAgentReloader(executablePath: gpgconfPath),
            state: LifecycleStateStore(rootURL: root),
            locks: LifecycleLockProvider(rootURL: root)
        )
    }
}

enum RunningLifecycleBinaryIdentity {
    static func read() throws -> LifecycleBinaryIdentity {
        guard let runningExecutable = Bundle.main.executableURL?
            .resolvingSymlinksInPath().path else {
            throw LifecycleMachineRuntimeError.runningExecutableUnavailable
        }
        do {
            return try LifecycleBinaryIdentity.read(
                invokedPath: CommandLineEntry.currentExecutablePath(),
                expectedResolvedPath: runningExecutable
            )
        } catch {
            throw LifecycleMachineRuntimeError.binaryIdentityUnavailable
        }
    }
}
