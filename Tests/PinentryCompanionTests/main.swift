import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import PinentryCompanionCore

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure.failed(message) }
    return value
}

func testAssuanEscapingRoundTrip() throws {
    let value = "line 1\nline 2 % \\"
    let escaped = Assuan.escape(value)
    let unescaped = try Assuan.unescape(escaped)

    try expect(escaped == "line 1%0Aline 2 %25 %5C", "Assuan escaping mismatch")
    try expect(unescaped == value, "Assuan unescape did not round trip")
}

func testAssuanCommandParsing() throws {
    let command = try require(try Assuan.parse("SETDESC hello%0Aworld"), "SETDESC did not parse")
    let keyDescription = try require(try Assuan.parse("SETKEYDESC hello%20key"), "SETKEYDESC did not parse")

    try expect(command.name == "SETDESC", "Command name was not normalized")
    try expect(command.parameters == "hello\nworld", "Command parameters were not unescaped")
    try expect(keyDescription.name == "SETKEYDESC", "SETKEYDESC command name mismatch")
    try expect(keyDescription.parameters == "hello key", "SETKEYDESC parameters were not unescaped")
    let comment = try Assuan.parse("# comment")
    let status = try Assuan.parse("S OPTION value")
    try expect(comment == nil, "Comments should be ignored")
    try expect(status == nil, "Status lines should be ignored")

    do {
        _ = try Assuan.parse(String(repeating: "a", count: Assuan.maxLineLength))
        throw TestFailure.failed("Oversized Assuan lines should be rejected")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .invalidValue, "Oversized Assuan line should map to invalidValue")
    }
}

func testAssuanDataChunking() throws {
    let value = String(repeating: "🔐%\n", count: 400)
    let lines = Assuan.dataLines(value)

    try expect(lines.count > 1, "Long Assuan data should be split across lines")
    try expect(
        lines.allSatisfy { $0.utf8.count + 1 <= Assuan.maxLineLength },
        "Assuan data lines must stay within the byte limit including newline"
    )
    let encoded = lines.map { String($0.dropFirst(2)) }.joined()
    let decoded = try Assuan.unescape(encoded)
    try expect(decoded == value, "Chunked Assuan data did not round trip")
}

func testAssuanCommandLineBounding() throws {
    let line = Assuan.encodedLine("ERR", String(repeating: "é%", count: 1_000))
    try expect(line.utf8.count <= Assuan.maxLineLength, "Assuan command lines must include the newline in their byte limit")
    try expect(line.hasSuffix("\n"), "Assuan command lines must end with a newline")
}

func testAssuanErrorParsing() throws {
    let rawCode = Assuan.errorCode(source: .pinentry, code: .canceled)
    let error = try require(Assuan.parseErrorLine("ERR \(rawCode) canceled <pinentry>"), "ERR line did not parse")

    try expect(error.rawCode == rawCode, "Raw Assuan error code was not preserved")
    try expect(error.source == .pinentry, "Assuan error source mismatch")
    try expect(error.code == .canceled, "Assuan error code mismatch")
    try expect(error.sourceName == "pinentry", "Assuan error source name mismatch")
    try expect(error.message == "canceled", "Assuan error message mismatch")
}

func testKeychainIdentity() throws {
    let identity = try KeychainIdentity(keyInfo: "n/0123456789ABCDEF")

    try expect(identity.account == "n/0123456789ABCDEF", "Keychain account should be raw SETKEYINFO")
    try expect(identity.displayName == "0123456789ABCDEF", "Display name should use SETKEYINFO suffix")
    try expect(identity.label == "pinentry-companion (0123456789ABCDEF)", "Keychain label mismatch")

    do {
        _ = try KeychainIdentity(keyInfo: "")
        throw TestFailure.failed("Empty SETKEYINFO should be rejected")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .canceled, "Missing SETKEYINFO should map to canceled")
    }

    do {
        _ = try KeychainIdentity(keyInfo: "n/key\nspoofed prompt")
        throw TestFailure.failed("Control characters in SETKEYINFO should be rejected")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .canceled, "Unsafe SETKEYINFO should map to canceled")
    }
}

