import Foundation
import LocalAuthentication

struct LocalAuthenticator {
    // Apple renamed the macOS 10.15+ Watch policy to "Companion" in the
    // macOS 15 SDK without changing its raw value. Constructing it by value
    // keeps the source compatible with both SDK generations.
    static var companionOrBiometricsPolicy: LAPolicy {
        guard let policy = LAPolicy(rawValue: 4) else {
            preconditionFailure("LocalAuthentication policy 4 is unavailable")
        }
        return policy
    }

    static let summary = "companion/biometry, with device-owner fallback"

    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(
            Self.companionOrBiometricsPolicy,
            error: &error
        ) {
            return true
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) throws {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        let policy = Self.companionOrBiometricsPolicy
        if context.canEvaluatePolicy(policy, error: &error) {
            do {
                try evaluate(context: context, policy: policy, reason: reason)
                return
            } catch let error as LAError where error.code == .userFallback {
                try authenticateDeviceOwner(reason: reason)
                return
            }
        }

        try authenticateDeviceOwner(reason: reason)
    }

    private func authenticateDeviceOwner(reason: String) throws {
        let context = LAContext()
        try evaluate(context: context, policy: .deviceOwnerAuthentication, reason: reason)
    }

    private func evaluate(context: LAContext, policy: LAPolicy, reason: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LocalAuthenticationResultBox()

        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            if success {
                result.set(.success(()))
            } else {
                result.set(.failure(error ?? LocalAuthenticatorError.authenticationFailed))
            }
            semaphore.signal()
        }

        semaphore.wait()
        try result.value.get()
    }
}

private final class LocalAuthenticationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error> = .failure(LocalAuthenticatorError.noResult)

    var value: Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}

enum LocalAuthenticatorError: Error, CustomStringConvertible {
    case authenticationFailed
    case noResult

    var description: String {
        switch self {
        case .authenticationFailed: return "Local authentication failed"
        case .noResult: return "Local authentication did not return a result"
        }
    }
}
