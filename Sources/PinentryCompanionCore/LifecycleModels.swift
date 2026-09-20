import Foundation

enum LifecyclePath {
    static func isCanonicalAbsolute(_ path: String, allowRoot: Bool = false) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            return false
        }
        if path == "/" { return allowRoot }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.first?.isEmpty == true &&
            components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct LifecycleTargetSnapshot: Equatable {
    var home: LifecycleHomeState
    var config: LifecycleFileState
}

protocol LifecycleTargetManaging: AnyObject {
    func snapshot(canonicalHomePath: String, configPath: String) throws -> LifecycleTargetSnapshot
    func applyHome(_ state: LifecycleHomeState, canonicalHomePath: String) throws
    func applyConfig(_ state: LifecycleFileState, configPath: String) throws
}

protocol LifecyclePreferenceManaging: AnyObject {
    func read() throws -> LifecyclePreferenceState
    func apply(_ state: LifecyclePreferenceState) throws
}

protocol LifecycleAgentReloading: AnyObject {
    func reload() throws
}

protocol LifecycleStatePersisting {
    func load(canonicalHomePath: String) throws -> LifecycleRecord?
    func loadAll() throws -> [LifecycleRecord]
    func save(_ record: LifecycleRecord) throws
    func remove(canonicalHomePath: String) throws
}

protocol LifecycleLockHolding: AnyObject {}

protocol LifecycleLockProviding {
    func acquire(canonicalHomePath: String) throws -> any LifecycleLockHolding
}

enum LifecycleOperationResult: Equatable {
    case changed
    case unchanged
    case restored
}

struct LifecycleSetupRequest {
    var canonicalHomePath: String
    var configPath: String
    var binary: LifecycleBinaryIdentity
    var takeOver: Bool
}

enum LifecycleError: Error, Equatable, CustomStringConvertible {
    case foreignConfiguration
    case unsupportedPreference
    case notManaged
    case uninstallWouldLeaveActiveConfiguration
    case incompleteTransaction(LifecyclePhase)
    case drift(String)
    case invalidConfiguration(String)
    case operationFailed(String)
    case rollbackFailed(primary: String, rollback: String)

    var description: String {
        switch self {
        case .foreignConfiguration: return "another pinentry-program requires explicit takeover"
        case .unsupportedPreference: return "DisableKeychain has an unsupported preference type"
        case .notManaged: return "no pinentry-companion lifecycle record exists"
        case .uninstallWouldLeaveActiveConfiguration:
            return "restored GPG configuration would still invoke the binary being removed"
        case .incompleteTransaction(let phase): return "lifecycle transaction is incomplete at phase \(phase.rawValue)"
        case .drift(let target): return "managed state drifted at \(target)"
        case .invalidConfiguration(let reason): return "invalid GPG configuration: \(reason)"
        case .operationFailed(let reason): return reason
        case .rollbackFailed(let primary, let rollback):
            return "operation failed (\(primary)); rollback also failed (\(rollback))"
        }
    }
}

func lifecycleError(_ error: any Error) -> LifecycleError {
    if let error = error as? LifecycleError { return error }
    return .operationFailed(String(describing: error))
}

func preferenceAfterReleasing(
    _ record: LifecycleRecord,
    among records: [LifecycleRecord]
) -> LifecyclePreferenceState {
    let anotherHomeRequiresManagedPreference = records.contains {
        $0.canonicalHomePath != record.canonicalHomePath && $0.requiresManagedPreference
    }
    return anotherHomeRequiresManagedPreference ? record.expectedPreference : record.originalPreference
}
