import Foundation

/// Honest Client-to-Host reachability for Settings.
///
/// A running Client runtime proves only that local capture storage is ready.
/// It does not prove that an adopted Host is reachable, so pairing and live
/// connectivity are represented separately here.
public enum ClientHostConnectionState: Equatable, Sendable {
    case starting
    case notPaired(pending: Int)
    case paired(lastContact: Date?, pending: Int)
    case connecting(lastContact: Date?, pending: Int)
    case connected(lastContact: Date, pending: Int)
    case needsAttention(message: String, lastContact: Date?, pending: Int)
    case securityBlocked(message: String, lastContact: Date?, pending: Int)

    public var pendingCount: Int {
        switch self {
        case .starting:
            0
        case .notPaired(let pending), .paired(_, let pending),
             .connecting(_, let pending), .connected(_, let pending),
             .needsAttention(_, _, let pending),
             .securityBlocked(_, _, let pending):
            pending
        }
    }

    public var lastContact: Date? {
        switch self {
        case .starting, .notPaired:
            nil
        case .paired(let lastContact, _),
             .connecting(let lastContact, _),
             .needsAttention(_, let lastContact, _),
             .securityBlocked(_, let lastContact, _):
            lastContact
        case .connected(let lastContact, _):
            lastContact
        }
    }

    public var isPaired: Bool {
        switch self {
        case .starting, .notPaired:
            false
        case .paired, .connecting, .connected, .needsAttention,
             .securityBlocked:
            true
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