func testOptionsAndBadPassphraseRetry() throws {
    var settings = PinentrySettings()

    try PinentryOptionParser.apply("allow-external-password-cache", to: &settings)
    try PinentryOptionParser.apply("display=:0", to: &settings)
    try PinentryOptionParser.apply("ttyname=/dev/ttys001", to: &settings)
    try PinentryOptionParser.apply("formatted-passphrase", to: &settings)
    try PinentryOptionParser.apply("formatted-passphrase-hint=Spaces are visual only", to: &settings)
    try PinentryOptionParser.apply("allow-emacs-prompt", to: &settings)
    try PinentryOptionParser.apply("default-ok=OK", to: &settings)

    try expect(settings.options.allowExternalPasswordCache, "External password cache option not applied")
    try expect(settings.options.display == ":0", "display option not applied")
    try expect(settings.options.ttyName == "/dev/ttys001", "ttyname option not applied")
    try expect(settings.options.formattedPassphrase, "formatted-passphrase option not applied")
    try expect(settings.options.formattedPassphraseHint == "Spaces are visual only", "formatted-passphrase hint mismatch")
    try expect(settings.options.allowEmacsPrompt, "allow-emacs-prompt option not applied")
    try expect(settings.options.defaultLabels["default-ok"] == "OK", "default label option not applied")

    settings.keyInfo = "n/transient"
    settings.repeatPrompt = "Repeat"
    settings.error = "Bad passphrase"
    settings.timeoutSeconds = 30
    settings.cacheAttempted = true
    settings.reset()
    try expect(settings.options.allowExternalPasswordCache, "RESET should preserve agent options")
    try expect(settings.options.display == ":0", "RESET should preserve display context")
    try expect(settings.options.allowEmacsPrompt, "RESET should preserve emacs prompt permission")
    try expect(settings.options.defaultLabels["default-ok"] == "OK", "RESET should preserve default labels")
    try expect(settings.options.ttyName == "/dev/ttys001", "RESET should preserve terminal context")
    try expect(settings.timeoutSeconds == 30, "RESET should preserve the agent timeout")
    try expect(!settings.options.formattedPassphrase && settings.options.formattedPassphraseHint.isEmpty, "RESET should clear per-prompt formatting")
    try expect(settings.keyInfo.isEmpty && settings.repeatPrompt.isEmpty && settings.error.isEmpty, "RESET should clear per-prompt metadata")
    try expect(!settings.cacheAttempted, "RESET should allow a fresh cache attempt")

    do {
        try PinentryOptionParser.apply("unknown-option", to: &settings)
        throw TestFailure.failed("Unknown option should be rejected")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .unknownOption, "Unknown option should map to unknownOption")
    }

    for invalidOption in ["grab=true", "allow-external-password-cache=yes", "default-unknown=value"] {
        do {
            try PinentryOptionParser.apply(invalidOption, to: &settings)
            throw TestFailure.failed("Invalid option should be rejected: \(invalidOption)")
        } catch let error as Assuan.ProtocolError {
            try expect(error.code == .unknownOption, "Invalid option should map to unknownOption")
        }
    }

    try expect(!settings.isBadPassphraseRetry, "Empty error should not be a bad-passphrase retry")
    settings.error = "Bad passphrase. Try again."
    try expect(settings.isBadPassphraseRetry, "Bad passphrase retry was not detected")
}

func testAuthenticationReason() throws {
    let identity = try KeychainIdentity(keyInfo: "n/0123456789ABCDEF")
    var settings = PinentrySettings()

    let defaultReason = AuthenticationReason.reason(identity: identity, settings: settings)
    try expect(defaultReason == "access the cached GPG passphrase for 0123456789ABCDEF", "Default auth reason mismatch")

    settings.description = "GPG signing request\nfor a test key"
    let describedReason = AuthenticationReason.reason(identity: identity, settings: settings)
    try expect(describedReason == "access the cached GPG passphrase for 0123456789ABCDEF: GPG signing request for a test key", "SETDESC auth reason mismatch")
}

func testFallbackPinentryNames() throws {
    let defaultNames = FallbackPinentryNames.preferred(userData: "", override: nil)
    try expect(defaultNames == ["pinentry-mac", "pinentry-curses", "pinentry-tty"], "Default fallback order mismatch")

    let cursesNames = FallbackPinentryNames.preferred(userData: "USE_CURSES=1", override: nil)
    try expect(cursesNames == ["pinentry-curses", "pinentry-tty", "pinentry-mac"], "Curses fallback order mismatch")

    let overrideNames = FallbackPinentryNames.preferred(userData: "", override: "pinentry-custom, /tmp/pinentry-other")
    try expect(overrideNames == ["pinentry-custom", "/tmp/pinentry-other"], "Fallback override parsing mismatch")
}

