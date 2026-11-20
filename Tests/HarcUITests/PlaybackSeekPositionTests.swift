import Foundation
import Testing
@testable import HarcUI

@Suite("Playback seek position")
struct PlaybackSeekPositionTests {
    @Test("Waveform inset maps both ends and midpoint precisely")
    func waveform() {
        #expect(PlaybackSeekPosition.seconds(x: 8, width: 216, inset: 8, duration: 120) == 0)
        #expect(PlaybackSeekPosition.seconds(x: 108, width: 216, inset: 8, duration: 120) == 60)
        #expect(PlaybackSeekPosition.seconds(x: 208, width: 216, inset: 8, duration: 120) == 120)
    }

    @Test("Speaker surfaces use their full width")
    func speakers() {
        #expect(PlaybackSeekPosition.seconds(x: 50, width: 200, duration: 80) == 20)
    }

    @Test("Dragging outside the plot clamps to the recording")
    func clamping() {
        #expect(PlaybackSeekPosition.seconds(x: -50, width: 200, duration: 80) == 0)
        #expect(PlaybackSeekPosition.seconds(x: 250, width: 200, duration: 80) == 80)
    }

    @Test("Unloaded audio and invalid geometry never produce invalid seek times")
    func invalid() {
        #expect(PlaybackSeekPosition.seconds(x: 50, width: 0, duration: 80) == 0)
        #expect(PlaybackSeekPosition.seconds(x: 50, width: 10, inset: 8, duration: 80) == 0)
        #expect(PlaybackSeekPosition.seconds(x: 50, width: 200, duration: 0) == 0)
        #expect(PlaybackSeekPosition.seconds(x: .nan, width: 200, duration: 80) == 0)
        #expect(PlaybackSeekPosition.seconds(x: 50, width: 200, duration: .infinity) == 0)
    }
}
