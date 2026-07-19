import Darwin
import Foundation

enum LifecycleFileSystemError: Error, Equatable, CustomStringConvertible {
    case rootUser
    case invalidPaths
    case symlink(String)
    case notDirectory(String)
    case notRegularFile(String)
    case notOwnedByCurrentUser(String)
    case fileTooLarge(String)
    case fileSystem(path: String, message: String)

    var description: String {
        switch self {
        case .rootUser: return "refusing to manage user GPG configuration as root"
        case .invalidPaths: return "GPG configuration path must be gpg-agent.conf inside canonical GNUPGHOME"
        case .symlink(let path): return "refusing symlinked lifecycle target: \(path)"
        case .notDirectory(let path): return "GNUPGHOME is not a directory: \(path)"
        case .notRegularFile(let path): return "GPG configuration is not a regular file: \(path)"
        case .notOwnedByCurrentUser(let path): return "lifecycle target is not owned by the current user: \(path)"
        case .fileTooLarge(let path): return "GPG configuration exceeds the 1 MiB safety limit: \(path)"
        case .fileSystem(let path, let message): return "lifecycle target I/O failed at \(path): \(message)"
        }
    }
}

final class FileSystemLifecycleTarget: LifecycleTargetManaging {
    private static let maximumConfigSize = 1_048_576
    private let effectiveUserID: uid_t

    init(effectiveUserID: uid_t = geteuid()) {
        self.effectiveUserID = effectiveUserID
    }

    func snapshot(canonicalHomePath: String, configPath: String) throws -> LifecycleTargetSnapshot {
        try requireNonRoot()
        let paths = try validatedPaths(homePath: canonicalHomePath, configPath: configPath)
        guard let homeMetadata = try metadataIfPresent(paths.home.path) else {
            try validateCreationParent(for: paths.home)
            return LifecycleTargetSnapshot(home: .missing, config: .missing)
        }
        try validateHome(homeMetadata, path: paths.home.path)
        try validateCanonicalExistingPath(paths.home)

        let homeDescriptor = try openHome(paths.home.path)
        defer { close(homeDescriptor) }
        return LifecycleTargetSnapshot(
            home: .directory(mode: permissionBits(homeMetadata.mode)),
            config: try readConfig(homeDescriptor: homeDescriptor, paths: paths)
        )
    }

    func applyHome(_ state: LifecycleHomeState, canonicalHomePath: String) throws {
        try requireNonRoot()
        let home = try validatedAbsoluteURL(canonicalHomePath)
        switch state {
        case .directory(let mode):
            if try metadataIfPresent(home.path) == nil {
                try validateCreationParent(for: home)
                guard mkdir(home.path, mode_t(mode)) == 0 else { throw fileSystemError(home.path) }
            }
            let descriptor = try openHome(home.path)
            defer { close(descriptor) }
            guard fchmod(descriptor, mode_t(mode)) == 0 else { throw fileSystemError(home.path) }
            guard fsync(descriptor) == 0 else { throw fileSystemError(home.path) }
        case .missing:
            guard try metadataIfPresent(home.path) != nil else { return }
            let descriptor = try openHome(home.path)
            close(descriptor)
            guard rmdir(home.path) == 0 else { throw fileSystemError(home.path) }
        }
    }

    func applyConfig(_ state: LifecycleFileState, configPath: String) throws {
        try requireNonRoot()
        let config = try validatedAbsoluteURL(configPath)
        let home = config.deletingLastPathComponent()
        let paths = try validatedPaths(homePath: home.path, configPath: config.path)
        let homeDescriptor = try openHome(paths.home.path)
        defer { close(homeDescriptor) }
        try validateConfigIfPresent(homeDescriptor: homeDescriptor, paths: paths)

        switch state {
        case .missing:
            if unlinkat(homeDescriptor, paths.config.lastPathComponent, 0) != 0, errno != ENOENT {
                throw fileSystemError(paths.config.path)
            }
            guard fsync(homeDescriptor) == 0 else { throw fileSystemError(paths.home.path) }
        case .file(let data, let mode):
            guard data.count <= Self.maximumConfigSize else {
                throw LifecycleFileSystemError.fileTooLarge(paths.config.path)
            }
            try atomicWrite(
                data,
                mode: mode,
                homeDescriptor: homeDescriptor,
                paths: paths
            )
        }
    }

    private func validatedPaths(homePath: String, configPath: String) throws -> (home: URL, config: URL) {
        let home = try validatedAbsoluteURL(homePath)
        let config = try validatedAbsoluteURL(configPath)
        guard config.lastPathComponent == "gpg-agent.conf",
              config.deletingLastPathComponent().path == home.path else {
            throw LifecycleFileSystemError.invalidPaths
        }
        return (home, config)
    }

    private func validatedAbsoluteURL(_ path: String) throws -> URL {
        guard LifecyclePath.isCanonicalAbsolute(path) else {
            throw LifecycleFileSystemError.invalidPaths
        }
        return URL(fileURLWithPath: path)
    }

