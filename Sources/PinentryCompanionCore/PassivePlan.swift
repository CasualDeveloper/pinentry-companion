import Foundation

enum PassivePlanBuilder {
    static func build(snapshot: PassiveSnapshot) -> ManagementEnvelope<PlanState> {
        var configuration = configurationPlan(snapshot: snapshot)
        if case .unreadable = snapshot.lifecycle {
            configuration.action = .blocked
            configuration.conflicts.append(PlanConflict(
                code: "ownershipRecordUnreadable",
                message: "Lifecycle ownership state could not be safely inspected."
            ))
        }
        let preference = preferencePlan(state: snapshot.preferenceState)
        let reloadRequired = configuration.action != .none || preference.action != .none
        var dependencyConflicts: [PlanConflict] = []
        if reloadRequired, snapshot.dependencyPaths["gpgconf"] == nil {
            dependencyConflicts.append(PlanConflict(
                code: "gpgconfMissing",
                message: "gpgconf is required to reload gpg-agent after this change."
            ))
        }
        if !hasFallbackPinentry(snapshot) {
            dependencyConflicts.append(PlanConflict(
                code: "fallbackPinentryMissing",
                message: "A supported fallback pinentry is required before activation."
            ))
        }
        let conflicts = configuration.conflicts + preference.conflicts + dependencyConflicts
        let blocked = !conflicts.isEmpty
        let changeRequired = configuration.action != .none || preference.action != .none
        let reversibility = reversibility(snapshot.lifecycle)
        var diagnostics = conflicts.map(diagnostic(for:))

        if diagnostics.isEmpty, changeRequired {
            diagnostics = [ManagementDiagnostic(
                code: "gpg.configuration.changeRequired",
                severity: .info,
                message: "GPG configuration changes are available for preview.",
                remediation: nil
            )]
        }

        return ManagementEnvelope(
            operation: "plan",
            outcome: blocked ? .conflict : (changeRequired ? .warning : .ok),
            diagnostics: diagnostics,
            state: PlanState(
                applicability: blocked ? .blocked : .ready,
                changeRequired: changeRequired,
                gpgConfiguration: GPGDirectivePlan(
                    targetDisplayPath: PrivatePathRedactor.display(snapshot.configPath, homePath: snapshot.userHomePath),
                    action: configuration.action,
                    beforeOccurrenceCount: configuration.values.count,
                    afterOccurrenceCount: configuration.action == .none ? configuration.values.count : 1,
                    beforeValues: configuration.values.map {
                        PrivatePathRedactor.display($0, homePath: snapshot.userHomePath)
                    },
                    afterValue: PrivatePathRedactor.display(snapshot.invokedPath, homePath: snapshot.userHomePath),
                    requiresReload: reloadRequired,
                    reloadAvailable: snapshot.dependencyPaths["gpgconf"] != nil,
                    reversible: reversibility
                ),
                disableKeychainPreference: PreferencePlan(
                    domain: "org.gpgtools.common",
                    key: "DisableKeychain",
                    action: preference.action,
                    beforeState: snapshot.preferenceState,
                    afterValue: true,
                    reversible: reversibility
                ),
                conflicts: conflicts
            )
        )
    }

    private static func reversibility(_ lifecycle: PassiveLifecycleState) -> Reversibility {
        switch lifecycle {
        case .tracked:
            return Reversibility(supported: true, reason: "ownershipRecordAvailable")
        case .unreadable:
            return Reversibility(supported: false, reason: "ownershipRecordUnreadable")
        case .notTracked:
            return Reversibility(supported: true, reason: "ownershipRecordWillBeCreated")
        }
    }

    private static func hasFallbackPinentry(_ snapshot: PassiveSnapshot) -> Bool {
        ["pinentry-mac", "pinentry-curses", "pinentry-tty"].contains {
            snapshot.dependencyPaths[$0] != nil
        }
    }

    private static func diagnostic(for conflict: PlanConflict) -> ManagementDiagnostic {
        switch conflict.code {
        case "ownershipRecordUnreadable":
            return ManagementDiagnostic(
                code: "lifecycle.recordUnreadable",
                severity: .error,
                message: "Lifecycle ownership state blocks a safe mutation plan.",
                remediation: nil
            )
        case "foreignPinentryProgram":
            return ManagementDiagnostic(
                code: "gpg.configuration.foreignPinentry",
                severity: .error,
                message: "A foreign pinentry-program directive blocks an automatic plan.",
                remediation: "Review the existing directive before explicitly taking ownership."
            )
        case "configurationUnreadable", "configurationInvalid":
            return ManagementDiagnostic(
                code: "gpg.configuration.unreadable",
                severity: .error,
                message: "The GPG agent configuration file could not be safely inspected.",
                remediation: nil
            )
        case "preferenceWrongType":
            return ManagementDiagnostic(
                code: "preference.disableKeychain.wrongType",
                severity: .error,
                message: "DisableKeychain has an unsupported preference type.",
                remediation: nil
            )
        case "gpgconfMissing":
            return ManagementDiagnostic(
                code: "dependency.gpgconf.missing",
                severity: .error,
                message: conflict.message,
                remediation: "Install GnuPG before applying this plan."
            )
        case "fallbackPinentryMissing":
            return ManagementDiagnostic(
                code: "dependency.fallbackPinentry.missing",
                severity: .error,
                message: conflict.message,
                remediation: "Install pinentry-mac, pinentry-curses, or pinentry-tty."
            )
        default:
            return ManagementDiagnostic(
                code: "plan.conflict",
                severity: .error,
                message: conflict.message,
                remediation: nil
            )
        }
    }

