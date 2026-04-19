import Foundation
import Combine

@MainActor
public final class MeetingDetectionState: ObservableObject {
    /// Bundle IDs with a pending (un-acknowledged) detection. While non-empty,
    /// the menu bar icon pulses.
    @Published public private(set) var pendingBundleIDs: Set<String> = []
    /// Display name for the most-recent pending detection — used by the popover hint.
    @Published public private(set) var mostRecentDisplayName: String? = nil

    public init() {}

    public var isPulsing: Bool { !pendingBundleIDs.isEmpty }

    public func add(bundleID: String, displayName: String) {
        pendingBundleIDs.insert(bundleID)
        mostRecentDisplayName = displayName
    }

    public func clear(bundleID: String) {
        pendingBundleIDs.remove(bundleID)
        if pendingBundleIDs.isEmpty { mostRecentDisplayName = nil }
    }

    public func clearAll() {
        pendingBundleIDs.removeAll()
        mostRecentDisplayName = nil
    }
}
