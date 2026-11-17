// SPDX-License-Identifier: BSD-3-Clause AND (GPL-3.0-or-later OR Apache-2.0)

import Foundation
import Network
import Security

public actor AdbConnection {
    private let host: String
    private let port: UInt16
    private let api: Int
    private let keyPair: KeyPair
    private var deviceName: String = "Unknown Device"
    
    private var connection: NWConnection?
    private var connectionEstablished = false
    private var connectAttempted = false
    private var sentSignature = false
    private var abortOnUnauthorised = false
    private var authorisationFailed = false
    private var connectionException: Error?
    
    private var maxData: UInt32
    private var protocolVersion: UInt32
    private var lastLocalId: UInt32 = 0
    private var openedStreams: [UInt32: AdbStream] = [:]
    
    private var isTls = false
    
    private var connectionContinuation: CheckedContinuation<Bool, Error>?
    private var readLoopTask: Task<Void, Never>?
    
    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 5555,
        keyPair: KeyPair,
        api: Int = 1,
        deviceName: String = "Unknown Device"
    ) {
        self.host = host
        self.port = port
        self.keyPair = keyPair
        self.api = api
        self.deviceName = deviceName
        self.protocolVersion = AdbProtocol.getProtocolVersion(api: api)
        self.maxData = AdbProtocol.getMaxData(api: api)
    }
    
    public func setDeviceName(_ deviceName: String) {
        self.deviceName = deviceName
    }
    
    public func getProtocolVersion() -> UInt32 {
        return protocolVersion
    }
    
    public func getMaxData() -> UInt32 {
        return maxData
    }
    
    public func isConnectionEstablished() -> Bool {
        return connectionEstablished
    }
    
    public func isConnected() -> Bool {
        if let conn = connection {
            return conn.state == .ready
        }
        return false
    }
    
    public func connect(timeout: TimeInterval = 30, throwOnUnauthorised: Bool = false, useTls: Bool = false) async throws -> Bool {
        if connectionEstablished {
            throw ADBError.alreadyConnected
        }
        
        connectAttempted = true
        abortOnUnauthorised = throwOnUnauthorised
        authorisationFailed = false
        sentSignature = false
        isTls = useTls
        
        let hostNW = NWEndpoint.Host(host)
        let portNW = NWEndpoint.Port(rawValue: port)!
        
        let parameters: NWParameters
        if useTls {
            guard let identity = getSecIdentity() else { throw ADBError.authenticationFailed }
            ADBStartTLSFramer.configure(identity: identity)
            parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: ADBStartTLSFramer.definition),at:0)
        } else {
            parameters = NWParameters.tcp
        }
        
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        
        let conn = NWConnection(host: hostNW, port: portNW, using: parameters)
        self.connection = conn
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    continuation.resume(throwing: ADBError.connectionClosed)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
        
        conn.stateUpdateHandler = nil
        
        // Send CONNECT
        let connectPacket = AdbProtocol.generateConnect(api: api)
        if !useTls { try await sendPacket(connectPacket) }
        
        // Start the connection thread to respond to the peer
        startReadLoop()
        
        return try await withCheckedThrowingContinuation { continuation in
            self.connectionContinuation = continuation
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.handleTimeout()
            }
        }
    }
    
    public func open(service: LocalServices, args: [String]) async throws -> AdbStream {
        let destination = try service.getDestination(args: args)
        return try await open(destination: destination)
    }
    
    public func open(destination: String) async throws -> AdbStream {
        if !connectAttempted {
            throw ADBError.notConnected
        }
        
        if !connectionEstablished {
            throw ADBError.connectionFailed("Connection not yet established")
        }
        
        lastLocalId += 1
        let localId = lastLocalId
        
        let stream = AdbStream(connection: self, localId: localId)
        openedStreams[localId] = stream
        
        // Send OPEN
        try await sendPacket(AdbProtocol.generateOpen(localId: localId, destination: destination))
        
        // Wait for the connection thread to receive the OKAY or CLSE
        try await stream.waitToBeOpened()
        
        return stream
    }
    
    public func close() async {
        readLoopTask?.cancel()
        readLoopTask = nil
        
        connection?.cancel()
        connection = nil
        
        cleanupStreams()
        
        connectionEstablished = false
        connectAttempted = false
        
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(throwing: ADBError.connectionClosed)
        }
    }
    
    public func sendPacket(_ packet: Data) async throws {
        guard let conn = connection else {
            throw ADBError.connectionClosed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: packet, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }))
        }
    }
    
    // MARK: - Private Methods
    
    private func handleTimeout() {
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(returning: false)
        }
    }
    
    private func startReadLoop() {
        readLoopTask = Task {
            await self.runReadLoop()
        }
    }
    
    private func runReadLoop() async {
        guard let conn = connection else { return }
        
        while !Task.isCancelled {
            do {
                let msg = try await AdbProtocol.parse(connection: conn, protocolVersion: protocolVersion, maxData: maxData)
                try await handleIncomingMessage(msg)
            } catch {
                connectionException = error
                cleanup(error: error)
                break
            }
        }
    }
    
    private func handleIncomingMessage(_ msg: AdbMessage) async throws {
        switch msg.command {
        case AdbCommand.okay.rawValue, AdbCommand.wrte.rawValue, AdbCommand.clse.rawValue:
            guard connectionEstablished else { return }
            
            guard let stream = openedStreams[msg.arg1] else { return }
            
            if msg.command == AdbCommand.okay.rawValue {
                await stream.updateRemoteId(msg.arg0)
                await stream.readyForWrite()
            } else if msg.command == AdbCommand.wrte.rawValue {
                if let payload = msg.payload {
                    await stream.addPayload(payload)
                }
                // Send READY
                try await sendPacket(AdbProtocol.generateReady(localId: msg.arg1, remoteId: msg.arg0))
            } else { // AdbCommand.clse
                openedStreams.removeValue(forKey: msg.arg1)
                await stream.notifyClose(closedByPeer: true)
            }
            
        case AdbCommand.stls.rawValue:
            try await sendPacket(AdbProtocol.generateStls())
            try await upgradeToTls()
            
        case AdbCommand.auth.rawValue:
            if isTls { return }
            guard msg.arg0 == AdbProtocol.adbAuthToken else { return }
            guard let payload = msg.payload else { return }
            
            let packet: Data
            if sentSignature {
                if abortOnUnauthorised {
                    authorisationFailed = true
                    if let continuation = connectionContinuation {
                        connectionContinuation = nil
                        continuation.resume(throwing: ADBError.authenticationFailed)
                    }
                    return
                }
                
                // Send public key
                let pubKeyData = try AndroidPubkey.encodeWithName(publicKey: keyPair.publicKey, deviceName: deviceName)
                packet = AdbProtocol.generateAuth(type: AdbProtocol.adbAuthRsaPublicKey, data: pubKeyData)
            } else {
                // Sign token
                let signed = try AndroidPubkey.adbAuthSign(privateKey: keyPair.privateKey, payload: payload)
                packet = AdbProtocol.generateAuth(type: AdbProtocol.adbAuthSignature, data: signed)
                sentSignature = true
            }
            try await sendPacket(packet)
            
        case AdbCommand.cnxn.rawValue:
            self.protocolVersion = msg.arg0
            self.maxData = msg.arg1
            self.connectionEstablished = true
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume(returning: true)
            }
            
        default:
            // Unrecognized or ignored command
            break
        }
    }
    
    private func upgradeToTls() async throws {
        readLoopTask?.cancel()
        connection?.cancel()
        
        isTls = true
        
        let hostNW = NWEndpoint.Host(host)
        let portNW = NWEndpoint.Port(rawValue: port)!
        
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        if let identity = getSecIdentity() {
            sec_protocol_options_set_local_identity(secOptions, identity)
        }
        sec_protocol_options_set_verify_block(secOptions, { _, _, completion in
            completion(true)
        }, .global())
        
        let parameters = NWParameters(tls: tlsOptions)
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        
        let conn = NWConnection(host: hostNW, port: portNW, using: parameters)
        self.connection = conn
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    // A failure of the post-STLS TLS 1.3 handshake means the device
                    // rejected our client certificate — on Android 11+ this is the
                    // signal that the device must be paired first. Surface a clear
                    // pairing-required error instead of a raw TLS status.
                    // (Ports libadb-android commit d88ca78.)
                    continuation.resume(throwing: AdbConnection.mapTlsHandshakeError(error))
                case .cancelled:
                    continuation.resume(throwing: ADBError.connectionClosed)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }

        conn.stateUpdateHandler = nil
        startReadLoop()
    }

    /// Maps a TLS-layer handshake failure to `ADBError.pairingRequired`.
    /// A TLS error during the STLS upgrade indicates the peer rejected the
    /// connection because pairing has not been performed; other errors pass
    /// through unchanged. Mirrors libadb-android's SSLProtocolException check.
    nonisolated static func mapTlsHandshakeError(_ error: Error) -> Error {
        if let nwError = error as? NWError, case .tls(let status) = nwError {
            return ADBError.pairingRequired("TLS handshake failed (status \(status)); the device likely requires pairing.")
        }
        return error
    }
    
    private func cleanup(error: Error) {
        cleanupStreams()
        connectionEstablished = false
        connectAttempted = false
        
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(throwing: error)
        }
    }
    
    private func cleanupStreams() {
        let streams = openedStreams.values
        openedStreams.removeAll()
        for stream in streams {
            Task {
                await stream.notifyClose(closedByPeer: false)
            }
        }
    }
    
    private func getSecIdentity() -> sec_identity_t? {
        guard let certificate = keyPair.certificate else { return nil }
        guard let identity = try? adbKeychainIdentity(key: keyPair.privateKey, certificate: certificate) else {
            return nil
        }
        return sec_identity_create(identity)
    }
}

