import Darwin
import Foundation

enum LifecycleLockError: Error, Equatable, CustomStringConvertible {
    case rootUser
    case busy(String)
    case symlink(String)
    case notRegularFile(String)
    case notOwnedByCurrentUser(String)
    case invalidPermissions(String)
    case fileSystem(path: String, message: String)

    var description: String {
        switch self {
        case .rootUser: return "refusing to acquire user lifecycle lock as root"
        case .busy(let home): return "another lifecycle operation is active for \(home)"
        case .symlink(let path): return "refusing symlinked lifecycle lock: \(path)"
        case .notRegularFile(let path): return "lifecycle lock is not a regular file: \(path)"
        case .notOwnedByCurrentUser(let path): return "lifecycle lock is not owned by the current user: \(path)"
        case .invalidPermissions(let path): return "lifecycle lock permissions must be 0600: \(path)"
        case .fileSystem(let path, let message): return "lifecycle lock I/O failed at \(path): \(message)"
        }
    }
}

final class LifecycleLockToken: LifecycleLockHolding {
    private var descriptor: CInt

    init(descriptor: CInt) {
        self.descriptor = descriptor
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }
}

struct LifecycleLockProvider: LifecycleLockProviding {
    private let stateStore: LifecycleStateStore
    private let effectiveUserID: uid_t

    init(rootURL: URL, effectiveUserID: uid_t = geteuid()) {
        stateStore = LifecycleStateStore(rootURL: rootURL, effectiveUserID: effectiveUserID)
        self.effectiveUserID = effectiveUserID
    }

    func prepare() throws {
        do {
            try stateStore.prepare()
        } catch LifecycleStateError.rootUser {
            throw LifecycleLockError.rootUser
        } catch {
            throw LifecycleLockError.fileSystem(path: stateStore.rootURL.path, message: String(describing: error))
        }
    }

    func lockURL(forCanonicalHomePath path: String) -> URL {
        _ = path
        return stateStore.rootURL.appendingPathComponent("lifecycle.lock")
    }

    func acquire(canonicalHomePath: String) throws -> any LifecycleLockHolding {
        guard effectiveUserID != 0 else { throw LifecycleLockError.rootUser }
        try prepare()
        let url = lockURL(forCanonicalHomePath: canonicalHomePath)
        try validateIfPresent(url)

        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw fileSystemError(url.path) }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }

        try validateDescriptor(descriptor, path: url.path)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw LifecycleLockError.busy(canonicalHomePath) }
            throw fileSystemError(url.path)
        }
        shouldClose = false
        return LifecycleLockToken(descriptor: descriptor)
    }

    private func validateIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw fileSystemError(url.path)
        }
        if info.st_mode & S_IFMT == S_IFLNK { throw LifecycleLockError.symlink(url.path) }
        try validate(info, path: url.path)
    }

    private func validateDescriptor(_ descriptor: CInt, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileSystemError(path) }
        try validate(info, path: path)
    }

    private func validate(_ info: stat, path: String) throws {
        guard info.st_mode & S_IFMT == S_IFREG else { throw LifecycleLockError.notRegularFile(path) }
        guard info.st_uid == effectiveUserID else { throw LifecycleLockError.notOwnedByCurrentUser(path) }
        guard info.st_mode & 0o777 == 0o600 else { throw LifecycleLockError.invalidPermissions(path) }
    }

    private func fileSystemError(_ path: String) -> LifecycleLockError {
        LifecycleLockError.fileSystem(path: path, message: String(cString: strerror(errno)))
    }
}
