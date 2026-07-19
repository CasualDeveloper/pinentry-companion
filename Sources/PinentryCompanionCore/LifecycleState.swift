import Darwin
import Foundation

enum LifecycleStateError: Error, Equatable, CustomStringConvertible {
    case rootUser
    case symlink(String)
    case notDirectory(String)
    case notRegularFile(String)
    case notOwnedByCurrentUser(String)
    case unsupportedSchema(Int)
    case recordHomeMismatch(expected: String, actual: String)
    case invalidRecord(String)
    case fileSystem(path: String, message: String)

    var description: String {
        switch self {
        case .rootUser: return "refusing to manage user lifecycle state as root"
        case .symlink(let path): return "refusing symlinked lifecycle state path: \(path)"
        case .notDirectory(let path): return "lifecycle state root is not a directory: \(path)"
        case .notRegularFile(let path): return "lifecycle state record is not a regular file: \(path)"
        case .notOwnedByCurrentUser(let path): return "lifecycle state path is not owned by the current user: \(path)"
        case .unsupportedSchema(let version): return "unsupported lifecycle state schema: \(version)"
        case .recordHomeMismatch(let expected, let actual):
            return "lifecycle record home mismatch: expected \(expected), found \(actual)"
        case .invalidRecord(let reason): return "invalid lifecycle record: \(reason)"
        case .fileSystem(let path, let message): return "lifecycle state I/O failed at \(path): \(message)"
        }
    }
}

struct LifecycleStateStore: LifecycleStatePersisting {
    private static let maximumRecordSize = 1_048_576
    let rootURL: URL
    private let effectiveUserID: uid_t

    init(rootURL: URL, effectiveUserID: uid_t = geteuid()) {
        self.rootURL = rootURL
        self.effectiveUserID = effectiveUserID
    }

    static func defaultRootURL(homeURL: URL) -> URL {
        homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("pinentry-companion/state-v1", isDirectory: true)
    }

    static func identifier(forCanonicalHomePath path: String) -> String {
        SHA256Digest.hex(Data(path.utf8))
    }

    func recordURL(forCanonicalHomePath path: String) -> URL {
        rootURL.appendingPathComponent("\(Self.identifier(forCanonicalHomePath: path)).json")
    }

    func save(_ record: LifecycleRecord) throws {
        guard effectiveUserID != 0 else { throw LifecycleStateError.rootUser }
        try record.validate()
        try prepare()
        let url = recordURL(forCanonicalHomePath: record.canonicalHomePath)
        try validateRecordIfPresent(url)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordSize else {
            throw LifecycleStateError.invalidRecord("encoded record exceeds the 1 MiB safety limit")
        }
        try atomicWrite(data, to: url)
    }

    func prepare() throws {
        guard effectiveUserID != 0 else { throw LifecycleStateError.rootUser }
        try prepareRoot()
    }

    func load(canonicalHomePath: String) throws -> LifecycleRecord? {
        guard effectiveUserID != 0 else { throw LifecycleStateError.rootUser }
        try validateRootPath()
        try validateNoSymlinkComponents(to: rootURL)
        guard try metadataIfPresent(rootURL) != nil else { return nil }
        try validateRoot()
        let url = recordURL(forCanonicalHomePath: canonicalHomePath)
        guard try metadataIfPresent(url) != nil else { return nil }
        try validateRecordIfPresent(url)

        do {
            let record = try decodeRecord(at: url)
            guard record.canonicalHomePath == canonicalHomePath else {
                throw LifecycleStateError.recordHomeMismatch(
                    expected: canonicalHomePath,
                    actual: record.canonicalHomePath
                )
            }
            return record
        } catch let error as LifecycleStateError {
            throw error
        } catch {
            throw LifecycleStateError.fileSystem(path: url.path, message: error.localizedDescription)
        }
    }

