import Testing
@testable import HarcCore

@Suite("Untranscribed audio marker")
struct UntranscribedAudioMarkerTests {
    @Test func roundTripAndUnicode() {
        let text = UntranscribedAudioMarker.text(startMs: 61_000, endMs: 125_000)
        let markers = UntranscribedAudioMarker.parse(in: "🗣 before \(text) after")
        #expect(markers.count == 1)
        #expect(markers.first?.startMs == 61_000)
        #expect(markers.first?.text == text)
    }
    @Test func chronologicalAndSubsecondNotice() {
        let late = UntranscribedAudioMarker.text(startMs: 5000, endMs: 6000)
        let early = UntranscribedAudioMarker.text(startMs: 100, endMs: 200)
        #expect(UntranscribedAudioMarker.parse(in: late + early).map(\.startMs) == [0, 5000])
    }
    @Test func malformedTimesAreNotNotices() {
        let valid = UntranscribedAudioMarker.text(startMs: 1000, endMs: 2000)
        for invalid in [valid.replacingOccurrences(of: "0:01", with: "0:99"),
                        valid.replacingOccurrences(of: "0:01", with: "999999999999999999999:01"),
                        valid.replacingOccurrences(of: "0:01", with: "1:01")] {
            #expect(UntranscribedAudioMarker.parse(in: invalid).isEmpty)
        }
        #expect(UntranscribedAudioMarker.parse(in: "They could not be transcribed yesterday.").isEmpty)
    }
}
