import Darwin
import Foundation

extension CommandLineEntry {
    static func runSetup(args: [String]) -> Int32 {
        var dryRun = false
        var yes = false
        var takeOver = false

        for arg in args {
            switch arg {
            case "help", "-h", "--help":
                printSetupUsage()
                return 0
            case "--dry-run":
                dryRun = true
            case "-y", "--yes":
                yes = true
            case "--take-over":
                takeOver = true
            default:
                printError("Invalid setup option: \(arg)")
                printError("Run `pinentry-companion help setup` for usage.")
                return 2
            }
        }

        let currentPath = currentExecutablePath()
        let homeURL = GPGAgentConfig.homeURL()
        let configURL = GPGAgentConfig.configURL()
        let initialSnapshot: LifecycleTargetSnapshot
        do {
            initialSnapshot = try FileSystemLifecycleTarget().snapshot(
                canonicalHomePath: homeURL.path,
                configPath: configURL.path
            )
        } catch {
            printError("Error: \(error)")
            return 1
        }
        let initialPreference: LifecyclePreferenceState
        do {
            initialPreference = try LifecyclePreferenceStore().read()
            if case .unsupported = initialPreference {
                printError("Error: DisableKeychain has an unsupported preference type.")
                return 1
            }
        } catch {
            printError("Error reading DisableKeychain: \(error)")
            return 1
        }

        let configContents: String
        let configExists: Bool
        switch initialSnapshot.config {
        case .missing:
            configContents = ""
            configExists = false
        case .file(let data, _):
            guard let contents = String(data: data, encoding: .utf8) else {
                printError("Error: gpg-agent.conf is not valid UTF-8.")
                return 1
            }
            configContents = contents
            configExists = true
        }

        let stateStore = LifecycleStateStore(rootURL: LifecycleStateStore.defaultRootURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        ))
        let ownershipAllowsReplacement: Bool
        do {
            ownershipAllowsReplacement = try stateStore
                .load(canonicalHomePath: homeURL.path)
                .map { record in
                    initialSnapshot.config == record.expectedConfig ||
                        (record.transactionBaseConfig != record.originalConfig &&
                            initialSnapshot.config == record.transactionBaseConfig)
                } ?? false
        } catch {
            printError("Error reading lifecycle state: \(error)")
            return 1
        }

        let plannedChange: GPGDirectiveChange
        do {
            plannedChange = try GPGDirectivePlanner.plan(
                contents: configContents,
                exists: configExists,
                invokedPath: currentPath,
                resolvedPath: resolvedPath(currentPath),
                allowTakeover: takeOver || ownershipAllowsReplacement
            )
            if let conflict = plannedChange.conflict {
                printError("Error: \(conflict.message)")
                printError("Re-run with `--take-over` only if replacing it is intentional.")
                return 1
            }
        } catch {
            printError("Error: \(error)")
            return 1
        }

        printOutput("pinentry-companion setup")
        printOutput()
        printOutput("pinentry-companion: \(currentPath)")
        printOutput("gpg-agent.conf:   \(configURL.path)")

        if ExecutableLookup.find("pinentry-mac") == nil, ExecutableLookup.findFirst(FallbackPinentryNames.preferred().filter { $0 != "pinentry-mac" }) == nil {
            printError("Error: no fallback pinentry was found. Install pinentry-mac with `brew install pinentry-mac`.")
            return 1
        }

        guard let gpgconfPath = ExecutableLookup.find("gpgconf") else {
            printError("Error: gpgconf was not found; install GnuPG before setup.")
            return 1
        }

        let configChanged = plannedChange.updatedContents != configContents
        let preferenceChanged = initialPreference != .boolean(true)
        if dryRun {
            printOutput(configChanged ? "Would update gpg-agent.conf." : "gpg-agent.conf already points at this binary.")
            printOutput(preferenceChanged
                ? "Would set the org.gpgtools.common DisableKeychain preference to true."
                : "The org.gpgtools.common DisableKeychain preference is already true.")
            printOutput("Would record exact restore state before mutation.")
            printOutput(configChanged || preferenceChanged
                ? "Would reload gpg-agent through gpgconf."
                : "No gpg-agent reload is required.")
            return 0
        }

