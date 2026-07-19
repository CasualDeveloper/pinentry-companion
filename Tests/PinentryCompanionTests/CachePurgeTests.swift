import Security
import XCTest
@testable import PinentryCompanionCore

final class CachePurgeTests: XCTestCase {
    func testPurgeDeletesOnlyComponentOwnedCacheServices() throws {
        let backend = RecordingKeychainServiceDeleter(statuses: [
            "pinentry-companion.acl": errSecSuccess,
            "pinentry-companion": errSecItemNotFound,
        ])

        let result = try KeychainCachePurger(backend: backend).purge()

        XCTAssertEqual(backend.services, ["pinentry-companion.acl", "pinentry-companion"])
        XCTAssertEqual(result.serviceGroupsDeleted, 1)
        XCTAssertEqual(result.serviceGroupsAlreadyEmpty, 1)
    }

    func testPurgeAttemptsEveryOwnedServiceBeforeReportingFailures() throws {
        let backend = RecordingKeychainServiceDeleter(statuses: [
            "pinentry-companion.acl": errSecAuthFailed,
            "pinentry-companion": errSecInteractionNotAllowed,
        ])

        XCTAssertThrowsError(try KeychainCachePurger(backend: backend).purge()) { error in
            XCTAssertEqual(
                error as? KeychainCachePurgeError,
                .failed([
                    KeychainCachePurgeFailure(service: "pinentry-companion.acl", status: errSecAuthFailed),
                    KeychainCachePurgeFailure(service: "pinentry-companion", status: errSecInteractionNotAllowed),
                ])
            )
        }
        XCTAssertEqual(backend.services, ["pinentry-companion.acl", "pinentry-companion"])
    }
}

private final class RecordingKeychainServiceDeleter: KeychainServiceDeleting {
    var statuses: [String: OSStatus]
    var services: [String] = []

    init(statuses: [String: OSStatus]) {
        self.statuses = statuses
    }

    func deleteGenericPasswords(service: String) -> OSStatus {
        services.append(service)
        return statuses[service] ?? errSecItemNotFound
    }
}
