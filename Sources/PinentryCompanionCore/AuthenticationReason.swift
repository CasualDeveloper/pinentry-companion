import Foundation

public enum AuthenticationReason {
    public static func reason(
        identity: KeychainIdentity,
        settings: PinentrySettings
    ) -> String {
        let base = "access the cached GPG passphrase for \(identity.displayName)"
        guard let description = cleaned(settings.description) else { return base }
        return truncate("\(base): \(description)")
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return truncate(collapsed)
    }

    private static func truncate(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 3))) + "..."
    }
}
