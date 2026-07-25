import Foundation

/// What the idle retroactive-record ring is actually doing.
///
/// `PreRollCapture` has always tracked a `.failed(reason)` state — its own doc
/// comment says it is "exposed so the UI can be honest about whether the
/// buffer is actually filling" — but nothing ever read it. The bridge
/// published `bankedSeconds` alone, so a ring that failed to open the mic
/// showed the same "Ready to capture the last 0s" as a healthy one that simply
/// had not banked anything yet. The user is told the feature is armed, macOS
/// shows no mic indicator, and starting a recording reaches back over nothing.
public enum PreRollStatus: Equatable, Sendable {
    /// Ring is live; `banked` is how much audio it currently holds.
    case listening(banked: TimeInterval)
    /// Ring is not capturing. `reason` is user-facing.
    case failed(reason: String)

    public var bankedSeconds: TimeInterval {
        switch self {
        case .listening(let banked): return banked
        case .failed: return 0
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
