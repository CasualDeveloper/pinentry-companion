import Foundation
import Darwin

public enum CommandLineEntry {
    public static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())

        if args == ["--version"] {
            printOutput("pinentry-companion \(ComponentVersion.current)")
            exit(0)
        }

        if args == ["status", "--format", "json"] {
            exit(runPassive(.status))
        }

        if args == ["plan", "--format", "json"] {
            exit(runPassive(.plan))
        }

        if LifecycleMachineCommand.isRequested(arguments: args) {
            let result = LifecycleMachineCommand.run(
                arguments: args,
                runner: LiveLifecycleMachineRunner()
            )
            FileHandle.standardOutput.write(result.data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(result.status)
        }

        if args.first == "status" || args.first == "plan" {
            printError("Machine commands require exactly `\(args.first ?? "command") --format json`.")
            exit(2)
        }

        if args == ["help"] || args == ["-h"] || args == ["--help"] {
            printUsage()
            exit(0)
        }

        if args == ["help", "doctor"] || args == ["doctor", "help"] || args == ["doctor", "-h"] || args == ["doctor", "--help"] {
            printDoctorUsage()
            exit(0)
        }

        if args == ["help", "doctor", "auth"] || args == ["doctor", "auth", "help"] || args == ["doctor", "auth", "-h"] || args == ["doctor", "auth", "--help"] {
            printDoctorAuthUsage()
            exit(0)
        }

        if args == ["help", "doctor", "report"] || args == ["doctor", "report", "help"] || args == ["doctor", "report", "-h"] || args == ["doctor", "report", "--help"] {
            printDoctorReportUsage()
            exit(0)
        }

        if args == ["help", "setup"] || args == ["setup", "help"] || args == ["setup", "-h"] || args == ["setup", "--help"] {
            printSetupUsage()
            exit(0)
        }

        if args == ["help", "restore"] || args == ["restore", "help"] || args == ["restore", "-h"] || args == ["restore", "--help"] {
            printRestoreUsage()
            exit(0)
        }

        if args == ["help", "cache", "purge"] || args == ["cache", "purge", "help"] || args == ["cache", "purge", "-h"] || args == ["cache", "purge", "--help"] {
            printCachePurgeUsage()
            exit(0)
        }

        if args == ["doctor"] {
            exit(runDoctor())
        }

        if args == ["doctor", "report"] {
            exit(runDoctorReport())
        }

        if args.first == "doctor", args.dropFirst().first == "auth" {
            exit(runDoctorAuth(args: Array(args.dropFirst(2))))
        }

        if args.first == "setup" {
            exit(runSetup(args: Array(args.dropFirst())))
        }

        if args.first == "restore" {
            exit(runRestore(
                args: Array(args.dropFirst()),
                commandName: "restore",
                preparingUninstall: false
            ))
        }

        if args.first == "uninstall" {
            guard args.dropFirst().first == "--prepare" else {
                printError("`uninstall` requires the explicit `--prepare` operation.")
                printError("Run `pinentry-companion help restore` for usage.")
                exit(2)
            }
            exit(runRestore(
                args: Array(args.dropFirst(2)),
                commandName: "uninstall --prepare",
                preparingUninstall: true
            ))
        }

        if args.first == "cache" {
            guard args.dropFirst().first == "purge" else {
                printError("Unknown cache operation. Run `pinentry-companion help cache purge` for usage.")
                exit(2)
            }
            exit(runCachePurge(args: Array(args.dropFirst(2))))
        }

        if args == ["-fix"] || args == ["--fix"] || args == ["fix"] {
            printError("-fix has been replaced by the safer `pinentry-companion setup` command.")
            printError("setup only updates user-owned GPG configuration and never rewrites Homebrew symlinks.")
            exit(2)
        }

        if !args.isEmpty {
            printError("Invalid arguments: \(args.joined(separator: " "))")
            if args.contains("-check") || args.contains("--check") || args.contains("check") {
                printError("Fix: use `pinentry-companion doctor`")
            } else {
                printError("Run `pinentry-companion help` for usage.")
            }
            exit(2)
        }

        let authenticator = LocalAuthenticator()
        let userData = ProcessInfo.processInfo.environment["PINENTRY_USER_DATA"] ?? ""

        do {
            if userData.contains("USE_CURSES=1") {
                try ExecutableLookup.execFallback(FallbackPinentryNames.preferred(userData: userData))
            }
            if !authenticator.canAuthenticate() {
                try ExecutableLookup.execFallback(FallbackPinentryNames.preferred(userData: userData))
            }
        } catch let error as Assuan.ProtocolError {
            Assuan.writeError(error)
            exit(1)
        } catch {
            Assuan.writeError(Assuan.ProtocolError(source: .pinentry, code: .noPinentry, sourceName: "pinentry", message: error.localizedDescription))
            exit(1)
        }

        PinentryServer().run()
        exit(0)
    }

    private static func printUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion

        Native macOS pinentry using LocalAuthentication and Keychain.

        Usage:
          pinentry-companion            Run pinentry protocol server on stdin/stdout
          pinentry-companion doctor     Check the local GPG/pinentry setup
          pinentry-companion doctor auth
                                        Run an interactive Touch ID/Watch auth check
          pinentry-companion doctor report
                                        Print safe Markdown diagnostics for bug reports
          pinentry-companion setup      Configure GPG to use pinentry-companion
          pinentry-companion restore    Restore configuration recorded by setup
          pinentry-companion uninstall --prepare
                                        Restore configuration before removing the binary
          pinentry-companion cache purge
                                        Explicitly delete component-owned passphrase cache entries
          pinentry-companion status --format json
                                        Print passive machine-readable status
          pinentry-companion plan --format json
                                        Print a passive machine-readable change plan
          pinentry-companion setup --yes --format json
                                        Apply setup with a strict machine response
          pinentry-companion restore --yes --format json
                                        Restore with a strict machine response
          pinentry-companion uninstall --prepare --yes --format json
                                        Prepare uninstall with a strict machine response
          pinentry-companion --version  Print the intrinsic component version
          pinentry-companion help       Show this help

        Help aliases:
          -h, --help                    Same as help

        Setup options:
          --dry-run                   Show changes without writing files
          -y, --yes                   Apply setup without an interactive prompt
          --take-over                 Explicitly replace a foreign pinentry-program

        """.utf8))
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func printOutput(_ message: String = "") {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    private static func runPassive(_ operation: PassiveOperation) -> Int32 {
        let reader = LivePassiveSnapshotReader(executablePath: currentExecutablePath())
        let result = PassiveCommand.run(operation: operation, reader: reader)
        FileHandle.standardOutput.write(result.data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return result.status
    }

}

public enum DiagnosticRedactor {
    public static func redact(_ value: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let homePath = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL.path
        let normalizedHome = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        guard !normalizedHome.isEmpty, normalizedHome != "/" else { return value }
        if value == normalizedHome { return "~" }
        return value.replacingOccurrences(of: normalizedHome + "/", with: "~/")
    }
}