    func loadAll() throws -> [LifecycleRecord] {
        guard effectiveUserID != 0 else { throw LifecycleStateError.rootUser }
        try validateRootPath()
        try validateNoSymlinkComponents(to: rootURL)
        guard try metadataIfPresent(rootURL) != nil else { return [] }
        try validateRoot()

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LifecycleStateError.fileSystem(path: rootURL.path, message: error.localizedDescription)
        }

        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                try validateRecordIfPresent(url)
                let record = try decodeRecord(at: url)
                let expectedName = "\(Self.identifier(forCanonicalHomePath: record.canonicalHomePath)).json"
                guard url.lastPathComponent == expectedName else {
                    throw LifecycleStateError.invalidRecord(
                        "record filename does not match its canonical GNUPGHOME"
                    )
                }
                return record
            }
    }

    private func decodeRecord(at url: URL) throws -> LifecycleRecord {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(LifecycleRecord.self, from: readRecordData(url))
            try record.validate()
            return record
        } catch let error as LifecycleStateError {
            throw error
        } catch {
            throw LifecycleStateError.fileSystem(path: url.path, message: error.localizedDescription)
        }
    }

    private func prepareRoot() throws {
        try validateRootPath()
        try validateNoSymlinkComponents(to: rootURL)
        if try metadataIfPresent(rootURL) == nil {
            let parent = try nearestExistingAncestor(of: rootURL)
            guard let metadata = try metadataIfPresent(parent) else {
                throw LifecycleStateError.notDirectory(parent.path)
            }
            guard metadata.isDirectory else { throw LifecycleStateError.notDirectory(parent.path) }
            guard metadata.uid == effectiveUserID else {
                throw LifecycleStateError.notOwnedByCurrentUser(parent.path)
            }
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw LifecycleStateError.fileSystem(path: rootURL.path, message: error.localizedDescription)
            }
        }
        try validateRoot()
        if chmod(rootURL.path, 0o700) != 0 { throw fileSystemError(rootURL.path) }
    }

    private func validateRoot() throws {
        try validateRootPath()
        try validateNoSymlinkComponents(to: rootURL)
        guard let metadata = try metadataIfPresent(rootURL) else { return }
        if metadata.isSymlink { throw LifecycleStateError.symlink(rootURL.path) }
        guard metadata.isDirectory else { throw LifecycleStateError.notDirectory(rootURL.path) }
        guard metadata.uid == effectiveUserID else {
            throw LifecycleStateError.notOwnedByCurrentUser(rootURL.path)
        }
    }

    private func validateRecordIfPresent(_ url: URL) throws {
        guard let metadata = try metadataIfPresent(url) else { return }
        if metadata.isSymlink { throw LifecycleStateError.symlink(url.path) }
        guard metadata.isRegularFile else { throw LifecycleStateError.notRegularFile(url.path) }
        guard metadata.uid == effectiveUserID else {
            throw LifecycleStateError.notOwnedByCurrentUser(url.path)
        }
        guard metadata.mode & 0o777 == 0o600 else {
            throw LifecycleStateError.invalidRecord("record permissions must be 0600")
        }
        guard metadata.size <= Self.maximumRecordSize else {
            throw LifecycleStateError.invalidRecord("record exceeds the 1 MiB safety limit")
        }
    }

    private func validateRootPath() throws {
        guard LifecyclePath.isCanonicalAbsolute(rootURL.path) else {
            throw LifecycleStateError.invalidRecord(
                "lifecycle state root must be an absolute canonical path"
            )
        }
    }

    private func readRecordData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileSystemError(url.path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileSystemError(url.path) }
        let metadata = Metadata(info)
        if metadata.isSymlink { throw LifecycleStateError.symlink(url.path) }
        guard metadata.isRegularFile else { throw LifecycleStateError.notRegularFile(url.path) }
        guard metadata.uid == effectiveUserID else {
            throw LifecycleStateError.notOwnedByCurrentUser(url.path)
        }
        guard metadata.mode & 0o777 == 0o600 else {
            throw LifecycleStateError.invalidRecord("record permissions must be 0600")
        }
        guard metadata.size <= Self.maximumRecordSize else {
            throw LifecycleStateError.invalidRecord("record exceeds the 1 MiB safety limit")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw fileSystemError(url.path)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumRecordSize {
                throw LifecycleStateError.invalidRecord("record exceeds the 1 MiB safety limit")
            }
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        guard destination.deletingLastPathComponent().path == rootURL.path else {
            throw LifecycleStateError.invalidRecord("record destination is outside the lifecycle state root")
        }
        let rootDescriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw fileSystemError(rootURL.path) }
        defer { close(rootDescriptor) }

        let temporaryName = ".\(UUID().uuidString).tmp"
        let descriptor = openat(
            rootDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        let temporaryPath = rootURL.appendingPathComponent(temporaryName).path
        guard descriptor >= 0 else { throw fileSystemError(temporaryPath) }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { _ = unlinkat(rootDescriptor, temporaryName, 0) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw fileSystemError(temporaryPath) }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if fchmod(descriptor, 0o600) != 0 { throw fileSystemError(temporaryPath) }
        if fsync(descriptor) != 0 { throw fileSystemError(temporaryPath) }
        if renameat(
            rootDescriptor,
            temporaryName,
            rootDescriptor,
            destination.lastPathComponent
        ) != 0 { throw fileSystemError(destination.path) }
        shouldRemove = false
        if fsync(rootDescriptor) != 0 { throw fileSystemError(rootURL.path) }
    }

    private func metadataIfPresent(_ url: URL) throws -> Metadata? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return Metadata(info) }
        if errno == ENOENT { return nil }
        throw fileSystemError(url.path)
    }

    private func validateNoSymlinkComponents(to url: URL) throws {
        var currentPath = ""
        for component in url.pathComponents.dropFirst() {
            currentPath += "/\(component)"
            let current = URL(fileURLWithPath: currentPath)
            guard let metadata = try metadataIfPresent(current) else { return }
            if metadata.isSymlink { throw LifecycleStateError.symlink(current.path) }
        }
    }

    private func nearestExistingAncestor(of url: URL) throws -> URL {
        var candidate = url.deletingLastPathComponent()
        while try metadataIfPresent(candidate) == nil {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return candidate }
            candidate = parent
        }
        return candidate
    }

    private func fileSystemError(_ path: String) -> LifecycleStateError {
        LifecycleStateError.fileSystem(path: path, message: String(cString: strerror(errno)))
    }

    private struct Metadata {
        let uid: uid_t
        let mode: mode_t
        let size: off_t

        init(_ info: stat) {
            uid = info.st_uid
            mode = info.st_mode
            size = info.st_size
        }

        var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    }
}
