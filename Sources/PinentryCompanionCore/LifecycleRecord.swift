import Foundation

struct LifecycleRecord: Codable, Equatable {
    var schemaVersion: Int
    var componentVersion: String
    var canonicalHomePath: String
    var configPath: String
    var binary: LifecycleBinaryIdentity
    var originalConfig: LifecycleFileState
    var expectedConfig: LifecycleFileState
    var originalHome: LifecycleHomeState
    var expectedHome: LifecycleHomeState
    var originalPreference: LifecyclePreferenceState
    var expectedPreference: LifecyclePreferenceState
    var transactionBaseConfig: LifecycleFileState
    var transactionBaseHome: LifecycleHomeState
    var transactionBasePreference: LifecyclePreferenceState
    var phase: LifecyclePhase
    var createdAt: Date
    var updatedAt: Date

    func validate() throws {
        guard schemaVersion == 1 else { throw LifecycleStateError.unsupportedSchema(schemaVersion) }
        guard !componentVersion.isEmpty, componentVersion.count <= 64 else {
            throw LifecycleStateError.invalidRecord("component version is missing or unreasonably long")
        }
        guard LifecyclePath.isCanonicalAbsolute(canonicalHomePath),
              LifecyclePath.isCanonicalAbsolute(configPath) else {
            throw LifecycleStateError.invalidRecord("lifecycle paths must be absolute and canonical")
        }
        let expectedConfigPath = URL(fileURLWithPath: canonicalHomePath, isDirectory: true)
            .appendingPathComponent("gpg-agent.conf")
            .path
        guard configPath == expectedConfigPath else {
            throw LifecycleStateError.invalidRecord(
                "config path must be gpg-agent.conf inside canonical GNUPGHOME"
            )
        }
        guard LifecyclePath.isCanonicalAbsolute(binary.invokedPath),
              LifecyclePath.isCanonicalAbsolute(binary.resolvedPath) else {
            throw LifecycleStateError.invalidRecord(
                "binary paths must be absolute canonical single-line paths"
            )
        }
        guard binary.sha256.isSHA256 else {
            throw LifecycleStateError.invalidRecord("binary digest must be lowercase SHA-256")
        }
        guard case .file = expectedConfig,
              case .directory = expectedHome,
              expectedPreference == .boolean(true) else {
            throw LifecycleStateError.invalidRecord("managed expected state has invalid node kinds")
        }
        guard [originalConfig, expectedConfig, transactionBaseConfig].allSatisfy(\.hasPermissionOnlyMode),
              [originalHome, expectedHome, transactionBaseHome].allSatisfy(\.hasPermissionOnlyMode) else {
            throw LifecycleStateError.invalidRecord("recorded modes must contain permission bits only")
        }
    }

    var requiresManagedPreference: Bool {
        switch phase {
        case .restored:
            return false
        case .rolledBack:
            return transactionBaseHome != originalHome ||
                transactionBaseConfig != originalConfig ||
                transactionBasePreference != originalPreference
        default:
            return true
        }
    }
}

struct LifecycleBinaryIdentity: Codable, Equatable {
    var invokedPath: String
    var resolvedPath: String
    var sha256: String
}

enum LifecycleFileState: Equatable {
    case missing
    case file(data: Data, mode: UInt16)

    fileprivate var hasPermissionOnlyMode: Bool {
        switch self {
        case .missing: return true
        case .file(_, let mode): return mode & ~UInt16(0o777) == 0
        }
    }
}

extension LifecycleFileState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, data, mode, sha256 }
    private enum Kind: String, Codable { case missing, file }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .missing:
            self = .missing
        case .file:
            let data = try values.decode(Data.self, forKey: .data)
            let digest = try values.decode(String.self, forKey: .sha256)
            guard digest == SHA256Digest.hex(data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sha256,
                    in: values,
                    debugDescription: "lifecycle file digest does not match its bytes"
                )
            }
            self = .file(data: data, mode: try values.decode(UInt16.self, forKey: .mode))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .missing:
            try values.encode(Kind.missing, forKey: .kind)
        case .file(let data, let mode):
            try values.encode(Kind.file, forKey: .kind)
            try values.encode(data, forKey: .data)
            try values.encode(mode, forKey: .mode)
            try values.encode(SHA256Digest.hex(data), forKey: .sha256)
        }
    }
}

enum LifecycleHomeState: Equatable {
    case missing
    case directory(mode: UInt16)

    fileprivate var hasPermissionOnlyMode: Bool {
        switch self {
        case .missing: return true
        case .directory(let mode): return mode & ~UInt16(0o777) == 0
        }
    }
}

extension LifecycleHomeState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, mode }
    private enum Kind: String, Codable { case missing, directory }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .missing: self = .missing
        case .directory: self = .directory(mode: try values.decode(UInt16.self, forKey: .mode))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .missing:
            try values.encode(Kind.missing, forKey: .kind)
        case .directory(let mode):
            try values.encode(Kind.directory, forKey: .kind)
            try values.encode(mode, forKey: .mode)
        }
    }
}

enum LifecyclePreferenceState: Equatable {
    case absent
    case boolean(Bool)
    case unsupported(type: String, description: String)
}

extension LifecyclePreferenceState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, type, description }
    private enum Kind: String, Codable { case absent, boolean, unsupported }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .absent: self = .absent
        case .boolean: self = .boolean(try values.decode(Bool.self, forKey: .value))
        case .unsupported:
            self = .unsupported(
                type: try values.decode(String.self, forKey: .type),
                description: try values.decode(String.self, forKey: .description)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try values.encode(Kind.absent, forKey: .kind)
        case .boolean(let value):
            try values.encode(Kind.boolean, forKey: .kind)
            try values.encode(value, forKey: .value)
        case .unsupported(let type, let description):
            try values.encode(Kind.unsupported, forKey: .kind)
            try values.encode(type, forKey: .type)
            try values.encode(description, forKey: .description)
        }
    }
}

enum LifecyclePhase: String, Codable, Equatable {
    case prepared
    case configApplied
    case preferenceApplied
    case agentReloaded
    case complete
    case rollingBack
    case rolledBack
    case restorePrepared
    case configRestored
    case preferenceRestored
    case restored
    case failed
}

private extension String {
    var isSHA256: Bool {
        count == 64 && unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
