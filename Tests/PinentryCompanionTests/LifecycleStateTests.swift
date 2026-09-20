import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class LifecycleStateTests: XCTestCase {
    func testCanonicalHomeIdentifierIsStableSHA256() {
        XCTAssertEqual(
            LifecycleStateStore.identifier(forCanonicalHomePath: "/Users/example/.gnupg"),
            "148b18f445245bca7b535641415b5c9a952398f2693e1ee051da661478f5416e"
        )
        XCTAssertNotEqual(
            LifecycleStateStore.identifier(forCanonicalHomePath: "/Users/example/.gnupg"),
            LifecycleStateStore.identifier(forCanonicalHomePath: "/Users/example/.gnupg-alt")
        )
    }

    func testStateStoreRefusesRootLifecycleContext() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(
            rootURL: fixture.root.appendingPathComponent("state-v1"),
            effectiveUserID: 0
        )

        XCTAssertThrowsError(try store.save(makeRecord())) { error in
            XCTAssertEqual(error as? LifecycleStateError, .rootUser)
        }
    }

    func testLifecycleRecordRoundTripsEveryCompareAndSwapValue() throws {
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(LifecycleRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.originalConfig, .file(data: Data("original\n".utf8), mode: 0o600))
        XCTAssertEqual(
            decoded.expectedConfig,
            .file(data: Data("pinentry-program /opt/homebrew/bin/pinentry-companion\n".utf8), mode: 0o600)
        )
        XCTAssertEqual(decoded.originalPreference, .absent)
        XCTAssertEqual(decoded.expectedPreference, .boolean(true))
    }

    func testStateStoreCreatesPrivateDirectoryAndAtomicPrivateRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let record = makeRecord()

        try store.save(record)

        XCTAssertEqual(permissions(at: store.rootURL), 0o700)
        XCTAssertEqual(permissions(at: store.recordURL(forCanonicalHomePath: record.canonicalHomePath)), 0o600)
        XCTAssertEqual(try store.load(canonicalHomePath: record.canonicalHomePath), record)
    }

    func testStateStoreListsTheCurrentRecordForEveryManagedHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let first = makeRecord()
        var second = makeRecord()
        second.canonicalHomePath = "/Users/example/.gnupg-work"
        second.configPath = "/Users/example/.gnupg-work/gpg-agent.conf"

        try store.save(first)
        try store.save(second)

        XCTAssertEqual(Set(try store.loadAll().map(\.canonicalHomePath)), Set([
            first.canonicalHomePath,
            second.canonicalHomePath,
        ]))
    }

    func testStateStoreRemovesOnlyTheRequestedRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let first = makeRecord()
        var second = makeRecord()
        second.canonicalHomePath = "/Users/example/.gnupg-work"
        second.configPath = "/Users/example/.gnupg-work/gpg-agent.conf"
        try store.save(first)
        try store.save(second)

        try store.remove(canonicalHomePath: first.canonicalHomePath)

        XCTAssertNil(try store.load(canonicalHomePath: first.canonicalHomePath))
        XCTAssertEqual(try store.load(canonicalHomePath: second.canonicalHomePath), second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testStateStoreRefusesSymlinkedStateDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let link = fixture.root.appendingPathComponent("state-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let store = LifecycleStateStore(rootURL: link)

        XCTAssertThrowsError(try store.save(makeRecord())) { error in
            XCTAssertEqual(error as? LifecycleStateError, .symlink(link.path))
        }
    }

    func testStateStoreRefusesSymlinkedAncestorBeforeCreatingRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let linkedParent = fixture.root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(symlink(outside.path, linkedParent.path), 0)
        let root = linkedParent.appendingPathComponent("state-v1", isDirectory: true)
        let store = LifecycleStateStore(rootURL: root)

        XCTAssertThrowsError(try store.save(makeRecord())) { error in
            XCTAssertEqual(error as? LifecycleStateError, .symlink(linkedParent.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("state-v1").path))
    }

    func testStateStoreLoadRefusesSymlinkedAncestorWhenRootIsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let linkedParent = fixture.root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(symlink(outside.path, linkedParent.path), 0)
        let store = LifecycleStateStore(
            rootURL: linkedParent.appendingPathComponent("missing-state-v1", isDirectory: true)
        )

        XCTAssertThrowsError(try store.load(canonicalHomePath: makeRecord().canonicalHomePath)) { error in
            XCTAssertEqual(error as? LifecycleStateError, .symlink(linkedParent.path))
        }
    }

    func testStateStoreRejectsUnsupportedRecordSchema() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        var record = makeRecord()
        record.schemaVersion = 2

        XCTAssertThrowsError(try store.save(record)) { error in
            XCTAssertEqual(error as? LifecycleStateError, .unsupportedSchema(2))
        }
    }

    func testLifecycleRecordRejectsOutOfScopeConfigAndInvalidBinaryPaths() throws {
        var record = makeRecord()
        record.configPath = "/Users/example/other.conf"
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("config path must be gpg-agent.conf inside canonical GNUPGHOME")
            )
        }

        record = makeRecord()
        record.binary.invokedPath = "relative/pinentry-companion"
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("binary paths must be absolute canonical single-line paths")
            )
        }
    }

    func testLifecycleRecordRejectsNoncanonicalPathsAndUnsafeModes() throws {
        var record = makeRecord()
        record.canonicalHomePath = "/Users/example/../example/.gnupg"
        record.configPath = "/Users/example/.gnupg/gpg-agent.conf"
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("lifecycle paths must be absolute and canonical")
            )
        }

        record = makeRecord()
        record.binary.resolvedPath = "/opt/homebrew/../homebrew/bin/pinentry-companion"
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("binary paths must be absolute canonical single-line paths")
            )
        }

        record = makeRecord()
        record.binary.resolvedPath = "/opt/homebrew/bin/pinentry-companion\0ignored"
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("binary paths must be absolute canonical single-line paths")
            )
        }

        record = makeRecord()
        record.originalConfig = .file(data: Data(), mode: 0o4_600)
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("recorded modes must contain permission bits only")
            )
        }
    }

    func testStateStoreRejectsBroadRecordPermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let record = makeRecord()
        try store.save(record)
        let recordURL = store.recordURL(forCanonicalHomePath: record.canonicalHomePath)
        XCTAssertEqual(chmod(recordURL.path, 0o644), 0)

        XCTAssertThrowsError(try store.load(canonicalHomePath: record.canonicalHomePath)) { error in
            XCTAssertEqual(error as? LifecycleStateError, .invalidRecord("record permissions must be 0600"))
        }
    }

    func testStateStoreRejectsOversizedRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let record = makeRecord()
        try store.save(record)
        let recordURL = store.recordURL(forCanonicalHomePath: record.canonicalHomePath)
        try Data(repeating: 0x20, count: 1_048_577).write(to: recordURL)
        XCTAssertEqual(chmod(recordURL.path, 0o600), 0)

        XCTAssertThrowsError(try store.load(canonicalHomePath: record.canonicalHomePath)) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("record exceeds the 1 MiB safety limit")
            )
        }
    }

    func testStateStoreRejectsOversizedEncodedRecordBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        var record = makeRecord()
        record.originalConfig = .file(data: Data(repeating: 0x41, count: 800_000), mode: 0o600)

        XCTAssertThrowsError(try store.save(record)) { error in
            XCTAssertEqual(
                error as? LifecycleStateError,
                .invalidRecord("encoded record exceeds the 1 MiB safety limit")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.recordURL(forCanonicalHomePath: record.canonicalHomePath).path
            )
        )
    }

    func testStateStoreRejectsSymlinkedRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LifecycleStateStore(rootURL: fixture.root.appendingPathComponent("state-v1"))
        let record = makeRecord()
        try store.save(record)
        let recordURL = store.recordURL(forCanonicalHomePath: record.canonicalHomePath)
        let target = fixture.root.appendingPathComponent("replacement.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.removeItem(at: recordURL)
        XCTAssertEqual(symlink(target.path, recordURL.path), 0)

        XCTAssertThrowsError(try store.save(record)) { error in
            XCTAssertEqual(error as? LifecycleStateError, .symlink(recordURL.path))
        }
    }

    private func makeRecord() -> LifecycleRecord {
        LifecycleRecord(
            schemaVersion: 1,
            componentVersion: "0.2.0",
            canonicalHomePath: "/Users/example/.gnupg",
            configPath: "/Users/example/.gnupg/gpg-agent.conf",
            binary: LifecycleBinaryIdentity(
                invokedPath: "/opt/homebrew/bin/pinentry-companion",
                resolvedPath: "/opt/homebrew/Cellar/pinentry-companion/0.2.0/bin/pinentry-companion",
                sha256: String(repeating: "a", count: 64)
            ),
            originalConfig: .file(data: Data("original\n".utf8), mode: 0o600),
            expectedConfig: .file(
                data: Data("pinentry-program /opt/homebrew/bin/pinentry-companion\n".utf8),
                mode: 0o600
            ),
            originalHome: .directory(mode: 0o700),
            expectedHome: .directory(mode: 0o700),
            originalPreference: .absent,
            expectedPreference: .boolean(true),
            transactionBaseConfig: .file(data: Data("baseline\n".utf8), mode: 0o640),
            transactionBaseHome: .directory(mode: 0o750),
            transactionBasePreference: .boolean(false),
            phase: .prepared,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func permissions(at url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }
}

private struct Fixture {
    let root: URL

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporaryPath, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("pinentry-lifecycle-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
