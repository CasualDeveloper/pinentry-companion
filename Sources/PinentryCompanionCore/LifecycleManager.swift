import Foundation

final class LifecycleManager {
    private let target: any LifecycleTargetManaging
    private let preference: any LifecyclePreferenceManaging
    private let agent: any LifecycleAgentReloading
    private let state: any LifecycleStatePersisting
    private let locks: any LifecycleLockProviding
    private let now: () -> Date

    init(
        target: any LifecycleTargetManaging,
        preference: any LifecyclePreferenceManaging,
        agent: any LifecycleAgentReloading,
        state: any LifecycleStatePersisting,
        locks: any LifecycleLockProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.target = target
        self.preference = preference
        self.agent = agent
        self.state = state
        self.locks = locks
        self.now = now
    }

    func setup(_ request: LifecycleSetupRequest) throws -> LifecycleOperationResult {
        let lock = try locks.acquire(canonicalHomePath: request.canonicalHomePath)
        return try withExtendedLifetime(lock) { try setupLocked(request) }
    }

    func restore(canonicalHomePath: String) throws -> LifecycleOperationResult {
        let lock = try locks.acquire(canonicalHomePath: canonicalHomePath)
        return try withExtendedLifetime(lock) { try restoreLocked(canonicalHomePath: canonicalHomePath) }
    }

    func prepareUninstall(
        canonicalHomePath: String,
        removingBinary: LifecycleBinaryIdentity
    ) throws -> LifecycleOperationResult {
        let lock = try locks.acquire(canonicalHomePath: canonicalHomePath)
        return try withExtendedLifetime(lock) {
            guard let record = try state.load(canonicalHomePath: canonicalHomePath) else {
                throw LifecycleError.notManaged
            }
            try requireUninstallSafe(record: record, removingBinary: removingBinary)
            return try restoreLocked(canonicalHomePath: canonicalHomePath)
        }
    }

    func previewRestore(canonicalHomePath: String) throws -> LifecycleOperationResult {
        guard let record = try state.load(canonicalHomePath: canonicalHomePath) else {
            throw LifecycleError.notManaged
        }
        let restoredPreference = preferenceAfterReleasing(record, among: try state.loadAll())
        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        let currentPreference = try preference.read()
        let matchesOriginal = current.home == record.originalHome &&
            current.config == record.originalConfig && currentPreference == restoredPreference

        switch record.phase {
        case .restored:
            try require(
                target: current,
                preference: currentPreference,
                matchesOriginalIn: record,
                preferenceOverride: restoredPreference
            )
            return .unchanged
        case .complete:
            try require(target: current, preference: currentPreference, matchesExpectedIn: record)
            return matchesOriginal ? .unchanged : .restored
        case .rolledBack:
            try requireCurrentState(matchesTransactionBaseIn: record)
            return matchesOriginal ? .unchanged : .restored
        case .prepared, .configApplied, .preferenceApplied, .agentReloaded, .rollingBack,
             .restorePrepared, .configRestored, .preferenceRestored:
            try requireRecoverable(
                target: current,
                preference: currentPreference,
                record: record
            )
            return matchesOriginal ? .unchanged : .restored
        case .failed:
            throw LifecycleError.incompleteTransaction(record.phase)
        }
    }

    func previewUninstallPreparation(
        canonicalHomePath: String,
        removingBinary: LifecycleBinaryIdentity
    ) throws -> LifecycleOperationResult {
        guard let record = try state.load(canonicalHomePath: canonicalHomePath) else {
            throw LifecycleError.notManaged
        }
        try requireUninstallSafe(record: record, removingBinary: removingBinary)
        return try previewRestore(canonicalHomePath: canonicalHomePath)
    }

    private func requireUninstallSafe(
        record: LifecycleRecord,
        removingBinary: LifecycleBinaryIdentity
    ) throws {
        let contents: String
        switch record.originalConfig {
        case .missing:
            return
        case .file(let data, _):
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw LifecycleError.invalidConfiguration("recorded original gpg-agent.conf is not valid UTF-8")
            }
            contents = decoded
        }

