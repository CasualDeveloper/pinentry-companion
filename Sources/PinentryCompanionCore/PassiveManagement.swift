import Foundation

enum PassiveStatusBuilder {
    static func build(snapshot: PassiveSnapshot) -> ManagementEnvelope<StatusState> {
        let inspected = inspectConfiguration(snapshot: snapshot)
        var diagnostics = inspected.diagnostics
        let lifecycle = lifecycleStatus(snapshot: snapshot)

        switch lifecycle.drift {
        case "drifted":
            diagnostics.append(ManagementDiagnostic(
                code: "lifecycle.managedStateDrifted",
                severity: .error,
                message: "Managed configuration differs from its recorded compare-and-swap state.",
                remediation: "Review the local change before retrying setup or restore."
            ))
        case "transactionIncomplete":
            diagnostics.append(ManagementDiagnostic(
                code: "lifecycle.transactionIncomplete",
                severity: .warning,
                message: "A lifecycle transaction was interrupted and can be recovered by setup or restore.",
                remediation: nil
            ))
        case "unreadable":
            diagnostics.append(ManagementDiagnostic(
                code: "lifecycle.recordUnreadable",
                severity: .error,
                message: "Lifecycle ownership state could not be safely inspected.",
                remediation: nil
            ))
        default:
            break
        }

        if snapshot.preferenceState == .disabled || snapshot.preferenceState == .wrongType {
            diagnostics.append(ManagementDiagnostic(
                code: "preference.disableKeychain.notEnabled",
                severity: snapshot.preferenceState == .wrongType ? .error : .warning,
                message: snapshot.preferenceState == .wrongType
                    ? "DisableKeychain has an unsupported preference type."
                    : "pinentry-mac Keychain storage is not disabled.",
                remediation: nil
            ))
        }

        if snapshot.dependencyPaths["gpgconf"] == nil {
            diagnostics.append(ManagementDiagnostic(
                code: "dependency.gpgconf.missing",
                severity: .warning,
                message: "gpgconf is unavailable, so setup and restore cannot safely reload gpg-agent.",
                remediation: "Install GnuPG before changing lifecycle state."
            ))
        }
        if !hasFallbackPinentry(snapshot) {
            diagnostics.append(ManagementDiagnostic(
                code: "dependency.fallbackPinentry.missing",
                severity: .error,
                message: "No supported fallback pinentry is available for uncached or unsupported prompts.",
                remediation: "Install pinentry-mac, pinentry-curses, or pinentry-tty."
            ))
        }

        let dependencies = ["gpgconf", "pinentry-mac", "pinentry-curses", "pinentry-tty"].map { name in
            DependencyStatus(
                name: name,
                availability: snapshot.dependencyPaths[name] == nil ? "missing" : "available",
                displayPath: snapshot.dependencyPaths[name].map {
                    PrivatePathRedactor.display($0, homePath: snapshot.userHomePath)
                } ?? "missing"
            )
        }

        let outcome: ManagementOutcome
        if diagnostics.contains(where: { $0.severity == .error }) {
            outcome = .error
        } else if !diagnostics.isEmpty {
            outcome = .warning
        } else {
            outcome = .ok
        }

        return ManagementEnvelope(
            operation: "status",
            outcome: outcome,
            diagnostics: diagnostics,
            state: StatusState(
                binary: BinaryStatus(
                    flavor: PinentryInfo.flavor,
                    architecture: snapshot.architecture,
                    invokedDisplayPath: PrivatePathRedactor.display(snapshot.invokedPath, homePath: snapshot.userHomePath),
                    resolvedDisplayPath: PrivatePathRedactor.display(snapshot.resolvedPath, homePath: snapshot.userHomePath)
                ),
                gpgConfiguration: GPGConfigurationStatus(
                    homeDisplayPath: PrivatePathRedactor.display(snapshot.homePath, homePath: snapshot.userHomePath),
                    configDisplayPath: PrivatePathRedactor.display(snapshot.configPath, homePath: snapshot.userHomePath),
                    presence: inspected.presence,
                    pinentryProgramOccurrences: inspected.displayValues,
                    alignment: inspected.alignment,
                    ownership: lifecycle.ownership,
                    drift: lifecycle.drift,
                    recoveryAvailable: lifecycle.recoveryAvailable
                ),
                dependencies: dependencies,
                localAuthentication: AuthenticationStatus(
                    policyMode: snapshot.authenticationPolicyMode,
                    availability: "notProbed"
                ),
                cache: CacheStatus(serviceMode: "componentOwnedServices", inventory: "notProbed"),
                disableKeychainPreference: PreferenceStatus(
                    domain: "org.gpgtools.common",
                    key: "DisableKeychain",
                    state: snapshot.preferenceState
                )
            )
        )
    }

