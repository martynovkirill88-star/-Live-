// ADBPairingConnection.swift
// ADBPairing sub-package — SwiftADB
//
// Implements the ADB wireless pairing connection protocol on top of TLS 1.3.
//
// Protocol (matches PairingConnectionCtx.java):
//   1. TLS handshake (mTLS-style: we present our self-signed cert, accept any cert from server)
//   2. Export 64 bytes of keying material from the TLS session: label = "adb-label\0"
//   3. password = user_password || tls_keying_material
//   4. Send: [header(SPAKE2_MSG)] + SPAKE2 message (32 bytes)
//   5. Receive: [header(SPAKE2_MSG)] + peer SPAKE2 message
//   6. Derive AES-128-GCM key via HKDF
//   7. Send: [header(PEER_INFO)] + AES-GCM( our PeerInfo )
//   8. Receive: [header(PEER_INFO)] + AES-GCM( peer PeerInfo )
//   9. Verify the peer's PeerInfo
//
// NOTE: TLS 1.3 keying material export uses RFC 5705/8446 `exportKeyingMaterial`.
// On Apple platforms this is available via SSLCopyExportedKeyingMaterial (Security.framework).

import Foundation
import Network
import CryptoKit
import Security

// MARK: - Public types

/// ADB pairing result. On success, contains the device's public key (Android RSA pub key).
public struct ADBPairingResult {
    public let devicePublicKey: Data
}

public enum ADBPairingError: Error, LocalizedError {
    case tlsHandshakeFailed(String)
    case keyingMaterialExportFailed
    case spake2Failed(Error)
    case peerInfoDecryptFailed
    case peerInfoInvalid
    case connectionFailed(Error)
    case unexpectedPacketType(UInt8)
    case protocolVersionMismatch

    public var errorDescription: String? {
        switch self {
        case .tlsHandshakeFailed(let r):   return "TLS handshake failed: \(r)"
        case .keyingMaterialExportFailed:  return "TLS keying material export failed"
        case .spake2Failed(let e):         return "SPAKE2 failed: \(e)"
        case .peerInfoDecryptFailed:       return "Failed to decrypt peer info"
        case .peerInfoInvalid:             return "Peer info structure invalid"
        case .connectionFailed(let e):     return "Connection failed: \(e)"
        case .unexpectedPacketType(let t): return "Unexpected packet type \(t)"
        case .protocolVersionMismatch:     return "Protocol version mismatch"
        }
    }
}

// MARK: - Packet header

private struct PairingPacketHeader {
    static let currentVersion: UInt8 = 1
    static let headerSize    = 6
    static let maxPayloadSize = 2 * (1 << 13) // 16 KiB

    static let typeSpake2Msg: UInt8 = 0
    static let typePeerInfo:  UInt8 = 1

    let version:     UInt8
    let type:        UInt8
    let payloadSize: UInt32

    var encoded: Data {
        var d = Data(capacity: Self.headerSize)
        d.append(version)
        d.append(type)
        var be = payloadSize.bigEndian
        d.append(contentsOf: withUnsafeBytes(of: &be, Array.init))
        return d
    }

    static func decode(_ data: Data) -> PairingPacketHeader? {
        guard data.count >= headerSize else { return nil }
        let version = data[data.startIndex]
        let type    = data[data.startIndex + 1]
        let payload = UInt32(bigEndian: data.subdata(in: (data.startIndex+2)..<(data.startIndex+6))
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        guard version >= 1 && version <= currentVersion else { return nil }
        guard type == typeSpake2Msg || type == typePeerInfo else { return nil }
        guard payload > 0 && payload <= maxPayloadSize else { return nil }
        return PairingPacketHeader(version: version, type: type, payloadSize: payload)
    }
}

// MARK: - PeerInfo

private struct PeerInfo {
    static let maxSize = 1 << 13  // 8192 bytes
    static let typeRSAPublicKey: UInt8 = 0

    let type: UInt8
    var data: Data   // maxSize - 1 bytes

    var encoded: Data {
        var d = Data(count: Self.maxSize)
        d[0] = type
        let len = min(data.count, Self.maxSize - 1)
        d.replaceSubrange(1..<(1+len), with: data.prefix(len))
        return d
    }

    /// The device public key bytes (null-terminated or raw, depending on ADB server).
    var publicKeyBytes: Data { data }

    static func decode(_ raw: Data) -> PeerInfo? {
        guard raw.count == maxSize else { return nil }
        let type = raw[raw.startIndex]
        let data = raw.subdata(in: (raw.startIndex + 1)..<raw.endIndex)
        return PeerInfo(type: type, data: data)
    }
}

// MARK: - ADBPairingConnection

/// Performs the full ADB wireless pairing handshake over TLS.
///
/// Usage:
/// ```swift
/// let conn = ADBPairingConnection(host: "192.168.1.5", port: 37145, password: "123456",
///                                  keyPair: myKeyPair, deviceName: "MacBook")
/// let result = try await conn.pair()
/// print("Paired! Device pubkey: \(result.devicePublicKey.base64EncodedString())")
/// ```
public final class ADBPairingConnection {

    public static let exportedKeyLabel = "adb-label\0"
    public static let exportKeySize    = 64

    private let host:       String
    private let port:       UInt16
    private let password:   [UInt8]
    private let keyPair:    ADBKeyPair
    private let deviceName: String

