import Foundation
import CoreFoundation
import CryptoKit

struct LiveShareCrypto: @unchecked Sendable {
    enum CryptoError: Error {
        case invalidKey
        case invalidEnvelope
    }

    private let key: SymmetricKey

    init() {
        self.key = SymmetricKey(size: .bits256)
    }

    init?(keyFragment: String) {
        let value = keyFragment.hasPrefix("k=") ? String(keyFragment.dropFirst(2)) : keyFragment
        guard let data = Self.base64URLDecode(value), data.count == 32 else { return nil }
        self.key = SymmetricKey(data: data)
    }

    var keyFragment: String {
        "k=" + key.withUnsafeBytes { Self.base64URLEncode(Data($0)) }
    }

    func seal(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.invalidEnvelope }
        let encodedLen = Self.base64URLEncodedCount(for: combined.count)
        let prefix: StaticString = "{\"v\":1,\"d\":\""
        let prefixLen = prefix.utf8CodeUnitCount
        var out = Data(count: prefixLen + encodedLen + 2)
        out.withUnsafeMutableBytes { outRaw in
            guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            prefix.withUTF8Buffer { pBuf in
                if let pBase = pBuf.baseAddress {
                    dst.update(from: pBase, count: prefixLen)
                }
            }
            let written = Self.encodeBase64URL(combined, into: dst.advanced(by: prefixLen))
            let endOffset = prefixLen + written
            dst[endOffset] = 0x22 // '"'
            dst[endOffset + 1] = 0x7D // '}'
        }
        return out
    }

    struct OpenedEnvelope: Sendable {
        let data: Data
        let type: String?
        let sequence: UInt64?
    }

    func seal(_ plaintext: Data, type: String, sequence: UInt64) throws -> Data {
        guard !type.contains(":") else { throw CryptoError.invalidEnvelope }
        let aad = Self.makeAAD(type: type, sequence: sequence)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw CryptoError.invalidEnvelope }
        guard Self.isSafeUnescapedJSONASCII(type) else {
            let envelope: [String: Any] = [
                "v": 1,
                "t": type,
                "s": NSNumber(value: sequence),
                "d": Self.base64URLEncode(combined)
            ]
            return try JSONSerialization.data(withJSONObject: envelope, options: [])
        }

        let typeBytes = Array(type.utf8)
        let encodedLen = Self.base64URLEncodedCount(for: combined.count)
        var seqValue = sequence
        var seqLen = 0
        var tmp = seqValue
        repeat {
            seqLen += 1
            tmp /= 10
        } while tmp > 0

        let prefix1: StaticString = "{\"v\":1,\"t\":\""
        let mid1: StaticString = "\",\"s\":"
        let mid2: StaticString = ",\"d\":\""
        let totalLen = prefix1.utf8CodeUnitCount + typeBytes.count + mid1.utf8CodeUnitCount + seqLen + mid2.utf8CodeUnitCount + encodedLen + 2

        var out = Data(count: totalLen)
        out.withUnsafeMutableBytes { outRaw in
            guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0

            prefix1.withUTF8Buffer { pBuf in
                if let pBase = pBuf.baseAddress {
                    dst.advanced(by: offset).update(from: pBase, count: pBuf.count)
                    offset += pBuf.count
                }
            }
            typeBytes.withUnsafeBufferPointer { tBuf in
                if let tBase = tBuf.baseAddress {
                    dst.advanced(by: offset).update(from: tBase, count: tBuf.count)
                    offset += tBuf.count
                }
            }
            mid1.withUTF8Buffer { mBuf in
                if let mBase = mBuf.baseAddress {
                    dst.advanced(by: offset).update(from: mBase, count: mBuf.count)
                    offset += mBuf.count
                }
            }
            var writeIdx = offset + seqLen
            repeat {
                writeIdx -= 1
                dst[writeIdx] = UInt8(0x30 + (seqValue % 10))
                seqValue /= 10
            } while seqValue > 0
            offset += seqLen

            mid2.withUTF8Buffer { mBuf in
                if let mBase = mBuf.baseAddress {
                    dst.advanced(by: offset).update(from: mBase, count: mBuf.count)
                    offset += mBuf.count
                }
            }
            let written = Self.encodeBase64URL(combined, into: dst.advanced(by: offset))
            offset += written
            dst[offset] = 0x22 // '"'
            dst[offset + 1] = 0x7D // '}'
        }
        return out
    }

    func open(_ envelope: Data, expectedType: String? = nil) throws -> Data {
        try openWithMetadata(envelope, expectedType: expectedType).data
    }

    func openWithMetadata(
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

        if hasType || hasSeq || expectedType != nil || minimumSequence != nil {
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

    private static let base64URLEncodeTable: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
    )

    private static let base64URLDecodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for i in 0..<26 {
            table[0x41 + i] = Int8(i)      // A-Z
            table[0x61 + i] = Int8(26 + i) // a-z
        }
        for i in 0..<10 {
            table[0x30 + i] = Int8(52 + i) // 0-9
        }
        table[0x2D] = 62 // '-'
        table[0x2B] = 62 // '+'
        table[0x5F] = 63 // '_'
        table[0x2F] = 63 // '/'
        return table
    }()

    @inline(__always)
    private static func isSafeUnescapedJSONASCII(_ value: String) -> Bool {
        for byte in value.utf8 {
            if byte < 0x20 || byte > 0x7E || byte == 0x22 || byte == 0x5C {
                return false
            }
        }
        return true
    }

    @inline(__always)
    private static func base64URLEncodedCount(for byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        let (fullTriples, remainder) = byteCount.quotientAndRemainder(dividingBy: 3)
        return fullTriples * 4 + (remainder == 0 ? 0 : remainder + 1)
    }

    private static func encodeBase64URL(_ data: Data, into dst: UnsafeMutablePointer<UInt8>) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return base64URLEncodeTable.withUnsafeBufferPointer { tableBuf in
                guard let table = tableBuf.baseAddress else { return 0 }
                var i = 0
                var j = 0
                while i + 3 <= count {
                    let n = (Int(src[i]) << 16) | (Int(src[i + 1]) << 8) | Int(src[i + 2])
                    dst[j] = table[(n >> 18) & 0x3F]
                    dst[j + 1] = table[(n >> 12) & 0x3F]
                    dst[j + 2] = table[(n >> 6) & 0x3F]
                    dst[j + 3] = table[n & 0x3F]
                    i += 3
                    j += 4
                }
                let remainder = count - i
                if remainder == 1 {
                    let b0 = Int(src[i])
                    dst[j] = table[b0 >> 2]
                    dst[j + 1] = table[(b0 & 0x03) << 4]
                    j += 2
                } else if remainder == 2 {
                    let b0 = Int(src[i])
                    let b1 = Int(src[i + 1])
                    dst[j] = table[b0 >> 2]
                    dst[j + 1] = table[((b0 & 0x03) << 4) | (b1 >> 4)]
                    dst[j + 2] = table[(b1 & 0x0F) << 2]
                    j += 3
                }
                return j
            }
        }
    }

    static func base64URLEncode(_ data: Data) -> String {
        let encodedLen = base64URLEncodedCount(for: data.count)
        guard encodedLen > 0 else { return "" }
        return String(unsafeUninitializedCapacity: encodedLen) { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return encodeBase64URL(data, into: base)
        }
    }

    static func base64URLDecode(_ value: String) -> Data? {
        if value.isEmpty { return Data() }
        func decodeBytes(_ buf: UnsafeBufferPointer<UInt8>) -> Data? {
            let rawCount = buf.count
            if rawCount == 0 { return Data() }
            var dataLen = rawCount
            while dataLen > 0 && buf[dataLen - 1] == 0x3D { // '='
                dataLen -= 1
            }
            let eqCount = rawCount - dataLen
            let remainder = dataLen % 4
            if remainder == 1 { return nil }
            if eqCount > 0 {
                let expectedPadding = (4 - remainder) % 4
                guard rawCount % 4 == 0, eqCount == expectedPadding else { return nil }
            }
            let fullQuads = dataLen / 4
            let outLen = fullQuads * 3 + (remainder == 0 ? 0 : remainder - 1)
            var out = Data(count: outLen)
            let valid: Bool = out.withUnsafeMutableBytes { outRaw in
                guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress else { return outLen == 0 }
                return base64URLDecodeTable.withUnsafeBufferPointer { tableBuf in
                    guard let dec = tableBuf.baseAddress else { return false }
                    var i = 0
                    var j = 0
                    while i + 4 <= dataLen {
                        let v0 = Int(dec[Int(buf[i])])
                        let v1 = Int(dec[Int(buf[i + 1])])
                        let v2 = Int(dec[Int(buf[i + 2])])
                        let v3 = Int(dec[Int(buf[i + 3])])
                        if (v0 | v1 | v2 | v3) < 0 { return false }
                        dst[j] = UInt8((v0 << 2) | (v1 >> 4))
                        dst[j + 1] = UInt8(((v1 & 0x0F) << 4) | (v2 >> 2))
                        dst[j + 2] = UInt8(((v2 & 0x03) << 6) | v3)
                        i += 4
                        j += 3
                    }
                    if remainder == 2 {
                        let v0 = Int(dec[Int(buf[i])])
                        let v1 = Int(dec[Int(buf[i + 1])])
                        if (v0 | v1) < 0 { return false }
                        dst[j] = UInt8((v0 << 2) | (v1 >> 4))
                    } else if remainder == 3 {
                        let v0 = Int(dec[Int(buf[i])])
                        let v1 = Int(dec[Int(buf[i + 1])])
                        let v2 = Int(dec[Int(buf[i + 2])])
                        if (v0 | v1 | v2) < 0 { return false }
                        dst[j] = UInt8((v0 << 2) | (v1 >> 4))
                        dst[j + 1] = UInt8(((v1 & 0x0F) << 4) | (v2 >> 2))
                    }
                    return true
                }
            }
            return valid ? out : nil
        }

        if let result = value.utf8.withContiguousStorageIfAvailable({ decodeBytes($0) }) {
            return result
        }
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer { decodeBytes($0) }
    }
}
