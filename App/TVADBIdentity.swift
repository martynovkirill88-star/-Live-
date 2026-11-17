import Foundation
import Security
import SwiftADB

/// A private, device-only keychain identity; never exported to the web page or server.
enum TVADBIdentity {
    private struct Stored: Codable { let key: Data; let certificate: Data }
    static func load() throws -> KeyPair {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"fun.chepushkavpn.live.tv-setup",kSecAttrAccount as String:"adb-key",kSecReturnData as String:true]
        var item:CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let data=item as? Data {
            let stored=try JSONDecoder().decode(Stored.self,from:data)
            guard let key=SecKeyCreateWithData(stored.key as CFData,[kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPrivate] as CFDictionary,nil),let certificate=SecCertificateCreateWithData(nil,stored.certificate as CFData) else{throw failure()}
            return KeyPair(privateKey:key,certificate:certificate)
        }
        let pair=try KeyPair.generate()
        guard let raw=SecKeyCopyExternalRepresentation(pair.privateKey,nil) as Data? else{throw failure()}
        let cert=try certificate(key:pair.privateKey,publicKey:pair.publicKey)
        let data=try JSONEncoder().encode(Stored(key:raw,certificate:cert))
        let status=SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrService:"fun.chepushkavpn.live.tv-setup",kSecAttrAccount:"adb-key",kSecValueData:data,kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil)
        guard status==errSecSuccess,let certificate=SecCertificateCreateWithData(nil,cert as CFData) else{throw failure()}
        return KeyPair(privateKey:pair.privateKey,certificate:certificate)
    }
    private static func failure()->NSError{NSError(domain:"TVSetup",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось сохранить ключ подключения к ТВ."])}
    private static func der(_ tag:UInt8,_ data:Data)->Data{
        let count=data.count
        var bytes=Data([tag])
        if count<128{bytes.append(UInt8(count))}else{var n=count;var varBytes=[UInt8]();while n>0{varBytes.insert(UInt8(n&255),at:0);n >>= 8};bytes.append(0x80|UInt8(varBytes.count));bytes.append(contentsOf:varBytes)}
        bytes.append(data);return bytes
    }
    private static func sequence(_ values:Data...)->Data{der(0x30,values.reduce(Data(),+))}
    private static func certificate(key:SecKey,publicKey:SecKey)throws->Data{
        let algorithm=sequence(der(6,Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,0x0b])),der(5,Data()))
        let rsa=sequence(der(6,Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1])),der(5,Data()))
        let name=sequence(der(0x31,sequence(der(6,Data([0x55,4,3])),der(0x0c,Data("Chepushka Live TV Setup".utf8)))))
        guard let publicBytes=SecKeyCopyExternalRepresentation(publicKey,nil) as Data? else{throw failure()}
        let spki=sequence(rsa,der(3,Data([0])+publicBytes))
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyyMMddHHmmss'Z'"
        let validity=sequence(der(0x18,Data(formatter.string(from:Date().addingTimeInterval(-86400)).utf8)),der(0x18,Data(formatter.string(from:Date().addingTimeInterval(10*365*86400)).utf8)))
        var serial=Data(count:16);let randomStatus=serial.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!)};guard randomStatus==errSecSuccess else{throw failure()};serial[0] &= 0x7f;while serial.count>1 && serial[0]==0 && serial[1]&0x80==0 {serial.removeFirst()}
        let tbs=sequence(der(0xa0,der(2,Data([2]))),der(2,serial),algorithm,name,validity,name,spki)
        var error:Unmanaged<CFError>?
        guard let signature=SecKeyCreateSignature(key,.rsaSignatureMessagePKCS1v15SHA256,tbs as CFData,&error) as Data? else{if let error { throw error.takeRetainedValue() }; throw failure()}
        return sequence(tbs,algorithm,der(3,Data([0])+signature))
    }
}
