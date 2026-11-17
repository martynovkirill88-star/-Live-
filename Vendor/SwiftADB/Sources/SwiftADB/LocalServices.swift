// SPDX-License-Identifier: GPL-3.0-or-later OR Apache-2.0

import Foundation

/// Local services extracted from the ADB client for easy access.
public enum LocalServices: Int, CaseIterable, Sendable {
    case shell = 1
    case remount = 2
    case file = 3
    case tcpConnect = 4
    case localUnixSocket = 5
    case localUnixSocketReserved = 6
    case localUnixSocketAbstract = 7
    case localUnixSocketFileSystem = 8
    case framebuffer = 9
    case connectJdwp = 10
    case trackJdwp = 11
    case sync = 12
    case reverse = 13
    case backup = 14
    case restore = 15
    
    public static let first = LocalServices.shell
    public static let last = LocalServices.restore
    
    public var serviceName: String {
        switch self {
        case .shell:
            return "shell:"
        case .connectJdwp:
            return "jdwp:"
        case .file:
            return "dev:"
        case .framebuffer:
            return "framebuffer:"
        case .localUnixSocket:
            return "local:"
        case .localUnixSocketAbstract:
            return "localabstract:"
        case .localUnixSocketFileSystem:
            return "localfilesystem:"
        case .localUnixSocketReserved:
            return "localreserved:"
        case .remount:
            return "remount:"
        case .reverse:
            return "reverse:"
        case .sync:
            return "sync:"
        case .tcpConnect:
            return "tcp:"
        case .trackJdwp:
            return "track-jdwp"
        case .backup:
            return "backup:"
        case .restore:
            return "restore:"
        }
    }
    
    public func getDestination(args: [String]) throws -> String {
        var destination = self.serviceName
        switch self {
        case .shell:
            for arg in args {
                if arg.contains("\"") {
                    throw ADBError.invalidArgument("Arguments for inline shell cannot contain double quotations.")
                }
                if arg.contains(" ") {
                    destination.append("\"\(arg)\"")
                } else {
                    destination.append(arg)
                }
            }
        case .file:
            guard args.count == 1 else {
                throw ADBError.invalidArgument("Service expects exactly one argument, \(args.count) supplied.")
            }
            destination.append(args[0])
        case .tcpConnect:
            if args.isEmpty {
                throw ADBError.invalidArgument("Port number must be specified.")
            } else if args.count == 1 {
                destination.append(args[0])
            } else if args.count == 2 {
                destination.append("\(args[0]):\(args[1])")
            } else {
                throw ADBError.invalidArgument("Invalid number of arguments supplied.")
            }
        case .localUnixSocket, .localUnixSocketAbstract, .localUnixSocketFileSystem, .localUnixSocketReserved:
            guard args.count == 1 else {
                throw ADBError.invalidArgument("Service expects exactly one argument, \(args.count) supplied.")
            }
            destination.append(args[0])
        case .connectJdwp:
            guard args.count == 1 else {
                throw ADBError.invalidArgument("PID must be specified.")
            }
            destination.append(args[0])
        case .reverse:
            guard args.count == 1 else {
                throw ADBError.invalidArgument("Forward command must be specified.")
            }
            let cmd = args[0]
            if cmd == "list-forward" || cmd == "killforward-all" {
                destination.append(cmd)
            } else if cmd.hasPrefix("forward:") || cmd.hasPrefix("killforward:") {
                destination.append(cmd)
            } else {
                throw ADBError.invalidArgument("Invalid forward command.")
            }
        case .backup:
            if args.isEmpty {
                throw ADBError.invalidArgument("At least one package must be specified or use -shared/-all.")
            }
            destination.append(args.joined(separator: " "))
        case .remount:
            destination.append(args.joined(separator: " "))
        case .restore, .framebuffer, .sync, .trackJdwp:
            guard args.isEmpty else {
                throw ADBError.invalidArgument("Service expects no arguments.")
            }
        }
        return destination
    }
}
