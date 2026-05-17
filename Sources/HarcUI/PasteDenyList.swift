import Foundation

/// Bundle IDs that are not safe auto-paste targets. The default set seeds the
/// user-editable preference on first launch. `isDenied(nil)` returns `false` so
/// callers can pass the optional return of
/// `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` without
/// unwrapping.
public enum PasteDenyList {
    public static let defaultBundleIDs: Set<String> = [
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

    public static let lockedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
    ]

    public static let bundleIDs = defaultBundleIDs

    @MainActor
    public static func isDenied(_ bundleID: String?) -> Bool {
        isDenied(bundleID, in: HarcPreferences.shared.pasteDenyListBundleIDs)
    }

    public static func isDenied(_ bundleID: String?, in bundleIDs: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
