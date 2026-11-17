// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation
import Network

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) {
            self.append(contentsOf: $0)
        }
    }
}

public enum AdbCommand: UInt32, Sendable {
    case sync = 0x434e5953
    case cnxn = 0x4e584e43
    case auth = 0x48545541
    case open = 0x4e45504f
    case okay = 0x59414b4f
    case clse = 0x45534c43
    case wrte = 0x45545257
    case stls = 0x534c5453
}

public struct AdbProtocol {
    public static let headerLength = 24
    
    public static let aSync: UInt32 = 0x434e5953
    public static let aCnxn: UInt32 = 0x4e584e43
    public static let aAuth: UInt32 = 0x48545541
    public static let aOpen: UInt32 = 0x4e45504f
    public static let aOkay: UInt32 = 0x59414b4f
    public static let aClse: UInt32 = 0x45534c43
    public static let aWrte: UInt32 = 0x45545257
    public static let aStls: UInt32 = 0x534c5453

    public static let systemIdentityStringHost = "host::\0".data(using: .utf8)!
    
    public static let maxPayloadV1: UInt32 = 4 * 1024
    public static let maxPayloadV2: UInt32 = 256 * 1024
    public static let maxPayloadV3: UInt32 = 1024 * 1024
    public static let maxPayload = maxPayloadV1
    
    public static let aVersionMin: UInt32 = 0x01000000
    public static let aVersionSkipChecksum: UInt32 = 0x01000001
    public static let aVersion = aVersionMin
    
    public static let aStlsVersionMin: UInt32 = 0x01000000
    public static let aStlsVersion = aStlsVersionMin
    
    public static let adbAuthToken = 1
    public static let adbAuthSignature = 2
    public static let adbAuthRsaPublicKey = 3
    
    public static func getMaxData(api: Int) -> UInt32 {
        if api >= 28 { // Android 9 (P)
            return maxPayloadV3
        }
        if api >= 24 { // Android 7 (N)
            return maxPayloadV2
        }
        return maxPayloadV1
    }
    
    public static func getProtocolVersion(api: Int) -> UInt32 {
        if api >= 28 { // Android 9 (P)
            return aVersionSkipChecksum
        }
        return aVersionMin
    }
    
    public static func getPayloadChecksum(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0
        for byte in data {
            checksum += UInt32(byte)
        }
        return checksum
    }
    
    public static func getPayloadChecksum(data: Data, offset: Int, length: Int) -> UInt32 {
        var checksum: UInt32 = 0
        let end = offset + length
        for i in offset..<end {
            checksum += UInt32(data[data.startIndex + i])
        }
        return checksum
    }
    
    public static func generateMessage(command: UInt32, arg0: UInt32, arg1: UInt32, data: Data?) -> Data {
        var message = Data()
        message.reserveCapacity(headerLength + (data?.count ?? 0))
        message.appendLittleEndian(command)
        message.appendLittleEndian(arg0)
        message.appendLittleEndian(arg1)
        if let data = data, !data.isEmpty {
            message.appendLittleEndian(UInt32(data.count))
            message.appendLittleEndian(getPayloadChecksum(data))
        } else {
            message.appendLittleEndian(0)
            message.appendLittleEndian(0)
        }
        message.appendLittleEndian(~command)
        if let data = data, !data.isEmpty {
            message.append(data)
        }
        return message
    }
    
    public static func generateConnect(api: Int) -> Data {
        return generateMessage(
            command: aCnxn,
            arg0: getProtocolVersion(api: api),
            arg1: getMaxData(api: api),
            data: systemIdentityStringHost
        )
    }
    
    public static func generateAuth(type: Int, data: Data) -> Data {
        return generateMessage(
            command: aAuth,
            arg0: UInt32(type),
            arg1: 0,
            data: data
        )
    }
    
    public static func generateStls() -> Data {
        return generateMessage(
            command: aStls,
            arg0: aStlsVersion,
            arg1: 0,
            data: nil
        )
    }
    
    public static func generateOpen(localId: UInt32, destination: String) -> Data {
        var destData = destination.data(using: .utf8) ?? Data()
        destData.append(0) // Null terminator
        return generateMessage(
            command: aOpen,
            arg0: localId,
            arg1: 0,
            data: destData
        )
    }
    
    public static func generateWrite(localId: UInt32, remoteId: UInt32, data: Data) -> Data {
        return generateMessage(
            command: aWrte,
            arg0: localId,
            arg1: remoteId,
            data: data
        )
    }
    
