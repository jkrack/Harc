import Foundation
import Testing
@testable import HarcUI

/// UI-test runs force a handful of preferences into a deterministic state, and
/// those writes land in the real `UserDefaults` domain — the same one the
/// user's install reads. Before this, every run left auto-summarize and
/// meeting detection switched off in the actual app.
@MainActor
@Suite("UITestPreferenceRestore")
struct UITestPreferenceRestoreTests {
    private func makePrefs() -> HarcPreferences {
        UserDefaults.standard.removeObject(forKey: "harc.uiTest.preferenceStash")
        return HarcPreferences.shared
    }

    @Test("captured preferences come back on restore")
    func restorePutsPreferencesBack() {
        let prefs = makePrefs()
        let originalSummarize = prefs.autoSummarizeEnabled
        let originalDetection = prefs.meetingDetectionEnabled
        defer {
            prefs.autoSummarizeEnabled = originalSummarize
            prefs.meetingDetectionEnabled = originalDetection
            UserDefaults.standard.removeObject(forKey: "harc.uiTest.preferenceStash")
        }

        prefs.autoSummarizeEnabled = true
        prefs.meetingDetectionEnabled = true

        UITestPreferenceRestore.capture(prefs)
        // What applyUITestConfigurationIfNeeded does to make runs deterministic.
        prefs.autoSummarizeEnabled = false
        prefs.meetingDetectionEnabled = false

        UITestPreferenceRestore.restore(prefs)

        #expect(prefs.autoSummarizeEnabled == true)
        #expect(prefs.meetingDetectionEnabled == true)
        #expect(UITestPreferenceRestore.hasPendingRestore() == false)
    }

    /// A second capture within one run would otherwise save the already-forced
    /// test values as though they were the user's, making restore a no-op that
    /// looks like it worked.
    @Test("a second capture does not overwrite the stash")
    func secondCaptureKeepsOriginalStash() {
        let prefs = makePrefs()
        let original = prefs.autoSummarizeEnabled
        defer {
            prefs.autoSummarizeEnabled = original
            UserDefaults.standard.removeObject(forKey: "harc.uiTest.preferenceStash")
        }

        prefs.autoSummarizeEnabled = true
        UITestPreferenceRestore.capture(prefs)
        prefs.autoSummarizeEnabled = false
        UITestPreferenceRestore.capture(prefs)

        UITestPreferenceRestore.restore(prefs)

        #expect(prefs.autoSummarizeEnabled == true)
    }

    @Test("restore without a stash leaves preferences alone")
    func restoreWithoutStashIsInert() {
        let prefs = makePrefs()
        let original = prefs.meetingDetectionEnabled
        defer { prefs.meetingDetectionEnabled = original }

        prefs.meetingDetectionEnabled = true
        UITestPreferenceRestore.restore(prefs)

        #expect(prefs.meetingDetectionEnabled == true)
    }
}
