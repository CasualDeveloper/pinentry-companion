import Foundation

public struct PinentryOptions {
    public var grab: Bool?
    public var allowExternalPasswordCache = false
    public var allowEmacsPrompt = false
    public var display = ""
    public var ttyType = ""
    public var ttyName = ""
    public var ttyAlert = ""
    public var lcCType = ""
    public var lcMessages = ""
    public var owner = ""
    public var touchFile = ""
    public var parentWID = ""
    public var invisibleChar = ""
    public var formattedPassphrase = false
    public var formattedPassphraseHint = ""
    public var defaultLabels: [String: String] = [:]

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
    public var repeatOK = ""
    public var qualityBar = ""
    public var qualityBarTooltip = ""
    public var generatePINLabel = ""
    public var generatePINTooltip = ""
    public var keyInfo = ""
    var confirmParameters = ""
    public var options = PinentryOptions()
    var cacheAttempted = false

    public init() {}

    public mutating func reset() {
        var persistentOptions = options
        persistentOptions.formattedPassphrase = false
        persistentOptions.formattedPassphraseHint = ""
        let persistentTimeout = timeoutSeconds
        self = PinentrySettings()
        options = persistentOptions
        timeoutSeconds = persistentTimeout
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
        case "no-grab":
            try requireFlag(key, value: value)
            settings.options.grab = false
        case "grab":
            try requireFlag(key, value: value)
            settings.options.grab = true
        case "display": settings.options.display = value
        case "ttytype": settings.options.ttyType = value
        case "ttyname": settings.options.ttyName = value
        case "ttyalert": settings.options.ttyAlert = value
        case "lc-ctype": settings.options.lcCType = value
        case "lc-messages": settings.options.lcMessages = value
        case "owner": settings.options.owner = value
        case "touch-file": settings.options.touchFile = value
        case "parent-wid": settings.options.parentWID = value
        case "invisible-char": settings.options.invisibleChar = value
        case "formatted-passphrase":
            try requireFlag(key, value: value)
            settings.options.formattedPassphrase = true
        case "formatted-passphrase-hint": settings.options.formattedPassphraseHint = value
        case "allow-external-password-cache":
            try requireFlag(key, value: value)
            settings.options.allowExternalPasswordCache = true
        case "allow-emacs-prompt":
            try requireFlag(key, value: value)
            settings.options.allowEmacsPrompt = true
        default:
            if defaultLabelKeys.contains(key) {
                settings.options.defaultLabels[key] = value
                return
            }
            throw Assuan.ProtocolError(source: .pinentry, code: .unknownOption, sourceName: "pinentry", message: "unknown option: \(key)")
        }
    }

    private static let defaultLabelKeys: Set<String> = [
        "default-ok", "default-cancel", "default-prompt", "default-pwmngr",
        "default-cf-visi", "default-tt-visi", "default-tt-hide", "default-capshint",
    ]

    private static func requireFlag(_ key: String, value: String) throws {
        guard value.isEmpty else {
            throw Assuan.ProtocolError(
                source: .pinentry,
                code: .unknownOption,
                sourceName: "pinentry",
                message: "option does not accept a value: \(key)"
            )
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
        guard !trimmed.isEmpty,
              trimmed != "--clear",
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
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
