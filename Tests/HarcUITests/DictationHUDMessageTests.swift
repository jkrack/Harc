import Foundation
import Testing
import HarcAudio
@testable import HarcUI

@Suite("Dictation HUD messages")
@MainActor
struct DictationHUDMessageTests {
    /// The HUD pill renders two lines of caption text. A full
    /// `localizedDescription` arrived truncated — "Audio engine failure: No
    /// microphone input is available. Check Harc's Microphone permission in
    /// S…" — cutting off exactly the part that says what to do.
    @Test("audio engine failures stay short enough to read whole")
    func engineFailureIsShort() {
        let message = DictationController.hudMessage(
            for: AudioError.audioEngineFailed(
                "No microphone input is available. Check Harc's Microphone permission in System Settings → Privacy & Security, and that an input device is selected."
            )
        )

        #expect(message.count < 45, "too long for the HUD pill: \(message)")
        #expect(!message.contains("Audio engine failure"))
    }

    @Test("a denied microphone says so plainly")
    func permissionDenied() {
        #expect(DictationController.hudMessage(for: AudioError.micPermissionDenied)
                == "Microphone permission needed")
    }

    /// Anything we haven't classified still reaches the user rather than being
    /// swallowed into a generic apology.
    @Test("unclassified errors pass their own description through")
    func unknownPassesThrough() {
        struct Odd: Error, LocalizedError {
            var errorDescription: String? { "Something specific went wrong" }
        }
        #expect(DictationController.hudMessage(for: Odd()) == "Something specific went wrong")
    }
}
