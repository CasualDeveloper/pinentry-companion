import XCTest
@testable import PinentryCompanionCore

final class FallbackPinentryTests: XCTestCase {
    func testLineBufferCountsIgnoredCarriageReturnsTowardProtocolLimit() throws {
        var accepted = FallbackLineBuffer()
        for _ in 0..<(Assuan.maxLineLength - 1) {
            XCTAssertFalse(try accepted.consume(13))
        }
        XCTAssertTrue(try accepted.consume(10))

        var rejected = FallbackLineBuffer()
        for _ in 0..<(Assuan.maxLineLength - 1) {
            XCTAssertFalse(try rejected.consume(13))
        }
        XCTAssertThrowsError(try rejected.consume(13)) { error in
            guard let fallbackError = error as? FallbackPinentryError,
                  case .lineTooLong = fallbackError else {
                return XCTFail("Expected lineTooLong, got \(error)")
            }
        }
    }

    func testGetPINForwardsPromptControlsTimeoutAndTerminalContext() {
        var settings = PinentrySettings()
        settings.title = "Signing"
        settings.description = "Line one\nLine two"
        settings.prompt = "Passphrase"
        settings.repeatPrompt = "Repeat"
        settings.repeatError = "Mismatch"
        settings.repeatOK = "Matches"
        settings.error = "Try again"
        settings.okButton = "Unlock"
        settings.notOkButton = "No"
        settings.cancelButton = "Cancel"
        settings.qualityBar = "Quality"
        settings.timeoutSeconds = 30
        settings.keyInfo = "n/key"
        settings.options.grab = true
        settings.options.allowEmacsPrompt = true
        settings.options.defaultLabels["default-ok"] = "OK"
        settings.options.display = ":0"
        settings.options.ttyName = "/dev/ttys001"
        settings.options.ttyType = "xterm-256color"
        settings.options.lcMessages = "en_US.UTF-8"
        settings.options.formattedPassphrase = true
        settings.options.formattedPassphraseHint = "Spaces are visual only"
        settings.options.allowExternalPasswordCache = true

        let commands = FallbackCommandPlanner.commands(for: .getPIN, settings: settings)

        XCTAssertTrue(commands.contains(.set("TITLE", "Signing")))
        XCTAssertTrue(commands.contains(.set("DESC", "Line one\\nLine two")))
        XCTAssertTrue(commands.contains(.set("PROMPT", "Passphrase")))
        XCTAssertTrue(commands.contains(.set("REPEAT", "Repeat")))
        XCTAssertTrue(commands.contains(.set("REPEATERROR", "Mismatch")))
        XCTAssertTrue(commands.contains(.set("REPEATOK", "Matches")))
        XCTAssertTrue(commands.contains(.set("ERROR", "Try again")))
        XCTAssertTrue(commands.contains(.set("OK", "Unlock")))
        XCTAssertTrue(commands.contains(.set("NOTOK", "No")))
        XCTAssertTrue(commands.contains(.set("CANCEL", "Cancel")))
        XCTAssertFalse(commands.contains(.set("QUALITYBAR", "Quality")))
        XCTAssertTrue(commands.contains(.set("TIMEOUT", "30")))
        XCTAssertTrue(commands.contains(.set("KEYINFO", "n/key")))
        XCTAssertTrue(commands.contains(.option("grab")))
        XCTAssertTrue(commands.contains(.option("allow-emacs-prompt")))
        XCTAssertTrue(commands.contains(.option("default-ok=OK")))
        XCTAssertTrue(commands.contains(.option("display=:0")))
        XCTAssertTrue(commands.contains(.option("ttyname=/dev/ttys001")))
        XCTAssertTrue(commands.contains(.option("ttytype=xterm-256color")))
        XCTAssertTrue(commands.contains(.option("lc-messages=en_US.UTF-8")))
        XCTAssertTrue(commands.contains(.option("formatted-passphrase")))
        XCTAssertTrue(commands.contains(.option("formatted-passphrase-hint=Spaces are visual only")))
        XCTAssertFalse(commands.contains(.option("allow-external-password-cache")))
    }

    func testNoGrabIsForwardedExplicitly() {
        var settings = PinentrySettings()
        settings.options.grab = false

        let commands = FallbackCommandPlanner.commands(for: .getPIN, settings: settings)

        XCTAssertTrue(commands.contains(.option("no-grab")))
        XCTAssertFalse(commands.contains(.option("grab")))
    }
}
