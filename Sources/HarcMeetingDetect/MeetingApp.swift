import Foundation

/// A meeting app known to Harc's detection system. One catalog entry may match
/// multiple runtime bundle IDs via `aliasBundleIDs` (e.g. new vs. classic Teams).
public struct MeetingApp: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let bundleID: String
    public let aliasBundleIDs: [String]
    public let displayName: String
    public let symbolName: String
    public let settingsNote: String?

    public init(
        id: String,
        bundleID: String,
        aliasBundleIDs: [String] = [],
        displayName: String,
        symbolName: String,
        settingsNote: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.aliasBundleIDs = aliasBundleIDs
        self.displayName = displayName
        self.symbolName = symbolName
        self.settingsNote = settingsNote
    }

    /// Whether this catalog entry matches the given runtime bundle ID.
    public func matches(bundleID candidate: String) -> Bool {
        bundleID == candidate || aliasBundleIDs.contains(candidate)
    }
}
