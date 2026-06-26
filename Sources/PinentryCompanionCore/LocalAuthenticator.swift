import Foundation
import LocalAuthentication

struct LocalAuthenticator {
    private static let biometricsOrCompanionPolicy = LAPolicy(rawValue: 4)!

    static var summary: String {
        if #available(macOS 15.0, *) {
            return "companion/biometry, with device-owner fallback"
        }
        return "device-owner authentication"
    }

    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        if #available(macOS 15.0, *), context.canEvaluatePolicy(Self.biometricsOrCompanionPolicy, error: &error) {
            return true
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) throws {
        if #available(macOS 15.0, *) {
            let context = LAContext()
            context.localizedFallbackTitle = "Use Password"
            var error: NSError?
            if context.canEvaluatePolicy(Self.biometricsOrCompanionPolicy, error: &error) {
                do {
                    try evaluate(context: context, policy: Self.biometricsOrCompanionPolicy, reason: reason)
                    return
                } catch let error as LAError where error.code == .userFallback {
                    try authenticateDeviceOwner(reason: reason)
                    return
                }
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
