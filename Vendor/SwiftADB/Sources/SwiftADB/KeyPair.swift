// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation
import Security

/// A helper class to hold RSA public and private keys,
/// generate new 2048-bit RSA key pairs, and sign AUTH challenge tokens.
public final class KeyPair: @unchecked Sendable {
    public let privateKey: SecKey
    public let publicKey: SecKey
    public let certificate: SecCertificate?

    /// Initializes a KeyPair with existing SecKey private and public keys.
    public init(privateKey: SecKey, publicKey: SecKey, certificate: SecCertificate? = nil) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.certificate = certificate
    }

    /// Initializes a KeyPair with a private key and a certificate.
    public init(privateKey: SecKey, certificate: SecCertificate) {
        self.privateKey = privateKey
        self.certificate = certificate
        self.publicKey = SecCertificateCopyKey(certificate)!
    }

    /// Generates a new 2048-bit RSA key pair.
    public static func generate() throws -> KeyPair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let err = error?.takeRetainedValue() {
                throw err
            }
            throw NSError(domain: "KeyPair", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate RSA key pair"])
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "KeyPair", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get public key from private key"])
        }

        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    /// Signs the 20-byte AUTH challenge token using the private key.
    /// This uses RSA signature with PKCS#1 v1.5 padding and SHA-1 OID prepended.
    public func sign(token: Data) throws -> Data {
        guard token.count == 20 else {
            throw NSError(domain: "KeyPair", code: 3, userInfo: [NSLocalizedDescriptionKey: "AUTH token must be exactly 20 bytes"])
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            &error
        ) as Data? else {
            if let err = error?.takeRetainedValue() {
                throw err
            }
            throw NSError(domain: "KeyPair", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to sign AUTH token"])
        }

        return signature
    }
}
