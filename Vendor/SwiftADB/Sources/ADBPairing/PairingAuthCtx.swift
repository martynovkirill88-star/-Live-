// PairingAuthCtx.swift
// ADBPairing sub-package — SwiftADB
//
// Swift port of io.github.muntashirakon.adb.PairingAuthCtx
//
// Orchestrates SPAKE2 + HKDF-SHA256 + AES-128-GCM for ADB wireless pairing.
// Wire-compatible with Android's pairing_auth.cpp / BoringSSL implementation.

import CryptoKit
import Foundation

// MARK: - Constants

private let clientName: [UInt8] = Array("adb pair client\0".utf8)
private let serverName: [UInt8] = Array("adb pair server\0".utf8)
/// HKDF info string — matches pairing_auth.cpp
private let hkdfInfo:   [UInt8] = Array("adb pairing_auth aes-128-gcm key".utf8)
private let hkdfKeyLen = 16   // 128-bit AES key

// MARK: - PairingAuthCtx

/// Manages SPAKE2 + HKDF + AES-GCM for a single ADB wireless pairing session.
public final class PairingAuthCtx {
    public static let gcmIVLength = 12

    private let spake2: SPAKE2Context
    private let myMsg: [UInt8]
    private var secretKey: SymmetricKey?
    private var encIV: UInt64 = 0
    private var decIV: UInt64 = 0

    // MARK: - Factory

    /// Create an Alice (client) context.
    public static func createAlice(password: [UInt8]) throws -> PairingAuthCtx {
        let ctx = SPAKE2Context(role: .alice, myName: clientName, theirName: serverName)
        return try PairingAuthCtx(spake2: ctx, password: password)
    }

    /// Create a Bob (server) context — mainly used for testing.
    public static func createBob(password: [UInt8]) throws -> PairingAuthCtx {
        let ctx = SPAKE2Context(role: .bob, myName: serverName, theirName: clientName)
        return try PairingAuthCtx(spake2: ctx, password: password)
    }

    private init(spake2: SPAKE2Context, password: [UInt8]) throws {
        self.spake2 = spake2
        self.myMsg  = try spake2.generateMessage(password: password)
    }

    // MARK: - Public API

    /// The 32-byte SPAKE2 message to send to the peer.
    public var msg: [UInt8] { myMsg }

    /// Process the peer's SPAKE2 message and derive the shared AES-128-GCM key.
    /// Must be called before encrypt/decrypt.
    /// - Returns: true on success.
    @discardableResult
    public func initCipher(peerMsg: [UInt8]) throws -> Bool {
        let keyMaterial = try spake2.processMessage(peerMsg)
        // HKDF-SHA256 with no salt, info = "adb pairing_auth aes-128-gcm key"
        // Note: salt=nil is equivalent to a zero-filled salt of hash length (RFC 5869 §2.2)
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            salt: Data()    // DataProtocol — empty = zero-filled hash-length salt
        )
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                      info: Data(hkdfInfo),
                                      outputByteCount: hkdfKeyLen)
        secretKey = okm
        return true
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt `data` with AES-128-GCM using the current enc IV (auto-incremented).
    public func encrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard let key = secretKey else {
            throw PairingAuthError.cipherNotInitialized
        }
        let iv = makeIV(encIV); encIV += 1
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(Data(data), using: key, nonce: nonce)
        // Output: ciphertext || tag (16 bytes)
        return Array(sealed.ciphertext) + Array(sealed.tag)
    }

    /// Decrypt `data` with AES-128-GCM using the current dec IV (auto-incremented).
    public func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard let key = secretKey else {
            throw PairingAuthError.cipherNotInitialized
        }
        let iv = makeIV(decIV); decIV += 1
        guard data.count >= 16 else { throw PairingAuthError.decryptionFailed }
        let tag = Data(data.suffix(16))
        let ct  = Data(data.dropLast(16))
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let plain = try AES.GCM.open(box, using: key)
        return Array(plain)
    }

    // MARK: - Helpers

    /// Build a 12-byte IV from a little-endian UInt64 counter (padded with zeros).
    private func makeIV(_ counter: UInt64) -> Data {
        var iv = Data(repeating: 0, count: Self.gcmIVLength)
        var le = counter.littleEndian
        withUnsafeBytes(of: &le) { src in
            iv.replaceSubrange(0..<8, with: src)
        }
        return iv
    }
}

// MARK: - Errors

public enum PairingAuthError: Error, LocalizedError {
    case cipherNotInitialized
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .cipherNotInitialized: return "PairingAuth: initCipher must be called before encrypt/decrypt"
        case .decryptionFailed:     return "PairingAuth: AES-GCM decryption failed (authentication tag mismatch)"
        }
    }
}
