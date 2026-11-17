// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation

public enum ADBError: Error, LocalizedError, Sendable {
    case invalidArgument(String)
    case connectionClosed
    case incompleteRead
    case invalidHeader(String)
    case checksumMismatch
    case invalidKey
    case signatureFailed
    case pairingRequired(String)
    case authenticationFailed
    case connectionFailed(String)
    case alreadyConnected
    case notConnected
    case streamRejected(String)
    case streamClosed
    
    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .connectionClosed:
            return "Connection closed."
        case .incompleteRead:
            return "Incomplete read from stream."
        case .invalidHeader(let msg):
            return "Invalid header: \(msg)"
        case .checksumMismatch:
            return "Invalid header: Checksum mismatched."
        case .invalidKey:
            return "Invalid public/private key."
        case .signatureFailed:
            return "Failed to sign payload."
        case .pairingRequired(let msg):
            return "ADB pairing is required: \(msg)"
        case .authenticationFailed:
            return "Initial authentication attempt rejected by peer."
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .alreadyConnected:
            return "Already connected."
        case .notConnected:
            return "connect() must be called first."
        case .streamRejected(let msg):
            return "Stream open actively rejected by remote peer: \(msg)"
        case .streamClosed:
            return "Stream closed."
        }
    }
}
