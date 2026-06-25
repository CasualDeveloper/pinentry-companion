import Foundation

public enum FallbackPinentryNames {
    public static func preferred(
        userData: String = ProcessInfo.processInfo.environment["PINENTRY_USER_DATA"] ?? "",
        override: String? = ProcessInfo.processInfo.environment["PINENTRY_COMPANION_FALLBACK_PINENTRY"]
    ) -> [String] {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if userData.contains("USE_CURSES=1") {
            return ["pinentry-curses", "pinentry-tty", "pinentry-mac"]
        }

        return ["pinentry-mac", "pinentry-curses", "pinentry-tty"]
    }
}
