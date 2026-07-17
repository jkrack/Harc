import Foundation
import Testing
@testable import HarcUI

struct DictationHUDPresentationTests {
    @Test("pref off: idle hides, activity shows the live HUD — today's behavior")
    func prefOffMatchesLegacyBehavior() {
        #expect(DictationHUDPresentation.from(
            phase: .idle, persistent: false, temporarilyHidden: false, isRecording: false
        ) == .hidden)
        for phase: DictationState.Phase in [
            .requestingMic, .listening, .loadingModel, .transcribing,
            .transforming, .inserting, .error("x"),
        ] {
            #expect(DictationHUDPresentation.from(
                phase: phase, persistent: false, temporarilyHidden: false, isRecording: false
            ) == .live, "phase \(phase) should present the live HUD")
        }
    }

    @Test("pref on: idle presents the pill; any activity presents the live HUD")
    func prefOnShowsPillWhenIdle() {
        #expect(DictationHUDPresentation.from(
            phase: .idle, persistent: true, temporarilyHidden: false, isRecording: false
        ) == .idlePill(recording: false))
        #expect(DictationHUDPresentation.from(
            phase: .listening, persistent: true, temporarilyHidden: false, isRecording: false
        ) == .live)
    }

    @Test("temporary hide beats the pref, but never suppresses the live HUD")
    func temporaryHideOnlyAffectsIdle() {
        #expect(DictationHUDPresentation.from(
            phase: .idle, persistent: true, temporarilyHidden: true, isRecording: false
        ) == .hidden)
        #expect(DictationHUDPresentation.from(
            phase: .transcribing, persistent: true, temporarilyHidden: true, isRecording: false
        ) == .live)
    }

    @Test("meeting recording tints the idle pill")
    func recordingReachesThePill() {
        #expect(DictationHUDPresentation.from(
            phase: .idle, persistent: true, temporarilyHidden: false, isRecording: true
        ) == .idlePill(recording: true))
        // Recording never suppresses the pill outright — it stays visible
        // (dimmed + tinted) so the user sees why dictation is unavailable.
        #expect(DictationHUDPresentation.from(
            phase: .idle, persistent: true, temporarilyHidden: true, isRecording: true
        ) == .hidden, "explicit hide still wins")
    }

    @Test("persistentDictationHUD pref defaults off and round-trips")
    @MainActor
    func prefDefaultAndPersistence() {
        let defaults = UserDefaults.standard
        let key = "harc.persistentDictationHUD"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let fresh = HarcPreferences()
        #expect(fresh.persistentDictationHUD == false, "defaults off — opt-in feature")

        fresh.persistentDictationHUD = true
        #expect(defaults.bool(forKey: key) == true)
        let reloaded = HarcPreferences()
        #expect(reloaded.persistentDictationHUD == true)
    }
}