        if !yes && isatty(STDIN_FILENO) != 0 {
            printOutput()
            printOutput("This will transactionally update user-owned GPG configuration and record exact restore state.")
            if takeOver { printOutput("A foreign pinentry-program will be replaced by explicit request.") }
            FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
            let answer = readLine(strippingNewline: true)?.lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                printOutput("Canceled.")
                return 1
            }
        } else if !yes && isatty(STDIN_FILENO) == 0 {
            printError("Refusing to change configuration without a TTY. Re-run with `--yes` or `--dry-run`.")
            return 2
        }

        do {
            guard let runningExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                printError("Setup failed: could not identify the running executable.")
                return 1
            }
            let identity = try LifecycleBinaryIdentity.read(
                invokedPath: currentPath,
                expectedResolvedPath: runningExecutable
            )
            let manager = makeLifecycleManager(gpgconfPath: gpgconfPath)
            let result = try manager.setup(LifecycleSetupRequest(
                canonicalHomePath: homeURL.path,
                configPath: configURL.path,
                binary: identity,
                takeOver: takeOver
            ))
            switch result {
            case .changed:
                printOutput("Configured: \(configURL.path)")
                printOutput("Recorded reversible lifecycle state.")
                printOutput("Reloaded gpg-agent.")
            case .unchanged:
                printOutput("Already configured and lifecycle state is current.")
            case .restored:
                break
            }
        } catch {
            printError("Setup failed: \(error)")
            return 1
        }

        printOutput("Run `pinentry-companion doctor` to verify.")
        return 0
    }

    static func runRestore(
        args: [String],
        commandName: String,
        preparingUninstall: Bool
    ) -> Int32 {
        var dryRun = false
        var yes = false
        for arg in args {
            switch arg {
            case "help", "-h", "--help":
                printRestoreUsage()
                return 0
            case "--dry-run":
                dryRun = true
            case "-y", "--yes":
                yes = true
            default:
                printError("Invalid restore option: \(arg)")
                printError("Run `pinentry-companion help restore` for usage.")
                return 2
            }
        }

        let homeURL = GPGAgentConfig.homeURL()
        let configURL = GPGAgentConfig.configURL()
        let stateRoot = LifecycleStateStore.defaultRootURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let stateStore = LifecycleStateStore(rootURL: stateRoot)
        let recordPhase: LifecyclePhase
        do {
            guard let record = try stateStore.load(canonicalHomePath: homeURL.path) else {
                printError("Error: no lifecycle record exists for this GNUPGHOME.")
                return 1
            }
            guard record.configPath == configURL.path else {
                printError("Error: lifecycle record does not match the current GPG configuration path.")
                return 1
            }
            recordPhase = record.phase
        } catch {
            printError("Error reading lifecycle state: \(error)")
            return 1
        }

        let removingBinary: LifecycleBinaryIdentity?
        if preparingUninstall {
            do {
                removingBinary = try RunningLifecycleBinaryIdentity.read()
            } catch {
                printError("Uninstall preparation failed: could not verify the running binary identity.")
                return 1
            }
        } else {
            removingBinary = nil
        }

        printOutput("pinentry-companion \(commandName)")
        printOutput()
        printOutput("gpg-agent.conf: \(configURL.path)")
        let preview: LifecycleOperationResult
        do {
            let manager = makeLifecycleManager(gpgconfPath: "/usr/bin/false")
            if let removingBinary {
                preview = try manager.previewUninstallPreparation(
                    canonicalHomePath: homeURL.path,
                    removingBinary: removingBinary
                )
            } else {
                preview = try manager.previewRestore(canonicalHomePath: homeURL.path)
            }
        } catch {
            printError("Restore preview failed: \(error)")
            return 1
        }
        if dryRun {
            if preview == .unchanged {
                printOutput("Recorded original state is already present.")
                printOutput("No configuration, preference, or agent reload would change.")
            } else {
                printOutput("Restore is permitted by the recorded compare-and-swap state.")
                printOutput("Would restore the recorded configuration and preference, then reload gpg-agent.")
            }
            return 0
        }
        if preview == .unchanged, recordPhase == .restored {
            printOutput("Configuration was already restored.")
            return 0
        }

        guard let gpgconfPath = ExecutableLookup.find("gpgconf") else {
            printError("Error: gpgconf was not found; restoration requires a safe agent reload.")
            return 1
        }
        if !yes && isatty(STDIN_FILENO) != 0 {
            printOutput("This will restore the exact configuration and preference recorded before setup.")
            FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
            let answer = readLine(strippingNewline: true)?.lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                printOutput("Canceled.")
                return 1
            }
        } else if !yes {
            printError("Refusing to restore configuration without a TTY. Re-run with `--yes` or `--dry-run`.")
            return 2
        }

        do {
            let manager = makeLifecycleManager(gpgconfPath: gpgconfPath)
            let result: LifecycleOperationResult
            if let removingBinary {
                result = try manager.prepareUninstall(
                    canonicalHomePath: homeURL.path,
                    removingBinary: removingBinary
                )
            } else {
                result = try manager.restore(canonicalHomePath: homeURL.path)
            }
            printOutput(result == .unchanged ? "Configuration was already restored." : "Restored recorded configuration.")
            return 0
        } catch {
            printError("Restore failed: \(error)")
            return 1
        }
    }

    private static func makeLifecycleManager(gpgconfPath: String) -> LifecycleManager {
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

    static func runCachePurge(args: [String]) -> Int32 {
        var dryRun = false
        var yes = false
        for arg in args {
            switch arg {
            case "help", "-h", "--help":
                printCachePurgeUsage()
                return 0
            case "--dry-run": dryRun = true
            case "-y", "--yes": yes = true
            default:
                printError("Invalid cache purge option: \(arg)")
                printError("Run `pinentry-companion help cache purge` for usage.")
                return 2
            }
        }

        printOutput("pinentry-companion cache purge")
        printOutput()
        printOutput("Owned Keychain services: \(PinentryCacheServices.all.joined(separator: ", "))")
        if dryRun {
            printOutput("Would delete all generic-password items in those services only.")
            return 0
        }

        if !yes && isatty(STDIN_FILENO) != 0 {
            printOutput("This permanently deletes cached GPG passphrases owned by pinentry-companion.")
            printOutput("GPG private keys and unrelated Keychain items are not targeted.")
            FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
            let answer = readLine(strippingNewline: true)?.lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                printOutput("Canceled.")
                return 1
            }
        } else if !yes {
            printError("Refusing to delete cached passphrases without a TTY. Re-run with `--yes` or `--dry-run`.")
            return 2
        }

        do {
            let result = try KeychainCachePurger().purge()
            printOutput("Purged \(result.serviceGroupsDeleted) non-empty service group(s); \(result.serviceGroupsAlreadyEmpty) already empty.")
            return 0
        } catch {
            printError("Cache purge failed: \(error)")
            return 1
        }
    }


    static func printSetupUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion setup

        Configure GPG to use pinentry-companion.

        Usage:
          pinentry-companion setup [--dry-run] [-y|--yes]
          pinentry-companion setup --yes --format json
          pinentry-companion setup --take-over --yes --format json
          pinentry-companion help setup

        Options:
          --dry-run   Show changes without writing files
          -y, --yes   Apply setup without an interactive prompt
          --take-over Explicitly replace a foreign pinentry-program and record it for restore
          -h, --help  Same as help setup

        """.utf8))
    }

    static func printRestoreUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion restore

        Restore the exact GPG configuration and preference recorded by setup.

        Usage:
          pinentry-companion restore [--dry-run] [-y|--yes]
          pinentry-companion uninstall --prepare [--dry-run] [-y|--yes]
          pinentry-companion restore --yes --format json
          pinentry-companion uninstall --prepare --yes --format json
          pinentry-companion help restore

        Restoration uses compare-and-swap checks and refuses unrecognized drift.
        Uninstall preparation also refuses a restored configuration that still
        invokes the binary being removed.
        It does not delete cached passphrases; cache removal is a separate explicit action.

        Options:
          --dry-run   Describe restoration without changing state
          -y, --yes   Restore without an interactive prompt
          -h, --help  Same as help restore

        """.utf8))
    }

    static func printCachePurgeUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion cache purge

        Explicitly delete cached GPG passphrases owned by pinentry-companion.

        Usage:
          pinentry-companion cache purge [--dry-run] [-y|--yes]
          pinentry-companion help cache purge

        This targets only the pinentry-companion and pinentry-companion.acl generic-
        password services. It does not delete GPG keys or unrelated Keychain items.

        Options:
          --dry-run   Describe the exact service scope without deleting items
          -y, --yes   Purge without an interactive prompt
          -h, --help  Same as help cache purge

        """.utf8))
    }

}
