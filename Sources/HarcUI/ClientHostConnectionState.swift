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

    /// Recoverable reachability failures may be retried without changing the
    /// adopted Host or touching durable Client recordings.
    public var canRetryConnection: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}

/// Independent Client-to-Host health axes. No single green label is allowed
/// to imply that trust, reachability, a live authenticated session, recording
/// delivery, derived processing, and speaker consistency are all healthy.
public struct ClientHostHealthSnapshot: Equatable, Sendable {
    public enum Trust: Equatable, Sendable {
        case checking
        case notPaired
        case adopted
        case securityBlocked(String)
    }

    public enum Route: Equatable, Sendable {
        case unknown
        case discovering
        case direct
        case encryptedRelay
        case unavailable(String)
    }

    public enum Session: Equatable, Sendable {
        case idle
        case authenticating
        case authenticated
        case failed(String)
    }

    public enum Work: Equatable, Sendable {
        case current
        case pending(Int)
        case syncing(Int)
        case retrying(Int, String)
        case blocked(Int, String)
    }

    public enum SpeakerSync: Equatable, Sendable {
        case current
        case pending(Int)
        /// Local diarization retries and Host identity decisions are separate
        /// counts so automatic repair is never mislabeled as user review.
        case needsAttention(repairing: Int, review: Int)
        case unknown
    }

    public let trust: Trust
    public let route: Route
    public let session: Session
    public let recordings: Work
    public let processing: Work
    public let speakers: SpeakerSync
    public let lastAuthenticatedAt: Date?
    public let nextAutomaticRetryAt: Date?

    public init(
        trust: Trust,
        route: Route,
        session: Session,
        recordings: Work,
        processing: Work,
        speakers: SpeakerSync,
        lastAuthenticatedAt: Date?,
        nextAutomaticRetryAt: Date? = nil
    ) {
        self.trust = trust
        self.route = route
        self.session = session
        self.recordings = recordings
        self.processing = processing
        self.speakers = speakers
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.nextAutomaticRetryAt = nextAutomaticRetryAt
    }

    public static let starting = ClientHostHealthSnapshot(
        trust: .checking,
        route: .unknown,
        session: .idle,
        recordings: .current,
        processing: .current,
        speakers: .unknown,
        lastAuthenticatedAt: nil
    )
}
