import CommonCrypto
import Foundation

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
