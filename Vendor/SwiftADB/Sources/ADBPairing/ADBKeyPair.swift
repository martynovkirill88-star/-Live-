// ADBKeyPair.swift
// ADBPairing sub-package — SwiftADB
//
// Protocol that the ADB pairing layer needs from a key pair.
// SwiftADB's main KeyPair type can be extended to conform.

import Foundation
import Security

/// The key-pair interface needed by the ADB wireless pairing layer.
/// Your key pair must supply:
///   - A SecIdentity (private key + certificate) for TLS client auth
///   - The encoded Android RSA public key string (base64 + user@host suffix)
public protocol ADBKeyPair: Sendable {
    /// Returns an `sec_identity_t` for presenting our client certificate during TLS.
    func secIdentity() throws -> sec_identity_t

    /// Returns the ADB-formatted public key for inclusion in PeerInfo.
    /// Format: base64(AndroidPubkey) + " " + deviceName + "\0"
    func encodedPublicKey(deviceName: String) throws -> Data
}
