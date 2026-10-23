import Foundation
import CryptoKit

public struct LiveShareCrypto: @unchecked Sendable {
    public enum CryptoError: Error {
        case invalidKey
        case invalidEnvelope
    }

    private let key: SymmetricKey

    public init() {
        self.key = SymmetricKey(size: .bits256)
    }

    public init?(keyFragment: String) {
        let value = keyFragment.hasPrefix("k=") ? String(keyFragment.dropFirst(2)) : keyFragment
        guard let data = Self.base64URLDecode(value), data.count == 32 else { return nil }
        self.key = SymmetricKey(data: data)
    }

    public var keyFragment: String {
        "k=" + key.withUnsafeBytes { Self.base64URLEncode(Data($0)) }
    }

    public func seal(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.invalidEnvelope }
        let envelope: [String: Any] = [
            "v": 1,
            "d": Self.base64URLEncode(combined)
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    public func open(_ envelope: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              object["v"] as? Int == 1,
              let encoded = object["d"] as? String,
              let combined = Self.base64URLDecode(encoded) else {
            throw CryptoError.invalidEnvelope
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}
