// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation
import Security
import BigInt
import SwiftASN1

public struct AndroidPubkey {
    public static let modulusSize = 256
    public static let encodedSize = 3 * 4 + 2 * modulusSize
    public static let modulusSizeWords = modulusSize / 4
    
    public static func adbAuthSign(privateKey: SecKey, payload: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureDigestPKCS1v15SHA1,
            payload as CFData,
            &error
        ) else {
            if let err = error?.takeRetainedValue() {
                throw err
            }
            throw ADBError.signatureFailed
        }
        return signature as Data
    }
    
    public static func encode(publicKey: SecKey) throws -> Data {
        guard let keyRepresentation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw ADBError.invalidKey
        }
        let parsed = try parseRSAPublicKey(keyRepresentation)
        
        var structData = Data()
        structData.reserveCapacity(encodedSize)
        
        // 1. modulus_size_words
        structData.appendLittleEndian(UInt32(modulusSizeWords))
        
        // 2. n0inv
        let modulus = Data(parsed.modulus)
        let len = modulus.count
        let n0 = UInt32(modulus[len - 1]) |
                 (UInt32(modulus[len - 2]) << 8) |
                 (UInt32(modulus[len - 3]) << 16) |
                 (UInt32(modulus[len - 4]) << 24)
        
        let n0Big = BigUInt(n0)
        let mod = BigUInt(1) << 32
        guard let inv = n0Big.inverse(mod) else {
            throw ADBError.invalidKey
        }
        let n0invVal = mod - inv
        let n0inv = UInt32(n0invVal)
        structData.appendLittleEndian(n0inv)
        
        // 3. modulus
        var modulusLE = Data(modulus.reversed())
        if modulusLE.count < modulusSize {
            modulusLE.append(contentsOf: repeatElement(0, count: modulusSize - modulusLE.count))
        } else if modulusLE.count > modulusSize {
            modulusLE = modulusLE.prefix(modulusSize)
        }
        structData.append(modulusLE)
        
        // 4. rr
        let rr = computeRR(modulus: modulus)
        structData.append(rr)
        
        // 5. exponent
        structData.appendLittleEndian(parsed.exponent)
        
        return structData
    }
    
    public static func encodeWithName(publicKey: SecKey, name: String) throws -> Data {
        let structData = try encode(publicKey: publicKey)
        let base64Encoded = structData.base64EncodedData()
        
        var userInfo = Data()
        if let deviceNameData = " \(name)\0".data(using: .utf8) {
            userInfo.append(deviceNameData)
        }
        
        var result = Data()
        result.append(base64Encoded)
        result.append(userInfo)
        return result
    }
    
    public static func encodeWithName(publicKey: SecKey, deviceName: String) throws -> Data {
        return try encodeWithName(publicKey: publicKey, name: deviceName)
    }
    
    public static func decode(androidPubkey: Data) throws -> SecKey {
        guard androidPubkey.count >= encodedSize else {
            throw ADBError.invalidKey
        }
        
        // Parse the header
        let modulusSizeWordsParsed = androidPubkey.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard modulusSizeWordsParsed == modulusSizeWords else {
            throw ADBError.invalidKey
        }
        
        // Parse modulus (starts at offset 8, length 256)
        let modulusLE = androidPubkey.subdata(in: 8..<8+modulusSize)
        let modulusBE = Data(modulusLE.reversed())
        
        // Parse exponent (starts at offset 520, length 4)
        let exponent = androidPubkey.subdata(in: 520..<524).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        
        let secKey = try createRSAPublicKey(modulus: modulusBE, exponent: exponent)
        return secKey
    }
    
    // MARK: - Private Helpers
    
    private static func computeRR(modulus: Data) -> Data {
        let N = BigUInt(modulus)
        let twoTo2048 = BigUInt(1) << 2048
        let rrVal = twoTo2048.power(2, modulus: N)
        var rrBytes = Data(rrVal.serialize().reversed())
        if rrBytes.count < modulusSize {
            rrBytes.append(contentsOf: repeatElement(0, count: modulusSize - rrBytes.count))
        } else if rrBytes.count > modulusSize {
            rrBytes = rrBytes.prefix(modulusSize)
        }
        return rrBytes
    }
    
    private static func parseRSAPublicKey(_ keyData: Data) throws -> (modulus: Data, exponent: UInt32) {
        let bytes = [UInt8](keyData)
        let rootNode = try DER.parse(bytes)
        
        guard rootNode.identifier == .sequence,
              case .constructed(let collection) = rootNode.content else {
            throw ADBError.invalidKey
        }
        
        let nodes = Array(collection)
        guard nodes.count == 2 else {
            throw ADBError.invalidKey
        }
        
        guard nodes[0].identifier == .integer,
              nodes[1].identifier == .integer,
              case .primitive(let modulusBytes) = nodes[0].content,
              case .primitive(let exponentBytes) = nodes[1].content else {
            throw ADBError.invalidKey
        }
        
        var modulusData = Data(modulusBytes)
        if modulusData.first == 0x00 {
            modulusData = modulusData.dropFirst()
        }
        
        var exponent: UInt32 = 0
        for byte in exponentBytes {
            exponent = (exponent << 8) | UInt32(byte)
        }
        
        return (modulusData, exponent)
    }
    
    private static func createRSAPublicKey(modulus: Data, exponent: UInt32) throws -> SecKey {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { sequenceSerializer in
            // Encode modulus as an INTEGER
            var modData = modulus
            if let firstByte = modData.first, firstByte >= 0x80 {
                modData.insert(0x00, at: 0)
            }
            sequenceSerializer.appendPrimitiveNode(identifier: .integer) { bytes in
                bytes.append(contentsOf: modData)
            }
            
            // Encode exponent as an INTEGER
            var expBytes = Data()
            var temp = exponent
            while temp > 0 {
                expBytes.insert(UInt8(temp & 0xff), at: 0)
                temp >>= 8
            }
            if let firstByte = expBytes.first, firstByte >= 0x80 {
                expBytes.insert(0x00, at: 0)
            }
            sequenceSerializer.appendPrimitiveNode(identifier: .integer) { bytes in
                bytes.append(contentsOf: expBytes)
            }
        }
        let derBytes = serializer.serializedBytes
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(derBytes) as CFData, attributes as CFDictionary, &error) else {
            if let err = error?.takeRetainedValue() {
                throw err
            }
            throw ADBError.invalidKey
        }
        return secKey
    }
}