        let identities = [removingBinary, record.binary]
        let leavesRemovedBinaryActive = GPGAgentConfig.activePinentryPrograms(in: contents)
            .contains { configuredPath in
                if !configuredPath.hasPrefix("/") {
                    return URL(fileURLWithPath: configuredPath).lastPathComponent == "pinentry-companion"
                }
                return identities.contains { identity in
                    PassiveStatusBuilder.pathsMatch(
                        configuredPath,
                        invokedPath: identity.invokedPath,
                        resolvedPath: identity.resolvedPath
                    )
                }
            }
        if leavesRemovedBinaryActive {
            throw LifecycleError.uninstallWouldLeaveActiveConfiguration
        }
    }

    private func setupLocked(_ request: LifecycleSetupRequest) throws -> LifecycleOperationResult {
        var existing = try state.load(canonicalHomePath: request.canonicalHomePath)
        var stateBeforePreparation = existing
        var ownsCurrentConfiguration = false

        if var record = existing {
            switch record.phase {
            case .complete:
                try requireCurrentState(matchesExpectedIn: record)
                if record.binary == request.binary { return .unchanged }
                ownsCurrentConfiguration = true
            case .restored:
                existing = nil
            case .rolledBack:
                try requireCurrentState(matchesTransactionBaseIn: record)
                ownsCurrentConfiguration = record.transactionBaseConfig != record.originalConfig
            case .prepared, .configApplied, .preferenceApplied, .agentReloaded, .rollingBack:
                ownsCurrentConfiguration = record.transactionBaseConfig != record.originalConfig
                _ = try recover(
                    &record,
                    to: .transactionBase,
                    beginPhase: .rollingBack,
                    finalPhase: .rolledBack
                )
                existing = record
                stateBeforePreparation = record
            case .restorePrepared, .configRestored, .preferenceRestored:
                _ = try recover(
                    &record,
                    to: .expected,
                    beginPhase: .rollingBack,
                    finalPhase: .complete
                )
                existing = record
                stateBeforePreparation = record
                if record.binary == request.binary { return .recovered }
                ownsCurrentConfiguration = true
            case .failed:
                throw LifecycleError.incompleteTransaction(record.phase)
            }
        }

        let currentTarget = try target.snapshot(
            canonicalHomePath: request.canonicalHomePath,
            configPath: request.configPath
        )
        let currentPreference = try preference.read()
        if case .unsupported = currentPreference { throw LifecycleError.unsupportedPreference }

        let suitePreferenceBaseline = try state.loadAll()
            .filter {
                $0.canonicalHomePath != request.canonicalHomePath && $0.requiresManagedPreference
            }
            .min { $0.createdAt < $1.createdAt }?
            .originalPreference

        let record = try makeRecord(
            request: request,
            target: currentTarget,
            preference: currentPreference,
            preserving: existing,
            ownsCurrentConfiguration: ownsCurrentConfiguration,
            suitePreferenceBaseline: suitePreferenceBaseline
        )
        try state.save(record)
        return try applySetup(record, restoringStateOnRejectedPreparation: stateBeforePreparation)
    }

    private func makeRecord(
        request: LifecycleSetupRequest,
        target: LifecycleTargetSnapshot,
        preference: LifecyclePreferenceState,
        preserving prior: LifecycleRecord?,
        ownsCurrentConfiguration: Bool,
        suitePreferenceBaseline: LifecyclePreferenceState?
    ) throws -> LifecycleRecord {
        let configContents: String
        let configExists: Bool
        let configMode: UInt16
        switch target.config {
        case .missing:
            configContents = ""
            configExists = false
            configMode = 0o600
        case .file(let data, let mode):
            guard let contents = String(data: data, encoding: .utf8) else {
                throw LifecycleError.invalidConfiguration("gpg-agent.conf is not valid UTF-8")
            }
            configContents = contents
            configExists = true
            configMode = mode
        }

        let change = try GPGDirectivePlanner.plan(
            contents: configContents,
            exists: configExists,
            invokedPath: request.binary.invokedPath,
            resolvedPath: request.binary.resolvedPath,
            allowTakeover: request.takeOver || ownsCurrentConfiguration
        )
        if change.conflict != nil { throw LifecycleError.foreignConfiguration }

        let expectedHome: LifecycleHomeState = target.home == .missing
            ? .directory(mode: 0o700)
            : target.home

        let timestamp = now()
        let record = LifecycleRecord(
            schemaVersion: 1,
            componentVersion: ComponentVersion.current,
            canonicalHomePath: request.canonicalHomePath,
            configPath: request.configPath,
            binary: request.binary,
            originalConfig: prior?.originalConfig ?? target.config,
            expectedConfig: .file(data: Data(change.updatedContents.utf8), mode: configMode),
            originalHome: prior?.originalHome ?? target.home,
            expectedHome: expectedHome,
            originalPreference: prior?.originalPreference ?? suitePreferenceBaseline ?? preference,
            expectedPreference: .boolean(true),
            transactionBaseConfig: target.config,
            transactionBaseHome: target.home,
            transactionBasePreference: preference,
            phase: .prepared,
            createdAt: prior?.createdAt ?? timestamp,
            updatedAt: timestamp
        )
        try record.validate()
        return record
    }

    private func applySetup(
        _ prepared: LifecycleRecord,
        restoringStateOnRejectedPreparation previousState: LifecycleRecord?
    ) throws -> LifecycleOperationResult {
        var record = prepared
        let initial = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        let initialPreference = try preference.read()
        do {
            try require(
                target: initial,
                preference: initialPreference,
                matchesTransactionBaseIn: record
            )
        } catch {
            let primary = lifecycleError(error)
            do {
                if let previousState {
                    try state.save(previousState)
                } else {
                    try state.remove(canonicalHomePath: record.canonicalHomePath)
                }
            } catch {
                throw LifecycleError.rollbackFailed(
                    primary: primary.description,
                    rollback: lifecycleError(error).description
                )
            }
            throw primary
        }
        let reloadRequired = initial.config != record.expectedConfig || initialPreference != record.expectedPreference

        do {
            if initial.home != record.expectedHome {
                try target.applyHome(record.expectedHome, canonicalHomePath: record.canonicalHomePath)
            }
            if initial.config != record.expectedConfig {
                try target.applyConfig(record.expectedConfig, configPath: record.configPath)
            }
            try save(&record, phase: .configApplied)

            if initialPreference != record.expectedPreference {
                try preference.apply(record.expectedPreference)
            }
            try save(&record, phase: .preferenceApplied)

            if reloadRequired { try agent.reload() }
            try save(&record, phase: .agentReloaded)
            try requireCurrentState(matchesExpectedIn: record)
            try save(&record, phase: .complete)
            return initial.home == record.expectedHome && !reloadRequired
                ? .ownershipRecorded
                : .changed
        } catch {
            let primary = lifecycleError(error)
            do {
                try rollbackSetup(&record)
            } catch {
                throw LifecycleError.rollbackFailed(
                    primary: primary.description,
                    rollback: lifecycleError(error).description
                )
            }
            throw primary
        }
    }

    private func rollbackSetup(_ record: inout LifecycleRecord) throws {
        _ = try recover(
            &record,
            to: .transactionBase,
            beginPhase: .rollingBack,
            finalPhase: .rolledBack
        )
    }

    private func restoreLocked(canonicalHomePath: String) throws -> LifecycleOperationResult {
        guard var record = try state.load(canonicalHomePath: canonicalHomePath) else {
            throw LifecycleError.notManaged
        }
        let restoredPreference = preferenceAfterReleasing(record, among: try state.loadAll())
        if record.phase == .restored {
            try requireCurrentState(
                matchesOriginalIn: record,
                preferenceOverride: restoredPreference
            )
            return .unchanged
        }
        if record.phase == .rolledBack {
            try requireCurrentState(matchesTransactionBaseIn: record)
            let changed = try recover(
                &record,
                to: .original,
                beginPhase: .restorePrepared,
                finalPhase: .restored,
                preferenceOverride: restoredPreference
            )
            return changed ? .restored : .unchanged
        }
        if record.phase != .complete {
            switch record.phase {
            case .prepared, .configApplied, .preferenceApplied, .agentReloaded, .rollingBack,
                 .restorePrepared, .configRestored, .preferenceRestored:
                let changed = try recover(
                    &record,
                    to: .original,
                    beginPhase: .restorePrepared,
                    finalPhase: .restored,
                    preferenceOverride: restoredPreference
                )
                return changed ? .restored : .unchanged
            case .failed:
                throw LifecycleError.incompleteTransaction(record.phase)
            case .complete, .rolledBack, .restored:
                break
            }
        }

        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        let currentPreference = try preference.read()
        try require(target: current, preference: currentPreference, matchesExpectedIn: record)

        try save(&record, phase: .restorePrepared)
        do {
            if current.config != record.originalConfig {
                try target.applyConfig(record.originalConfig, configPath: record.configPath)
            }
            try save(&record, phase: .configRestored)
            if currentPreference != restoredPreference {
                try preference.apply(restoredPreference)
            }
            try save(&record, phase: .preferenceRestored)
            if current.home != record.originalHome {
                try target.applyHome(record.originalHome, canonicalHomePath: record.canonicalHomePath)
            }
            if current.config != record.originalConfig || currentPreference != restoredPreference {
                try agent.reload()
            }
            try requireCurrentState(
                matchesOriginalIn: record,
                preferenceOverride: restoredPreference
            )
            try save(&record, phase: .restored)
            return .restored
        } catch {
            let primary = lifecycleError(error)
            do {
                _ = try recover(
                    &record,
                    to: .expected,
                    beginPhase: .rollingBack,
                    finalPhase: .complete
                )
            } catch {
                throw LifecycleError.rollbackFailed(
                    primary: primary.description,
                    rollback: lifecycleError(error).description
                )
            }
            throw primary
        }
    }

    private enum RecoveryTarget {
        case original
        case expected
        case transactionBase
    }

    @discardableResult
    private func recover(
        _ record: inout LifecycleRecord,
        to recoveryTarget: RecoveryTarget,
        beginPhase: LifecyclePhase,
        finalPhase: LifecyclePhase,
        preferenceOverride: LifecyclePreferenceState? = nil
    ) throws -> Bool {
        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        let currentPreference = try preference.read()
        try requireRecoverable(target: current, preference: currentPreference, record: record)

        let desired = states(for: recoveryTarget, in: record)
        let desiredPreference = preferenceOverride ?? desired.preference
        let changed = current.home != desired.home ||
            current.config != desired.config || currentPreference != desiredPreference
        let reloadRequired = current.config != desired.config || currentPreference != desiredPreference

        // A failed marker write must never prevent restoration. The final durable
        // phase is authoritative once the target state has been verified.
        try? save(&record, phase: beginPhase)
        if current.config != desired.config {
            try target.applyConfig(desired.config, configPath: record.configPath)
        }
        if currentPreference != desiredPreference {
            try preference.apply(desiredPreference)
        }
        if current.home != desired.home {
            try target.applyHome(desired.home, canonicalHomePath: record.canonicalHomePath)
        }
        if reloadRequired { try agent.reload() }
        try requireCurrentState(
            record,
            matches: recoveryTarget,
            preferenceOverride: preferenceOverride
        )
        try save(&record, phase: finalPhase)
        return changed
    }

    private func states(
        for recoveryTarget: RecoveryTarget,
        in record: LifecycleRecord
    ) -> (home: LifecycleHomeState, config: LifecycleFileState, preference: LifecyclePreferenceState) {
        switch recoveryTarget {
        case .original:
            return (record.originalHome, record.originalConfig, record.originalPreference)
        case .expected:
            return (record.expectedHome, record.expectedConfig, record.expectedPreference)
        case .transactionBase:
            return (
                record.transactionBaseHome,
                record.transactionBaseConfig,
                record.transactionBasePreference
            )
        }
    }

    private func requireRecoverable(
        target: LifecycleTargetSnapshot,
        preference: LifecyclePreferenceState,
        record: LifecycleRecord
    ) throws {
        let homes = [record.originalHome, record.expectedHome, record.transactionBaseHome]
        let configs = [record.originalConfig, record.expectedConfig, record.transactionBaseConfig]
        let preferences = [
            record.originalPreference,
            record.expectedPreference,
            record.transactionBasePreference,
        ]
        if !homes.contains(target.home) { throw LifecycleError.drift("GNUPGHOME") }
        if !configs.contains(target.config) { throw LifecycleError.drift("gpg-agent.conf") }
        if !preferences.contains(preference) { throw LifecycleError.drift("DisableKeychain") }
    }

    private func requireCurrentState(
        _ record: LifecycleRecord,
        matches recoveryTarget: RecoveryTarget,
        preferenceOverride: LifecyclePreferenceState? = nil
    ) throws {
        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        let currentPreference = try preference.read()
        let desired = states(for: recoveryTarget, in: record)
        if current.home != desired.home { throw LifecycleError.drift("GNUPGHOME") }
        if current.config != desired.config { throw LifecycleError.drift("gpg-agent.conf") }
        if currentPreference != (preferenceOverride ?? desired.preference) {
            throw LifecycleError.drift("DisableKeychain")
        }
    }

    private func requireCurrentState(matchesExpectedIn record: LifecycleRecord) throws {
        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        try require(target: current, preference: try preference.read(), matchesExpectedIn: record)
    }

    private func requireCurrentState(
        matchesOriginalIn record: LifecycleRecord,
        preferenceOverride: LifecyclePreferenceState? = nil
    ) throws {
        let current = try target.snapshot(
            canonicalHomePath: record.canonicalHomePath,
            configPath: record.configPath
        )
        try require(
            target: current,
            preference: try preference.read(),
            matchesOriginalIn: record,
            preferenceOverride: preferenceOverride
        )
    }

    private func requireCurrentState(matchesTransactionBaseIn record: LifecycleRecord) throws {
        try requireCurrentState(record, matches: .transactionBase)
    }

    private func require(
        target: LifecycleTargetSnapshot,
        preference: LifecyclePreferenceState,
        matchesTransactionBaseIn record: LifecycleRecord
    ) throws {
        if target.home != record.transactionBaseHome { throw LifecycleError.drift("GNUPGHOME") }
        if target.config != record.transactionBaseConfig {
            throw LifecycleError.drift("gpg-agent.conf")
        }
        if preference != record.transactionBasePreference {
            throw LifecycleError.drift("DisableKeychain")
        }
    }

    private func require(
        target: LifecycleTargetSnapshot,
        preference: LifecyclePreferenceState,
        matchesExpectedIn record: LifecycleRecord
    ) throws {
        if target.home != record.expectedHome { throw LifecycleError.drift("GNUPGHOME") }
        if target.config != record.expectedConfig { throw LifecycleError.drift("gpg-agent.conf") }
        if preference != record.expectedPreference { throw LifecycleError.drift("DisableKeychain") }
    }

    private func require(
        target: LifecycleTargetSnapshot,
        preference: LifecyclePreferenceState,
        matchesOriginalIn record: LifecycleRecord,
        preferenceOverride: LifecyclePreferenceState? = nil
    ) throws {
        if target.home != record.originalHome { throw LifecycleError.drift("GNUPGHOME") }
        if target.config != record.originalConfig { throw LifecycleError.drift("gpg-agent.conf") }
        if preference != (preferenceOverride ?? record.originalPreference) {
            throw LifecycleError.drift("DisableKeychain")
        }
    }

    private func save(_ record: inout LifecycleRecord, phase: LifecyclePhase) throws {
        record.phase = phase
        record.updatedAt = now()
        try state.save(record)
    }
}
