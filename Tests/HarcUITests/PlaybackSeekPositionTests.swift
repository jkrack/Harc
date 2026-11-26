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
    @Test("Playhead and seek coordinates round trip for both surfaces")
    func playheadAlignment() throws {
        for inset: CGFloat in [0, 8] {
            for time: Double in [0, 0.1, 20, 40, 80] {
                let x = try #require(PlaybackSeekPosition.x(seconds: time, width: 216, inset: inset, duration: 80))
                let sought = PlaybackSeekPosition.seconds(x: x, width: 216, inset: inset, duration: 80)
                #expect(abs(sought - time) < 0.000001)
            }
        }
    }

    @Test("Speaker playhead clamps at edges and supports subsecond audio")
    func playheadEndpoints() {
        #expect(PlaybackSeekPosition.x(seconds: -1, width: 200, duration: 80) == 0)
        #expect(PlaybackSeekPosition.x(seconds: 90, width: 200, duration: 80) == 200)
        #expect(PlaybackSeekPosition.x(seconds: 0.25, width: 200, duration: 0.5) == 100)
    }

    @Test("No playhead is drawn for unloaded or nonfinite data")
    func invalidPlayhead() {
        #expect(PlaybackSeekPosition.x(seconds: 0, width: 200, duration: 0) == nil)
        #expect(PlaybackSeekPosition.x(seconds: .nan, width: 200, duration: 80) == nil)
        #expect(PlaybackSeekPosition.x(seconds: 5, width: .infinity, duration: 80) == nil)
        #expect(PlaybackSeekPosition.x(seconds: 5, width: 200, duration: .infinity) == nil)
        #expect(PlaybackSeekPosition.x(seconds: 5, width: 10, inset: 8, duration: 80) == nil)
    }

}
