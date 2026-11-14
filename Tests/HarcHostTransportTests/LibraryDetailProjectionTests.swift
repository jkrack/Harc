import Foundation
import HarcDomain
import HarcProtocolWire
import HarcProtocol
import Testing
@testable import HarcHostTransport

@Suite("Library detail transport projection")
struct LibraryDetailProjectionTests {
    @Test("speaker confirmation survives authorized detail selection and wire round trip")
    func speakerConfirmation() throws {
        let summary = try LibraryRecordingSummary(canonicalID: CanonicalRecordingID(UUID()),
            revision: .initial, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let labels = try [nil, false, true].enumerated().map { index, confirmed in
            try SpeakerLabel(speakerIndex: UInt32(index), displayName: "Person \(index)",
                personID: PersonID.random(), identityRevision: .initial, isUserConfirmed: confirmed)
        }
        let detail = try LibraryRecordingDetail(summary: summary, speakerLabels: labels)
        let included = try HarcLibraryGRPCServiceAdapterV1.project(detail,
            requestedFields: [.recordingDetailFieldSpeakerLabels])
        let encoded = try Harc_V1_LibraryRecordingDetailV1(included).serializedData()
        let decoded = try Harc_V1_LibraryRecordingDetailV1(serializedBytes: encoded).domainValue()
        #expect(decoded.speakerLabels == labels)
        let omitted = try HarcLibraryGRPCServiceAdapterV1.project(detail, requestedFields: [])
        #expect(omitted.speakerLabels.isEmpty)
    }

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
