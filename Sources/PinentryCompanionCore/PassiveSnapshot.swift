import CoreFoundation
import Foundation

enum PassiveConfigContents {
    case missing
    case readable(String)
    case unreadable
}

enum PassiveLifecycleState {
    case notTracked
    case tracked(record: LifecycleRecord, current: LifecycleTargetSnapshot?)
    case unreadable
}

struct PassiveSnapshot {
    var invokedPath: String
    var resolvedPath: String
    var architecture: String
    var userHomePath: String
    var homePath: String
    var configPath: String
    var configContents: PassiveConfigContents
    var dependencyPaths: [String: String]
    var preferenceState: PreferenceState
    var authenticationPolicyMode: String
    var lifecycle: PassiveLifecycleState = .notTracked
    var otherHomeRequiresManagedPreference = false
}

protocol PassiveSnapshotReading {
    func read() -> PassiveSnapshot
}

protocol PassivePreferenceReading {
    func readDisableKeychainPreference() -> PreferenceState
}

struct CFPreferencesReader: PassivePreferenceReading {
    func readDisableKeychainPreference() -> PreferenceState {
        guard let value = CFPreferencesCopyAppValue(
            "DisableKeychain" as CFString,
            "org.gpgtools.common" as CFString
        ) else { return .absent }

        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let enabled = value as? Bool else {
            return .wrongType
        }
        return enabled ? .enabled : .disabled
    }
}

struct LivePassiveSnapshotReader: PassiveSnapshotReading {
    private let executablePath: String
    private let environment: [String: String]
    private let preferenceReader: any PassivePreferenceReading
    private let lifecycleStateRootURL: URL

    init(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferenceReader: any PassivePreferenceReading = CFPreferencesReader(),
        lifecycleStateRootURL: URL = LifecycleStateStore.defaultRootURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
    ) {
        self.executablePath = executablePath
        self.environment = environment
        self.preferenceReader = preferenceReader
        self.lifecycleStateRootURL = lifecycleStateRootURL
    }

    func read() -> PassiveSnapshot {
        let homeURL = GPGAgentConfig.homeURL(environment: environment)
        let configURL = GPGAgentConfig.configURL(environment: environment)
        let resolvedPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        var dependencies: [String: String] = [:]

        for name in ["gpgconf", "pinentry-mac", "pinentry-curses", "pinentry-tty"] {
            if let path = ExecutableLookup.find(name, environment: environment) {
                dependencies[name] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }

        let lifecycle = readLifecycle(homeURL: homeURL, configURL: configURL)
        return PassiveSnapshot(
            invokedPath: executablePath,
            resolvedPath: resolvedPath,
            architecture: Self.architecture,
            userHomePath: environment["HOME"] ?? NSHomeDirectory(),
            homePath: homeURL.path,
            configPath: configURL.path,
            configContents: readConfig(homeURL: homeURL, configURL: configURL),
            dependencyPaths: dependencies,
            preferenceState: preferenceReader.readDisableKeychainPreference(),
            authenticationPolicyMode: LocalAuthenticator.summary,
            lifecycle: lifecycle.state,
            otherHomeRequiresManagedPreference: lifecycle.otherHomeRequiresManagedPreference
        )
    }

    private func readLifecycle(
        homeURL: URL,
        configURL: URL
    ) -> (state: PassiveLifecycleState, otherHomeRequiresManagedPreference: Bool) {
        let store = LifecycleStateStore(rootURL: lifecycleStateRootURL)
        do {
            guard let record = try store.load(canonicalHomePath: homeURL.path) else {
                return (.notTracked, false)
            }
            guard record.configPath == configURL.path else { return (.unreadable, false) }
            let current = try? FileSystemLifecycleTarget().snapshot(
                canonicalHomePath: homeURL.path,
                configPath: configURL.path
            )
            let otherHomeRequiresManagedPreference = try store.loadAll().contains {
                $0.canonicalHomePath != homeURL.path && $0.requiresManagedPreference
            }
            return (
                .tracked(record: record, current: current),
                otherHomeRequiresManagedPreference
            )
        } catch {
            return (.unreadable, false)
        }
    }

    private func readConfig(homeURL: URL, configURL: URL) -> PassiveConfigContents {
        guard let snapshot = try? FileSystemLifecycleTarget().snapshot(
            canonicalHomePath: homeURL.path,
            configPath: configURL.path
        ) else { return .unreadable }
        switch snapshot.config {
        case .missing:
            return .missing
        case .file(let data, _):
            guard let contents = String(data: data, encoding: .utf8) else { return .unreadable }
            return .readable(contents)
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
