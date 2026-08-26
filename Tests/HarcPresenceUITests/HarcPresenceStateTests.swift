import Testing
@testable import HarcPresenceUI

@Suite("Harc presence state")
struct HarcPresenceStateTests {
    @Test("Every state has a nonempty accessibility value")
    func accessibilityValues() {
        for state in HarcPresenceState.allCases {
            #expect(!state.accessibilityValue.isEmpty)
        }
    }

    @Test("Ready presence is calm and continuously alive")
    func readyMotion() {
        let style = HarcPresenceStyle(state: .ready)

        #expect(style.animates)
        #expect(!style.respondsToAudio)
        #expect(style.framesPerSecond == 15)
        #expect(style.breathAmplitude > 0)
        #expect(style.phaseSpeed > 0)
    }

    @Test("Recording presence is audio reactive")
    func recordingMotion() {
        let style = HarcPresenceStyle(state: .recording)

        #expect(style.animates)
        #expect(style.respondsToAudio)
        #expect(style.framesPerSecond == 24)
    }

    @Test("Terminal problems do not use reassuring motion")
    func problemMotion() {
        for state in [HarcPresenceState.attention, .failure] {
            let style = HarcPresenceStyle(state: state)
            #expect(!style.animates)
            #expect(!style.respondsToAudio)
        }
    }
}
