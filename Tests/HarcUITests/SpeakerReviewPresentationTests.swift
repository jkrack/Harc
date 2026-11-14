import Testing
@testable import HarcUI

@Suite("Speaker review presentation")
struct SpeakerReviewPresentationTests {
    @Test func unnamedSlotsHaveOneIdentityLabel() {
        #expect(SpeakerReviewPresentation.assignmentTitle(nil, speakerIndex: 0) == "Assign person…")
        #expect(SpeakerReviewPresentation.assignmentTitle("Speaker 1", speakerIndex: 0) == "Assign person…")
        #expect(SpeakerReviewPresentation.assignmentTitle("  Alice  ", speakerIndex: 0) == "Alice")
        #expect(SpeakerReviewPresentation.assignmentTitle("Speaker 2", speakerIndex: 0) == "Speaker 2")
    }

    @Test func provenanceIsNeverInferredFromAName() {
        #expect(SpeakerReviewPresentation.statusText(true) == "Confirmed")
        #expect(SpeakerReviewPresentation.statusText(false) == "Auto-matched")
        #expect(SpeakerReviewPresentation.statusText(nil) == "Confirmation unknown")
    }

    @Test func evidenceIsSimilarityNotConfidence() {
        #expect(SpeakerReviewPresentation.similarityText(0.82) == "Voice similarity: 0.82")
        for score in [Double.nan, .infinity, -.infinity, 1.01, -1.01] {
            #expect(SpeakerReviewPresentation.similarityText(score) == "Voice similarity unavailable")
        }
    }
}