    private static func configurationPlan(snapshot: PassiveSnapshot) -> (action: PlanAction, values: [String], conflicts: [PlanConflict]) {
        switch snapshot.configContents {
        case .missing:
            return (.create, [], [])
        case .unreadable:
            return (.blocked, [], [PlanConflict(
                code: "configurationUnreadable",
                message: "The configuration file could not be safely inspected."
            )])
        case .readable(let contents):
            do {
                let plan = try GPGDirectivePlanner.plan(
                    contents: contents,
                    exists: true,
                    invokedPath: snapshot.invokedPath,
                    resolvedPath: snapshot.resolvedPath,
                    allowTakeover: ownsCurrentConfiguration(snapshot.lifecycle)
                )
                return (plan.action, plan.beforeValues, plan.conflict.map { [$0] } ?? [])
            } catch {
                return (.blocked, [], [PlanConflict(
                    code: "configurationInvalid",
                    message: "The configuration plan could not be created."
                )])
            }
        }
    }

    private static func ownsCurrentConfiguration(_ lifecycle: PassiveLifecycleState) -> Bool {
        guard case .tracked(let record, let current) = lifecycle, let current else { return false }
        switch record.phase {
        case .complete:
            return current.config == record.expectedConfig
        case .rolledBack:
            return record.transactionBaseConfig != record.originalConfig &&
                current.config == record.transactionBaseConfig
        case .restorePrepared, .configRestored, .preferenceRestored:
            return current.config == record.expectedConfig || current.config == record.originalConfig
        default:
            return false
        }
    }

    private static func preferencePlan(state: PreferenceState) -> (action: PlanAction, conflicts: [PlanConflict]) {
        switch state {
        case .enabled:
            return (.none, [])
        case .absent, .disabled:
            return (.set, [])
        case .wrongType:
            return (.blocked, [PlanConflict(
                code: "preferenceWrongType",
                message: "DisableKeychain has an unsupported preference type."
            )])
        }
    }
}

enum PassiveOperation {
    case status
    case plan
}

enum PassiveCommand {
    static func run(operation: PassiveOperation, reader: any PassiveSnapshotReading) -> (data: Data, status: Int32) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = reader.read()

        do {
            switch operation {
            case .status:
                let envelope = PassiveStatusBuilder.build(snapshot: snapshot)
                return (try encoder.encode(envelope), exitStatus(for: envelope.outcome))
            case .plan:
                let envelope = PassivePlanBuilder.build(snapshot: snapshot)
                return (try encoder.encode(envelope), exitStatus(for: envelope.outcome))
            }
        } catch {
            return (encodingFailureData(operation: operation), 1)
        }
    }

    static func encodingFailureData(operation: PassiveOperation) -> Data {
        let header = "\"changed\":false,\"component\":\"pinentry-companion\",\"componentVersion\":\"\(ComponentVersion.current)\",\"diagnostics\":[{\"code\":\"contract.encodingFailed\",\"message\":\"The machine response could not be encoded.\",\"severity\":\"error\"}]"
        switch operation {
        case .status:
            return Data("{\(header),\"operation\":\"status\",\"outcome\":\"error\",\"schemaVersion\":1,\"state\":{\"binary\":{\"architecture\":\"unknown\",\"flavor\":\"companion\",\"invokedDisplayPath\":\"unavailable\",\"resolvedDisplayPath\":\"unavailable\"},\"cache\":{\"inventory\":\"notProbed\",\"serviceMode\":\"componentOwnedServices\"},\"dependencies\":[],\"disableKeychainPreference\":{\"domain\":\"org.gpgtools.common\",\"key\":\"DisableKeychain\",\"state\":\"wrongType\"},\"gpgConfiguration\":{\"alignment\":\"unknown\",\"configDisplayPath\":\"unavailable\",\"drift\":\"notAssessable\",\"homeDisplayPath\":\"unavailable\",\"ownership\":\"notTracked\",\"pinentryProgramOccurrences\":[],\"presence\":\"unreadable\",\"recoveryAvailable\":false},\"localAuthentication\":{\"availability\":\"notProbed\",\"policyMode\":\"unavailable\"}}}".utf8)
        case .plan:
            return Data("{\(header),\"operation\":\"plan\",\"outcome\":\"error\",\"schemaVersion\":1,\"state\":{\"applicability\":\"blocked\",\"changeRequired\":false,\"conflicts\":[{\"code\":\"encodingFailed\",\"message\":\"The machine response could not be encoded.\"}],\"disableKeychainPreference\":{\"action\":\"blocked\",\"afterValue\":true,\"beforeState\":\"wrongType\",\"domain\":\"org.gpgtools.common\",\"key\":\"DisableKeychain\",\"reversible\":{\"reason\":\"ownershipRecordUnavailable\",\"supported\":false}},\"gpgConfiguration\":{\"action\":\"blocked\",\"afterOccurrenceCount\":0,\"afterValue\":\"unavailable\",\"beforeOccurrenceCount\":0,\"beforeValues\":[],\"reloadAvailable\":false,\"requiresReload\":false,\"reversible\":{\"reason\":\"ownershipRecordUnavailable\",\"supported\":false},\"targetDisplayPath\":\"unavailable\"}}}".utf8)
        }
    }

    private static func exitStatus(for outcome: ManagementOutcome) -> Int32 {
        outcome == .error || outcome == .conflict ? 1 : 0
    }
}

enum PrivatePathRedactor {
    static func display(_ path: String, homePath: String) -> String {
        let redacted = DiagnosticRedactor.redact(path, homeDirectory: homePath)
        if redacted != path || path == homePath { return redacted }

        let publicPrefixes = ["/opt/homebrew/", "/usr/local/", "/usr/bin/", "/bin/", "/Library/Apple/"]
        return publicPrefixes.contains(where: { path.hasPrefix($0) }) ? path : "<private-path>"
    }
}