    public static func generateClose(localId: UInt32, remoteId: UInt32) -> Data {
        return generateMessage(
            command: aClse,
            arg0: localId,
            arg1: remoteId,
            data: nil
        )
    }
    
    public static func generateReady(localId: UInt32, remoteId: UInt32) -> Data {
        return generateMessage(
            command: aOkay,
            arg0: localId,
            arg1: remoteId,
            data: nil
        )
    }
    
    public struct Message: Sendable {
        public let command: UInt32
        public let arg0: UInt32
        public let arg1: UInt32
        public let dataLength: UInt32
        public let dataCheck: UInt32
        public let magic: UInt32
        public var payload: Data?
        
        public init(command: UInt32, arg0: UInt32, arg1: UInt32, dataLength: UInt32, dataCheck: UInt32, magic: UInt32, payload: Data? = nil) {
            self.command = command
            self.arg0 = arg0
            self.arg1 = arg1
            self.dataLength = dataLength
            self.dataCheck = dataCheck
            self.magic = magic
            self.payload = payload
        }
        
        public static func parse(
            from data: Data,
            protocolVersion: UInt32,
            maxData: UInt32
        ) throws -> (message: Message, bytesConsumed: Int)? {
            guard data.count >= 24 else {
                return nil
            }

            let command = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let arg0 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
            let arg1 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).littleEndian }
            let dataLength = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
            let dataCheck = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }
            let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self).littleEndian }

            // Validate header
            guard command == ~magic else {
                throw ADBError.invalidHeader("Invalid magic 0x\(String(magic, radix: 16))")
            }

            let validCommands = [aSync, aCnxn, aOpen, aOkay, aClse, aWrte, aAuth, aStls]
            guard validCommands.contains(command) else {
                throw ADBError.invalidHeader("Invalid command 0x\(String(command, radix: 16))")
            }

            guard dataLength <= maxData else {
                throw ADBError.invalidHeader("Invalid data length \(dataLength)")
            }

            let totalNeeded = 24 + Int(dataLength)
            guard data.count >= totalNeeded else {
                return nil
            }

            var payload: Data? = nil
            if dataLength > 0 {
                let start = data.index(data.startIndex, offsetBy: 24)
                let end = data.index(start, offsetBy: Int(dataLength))
                payload = data[start..<end]

                // Verify checksum if required by protocol version
                if protocolVersion <= aVersionMin || (command == aCnxn && arg0 <= aVersionMin) {
                    let check = getPayloadChecksum(data: payload!, offset: 0, length: Int(dataLength))
                    guard check == dataCheck else {
                        throw ADBError.checksumMismatch
                    }
                }
            }

            let message = Message(command: command, arg0: arg0, arg1: arg1, dataLength: dataLength, dataCheck: dataCheck, magic: magic, payload: payload)
            return (message, totalNeeded)
        }
    }
    
    public static func parse(connection: NWConnection, protocolVersion: UInt32, maxData: UInt32) async throws -> Message {
        let headerData = try await connection.readExactly(count: headerLength)
        
        let command = headerData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let arg0 = headerData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let arg1 = headerData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let dataLength = headerData.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let dataCheck = headerData.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let magic = headerData.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        
        guard command == ~magic else {
            throw ADBError.invalidHeader("Invalid magic 0x\(String(magic, radix: 16))")
        }
        
        let validCommands = [aSync, aCnxn, aOpen, aOkay, aClse, aWrte, aAuth, aStls]
        guard validCommands.contains(command) else {
            throw ADBError.invalidHeader("Invalid command 0x\(String(command, radix: 16))")
        }
        
        guard dataLength <= maxData else {
            throw ADBError.invalidHeader("Invalid data length \(dataLength)")
        }
        
        var message = Message(
            command: command,
            arg0: arg0,
            arg1: arg1,
            dataLength: dataLength,
            dataCheck: dataCheck,
            magic: magic
        )
        
        if dataLength > 0 {
            let payload = try await connection.readExactly(count: Int(dataLength))
            
            // Verify checksum
            if (protocolVersion <= aVersionMin || (command == aCnxn && arg0 <= aVersionMin)) {
                if getPayloadChecksum(payload) != dataCheck {
                    throw ADBError.checksumMismatch
                }
            }
            message.payload = payload
        }
        
        return message
    }
}

public typealias AdbMessage = AdbProtocol.Message
