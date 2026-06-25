import Foundation

public struct PinentryOptions {
    public var grab = false
    public var allowExternalPasswordCache = false
    public var ttyType = ""
    public var ttyName = ""
    public var ttyAlert = ""
    public var lcCType = ""
    public var lcMessages = ""
    public var owner = ""
    public var touchFile = ""
    public var parentWID = ""
    public var invisibleChar = ""

    public init() {}
}

public struct PinentrySettings {
    public var description = ""
    public var prompt = ""
    public var error = ""
    public var okButton = ""
    public var notOkButton = ""
    public var cancelButton = ""
    public var title = ""
    public var timeoutSeconds = 0
    public var repeatPrompt = ""
    public var repeatError = ""
    public var qualityBar = ""
    public var keyInfo = ""
    public var options = PinentryOptions()

    public init() {}

    public mutating func reset() {
        self = PinentrySettings()
    }

    public var isBadPassphraseRetry: Bool {
        error.localizedCaseInsensitiveContains("bad passphrase")
    }
}

public enum PinentryOptionParser {
    public static func apply(_ option: String, to settings: inout PinentrySettings) throws {
        let parts = option.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == " " || $0 == "=" }
        guard let key = parts.first.map(String.init), !key.isEmpty else {
            throw Assuan.ProtocolError(source: .assuan, code: .invalidValue, sourceName: "assuan", message: "invalid OPTION syntax")
        }
        let value = parts.count > 1 ? String(parts[1]) : ""

        switch key {
        case "no-grab": settings.options.grab = false
        case "grab": settings.options.grab = true
        case "ttytype": settings.options.ttyType = value
        case "ttyname": settings.options.ttyName = value
        case "ttyalert": settings.options.ttyAlert = value
        case "lc-ctype": settings.options.lcCType = value
        case "lc-messages": settings.options.lcMessages = value
        case "owner": settings.options.owner = value
        case "touch-file": settings.options.touchFile = value
        case "parent-wid": settings.options.parentWID = value
        case "invisible-char": settings.options.invisibleChar = value
        case "allow-external-password-cache": settings.options.allowExternalPasswordCache = true
        default:
            if key.hasPrefix("default-") { return }
            throw Assuan.ProtocolError(source: .pinentry, code: .unknownOption, sourceName: "pinentry", message: "unknown option: \(key)")
        }
    }
}

public struct KeychainIdentity: Equatable {
    public static let service = "pinentry-companion"

    public var keyInfo: String

    public var account: String { keyInfo }

    public var label: String {
        "pinentry-companion (\(displayName))"
    }

    public var displayName: String {
        keyInfo.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? keyInfo
    }

    public init(keyInfo: String) throws {
        let trimmed = keyInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "--clear" else {
            throw Assuan.ProtocolError(
                source: .pinentry,
                code: .canceled,
                sourceName: "pinentry",
                message: "missing SETKEYINFO cache identity"
            )
        }
        self.keyInfo = trimmed
    }
}
