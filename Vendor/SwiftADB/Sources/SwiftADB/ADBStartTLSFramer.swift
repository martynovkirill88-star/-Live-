import Foundation
import Network
import Security

/// Upgrade the *same TCP connection* after ADB's plaintext CNXN/STLS exchange.
final class ADBStartTLSFramer: NWProtocolFramerImplementation {
    static let label = "Chepushka ADB STLS"
    static let definition = NWProtocolFramer.Definition(implementation: ADBStartTLSFramer.self)
    private final class Configuration: @unchecked Sendable {
        let lock = NSLock()
        var identity: sec_identity_t?
        func set(_ value: sec_identity_t) { lock.lock(); defer { lock.unlock() }; identity=value }
        func get() -> sec_identity_t? { lock.lock(); defer { lock.unlock() }; return identity }
    }
    private static let configuration = Configuration()
    static func configure(identity: sec_identity_t) { configuration.set(identity) }
    private var upgraded=false
    private var payloadLength: Int?
    private var command: UInt32=0
    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.writeOutput(data: AdbProtocol.generateConnect(api:33))
        return .willMarkReady
    }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if upgraded {
            _ = framer.parseInput(minimumIncompleteLength:1, maximumLength:65536) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                framer.deliverInput(data:Data(buffer),message:NWProtocolFramer.Message(definition:Self.definition),isComplete:false)
                return buffer.count
            }
            return 1
        }
        if payloadLength == nil {
            var header: Data?
            _ = framer.parseInput(minimumIncompleteLength:24,maximumLength:24) { buffer, _ in
                guard let buffer, buffer.count>=24 else { return 0 };header=Data(buffer.prefix(24));return 24
            }
            guard let header else { return 24 }
            func number(_ offset:Int)->UInt32 { (0..<4).reduce(UInt32(0)){ $0 | UInt32(header[offset+$1]) << (8*$1) } }
            command=number(0);let length=number(12)
            guard length<=65536, number(20) == ~command else { framer.markFailed(error:.posix(.EPROTO));return 0 }
            payloadLength=Int(length)
        }
        guard let length=payloadLength else { return 1 }
        if length>0 {
            var consumed=false
            _ = framer.parseInput(minimumIncompleteLength:length,maximumLength:length) { buffer, _ in
                guard let buffer,buffer.count>=length else{return 0};consumed=true;return length
            }
            if !consumed{return length}
        }
        guard command==0x534c5453,let identity=Self.configuration.get() else {framer.markFailed(error:.posix(.EACCES));return 0}
        framer.writeOutput(data:AdbProtocol.generateStls())
        let tls=NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions,identity)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{_,_,complete in complete(true)},.global())
        do {try framer.prependApplicationProtocol(options:tls);upgraded=true;framer.markReady()}
        catch {framer.markFailed(error:.posix(.EPROTO))}
        return 0
    }
    func handleOutput(framer: NWProtocolFramer.Instance,message:NWProtocolFramer.Message,messageLength:Int,isComplete:Bool){
        do {try framer.writeOutputNoCopy(length:messageLength)}catch {framer.markFailed(error:.posix(.EIO))}
    }
    func wakeup(framer:NWProtocolFramer.Instance){}
    func stop(framer:NWProtocolFramer.Instance)->Bool{true}
    func cleanup(framer:NWProtocolFramer.Instance){}
}