func testKeychainPresenceMapping() throws {
    let success = try KeychainPresence.containsResult(for: errSecSuccess)
    let interactionBlocked = try KeychainPresence.containsResult(for: errSecInteractionNotAllowed)
    let missing = try KeychainPresence.containsResult(for: errSecItemNotFound)

    try expect(success, "Successful Keychain lookup should mean present")
    try expect(interactionBlocked, "Interaction-blocked access-controlled item should mean present")
    try expect(!missing, "Missing Keychain item should mean absent")

    var unexpectedStatusThrew = false
    do {
        _ = try KeychainPresence.containsResult(for: errSecParam)
    } catch {
        unexpectedStatusThrew = true
    }
    try expect(unexpectedStatusThrew, "Unexpected Keychain status should throw")
}

func testKeychainAccessPolicyFlags() throws {
    let flags = KeychainAccessPolicy.flags

    try expect(flags.contains(.biometryAny), "Keychain access policy should include biometryAny")
    try expect(flags.contains(.devicePasscode), "Keychain access policy should include devicePasscode")
    try expect(flags.contains(.or), "Keychain access policy should combine constraints with OR")
    try expect(flags.contains(KeychainAccessPolicy.companionFlag), "Keychain access policy should include companion")
    try expect(KeychainAccessPolicy.companionFlag.rawValue == 1 << 5, "Companion Keychain constraint raw value mismatch")
    try expect(KeychainAccessPolicy.summary == "companion OR biometryAny OR devicePasscode", "Keychain access policy summary mismatch")
}

func testLocalAuthenticatorPolicy() throws {
    try expect(LocalAuthenticator.companionOrBiometricsPolicy.rawValue == 4, "Companion LocalAuthentication policy raw value mismatch")
    try expect(LocalAuthenticator.summary == "companion/biometry, with device-owner fallback", "LocalAuthentication policy summary mismatch")
}

func testKeychainAccessPolicyCreatesAccessControl() throws {
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        KeychainAccessPolicy.flags,
        &error
    )

    try expect(access != nil, error?.takeRetainedValue().localizedDescription ?? "Keychain access policy should create SecAccessControl")
}

func testGPGAgentConfigPaths() throws {
    let configURL = GPGAgentConfig.configURL(environment: ["GNUPGHOME": "/tmp/pinentry-companion-test-gnupg"])

    try expect(configURL.path == "/tmp/pinentry-companion-test-gnupg/gpg-agent.conf", "GNUPGHOME config path mismatch")
}

func testGPGAgentConfigParsingAndUpdate() throws {
    let original = """
    # pinentry-program /old/commented
    default-cache-ttl 600
    pinentry-program /old/active
    max-cache-ttl 7200
    pinentry-program /old/duplicate
    """

    try expect(GPGAgentConfig.activePinentryProgram(in: original) == "/old/active", "Active pinentry-program parsing mismatch")
    try expect(GPGAgentConfig.activePinentryPrograms(in: original) == ["/old/active", "/old/duplicate"], "All active pinentry-program directives should be preserved for inspection")

    let updated = try GPGAgentConfig.updatedContents(original, pinentryPath: "/new/pinentry-companion")
    let expected = """
    # pinentry-program /old/commented
    default-cache-ttl 600
    pinentry-program /new/pinentry-companion
    max-cache-ttl 7200

    """

    try expect(updated == expected, "gpg-agent.conf update mismatch")
}

func testGPGAgentConfigAppendAndValidation() throws {
    let appended = try GPGAgentConfig.updatedContents("default-cache-ttl 600", pinentryPath: "/new/pinentry-companion")

    try expect(appended == "default-cache-ttl 600\npinentry-program /new/pinentry-companion\n", "pinentry-program should append when absent")

    var invalidPathThrew = false
    do {
        _ = try GPGAgentConfig.updatedContents("", pinentryPath: "/bad\npath")
    } catch {
        invalidPathThrew = true
    }
    try expect(invalidPathThrew, "Invalid pinentry path should throw")

    XCTAssertThrowsError(
        try GPGAgentConfig.updatedContents("", pinentryPath: "/valid-looking\0ignored")
    )
}

func testDiagnosticRedaction() throws {
    try expect(DiagnosticRedactor.redact("/Users/alice", homeDirectory: "/Users/alice") == "~", "Home path should redact to tilde")
    try expect(DiagnosticRedactor.redact("/Users/alice/.gnupg/gpg-agent.conf", homeDirectory: "/Users/alice") == "~/.gnupg/gpg-agent.conf", "Nested home path should redact")
    try expect(DiagnosticRedactor.redact("/opt/homebrew/bin/pinentry-companion", homeDirectory: "/Users/alice") == "/opt/homebrew/bin/pinentry-companion", "Non-home path should not redact")
}

