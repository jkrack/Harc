import Testing
import Foundation
@testable import HarcExport

@Suite("SpeakerLabel")
struct SpeakerLabelTests {
    @Test("nil speaker returns nil (un-diarized segment)")
    func nilSpeaker() {
        #expect(SpeakerLabel.displayLabel(for: nil, names: [:]) == nil)
        #expect(SpeakerLabel.displayLabel(for: nil, names: [0: "Jason"]) == nil)
    }

    @Test("missing override falls back to Speaker N (1-based)")
    func fallback() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [:]) == "Speaker 1")
        #expect(SpeakerLabel.displayLabel(for: 2, names: [0: "Jason"]) == "Speaker 3")
    }

    @Test("override name returned when present and non-empty")
    func overrideHit() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "Jason"]) == "Jason")
        #expect(SpeakerLabel.displayLabel(for: 1, names: [0: "Jason", 1: "Amy"]) == "Amy")
    }

    @Test("empty-trim override is treated as absent (fallback)")
    func emptyTrimFallback() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: ""]) == "Speaker 1")
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "   "]) == "Speaker 1")
    }

    @Test("override is trimmed before return")
    func trimmedOverride() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "  Jason  "]) == "Jason")
    }
}
