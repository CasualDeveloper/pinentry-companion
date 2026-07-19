import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleLockTests: XCTestCase {
    func testLockIsExclusiveAndPrivate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LifecycleLockProvider(rootURL: root.appendingPathComponent("state-v1"))
        let home = "/Users/example/.gnupg"
        let first = try provider.acquire(canonicalHomePath: home)
        let lockURL = provider.lockURL(forCanonicalHomePath: home)

        XCTAssertEqual(permissions(at: lockURL), 0o600)
        XCTAssertThrowsError(try provider.acquire(canonicalHomePath: home)) { error in
            XCTAssertEqual(error as? LifecycleLockError, .busy(home))
        }
        withExtendedLifetime(first) {}
    }

    func testReleasedLockCanBeReacquired() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LifecycleLockProvider(rootURL: root.appendingPathComponent("state-v1"))
        let home = "/Users/example/.gnupg"

        do {
            _ = try provider.acquire(canonicalHomePath: home)
        }
        XCTAssertNoThrow(try provider.acquire(canonicalHomePath: home))
    }

    func testDifferentHomesShareTheGlobalPreferenceLock() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LifecycleLockProvider(rootURL: root.appendingPathComponent("state-v1"))
        let firstHome = "/Users/example/.gnupg"
        let secondHome = "/Users/example/.gnupg-work"
        let first = try provider.acquire(canonicalHomePath: firstHome)

        XCTAssertEqual(
            provider.lockURL(forCanonicalHomePath: firstHome),
            provider.lockURL(forCanonicalHomePath: secondHome)
        )
        XCTAssertThrowsError(try provider.acquire(canonicalHomePath: secondHome)) { error in
            XCTAssertEqual(error as? LifecycleLockError, .busy(secondHome))
        }
        withExtendedLifetime(first) {}
    }

    func testLockRefusesSymlinkedFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LifecycleLockProvider(rootURL: root.appendingPathComponent("state-v1"))
        try provider.prepare()
        let home = "/Users/example/.gnupg"
        let lockURL = provider.lockURL(forCanonicalHomePath: home)
        let target = root.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        XCTAssertEqual(symlink(target.path, lockURL.path), 0)

        XCTAssertThrowsError(try provider.acquire(canonicalHomePath: home)) { error in
            XCTAssertEqual(error as? LifecycleLockError, .symlink(lockURL.path))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporaryPath, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("pinentry-lifecycle-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(at url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }
}