func testPinentryInfo() throws {
    let flavor = try PinentryInfo.value(for: "flavor")
    let version = try PinentryInfo.value(for: "version")
    let processID = try PinentryInfo.value(for: "pid")

    try expect(flavor == "companion", "GETINFO flavor mismatch")
    try expect(version == ComponentVersion.current, "GETINFO version mismatch")
    try expect(Int(processID) == Int(ProcessInfo.processInfo.processIdentifier), "GETINFO pid mismatch")

    var options = PinentryOptions()
    options.ttyName = "/dev/null"
    options.ttyType = "xterm-256color"
    options.display = ":0"
    let ttyFields = try PinentryInfo.value(for: "ttyinfo", options: options).split(separator: " ").map(String.init)
    try expect(ttyFields.count == 6, "GETINFO ttyinfo should return six upstream-compatible fields")
    try expect(Array(ttyFields.prefix(3)) == ["/dev/null", "xterm-256color", ":0"], "GETINFO ttyinfo terminal context mismatch")
    try expect(ttyFields[3] != "?" && ttyFields[3].split(separator: "/").count == 3, "GETINFO ttyinfo device metadata mismatch")
    try expect(ttyFields[4] == "\(geteuid())/\(getegid())", "GETINFO ttyinfo identity mismatch")
    try expect(ttyFields[5] == "-", "GETINFO ttyinfo emacs status mismatch")

    let emptyTTYInfo = try PinentryInfo.value(for: "ttyinfo")
    try expect(emptyTTYInfo == "- - - - \(geteuid())/\(getegid()) -", "GETINFO ttyinfo missing-value placeholders mismatch")

    do {
        _ = try PinentryInfo.value(for: "")
        throw TestFailure.failed("Empty GETINFO argument should fail")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .invalidValue, "Empty GETINFO should map to invalidValue")
    }

    do {
        _ = try PinentryInfo.value(for: "unknown")
        throw TestFailure.failed("Unknown GETINFO value should fail")
    } catch let error as Assuan.ProtocolError {
        try expect(error.code == .notFound, "Unknown GETINFO should map to notFound")
    }
}

func testPinentryProtocolCheck() throws {
    let output = """
    OK Hi from pinentry-companion!
    D companion
    OK
    D 0.2.0
    OK
    D 12345
    OK
    D /dev/ttys001 123 xterm-256color
    OK
    OK
    """

    let success = PinentryProtocolCheck.validate(output: output, status: 0)
    try expect(success.passed, "Valid GETINFO smoke output should pass")

    let failedStatus = PinentryProtocolCheck.validate(output: output, status: 1)
    try expect(!failedStatus.passed, "Non-zero protocol process status should fail")

    let missingFlavor = PinentryProtocolCheck.validate(output: output.replacingOccurrences(of: "D companion\n", with: ""), status: 0)
    try expect(!missingFlavor.passed, "Missing GETINFO flavor should fail")

    let protocolError = PinentryProtocolCheck.validate(output: output + "\nERR 1 bad <assuan>\n", status: 0)
    try expect(!protocolError.passed, "Protocol smoke ERR lines should fail")
}

final class PinentryCompanionTests: XCTestCase {
    func testAssuanEscaping() throws { try testAssuanEscapingRoundTrip() }
    func testAssuanCommandParser() throws { try testAssuanCommandParsing() }
    func testAssuanDataUsesByteBoundedLines() throws { try testAssuanDataChunking() }
    func testAssuanCommandsUseByteBoundedLines() throws { try testAssuanCommandLineBounding() }
    func testAssuanErrorParser() throws { try testAssuanErrorParsing() }
    func testCacheIdentity() throws { try testKeychainIdentity() }
    func testOptionsAndRetryDetection() throws { try testOptionsAndBadPassphraseRetry() }
    func testAuthenticationReasonText() throws { try testAuthenticationReason() }
    func testFallbackNames() throws { try testFallbackPinentryNames() }
    func testKeychainPresenceStatusMapping() throws { try testKeychainPresenceMapping() }
    func testAccessPolicyFlags() throws { try testKeychainAccessPolicyFlags() }
    func testAccessPolicyCreation() throws { try testKeychainAccessPolicyCreatesAccessControl() }
    func testCompanionAuthenticationPolicy() throws { try testLocalAuthenticatorPolicy() }
    func testGPGConfigPaths() throws { try testGPGAgentConfigPaths() }
    func testGPGConfigParsingAndUpdate() throws { try testGPGAgentConfigParsingAndUpdate() }
    func testGPGConfigAppendAndValidation() throws { try testGPGAgentConfigAppendAndValidation() }
    func testRedaction() throws { try testDiagnosticRedaction() }
    func testGETINFO() throws { try testPinentryInfo() }
    func testProtocolCheck() throws { try testPinentryProtocolCheck() }
}