    private func validateCreationParent(for home: URL) throws {
        let parent = home.deletingLastPathComponent()
        guard let metadata = try metadataIfPresent(parent.path) else {
            throw LifecycleFileSystemError.notDirectory(parent.path)
        }
        if metadata.isSymlink { throw LifecycleFileSystemError.symlink(parent.path) }
        guard metadata.isDirectory else { throw LifecycleFileSystemError.notDirectory(parent.path) }
        try validateOwner(metadata, path: parent.path)
        try validateCanonicalExistingPath(parent)
    }

    private func validateCanonicalExistingPath(_ url: URL) throws {
        var currentPath = ""
        for component in url.pathComponents.dropFirst() {
            currentPath += "/\(component)"
            guard let metadata = try metadataIfPresent(currentPath) else { return }
            if metadata.isSymlink { throw LifecycleFileSystemError.symlink(currentPath) }
        }
    }

    private func openHome(_ path: String) throws -> CInt {
        guard let metadata = try metadataIfPresent(path) else {
            throw LifecycleFileSystemError.notDirectory(path)
        }
        try validateHome(metadata, path: path)
        try validateCanonicalExistingPath(URL(fileURLWithPath: path))
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileSystemError(path) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw fileSystemError(path) }
            try validateHome(Metadata(info), path: path)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func readConfig(
        homeDescriptor: CInt,
        paths: (home: URL, config: URL)
    ) throws -> LifecycleFileState {
        let name = paths.config.lastPathComponent
        let descriptor = openat(homeDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .missing }
            if errno == ELOOP { throw LifecycleFileSystemError.symlink(paths.config.path) }
            throw fileSystemError(paths.config.path)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileSystemError(paths.config.path) }
        let metadata = Metadata(info)
        try validateConfig(metadata, path: paths.config.path)
        guard info.st_size <= Self.maximumConfigSize else {
            throw LifecycleFileSystemError.fileTooLarge(paths.config.path)
        }
        return .file(
            data: try readAll(descriptor, path: paths.config.path),
            mode: permissionBits(metadata.mode)
        )
    }

    private func validateConfigIfPresent(
        homeDescriptor: CInt,
        paths: (home: URL, config: URL)
    ) throws {
        var info = stat()
        if fstatat(homeDescriptor, paths.config.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw fileSystemError(paths.config.path)
        }
        let metadata = Metadata(info)
        if metadata.isSymlink { throw LifecycleFileSystemError.symlink(paths.config.path) }
        try validateConfig(metadata, path: paths.config.path)
    }

    private func atomicWrite(
        _ data: Data,
        mode: UInt16,
        homeDescriptor: CInt,
        paths: (home: URL, config: URL)
    ) throws {
        let temporaryName = ".gpg-agent.conf.pinentry-companion.\(UUID().uuidString).tmp"
        let descriptor = openat(
            homeDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(mode)
        )
        guard descriptor >= 0 else { throw fileSystemError(paths.home.appendingPathComponent(temporaryName).path) }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { _ = unlinkat(homeDescriptor, temporaryName, 0) }
        }

        try writeAll(data, descriptor: descriptor, path: paths.config.path)
        guard fchmod(descriptor, mode_t(mode)) == 0 else { throw fileSystemError(paths.config.path) }
        guard fsync(descriptor) == 0 else { throw fileSystemError(paths.config.path) }
        guard renameat(
            homeDescriptor,
            temporaryName,
            homeDescriptor,
            paths.config.lastPathComponent
        ) == 0 else { throw fileSystemError(paths.config.path) }
        removeTemporary = false
        guard fsync(homeDescriptor) == 0 else { throw fileSystemError(paths.home.path) }
    }

    private func readAll(_ descriptor: CInt, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw fileSystemError(path)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumConfigSize {
                throw LifecycleFileSystemError.fileTooLarge(path)
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: CInt, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw fileSystemError(path) }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private func metadataIfPresent(_ path: String) throws -> Metadata? {
        var info = stat()
        if lstat(path, &info) == 0 { return Metadata(info) }
        if errno == ENOENT { return nil }
        throw fileSystemError(path)
    }

    private func validateHome(_ metadata: Metadata, path: String) throws {
        if metadata.isSymlink { throw LifecycleFileSystemError.symlink(path) }
        guard metadata.isDirectory else { throw LifecycleFileSystemError.notDirectory(path) }
        try validateOwner(metadata, path: path)
    }

    private func validateConfig(_ metadata: Metadata, path: String) throws {
        guard metadata.isRegularFile else { throw LifecycleFileSystemError.notRegularFile(path) }
        try validateOwner(metadata, path: path)
    }

    private func validateOwner(_ metadata: Metadata, path: String) throws {
        guard metadata.uid == effectiveUserID else {
            throw LifecycleFileSystemError.notOwnedByCurrentUser(path)
        }
    }

    private func requireNonRoot() throws {
        guard effectiveUserID != 0 else { throw LifecycleFileSystemError.rootUser }
    }

    private func permissionBits(_ mode: mode_t) -> UInt16 { UInt16(mode & 0o777) }

    private func fileSystemError(_ path: String) -> LifecycleFileSystemError {
        LifecycleFileSystemError.fileSystem(path: path, message: String(cString: strerror(errno)))
    }

    private struct Metadata {
        let uid: uid_t
        let mode: mode_t

        init(_ info: stat) {
            uid = info.st_uid
            mode = info.st_mode
        }

        var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    }
}
