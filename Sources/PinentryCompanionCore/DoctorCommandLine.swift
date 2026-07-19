import Darwin
import Foundation

extension CommandLineEntry {
    static func runDoctor() -> Int32 {
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
        report(.info, "Keychain storage", "not probed; run `pinentry-companion doctor auth`")
        report(.info, "Keychain ACL storage", KeychainAccessPolicy.summary + " (not probed)")

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

    static func runDoctorReport() -> Int32 {
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
        printReportItem("Keychain storage", "not probed; use `pinentry-companion doctor auth`")
        printReportItem("Keychain ACL storage", "\(KeychainAccessPolicy.summary) (not probed)")
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

    static func runDoctorAuth(args: [String]) -> Int32 {
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
        printOutput("This stores temporary diagnostic Keychain items, then reads one through the same authenticated path used for cached GPG passphrases.")
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

        let storage = KeychainStorage.storageCheck()
        report(storage.passed ? .ok : .fail, "Keychain storage", storage.detail)
        let accessPolicy = KeychainAccessPolicy.storageCheck()
        if accessPolicy.canStore, accessPolicy.usesPreferredPolicy {
            report(.ok, "Keychain ACL storage", accessPolicy.detail)
        } else if accessPolicy.canStore {
            report(.warn, "Keychain ACL storage", accessPolicy.detail)
        } else if accessPolicy.isUnentitledBuildLimitation {
            report(.info, "Keychain ACL storage", accessPolicy.userDetail)
        } else {
            report(.warn, "Keychain ACL storage", accessPolicy.detail)
        }
        let result = AuthenticatedKeychainCheck.run()
        if result.passed, storage.passed {
            report(.ok, "authenticated Keychain read", result.detail)
            return 0
        }

        if !result.passed { report(.fail, "authenticated Keychain read", result.detail) }
        return 1
    }

    static func printDoctorUsage() {
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

    static func printDoctorAuthUsage() {
        FileHandle.standardOutput.write(Data("""
        pinentry-companion doctor auth

        Run an explicit interactive authentication check.

        Usage:
          pinentry-companion doctor auth [--yes]
          pinentry-companion help doctor auth

        This stores temporary diagnostic Keychain items, then reads one through the same
        authenticated path used for cached GPG passphrases. It should show a Touch ID,
        Apple Watch, or account-password prompt. The items are deleted afterwards.

        Options:
          -y, --yes   Run without asking for terminal confirmation first

        """.utf8))
    }

    static func printDoctorReportUsage() {
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
        case info
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
        case .info: label = "[info]"
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

    static func currentExecutablePath() -> String {
        let invoked = ProcessInfo.processInfo.arguments.first ?? "pinentry-companion"
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
                .path
        }
        return ExecutableLookup.find(invoked) ?? invoked
    }

    static func resolvedPath(_ path: String) -> String {
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
        return redactedInlineCode(String(firstLine))
    }

    private static func homebrewPackageVersion() -> String {
        guard let brew = ExecutableLookup.find("brew") else { return "brew not found" }
        let result = runProcess(brew, ["list", "--versions", "pinentry-companion"])
        guard result.status == 0 else { return "not installed via Homebrew" }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "not installed via Homebrew" : redactedInlineCode(trimmed)
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
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }
        } catch {
            return (1, "")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