    private static func lifecycleStatus(
        snapshot: PassiveSnapshot
    ) -> (ownership: String, drift: String, recoveryAvailable: Bool) {
        switch snapshot.lifecycle {
        case .notTracked:
            return ("notTracked", "notAssessable", false)
        case .unreadable:
            return ("unreadable", "unreadable", false)
        case .tracked(let record, let current):
            guard let current else { return ("managed", "unreadable", true) }
            let preference = lifecyclePreference(snapshot.preferenceState)
            switch record.phase {
            case .complete:
                let matches = current.home == record.expectedHome &&
                    current.config == record.expectedConfig && preference == record.expectedPreference
                return ("managed", matches ? "inSync" : "drifted", true)
            case .restored:
                let restoredPreference = snapshot.otherHomeRequiresManagedPreference
                    ? record.expectedPreference
                    : record.originalPreference
                let matches = current.home == record.originalHome &&
                    current.config == record.originalConfig && preference == restoredPreference
                return ("released", matches ? "inSync" : "drifted", true)
            case .rolledBack:
                let matches = current.home == record.transactionBaseHome &&
                    current.config == record.transactionBaseConfig &&
                    preference == record.transactionBasePreference
                return ("released", matches ? "inSync" : "drifted", true)
            default:
                return ("transactionIncomplete", "transactionIncomplete", true)
            }
        }
    }

    private static func hasFallbackPinentry(_ snapshot: PassiveSnapshot) -> Bool {
        ["pinentry-mac", "pinentry-curses", "pinentry-tty"].contains {
            snapshot.dependencyPaths[$0] != nil
        }
    }

    private static func lifecyclePreference(_ state: PreferenceState) -> LifecyclePreferenceState {
        switch state {
        case .absent: return .absent
        case .enabled: return .boolean(true)
        case .disabled: return .boolean(false)
        case .wrongType: return .unsupported(type: "unknown", description: "non-boolean value")
        }
    }

    private static func inspectConfiguration(snapshot: PassiveSnapshot) -> ConfigurationInspection {
        switch snapshot.configContents {
        case .missing:
            return ConfigurationInspection(
                presence: .missing,
                rawValues: [],
                displayValues: [],
                alignment: .missing,
                diagnostics: [ManagementDiagnostic(
                    code: "gpg.configuration.missing",
                    severity: .warning,
                    message: "The GPG agent configuration file is absent.",
                    remediation: nil
                )]
            )
        case .unreadable:
            return ConfigurationInspection(
                presence: .unreadable,
                rawValues: [],
                displayValues: [],
                alignment: .unknown,
                diagnostics: [ManagementDiagnostic(
                    code: "gpg.configuration.unreadable",
                    severity: .error,
                    message: "The GPG agent configuration file could not be safely inspected.",
                    remediation: nil
                )]
            )
        case .readable(let contents):
            let values = GPGAgentConfig.activePinentryPrograms(in: contents)
            let displayValues = values.map {
                PrivatePathRedactor.display($0, homePath: snapshot.userHomePath)
            }

            if values.isEmpty {
                return ConfigurationInspection(
                    presence: .readable,
                    rawValues: values,
                    displayValues: displayValues,
                    alignment: .missing,
                    diagnostics: [ManagementDiagnostic(
                        code: "gpg.configuration.directiveMissing",
                        severity: .warning,
                        message: "No active pinentry-program directive was found.",
                        remediation: nil
                    )]
                )
            }

            if values.count > 1 {
                return ConfigurationInspection(
                    presence: .readable,
                    rawValues: values,
                    displayValues: displayValues,
                    alignment: .ambiguous,
                    diagnostics: [ManagementDiagnostic(
                        code: "gpg.configuration.duplicateDirectives",
                        severity: .warning,
                        message: "Multiple active pinentry-program directives were found.",
                        remediation: nil
                    )]
                )
            }

            let alignment: ConfigurationAlignment = pathsMatch(
                values[0],
                invokedPath: snapshot.invokedPath,
                resolvedPath: snapshot.resolvedPath
            )
                ? .currentBinary
                : .otherBinary
            let diagnostics: [ManagementDiagnostic] = alignment == .otherBinary
                ? [ManagementDiagnostic(
                    code: "gpg.configuration.foreignPinentry",
                    severity: .warning,
                    message: "The active pinentry-program points to a different binary.",
                    remediation: nil
                )]
                : []

            return ConfigurationInspection(
                presence: .readable,
                rawValues: values,
                displayValues: displayValues,
                alignment: alignment,
                diagnostics: diagnostics
            )
        }
    }

    static func pathsMatch(_ path: String, invokedPath: String, resolvedPath: String) -> Bool {
        path == invokedPath || path == resolvedPath ||
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == resolvedPath
    }

    struct ConfigurationInspection {
        var presence: ConfigurationPresence
        var rawValues: [String]
        var displayValues: [String]
        var alignment: ConfigurationAlignment
        var diagnostics: [ManagementDiagnostic]
    }
}
