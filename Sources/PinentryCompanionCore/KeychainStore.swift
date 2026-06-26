import Foundation
import LocalAuthentication
import Security

enum KeychainStoreError: Error, CustomStringConvertible, LocalizedError {
    case osStatus(OSStatus)
    case notFound
    case missingData
    case invalidData
    case accessControl(String)

    var description: String {
        switch self {
        case .osStatus(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .notFound:
            return "Keychain item was not found"
        case .missingData:
            return "Keychain item did not include password data"
        case .invalidData:
            return "Keychain password data was not valid UTF-8"
        case .accessControl(let message):
            return message
        }
    }

    var errorDescription: String? { description }
}

struct KeychainStore {
    private static let accessControlledService = "pinentry-companion.acl"

    func contains(identity: KeychainIdentity) throws -> Bool {
        if try contains(identity: identity, service: Self.accessControlledService) { return true }
        return try contains(identity: identity, service: KeychainIdentity.service)
    }

    func password(identity: KeychainIdentity, reason: String) throws -> String {
        do {
            return try password(identity: identity, service: Self.accessControlledService, reason: reason)
        } catch KeychainStoreError.notFound {
            guard try contains(identity: identity, service: KeychainIdentity.service) else {
                throw KeychainStoreError.notFound
            }

            try LocalAuthenticator().authenticate(reason: reason)
            return try password(identity: identity, service: KeychainIdentity.service, reason: nil)
        }
    }

    func store(identity: KeychainIdentity, password: String) throws {
        if storeAccessControlled(identity: identity, password: password) {
            try? delete(identity: identity, service: KeychainIdentity.service)
            return
        }

        try storeLegacy(identity: identity, password: password)
    }

    func delete(identity: KeychainIdentity) throws {
        var firstError: Error?
        do {
            try delete(identity: identity, service: Self.accessControlledService)
        } catch {
            firstError = error
        }

        do {
            try delete(identity: identity, service: KeychainIdentity.service)
        } catch {
            if firstError == nil { firstError = error }
        }

        if let firstError { throw firstError }
    }

    private func contains(identity: KeychainIdentity, service: String) throws -> Bool {
        var query = baseQuery(identity: identity, service: service)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnAttributes] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try KeychainPresence.containsResult(for: status)
    }

    private func password(identity: KeychainIdentity, service: String, reason: String?) throws -> String {
        var query = baseQuery(identity: identity, service: service)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        if let reason { query[kSecUseOperationPrompt] = reason }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainStoreError.notFound }
        guard status == errSecSuccess else { throw KeychainStoreError.osStatus(status) }
        guard let data = result as? Data else { throw KeychainStoreError.missingData }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainStoreError.invalidData }
        return value
    }

    private func storeAccessControlled(identity: KeychainIdentity, password: String) -> Bool {
        for policy in KeychainAccessPolicy.storageCandidates {
            guard let access = try? KeychainAccessPolicy.accessControl(for: policy) else { continue }
            if storeAccessControlled(identity: identity, password: password, access: access) { return true }
        }
        return false
    }

    private func storeAccessControlled(identity: KeychainIdentity, password: String, access: SecAccessControl) -> Bool {
        var item = baseQuery(identity: identity, service: Self.accessControlledService)
        item[kSecAttrLabel] = identity.label
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrSynchronizable] = kCFBooleanFalse
        item[kSecAttrAccessControl] = access

        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return true }

        if status == errSecDuplicateItem {
            try? delete(identity: identity, service: Self.accessControlledService)
            let retry = SecItemAdd(item as CFDictionary, nil)
            return retry == errSecSuccess
        }

        return false
    }

    private func storeLegacy(identity: KeychainIdentity, password: String) throws {
        var item = baseQuery(identity: identity, service: KeychainIdentity.service)
        item[kSecAttrLabel] = identity.label
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrSynchronizable] = kCFBooleanFalse
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return }

        if status == errSecDuplicateItem {
            try delete(identity: identity)
            let retry = SecItemAdd(item as CFDictionary, nil)
            if retry == errSecSuccess { return }
            throw KeychainStoreError.osStatus(retry)
        }

        throw KeychainStoreError.osStatus(status)
    }

    private func delete(identity: KeychainIdentity, service: String) throws {
        let status = SecItemDelete(baseQuery(identity: identity, service: service) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainStoreError.osStatus(status)
        }
    }

    private func baseQuery(identity: KeychainIdentity, service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identity.account,
        ]
    }

}

public enum AuthenticatedKeychainCheck {
    public struct CheckResult {
        public var passed: Bool
        public var detail: String
    }