    /// - Parameters:
    ///   - host:       IP address or hostname of the Android device.
    ///   - port:       Pairing port (shown in the device's QR/six-digit code dialog).
    ///   - password:   Six-digit numeric pairing code as UTF-8 bytes.
    ///   - keyPair:    Our RSA key pair for authentication.
    ///   - deviceName: A human-readable name for this client.
    public init(host: String, port: UInt16, password: String,
                keyPair: ADBKeyPair, deviceName: String) {
        self.host       = host
        self.port       = port
        self.password   = Array(password.utf8)
        self.keyPair    = keyPair
        self.deviceName = deviceName
    }

    // MARK: - pair()

    /// Execute the pairing handshake. Throws on any failure.
    public func pair() async throws -> ADBPairingResult {
        // 1. Establish TLS 1.3 connection
        let (conn, keyingMaterial) = try await connectTLS()

        // 2. password = user_password || tls_keying_material
        let fullPassword = password + keyingMaterial

        // 3. Create SPAKE2/HKDF auth context
        let authCtx = try PairingAuthCtx.createAlice(password: fullPassword)

        // 4. Exchange SPAKE2 messages
        let ourMsg = authCtx.msg
        try await sendPacket(conn: conn, type: PairingPacketHeader.typeSpake2Msg, payload: Data(ourMsg))
        let theirMsgData = try await recvPacket(conn: conn, expectedType: PairingPacketHeader.typeSpake2Msg)
        try authCtx.initCipher(peerMsg: Array(theirMsgData))

        // 5. Build and encrypt our PeerInfo (type 0 = RSA public key)
        let pubKeyBytes = try keyPair.encodedPublicKey(deviceName: deviceName)
        let ourPeerInfo = PeerInfo(type: PeerInfo.typeRSAPublicKey, data: pubKeyBytes)
        let encryptedPeerInfo = try authCtx.encrypt(Array(ourPeerInfo.encoded))

        // 6. Exchange PeerInfo
        try await sendPacket(conn: conn, type: PairingPacketHeader.typePeerInfo, payload: Data(encryptedPeerInfo))
        let theirEncPeerInfo = try await recvPacket(conn: conn, expectedType: PairingPacketHeader.typePeerInfo)
        let theirPeerInfoBytes = try authCtx.decrypt(Array(theirEncPeerInfo))

        // 7. Parse and return the peer's public key
        guard let peerInfo = PeerInfo.decode(Data(theirPeerInfoBytes)) else {
            throw ADBPairingError.peerInfoInvalid
        }

        conn.cancel()
        return ADBPairingResult(devicePublicKey: peerInfo.publicKeyBytes)
    }

    // MARK: - TLS connection

    private func connectTLS() async throws -> (NWConnection, [UInt8]) {
        // Build a TLS config that:
        //  - presents our identity (self-signed cert)
        //  - accepts any server cert (ADB doesn't verify chains)
        let tlsOptions = NWProtocolTLS.Options()

        // Set our identity
        if let identity = try? keyPair.secIdentity() {
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        }

        // Accept any server cert (ADB uses self-signed certs)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completion in
            completion(true)
        }, .main)

        // Minimum TLS 1.3
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())

        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)

        // Wait for connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let e):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: ADBPairingError.connectionFailed(e))
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }

        // Export TLS keying material
        // On Apple platforms: sec_protocol_metadata_access_peer_certificate_chain provides the session
        // but exportKeyingMaterial is only available via SSLCopyExportedKeyingMaterial (deprecated) or
        // the newer sec_protocol_metadata_copy_negotiated_protocol on iOS 12+.
        //
        // The cleanest cross-platform approach: extract via the underlying SSLContext.
        // We use the callback-based API to access the metadata synchronously.
        let keyMat = try await exportKeyingMaterial(conn: conn)
        return (conn, keyMat)
    }

    private func exportKeyingMaterial(conn: NWConnection) async throws -> [UInt8] {
        guard let secMetadata = (conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?.securityProtocolMetadata else {
            throw ADBPairingError.keyingMaterialExportFailed
        }

        let label = Self.exportedKeyLabel
        let labelBytes = [UInt8](label.utf8)

        guard let data = labelBytes.withUnsafeBytes({ ptr in
            sec_protocol_metadata_create_secret(
                secMetadata,
                labelBytes.count,
                ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                Self.exportKeySize
            )
        }) else {
            throw ADBPairingError.keyingMaterialExportFailed
        }

        let dd = data as DispatchData
        let count = dd.count
        return dd.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> [UInt8] in
            Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }

    // MARK: - Packet I/O

    private func sendPacket(conn: NWConnection, type: UInt8, payload: Data) async throws {
        let header = PairingPacketHeader(version: PairingPacketHeader.currentVersion,
                                         type: type,
                                         payloadSize: UInt32(payload.count))
        var frame = header.encoded
        frame.append(payload)
        try await send(conn: conn, data: frame)
    }

    private func recvPacket(conn: NWConnection, expectedType: UInt8) async throws -> Data {
        let headerData = try await recv(conn: conn, length: PairingPacketHeader.headerSize)
        guard let header = PairingPacketHeader.decode(headerData) else {
            throw ADBPairingError.protocolVersionMismatch
        }
        guard header.type == expectedType else {
            throw ADBPairingError.unexpectedPacketType(header.type)
        }
        return try await recv(conn: conn, length: Int(header.payloadSize))
    }

    // MARK: - Raw I/O

    private func send(conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { cont.resume(throwing: e) }
                else { cont.resume() }
            })
        }
    }

    private func recv(conn: NWConnection, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let e = error { cont.resume(throwing: e); return }
                guard let d = data, d.count == length else {
                    cont.resume(throwing: ADBPairingError.connectionFailed(
                        NSError(domain: "ADBPairing", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Short read"])
                    ))
                    return
                }
                cont.resume(returning: d)
            }
        }
    }
}
