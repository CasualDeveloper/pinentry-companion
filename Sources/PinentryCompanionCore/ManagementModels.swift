import Foundation

enum ManagementOutcome: String, Codable {
    case ok
    case warning
    case error
    case conflict
}

enum DiagnosticSeverity: String, Codable {
    case info
    case warning
    case error
}

struct ManagementDiagnostic: Codable, Equatable {
    var code: String
    var severity: DiagnosticSeverity
    var message: String
    var remediation: String?
}

struct ManagementEnvelope<State: Codable & Equatable>: Codable, Equatable {
    var schemaVersion = 1
    var component = "pinentry-companion"
    var componentVersion = ComponentVersion.current
    var operation: String
    var outcome: ManagementOutcome
    var changed = false
    var diagnostics: [ManagementDiagnostic]
    var state: State
}

struct BinaryStatus: Codable, Equatable {
    var flavor: String
    var architecture: String
    var invokedDisplayPath: String
    var resolvedDisplayPath: String
}

enum ConfigurationPresence: String, Codable {
    case missing
    case readable
    case unreadable
}

enum ConfigurationAlignment: String, Codable {
    case currentBinary
    case otherBinary
    case missing
    case ambiguous
    case unknown
}

struct GPGConfigurationStatus: Codable, Equatable {
    var homeDisplayPath: String
    var configDisplayPath: String
    var presence: ConfigurationPresence
    var pinentryProgramOccurrences: [String]
    var alignment: ConfigurationAlignment
    var ownership: String
    var drift: String
    var recoveryAvailable: Bool
}

struct DependencyStatus: Codable, Equatable {
    var name: String
    var availability: String
    var displayPath: String
}

struct AuthenticationStatus: Codable, Equatable {
    var policyMode: String
    var availability: String
}

struct CacheStatus: Codable, Equatable {
    var serviceMode: String
    var inventory: String
}

enum PreferenceState: String, Codable {
    case absent
    case enabled
    case disabled
    case wrongType
}

struct PreferenceStatus: Codable, Equatable {
    var domain: String
    var key: String
    var state: PreferenceState
}

struct StatusState: Codable, Equatable {
    var binary: BinaryStatus
    var gpgConfiguration: GPGConfigurationStatus
    var dependencies: [DependencyStatus]
    var localAuthentication: AuthenticationStatus
    var cache: CacheStatus
    var disableKeychainPreference: PreferenceStatus
}

enum PlanApplicability: String, Codable {
    case ready
    case blocked
}

enum PlanAction: String, Codable {
    case none
    case create
    case add
    case replace
    case deduplicate
    case set
    case blocked
}

struct Reversibility: Codable, Equatable {
    var supported: Bool
    var reason: String
}

struct GPGDirectivePlan: Codable, Equatable {
    var targetDisplayPath: String
    var action: PlanAction
    var beforeOccurrenceCount: Int
    var afterOccurrenceCount: Int
    var beforeValues: [String]
    var afterValue: String
    var requiresReload: Bool
    var reloadAvailable: Bool
    var reversible: Reversibility
}

struct PreferencePlan: Codable, Equatable {
    var domain: String
    var key: String
    var action: PlanAction
    var beforeState: PreferenceState
    var afterValue: Bool
    var reversible: Reversibility
}

struct PlanConflict: Codable, Equatable {
    var code: String
    var message: String
}

struct PlanState: Codable, Equatable {
    var applicability: PlanApplicability
    var changeRequired: Bool
    var gpgConfiguration: GPGDirectivePlan
    var disableKeychainPreference: PreferencePlan
    var conflicts: [PlanConflict]
}
