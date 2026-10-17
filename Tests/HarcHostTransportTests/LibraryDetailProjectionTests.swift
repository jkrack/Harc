import Foundation
import HarcDomain
import HarcProtocolWire
import Testing
@testable import HarcHostTransport

@Suite("Library detail transport projection")
struct LibraryDetailProjectionTests {
    @Test("capture advisory survives optional field selection", arguments: [false, true])
    func captureAdvisory(needsReview: Bool) throws {
        let summary = try LibraryRecordingSummary(
            canonicalID: CanonicalRecordingID(UUID()),
            revision: .initial,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let detail = try LibraryRecordingDetail(
            summary: summary, transcriptText: "Saved audio",
            captureNeedsReview: needsReview
        )
        let selections: [Set<Harc_V1_RecordingDetailFieldV1>] = [[], [.recordingDetailFieldTranscript]]
        for fields in selections {
            let projected = try HarcLibraryGRPCServiceAdapterV1.project(detail, requestedFields: fields)
            #expect(projected.captureNeedsReview == needsReview)
            #expect(projected.summary.originID == nil)
            #expect(projected.discontinuities.isEmpty)
            #expect(projected.transcriptText == (fields.isEmpty ? nil : "Saved audio"))
        }
    }
}
