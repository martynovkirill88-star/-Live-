import Testing
import Foundation
import Network
@testable import SwiftADB

@Suite("SwiftADB Tests")
struct SwiftADBTests {

    @Test("TLS handshake failure maps to pairingRequired (ported from libadb d88ca78)")
    func testTlsHandshakeMapsToPairingRequired() {
        // A TLS-layer failure during STLS upgrade means the device requires pairing.
        let tlsError = NWError.tls(OSStatus(-9800)) // errSSLProtocol
        let mapped = AdbConnection.mapTlsHandshakeError(tlsError)
        if case ADBError.pairingRequired = mapped {
            // expected
        } else {
            Issue.record("TLS error should map to ADBError.pairingRequired, got \(mapped)")
        }

        // Non-TLS errors must pass through unchanged.
        let posix = NWError.posix(.ECONNREFUSED)
        let passthrough = AdbConnection.mapTlsHandshakeError(posix)
        #expect(passthrough is NWError, "Non-TLS errors must not be remapped")
    }

    @Test("KeyPair Generation and Signature")
    func testKeyPairAndSignature() throws {
        let keyPair = try KeyPair.generate()
        let token = Data(repeating: 0x42, count: 20)
        let signature = try keyPair.sign(token: token)

        #expect(signature.count == 256) // 2048-bit signature is 256 bytes
    }

    @Test("AndroidPubkey Encoding and N0Inv Correctness")
    func testAndroidPubkeyEncoding() throws {
        let keyPair = try KeyPair.generate()
        let encoded = try AndroidPubkey.encode(publicKey: keyPair.publicKey)

        #expect(encoded.count == 524)

        // Verify modulus_size_words is 64
        let modulusSizeWords = encoded.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        #expect(modulusSizeWords == 64)

        // Verify n0inv: (n0 * n0inv) mod 2^32 == 0xFFFFFFFF
        let n0inv = encoded.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

        // modulus starts at byte 8 and is 256 bytes
        let modulusBytes = encoded.subdata(in: 8..<264)
        let idx = modulusBytes.startIndex
        let n0_0 = UInt32(modulusBytes[idx])
        let n0_1 = UInt32(modulusBytes[idx + 1]) << 8
        let n0_2 = UInt32(modulusBytes[idx + 2]) << 16
        let n0_3 = UInt32(modulusBytes[idx + 3]) << 24
        let n0 = n0_0 | n0_1 | n0_2 | n0_3

        let product = n0 &* n0inv
        #expect(product == 0xFFFFFFFF)

        // Verify encodeWithName works
        let encodedWithName = try AndroidPubkey.encodeWithName(publicKey: keyPair.publicKey, name: "test-device")
        let base64Length = 4 * Int(ceil(524.0 / 3.0)) // 700 bytes
        #expect(encodedWithName.count >= base64Length + 13) // base64 + " " + "test-device" + "\0"
    }

    @Test("AdbProtocol Packet Serialization and Parsing")
    func testAdbProtocol() throws {
        let api = 28 // Android 9+
        let connectMessageData = AdbProtocol.generateConnect(api: api)

        // Check connect message header size is 24, plus payload "host::\0" (7 bytes)
        #expect(connectMessageData.count == 24 + 7)

        // Parse message
        let result = try AdbProtocol.Message.parse(
            from: connectMessageData,
            protocolVersion: AdbProtocol.getProtocolVersion(api: api),
            maxData: AdbProtocol.getMaxData(api: api)
        )

        #expect(result != nil)
        let parsed = result!.message
        #expect(parsed.command == AdbProtocol.aCnxn)
        #expect(parsed.arg0 == AdbProtocol.aVersionSkipChecksum)
        #expect(parsed.arg1 == AdbProtocol.maxPayloadV3)
        #expect(parsed.dataLength == 7)
        #expect(parsed.payload == AdbProtocol.systemIdentityStringHost)
        #expect(result!.bytesConsumed == 24 + 7)
    }
}
