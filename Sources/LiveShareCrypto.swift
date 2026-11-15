import Foundation
import CoreFoundation
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

    public struct OpenedEnvelope: Sendable {
        public let data: Data
        public let type: String?
        public let sequence: UInt64?
    }

    public func seal(_ plaintext: Data, type: String, sequence: UInt64) throws -> Data {
        guard !type.contains(":") else { throw CryptoError.invalidEnvelope }
        let aad = Self.makeAAD(type: type, sequence: sequence)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw CryptoError.invalidEnvelope }
        let envelope: [String: Any] = [
            "v": 1,
            "t": type,
            "s": NSNumber(value: sequence),
            "d": Self.base64URLEncode(combined)
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    public func open(_ envelope: Data, expectedType: String? = nil) throws -> Data {
        try openWithMetadata(envelope, expectedType: expectedType).data
    }

    public func openWithMetadata(
        _ envelope: Data,
        expectedType: String? = nil,
        minimumSequence: UInt64? = nil
    ) throws -> OpenedEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let versionNumber = object["v"] as? NSNumber,
              CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(versionNumber),
              let version = versionNumber as? Int,
              version == 1,
              let encoded = object["d"] as? String,
              let combined = Self.base64URLDecode(encoded) else {
            throw CryptoError.invalidEnvelope
        }

        let box = try AES.GCM.SealedBox(combined: combined)
        let hasType = object["t"] != nil
        let hasSeq = object["s"] != nil

        if hasType || hasSeq || expectedType != nil {
            guard let type = object["t"] as? String,
                  !type.contains(":"),
                  let sequence = Self.parseUInt64(object["s"]) else {
                throw CryptoError.invalidEnvelope
            }
            if let expectedType, type != expectedType {
                throw CryptoError.invalidEnvelope
            }
            if let minimumSequence, sequence < minimumSequence {
                throw CryptoError.invalidEnvelope
            }
            let aad = Self.makeAAD(type: type, sequence: sequence)
            let data = try AES.GCM.open(box, using: key, authenticating: aad)
            return OpenedEnvelope(data: data, type: type, sequence: sequence)
        }

        let data = try AES.GCM.open(box, using: key)
        return OpenedEnvelope(data: data, type: nil, sequence: nil)
    }

    private static func makeAAD(type: String, sequence: UInt64) -> Data {
        Data("v1:\(type):\(sequence)".utf8)
    }

    private static func parseUInt64(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        if let signed = number as? Int64 {
            return signed >= 0 ? UInt64(signed) : nil
        }
        if let unsigned = number as? UInt64 {
            return unsigned
        }
        return nil
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
