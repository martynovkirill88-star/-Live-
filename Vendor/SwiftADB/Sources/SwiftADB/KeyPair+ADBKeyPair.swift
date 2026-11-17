// KeyPair+ADBKeyPair.swift
// SwiftADB — extends KeyPair to conform to ADBKeyPair so it can be used with ADBPairing.

import Foundation
import Security
import ADBPairing

extension KeyPair: ADBKeyPair {
    // MARK: - secIdentity

    public func secIdentity() throws -> sec_identity_t {
        guard let cert = certificate else {
            throw NSError(domain: "KeyPair", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "KeyPair has no certificate — generate one with KeyPair.generateWithCertificate()"])
        }
        guard let identity = try? adbKeychainIdentity(key: privateKey, certificate: cert) else {
            throw NSError(domain: "KeyPair", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not create SecIdentity"])
        }
        return sec_identity_create(identity)!
    }

    // MARK: - encodedPublicKey

    public func encodedPublicKey(deviceName: String) throws -> Data {
        let raw = try AndroidPubkey.encode(publicKey: publicKey)
        let b64 = raw.base64EncodedString()
        let formatted = b64 + " " + deviceName + "\0"
        return Data(formatted.utf8)
    }
}


func adbKeychainIdentity(key: SecKey, certificate: SecCertificate) throws -> SecIdentity {
    let certData = SecCertificateCopyData(certificate) as Data
    var result: CFTypeRef?
    _ = SecItemAdd([kSecClass:kSecClassKey,kSecValueRef:key,kSecAttrApplicationTag:Data("fun.chepushkavpn.live.tv-adb".utf8),kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil)
    _ = SecItemAdd([kSecClass:kSecClassCertificate,kSecValueRef:certificate] as CFDictionary,nil)
    let status = SecItemCopyMatching([kSecClass:kSecClassIdentity,kSecReturnRef:true,kSecMatchLimit:kSecMatchLimitAll] as CFDictionary,&result)
    if status == errSecSuccess, let identities = result as? [SecIdentity] {
        for identity in identities {
            var current: SecCertificate?
            if SecIdentityCopyCertificate(identity,&current)==errSecSuccess, let current,
               (SecCertificateCopyData(current) as Data)==certData { return identity }
        }
    }
    throw NSError(domain:"TVSetup",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось подготовить ключ сопряжения."])
}
