import Foundation

public enum MeetingCatalog {
    /// Apps Harc detects out of the box.
    public static let builtIn: [MeetingApp] = [
        MeetingApp(
            id: "us.zoom.xos",
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            symbolName: "video.fill"
        ),
        MeetingApp(
            id: "com.microsoft.teams2",
            bundleID: "com.microsoft.teams2",
            aliasBundleIDs: ["com.microsoft.teams"],
            displayName: "Microsoft Teams",
            symbolName: "person.2.wave.2.fill"
        ),
        MeetingApp(
            id: "com.tinyspeck.slackmacgap",
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            symbolName: "bubble.left.and.bubble.right.fill",
            settingsNote: "Will prompt on app launch, not just huddles."
        ),
    ]

    /// Returns the catalog entry matching a runtime bundle ID, or nil.
    public static func entry(forBundleID bundleID: String) -> MeetingApp? {
        builtIn.first { $0.matches(bundleID: bundleID) }
    }
}
