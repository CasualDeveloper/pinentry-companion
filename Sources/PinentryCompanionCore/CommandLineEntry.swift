import Foundation
import Darwin

public enum CommandLineEntry {
    public static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())

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
          pinentry-companion help       Show this help

        Help aliases:
          -h, --help                    Same as help

        Setup options:
          --dry-run                   Show changes without writing files
          -y, --yes                   Apply setup without an interactive prompt

        """.utf8))
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func printOutput(_ message: String = "") {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    private static func runDoctor() -> Int32 {
        printOutput("pinentry-companion doctor")
        printOutput()

        var failures = 0
        let currentPath = currentExecutablePath()
        report(.ok, "pinentry-companion", currentPath)

        let protocolCheck = runProtocolCheck(currentPath)
        if protocolCheck.passed {
            report(.ok, "pinentry protocol", protocolCheck.detail)
        } else {
            failures += 1
            report(.fail, "pinentry protocol", protocolCheck.detail)
        }

        if let path = ExecutableLookup.find("pinentry-mac") {
            report(.ok, "pinentry-mac", resolvedPath(path))
        } else if let fallback = ExecutableLookup.findFirst(FallbackPinentryNames.preferred().filter { $0 != "pinentry-mac" }) {
            report(.warn, "pinentry-mac", "not found; fallback available: \(resolvedPath(fallback.path))")
        } else {
            failures += 1
            report(.fail, "pinentry-mac", "not found; install with `brew install pinentry-mac` or provide pinentry-curses/pinentry-tty")
        }

        report(.ok, "Local authentication", LocalAuthenticator.summary)
        let keychainStorageCheck = KeychainStorage.storageCheck()
        if keychainStorageCheck.passed {
            report(.ok, "Keychain storage", keychainStorageCheck.detail)
        } else {
            failures += 1
            report(.fail, "Keychain storage", keychainStorageCheck.detail)
        }

        let keychainACLCheck = KeychainAccessPolicy.storageCheck()
        if keychainACLCheck.canStore, keychainACLCheck.usesPreferredPolicy {
            report(.ok, "Keychain ACL storage", keychainACLCheck.detail)
        } else if keychainACLCheck.canStore {
            report(.warn, "Keychain ACL storage", keychainACLCheck.detail)
        } else {
            report(.warn, "Keychain ACL storage", keychainACLCheck.detail)
        }

        if let path = ExecutableLookup.find("gpgconf") {
            report(.ok, "gpgconf", path)
        } else {
            failures += 1
            report(.fail, "gpgconf", "not found; install GnuPG with `brew install gnupg`")
        }

        let configURL = GPGAgentConfig.configURL()
        switch configPinentryStatus(configURL: configURL, expectedPath: currentPath) {
        case .ok(let detail):
            report(.ok, "gpg-agent.conf", detail)
        case .fail(let detail):
            failures += 1
            report(.fail, "gpg-agent.conf", detail)
        }

        switch pinentryMacKeychainDisabled() {
        case true:
            report(.ok, "pinentry-mac Keychain", "disabled")
        case false:
            report(.warn, "pinentry-mac Keychain", "not disabled; `pinentry-companion setup` can set this")
        }

        printOutput()
        if failures == 0 {
            printOutput("All required checks passed.")
            return 0
        }

        printError("\(failures) required check\(failures == 1 ? "" : "s") failed. Run `pinentry-companion setup` to fix user configuration.")
        return 1
    }

    private static func runDoctorReport() -> Int32 {
        let currentPath = currentExecutablePath()
        let configURL = GPGAgentConfig.configURL()
        let configContents = try? String(contentsOf: configURL, encoding: .utf8)
        let configuredPinentry = configContents.flatMap { GPGAgentConfig.activePinentryProgram(in: $0) }

        printOutput("# pinentry-companion doctor report")
        printOutput()
        printOutput("This report redacts the home directory as `~` and does not include GPG keys, passphrases, Keychain items, or the full `gpg-agent.conf` contents.")
        printOutput()
        printOutput("## System")
        printReportItem("macOS", macOSVersion())
        printReportItem("architecture", processOutput("uname", ["-m"]))
        printOutput()

        printOutput("## pinentry-companion")
        printReportItem("binary", redactedInlineCode(currentPath))
        printReportItem("resolved binary", redactedInlineCode(resolvedPath(currentPath)))
        printReportItem("Homebrew package", homebrewPackageVersion())
        printReportItem("Local authentication", inlineCode(LocalAuthenticator.summary))
        printReportItem("Keychain storage", KeychainStorage.storageCheck().detail)
        printReportItem("Keychain ACL storage", KeychainAccessPolicy.storageCheck().detail)
        printReportItem("protocol GETINFO", runProtocolCheck(currentPath).detail)
        printOutput()

        printOutput("## Dependencies")
        printReportItem("gpg", commandVersion("gpg"))
        printReportItem("gpg-agent", commandVersion("gpg-agent"))
        printReportItem("gpgconf", commandVersion("gpgconf"))
        printReportItem("swift", commandVersion("swift"))
        if let pinentryMac = ExecutableLookup.find("pinentry-mac") {
            printReportItem("pinentry-mac", "found at \(redactedInlineCode(resolvedPath(pinentryMac)))")
        } else {
            printReportItem("pinentry-mac", "not found")
        }
        printReportItem("fallback pinentries", fallbackPinentryReport())
        printOutput()

        printOutput("## Interactive Checks")
        printReportItem("authenticated Keychain read", "not run; use `pinentry-companion doctor auth`")
        printOutput()

        printOutput("## GPG Configuration")
        printReportItem("GNUPGHOME", safeEnvironmentValue("GNUPGHOME"))
        printReportItem("gpg-agent.conf", redactedInlineCode(configURL.path))
        printReportItem("gpg-agent.conf readable", configContents == nil ? "no" : "yes")
        printReportItem("active pinentry-program", configuredPinentry.map(redactedInlineCode) ?? "missing")
        if let configuredPinentry {
            printReportItem("points at this binary", pathsMatch(configuredPinentry, currentPath) ? "yes" : "no")
        } else {
            printReportItem("points at this binary", "no")
        }
        printReportItem("pinentry-mac Keychain disabled", pinentryMacKeychainDisabled() ? "yes" : "no")
        printOutput()

        printOutput("## Environment")
        printReportItem("GPG_TTY", safeEnvironmentValue("GPG_TTY"))
        printReportItem("TERM", safeEnvironmentValue("TERM"))
        printReportItem("PINENTRY_USER_DATA", safePinentryUserData())

        return 0
    }

    private static func runSetup(args: [String]) -> Int32 {
        var dryRun = false
        var yes = false

        for arg in args {
            switch arg {
            case "help", "-h", "--help":
                printSetupUsage()
                return 0
            case "--dry-run":
                dryRun = true
            case "-y", "--yes":
                yes = true
            default:
                printError("Invalid setup option: \(arg)")
                printError("Run `pinentry-companion help setup` for usage.")
                return 2
            }
        }

        let currentPath = currentExecutablePath()
        let homeURL = GPGAgentConfig.homeURL()
        let configURL = GPGAgentConfig.configURL()
        let initialSnapshot: GPGAgentConfigSnapshot
        do {
            try GPGAgentConfigFile.validateHomeIfPresent(homeURL)
            initialSnapshot = try GPGAgentConfigFile.read(configURL)
        } catch {
            printError("Error: \(error)")
            return 1
        }

        let updated: String
        do {
            updated = try GPGAgentConfig.updatedContents(initialSnapshot.contents, pinentryPath: currentPath)
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

        let configChanged = updated != initialSnapshot.contents
        if dryRun {
            printOutput(configChanged ? "Would update gpg-agent.conf." : "gpg-agent.conf already points at this binary.")
            printOutput("Would set: defaults write org.gpgtools.common DisableKeychain -bool yes")
            printOutput("Would reload gpg-agent if gpgconf is available.")
            return 0
        }

        if !yes && isatty(STDIN_FILENO) != 0 {
            printOutput()
            printOutput("This will update user-owned GPG configuration and leave a backup if the file exists.")
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
            try GPGAgentConfigFile.prepareHome(homeURL)
            let currentSnapshot = try GPGAgentConfigFile.read(configURL)
            let currentUpdate = try GPGAgentConfig.updatedContents(currentSnapshot.contents, pinentryPath: currentPath)
            if currentUpdate != currentSnapshot.contents {
                if let backup = try GPGAgentConfigFile.backup(configURL) {
                    printOutput("Backed up: \(backup.path)")
                }
                try GPGAgentConfigFile.write(currentUpdate, to: configURL, preserving: currentSnapshot)
                printOutput("Updated:   \(configURL.path)")
            } else {
                printOutput("Already configured: \(configURL.path)")
            }
        } catch {
            printError("Error updating gpg-agent.conf: \(error.localizedDescription)")
            return 1
        }

        if !writePinentryMacKeychainPreference() {
            report(.warn, "pinentry-mac Keychain", "could not update preference; run `defaults write org.gpgtools.common DisableKeychain -bool yes`")
        }

        if reloadGPGAgent() {
            printOutput("Reloaded gpg-agent.")
        } else {
            report(.warn, "gpg-agent", "could not reload automatically; run `gpgconf --kill gpg-agent`")
            return 1
        }

        printOutput("Run `pinentry-companion doctor` to verify.")
        return 0
    }

    private static func runDoctorAuth(args: [String]) -> Int32 {
        var yes = false
        for arg in args {
            switch arg {
            case "-y", "--yes":
                yes = true
            default:
                printError("Invalid doctor auth option: \(arg)")
                printError("Run `pinentry-companion help doctor auth` for usage.")
                return 2
            }
        }

        printOutput("pinentry-companion doctor auth")
        printOutput()
        printOutput("This stores a temporary dummy Keychain item, then reads it through the same authenticated path used for cached GPG passphrases.")
        printOutput("macOS should show a Touch ID, Apple Watch, or account-password prompt.")

        if !yes && isatty(STDIN_FILENO) != 0 {
            FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
            let answer = readLine(strippingNewline: true)?.lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                printOutput("Canceled.")
                return 1
            }
        } else if !yes && isatty(STDIN_FILENO) == 0 {
            printError("Refusing to show an authentication prompt without a TTY. Re-run with `--yes`.")
            return 2
        }

        let result = AuthenticatedKeychainCheck.run()
        if result.passed {
            report(.ok, "authenticated Keychain read", result.detail)
            return 0
        }

        report(.fail, "authenticated Keychain read", result.detail)
        return 1
    }

    private static func printSetupUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion setup

        Configure GPG to use pinentry-companion.

        Usage:
          pinentry-companion setup [--dry-run] [-y|--yes]
          pinentry-companion help setup

        Options:
          --dry-run   Show changes without writing files
          -y, --yes   Apply setup without an interactive prompt
          -h, --help  Same as help setup

        """.utf8))
    }

    private static func printDoctorUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion doctor

        Check the local GPG/pinentry setup without changing files.

        Usage:
          pinentry-companion doctor
          pinentry-companion doctor auth [--yes]
          pinentry-companion doctor report
          pinentry-companion help doctor
          pinentry-companion doctor -h, --help  Same as help doctor

        """.utf8))
    }

    private static func printDoctorAuthUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion doctor auth

        Run an explicit interactive authentication check.

        Usage:
          pinentry-companion doctor auth [--yes]
          pinentry-companion help doctor auth

        This stores a temporary dummy Keychain item, then reads it through the same
        authenticated path used for cached GPG passphrases. It should show a Touch ID,
        Apple Watch, or account-password prompt. The dummy item is deleted afterwards.

        Options:
          -y, --yes   Run without asking for terminal confirmation first

        """.utf8))
    }

    private static func printDoctorReportUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion doctor report

        Print safe Markdown diagnostics for bug reports.

        Usage:
          pinentry-companion doctor report
          pinentry-companion help doctor report

        The report redacts the home directory and does not include keys, passphrases,
        Keychain items, or full GPG configuration files.

        """.utf8))
    }

    private enum DoctorStatus {
        case ok
        case warn
        case fail
    }

    private enum ConfigStatus {
        case ok(String)
        case fail(String)
    }

    private static func report(_ status: DoctorStatus, _ name: String, _ detail: String) {
        let label: String
        switch status {
        case .ok: label = "[ok]"
        case .warn: label = "[warn]"
        case .fail: label = "[fail]"
        }
        printOutput("\(label) \(name): \(detail)")
    }

    private static func configPinentryStatus(configURL: URL, expectedPath: String) -> ConfigStatus {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .fail("missing at \(configURL.path)")
        }

        guard let configured = GPGAgentConfig.activePinentryProgram(in: contents), !configured.isEmpty else {
            return .fail("no active pinentry-program line in \(configURL.path)")
        }

        if pathsMatch(configured, expectedPath) {
            return .ok(configured)
        }

        return .fail("points to \(configured); expected \(expectedPath)")
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || resolvedPath(lhs) == resolvedPath(rhs)
    }

    private static func currentExecutablePath() -> String {
        let invoked = CommandLine.arguments.first ?? "pinentry-companion"
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
                .path
        }
        return ExecutableLookup.find(invoked) ?? invoked
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func macOSVersion() -> String {
        let productVersion = processOutput("sw_vers", ["-productVersion"])
        let buildVersion = processOutput("sw_vers", ["-buildVersion"])
        if productVersion == "unknown" { return ProcessInfo.processInfo.operatingSystemVersionString }
        if buildVersion == "unknown" { return productVersion }
        return "\(productVersion) (\(buildVersion))"
    }

    private static func commandVersion(_ name: String) -> String {
        guard let path = ExecutableLookup.find(name) else { return "not found" }
        let result = runProcess(path, ["--version"])
        guard result.status == 0 else { return "found at \(redactedInlineCode(path)); `--version` failed" }
        guard let firstLine = result.output.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return "found at \(redactedInlineCode(path)); version unavailable"
        }
        return inlineCode(String(firstLine))
    }

    private static func homebrewPackageVersion() -> String {
        guard let brew = ExecutableLookup.find("brew") else { return "brew not found" }
        let result = runProcess(brew, ["list", "--versions", "pinentry-companion"])
        guard result.status == 0 else { return "not installed via Homebrew" }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "not installed via Homebrew" : inlineCode(trimmed)
    }

    private static func processOutput(_ executableName: String, _ arguments: [String]) -> String {
        guard let path = ExecutableLookup.find(executableName) else { return "unknown" }
        let result = runProcess(path, arguments)
        guard result.status == 0 else { return "unknown" }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : DiagnosticRedactor.redact(trimmed)
    }

    private static func safeEnvironmentValue(_ name: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return "unset" }
        return inlineCode(DiagnosticRedactor.redact(singleLine(value)))
    }

    private static func safePinentryUserData() -> String {
        guard let value = ProcessInfo.processInfo.environment["PINENTRY_USER_DATA"], !value.isEmpty else { return "unset" }
        if value.contains("USE_CURSES=1") { return "set (`USE_CURSES=1`)" }
        return "set (redacted)"
    }

    private static func fallbackPinentryReport() -> String {
        let items = FallbackPinentryNames.preferred().map { name -> String in
            if let path = ExecutableLookup.find(name) { return "\(name)=\(redactedInlineCode(resolvedPath(path)))" }
            return "\(name)=missing"
        }
        return items.joined(separator: ", ")
    }

    private static func redactedInlineCode(_ value: String) -> String {
        inlineCode(DiagnosticRedactor.redact(singleLine(value)))
    }

    private static func inlineCode(_ value: String) -> String {
        "`\(singleLine(value).replacingOccurrences(of: "`", with: "\\`"))`"
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func printReportItem(_ name: String, _ value: String) {
        printOutput("- \(name): \(value)")
    }

    private static func pinentryMacKeychainDisabled() -> Bool {
        guard let defaults = ExecutableLookup.find("defaults") else { return false }
        let result = runProcess(defaults, ["read", "org.gpgtools.common", "DisableKeychain"])
        guard result.status == 0 else { return false }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    private static func writePinentryMacKeychainPreference() -> Bool {
        guard let defaults = ExecutableLookup.find("defaults") else { return false }
        return runProcess(defaults, ["write", "org.gpgtools.common", "DisableKeychain", "-bool", "yes"]).status == 0
    }

    private static func reloadGPGAgent() -> Bool {
        guard let gpgconf = ExecutableLookup.find("gpgconf") else { return false }
        return runProcess(gpgconf, ["--kill", "gpg-agent"]).status == 0
    }

    private static func runProtocolCheck(_ executable: String) -> PinentryProtocolCheck.Result {
        let result = runProcess(executable, [], input: PinentryProtocolCheck.smokeInput)
        return PinentryProtocolCheck.validate(output: result.output, status: result.status)
    }

    private static func runProcess(_ executable: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }

        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }
            process.waitUntilExit()
        } catch {
            return (1, "")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
