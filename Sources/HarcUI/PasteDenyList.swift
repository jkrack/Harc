import Foundation

/// Bundle IDs that are never safe auto-paste targets. Seed list — not
/// user-editable in v1 (see spec §8). `isDenied(nil)` returns `false` so
/// callers can pass the optional return of
/// `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` without
/// unwrapping.
public enum PasteDenyList {
    public static let bundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.ScreenSaver.Engine",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
    ]

    public static func isDenied(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
