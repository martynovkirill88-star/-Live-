// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation

public actor AdbStream {
    private let connection: AdbConnection
    public let localId: UInt32
    private var remoteId: UInt32 = 0
    private var isClosed = false
    private var pendingClose = false
    private var writeReady = false
    
    private var readQueue: [Data] = []
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Error>?
    
    init(connection: AdbConnection, localId: UInt32) {
        self.connection = connection
        self.localId = localId
    }
    
    public func waitToBeOpened() async throws {
        if writeReady { return }
        if isClosed {
            throw ADBError.streamRejected("Stream already closed or rejected.")
        }
        try await withCheckedThrowingContinuation { continuation in
            self.openContinuation = continuation
        }
    }
    
    public func read() async throws -> Data {
        if !readQueue.isEmpty {
            return readQueue.removeFirst()
        }
        if isClosed {
            throw ADBError.streamClosed
        }
        if pendingClose {
            isClosed = true
            return Data()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.readContinuation = continuation
        }
    }
    
    public func write(_ data: Data) async throws {
        if isClosed {
            throw ADBError.streamClosed
        }
        
        if !writeReady {
            await withCheckedContinuation { continuation in
                self.writeContinuation = continuation
            }
        }
        writeReady = false
        
        let maxData = await connection.getMaxData()
        var offset = 0
        let count = data.count
        while offset < count {
            let chunkLen = min(count - offset, Int(maxData))
            let chunk = data.subdata(in: offset..<(offset + chunkLen))
            try await connection.sendPacket(AdbProtocol.generateWrite(localId: localId, remoteId: remoteId, data: chunk))
            offset += chunkLen
        }
    }
    
    public func close() async throws {
        if isClosed { return }
        
        notifyClose(closedByPeer: false)
        
        try await connection.sendPacket(AdbProtocol.generateClose(localId: localId, remoteId: remoteId))
    }
    
    public func getIsClosed() -> Bool {
        return isClosed
    }
    
    // MARK: - Internal Callbacks (called by AdbConnection)
    
    func addPayload(_ payload: Data) {
        if let continuation = readContinuation {
            readContinuation = nil
            continuation.resume(returning: payload)
        } else {
            readQueue.append(payload)
        }
    }
    
    func updateRemoteId(_ remoteId: UInt32) {
        self.remoteId = remoteId
    }
    
    func readyForWrite() {
        writeReady = true
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume()
        }
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume()
        }
    }
    
    func notifyClose(closedByPeer: Bool) {
        if closedByPeer && !readQueue.isEmpty {
            pendingClose = true
        } else {
            isClosed = true
        }
        
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(throwing: ADBError.streamRejected("Closed by peer"))
        }
        
        if let continuation = readContinuation {
            readContinuation = nil
            if pendingClose {
                isClosed = true
                continuation.resume(returning: Data()) // EOF
            } else {
                continuation.resume(throwing: ADBError.streamClosed)
            }
        }
        
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume()
        }
    }
}