// MARK: - NWConnection Extension for Async Reading

extension NWConnection {
    func readExactly(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            self.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data = data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: ADBError.connectionClosed)
                    return
                }
                continuation.resume(throwing: ADBError.incompleteRead)
            }
        }
    }
}

// MARK: - AdbConnection Builder

public extension AdbConnection {
    struct Builder {
        private var host: String = "127.0.0.1"
        private var port: UInt16 = 5555
        private var api: Int = 1
        private var keyPair: KeyPair?
        private var deviceName: String = "Unknown Device"
        
        public init() {}
        
        public mutating func setHost(_ host: String) -> Builder {
            self.host = host
            return self
        }
        
        public mutating func setPort(_ port: UInt16) -> Builder {
            self.port = port
            return self
        }
        
        public mutating func setApi(_ api: Int) -> Builder {
            self.api = api
            return self
        }
        
        public mutating func setKeyPair(_ keyPair: KeyPair) -> Builder {
            self.keyPair = keyPair
            return self
        }
        
        public mutating func setDeviceName(_ deviceName: String) -> Builder {
            self.deviceName = deviceName
            return self
        }
        
        public func build() throws -> AdbConnection {
            guard let keyPair = keyPair else {
                throw ADBError.invalidArgument("KeyPair must be set.")
            }
            return AdbConnection(
                host: host,
                port: port,
                keyPair: keyPair,
                api: api,
                deviceName: deviceName
            )
        }
    }
}
