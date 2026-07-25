import Foundation

/// Saves and restores the preferences a UI-test run overwrites.
///
/// `AppDelegate.applyUITestConfigurationIfNeeded()` forces a handful of
/// preferences into a known state so tests are deterministic — destination
/// folder, auto-summarize, meeting detection, post-stop notification. Those
/// writes go to the app's single `UserDefaults` domain, which is also the
/// user's, so every UI-test run silently switched features off in the real
/// install and left them off.
///
/// The values are stashed under a separate key and put back on terminate. A
/// stash that survives (the runner was killed mid-test) is replayed on the
/// next launch, so a crashed run doesn't strand the settings either.
@MainActor
public enum UITestPreferenceRestore {
    private static let stashKey = "harc.uiTest.preferenceStash"

    private enum Field: String, CaseIterable {
        case destinationPath = "harc.destinationPath"
        case autoSummarize = "harc.autoSummarizeEnabled"
        case meetingDetection = "harc.meetingDetectionEnabled"
        case postStopNotification = "harc.postStopNotificationEnabled"
    }

    public static func capture(_ prefs: HarcPreferences) {
        let defaults = UserDefaults.standard
        // Don't overwrite an existing stash: a second capture in the same run
        // would save the already-forced test values as if they were the
        // user's.
        guard defaults.dictionary(forKey: stashKey) == nil else { return }
        defaults.set([
            Field.destinationPath.rawValue: prefs.destinationPath,
            Field.autoSummarize.rawValue: prefs.autoSummarizeEnabled,
            Field.meetingDetection.rawValue: prefs.meetingDetectionEnabled,
            Field.postStopNotification.rawValue: prefs.postStopNotificationEnabled,
        ], forKey: stashKey)
    }

    public static func restore(_ prefs: HarcPreferences) {
        let defaults = UserDefaults.standard
        guard let stash = defaults.dictionary(forKey: stashKey) else { return }
        if let value = stash[Field.destinationPath.rawValue] as? String {
            prefs.destinationPath = value
        }
        if let value = stash[Field.autoSummarize.rawValue] as? Bool {
            prefs.autoSummarizeEnabled = value
        }
        if let value = stash[Field.meetingDetection.rawValue] as? Bool {
            prefs.meetingDetectionEnabled = value
        }
        if let value = stash[Field.postStopNotification.rawValue] as? Bool {
            prefs.postStopNotificationEnabled = value
        }
        defaults.removeObject(forKey: stashKey)
    }

    /// True when a previous run left preferences overwritten.
    public static func hasPendingRestore() -> Bool {
        UserDefaults.standard.dictionary(forKey: stashKey) != nil
    }
}