    public static func run() -> CheckResult {
        let keyInfo = "doctor-auth/\(UUID().uuidString)"
        let expected = "pinentry-companion-auth-check-\(UUID().uuidString)"

        do {
            let identity = try KeychainIdentity(keyInfo: keyInfo)
            let store = KeychainStore()
            defer { try? store.delete(identity: identity) }

            try store.store(identity: identity, password: expected)
            let actual = try store.password(
                identity: identity,
                reason: "read a temporary pinentry-companion test passphrase"
            )

            guard actual == expected else {
                return CheckResult(passed: false, detail: "authenticated read returned unexpected data")
            }

            return CheckResult(passed: true, detail: "authenticated Keychain read OK")
        } catch {
            return CheckResult(passed: false, detail: String(describing: error))
        }
    }
}

public enum KeychainStorage {
    public struct CheckResult {
        public var passed: Bool
        public var detail: String
    }

    public static func storageCheck() -> CheckResult {
        let service = "pinentry-companion-doctor"
        let account = "storage-check-\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        var item = query
        item[kSecAttrLabel] = "pinentry-companion doctor storage check"
        item[kSecValueData] = Data("doctor".utf8)
        item[kSecAttrSynchronizable] = kCFBooleanFalse
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return CheckResult(passed: false, detail: "SecItemAdd failed: \(statusDescription(addStatus))")
        }

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return CheckResult(passed: false, detail: "SecItemAdd OK, cleanup failed: \(statusDescription(deleteStatus))")
        }

        return CheckResult(passed: true, detail: "ThisDeviceOnly item add/delete OK")
    }

    private static func statusDescription(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

public enum KeychainPresence {
    public static func containsResult(for status: OSStatus) throws -> Bool {
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainStoreError.osStatus(status)
        }
    }
}

public enum KeychainAccessPolicy {
    public struct Policy {
        public var flags: SecAccessControlCreateFlags
        public var summary: String
        public var isPreferred: Bool
    }

    public struct CheckResult {
        public var canStore: Bool
        public var usesPreferredPolicy: Bool
        public var detail: String
    }

    public static var flags: SecAccessControlCreateFlags {
        if #available(macOS 15.0, *) {
            return [companionFlag, .or, .biometryAny, .devicePasscode]
        }
        return .userPresence
    }

    public static var companionFlag: SecAccessControlCreateFlags {
        SecAccessControlCreateFlags(rawValue: 1 << 5)
    }

    public static var summary: String {
        if #available(macOS 15.0, *) {
            return "companion OR biometryAny OR devicePasscode"
        }
        return "userPresence"
    }

    public static var storageCandidates: [Policy] {
        if #available(macOS 15.0, *) {
            return [
                Policy(flags: [companionFlag, .or, .biometryAny, .devicePasscode], summary: "companion OR biometryAny OR devicePasscode", isPreferred: true),
                Policy(flags: .userPresence, summary: "userPresence", isPreferred: false),
            ]
        }
        return [Policy(flags: .userPresence, summary: "userPresence", isPreferred: true)]
    }

    public static func accessControl() throws -> SecAccessControl {
        try accessControl(for: storageCandidates[0])
    }

    public static func accessControl(for policy: Policy) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            policy.flags,
            &error
        ) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Unable to create Keychain access control"
            throw KeychainStoreError.accessControl(message)
        }
        return access
    }

    public static func storageCheck() -> CheckResult {
        var failures: [String] = []
        for policy in storageCandidates {
            let result = temporaryStorageCheck(policy: policy)
            if result.canStore {
                if policy.isPreferred {
                    return result
                }

                let prefix = failures.isEmpty ? "" : failures.joined(separator: "; ") + "; "
                return CheckResult(
                    canStore: true,
                    usesPreferredPolicy: false,
                    detail: prefix + "fallback \(policy.summary) temporary ACL item add/delete OK"
                )
            }
            failures.append("\(policy.summary): \(result.detail)")
        }

        return CheckResult(
            canStore: false,
            usesPreferredPolicy: false,
            detail: failures.joined(separator: "; ")
        )
    }

    private static func temporaryStorageCheck(policy: Policy) -> CheckResult {
        let service = "pinentry-companion-doctor"
        let account = "acl-check-\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        do {
            var item = query
            item[kSecAttrLabel] = "pinentry-companion doctor ACL check"
            item[kSecValueData] = Data("doctor".utf8)
            item[kSecAttrSynchronizable] = kCFBooleanFalse
            item[kSecAttrAccessControl] = try accessControl(for: policy)

            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                return CheckResult(canStore: false, usesPreferredPolicy: policy.isPreferred, detail: "SecItemAdd failed: \(statusDescription(addStatus))")
            }

            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return CheckResult(canStore: false, usesPreferredPolicy: policy.isPreferred, detail: "SecItemAdd OK, cleanup failed: \(statusDescription(deleteStatus))")
            }

            return CheckResult(canStore: true, usesPreferredPolicy: policy.isPreferred, detail: "\(policy.summary) temporary ACL item add/delete OK")
        } catch {
            _ = SecItemDelete(query as CFDictionary)
            return CheckResult(canStore: false, usesPreferredPolicy: policy.isPreferred, detail: String(describing: error))
        }
    }

    private static func statusDescription(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
