import Foundation
import Testing
@testable import HarcDomain

@Suite("HarcDomain path-free library values")
struct LibraryViewAndConflictTests {
    private let firstID = CanonicalRecordingID(
        UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    )
    private let secondID = CanonicalRecordingID(
        UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    )

    private func origin(byte: UInt8 = 1) throws -> OriginRecordingID {
        OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: byte, count: 32)),
            recordingUUID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )
    }

    private func summary(
        id: CanonicalRecordingID,
        originID: OriginRecordingID? = nil,
        revision: UInt64 = 1
    ) throws -> LibraryRecordingSummary {
        try LibraryRecordingSummary(
            canonicalID: id,
            originID: originID,
            revision: EntityRevision(revision),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            title: "Planning",
            suggestedTitle: "Roadmap",
            tags: ["work"],
            pinned: true,
            canonicalAudio: .unavailablePendingHash,
            processing: .ready,
            projection: .readyV1
        )
    }

    @Test("Summary rejects an end before its start")
    func summaryTimes() throws {
        #expect(throws: DomainValidationError.self) {
            try LibraryRecordingSummary(
                canonicalID: firstID,
                revision: .initial,
                startedAt: Date(timeIntervalSince1970: 20),
                endedAt: Date(timeIntervalSince1970: 10)
            )
        }
    }

    @Test("Detail requires sorted unique speaker labels and ordered matching discontinuities")
    func detailInvariants() throws {
        let originID = try origin()
        let base = try summary(id: firstID, originID: originID)
        let speaker0 = try SpeakerLabel(speakerIndex: 0, displayName: "Alex")
        let speaker1 = try SpeakerLabel(speakerIndex: 1, displayName: "Sam")

        #expect(throws: DomainValidationError.self) {
            try LibraryRecordingDetail(summary: base, speakerLabels: [speaker1, speaker0])
        }
        #expect(throws: DomainValidationError.self) {
            try LibraryRecordingDetail(summary: base, speakerLabels: [speaker0, speaker0])
        }

        let later = try CaptureDiscontinuity(
            recordingID: originID,
            monotonicTimeNanoseconds: 20,
            wallTime: Date(timeIntervalSince1970: 20),
            reason: .interruptionEnded,
            affectedFrames: CanonicalFrameRange(startFrame: 20, endFrameExclusive: 20),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        let earlier = try CaptureDiscontinuity(
            recordingID: originID,
            monotonicTimeNanoseconds: 10,
            wallTime: Date(timeIntervalSince1970: 10),
            reason: .interruptionBegan,
            affectedFrames: CanonicalFrameRange(startFrame: 10, endFrameExclusive: 10),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        #expect(throws: DomainValidationError.self) {
            try LibraryRecordingDetail(summary: base, discontinuities: [later, earlier])
        }

        let detail = try LibraryRecordingDetail(
            summary: base,
            transcriptText: "Hello",
            speakerLabels: [speaker0, speaker1],
            notesMarkdown: "A note",
            discontinuities: [earlier, later]
        )
        #expect(detail.discontinuities.count == 2)
    }

    @Test("Encoded library views cannot expose local path fields")
    func pathFreeEncoding() throws {
        let detail = try LibraryRecordingDetail(
            summary: summary(id: firstID),
            transcriptText: "Portable transcript",
            speakerLabels: [SpeakerLabel(speakerIndex: 0, displayName: "Alex")]
        )
        let encoded = try JSONEncoder().encode(detail)
        let json = String(decoding: encoded, as: UTF8.self)

        for forbidden in [
            "wavPath", "wav_path", "txtPath", "txt_path", "jsonPath", "json_path",
            "audioPath", "audio_path", "fileURL", "file_url", "rowID", "row_id",
        ] {
            #expect(!json.contains(forbidden))
        }
        #expect(try JSONDecoder().decode(LibraryRecordingDetail.self, from: encoded) == detail)
    }

    @Test("Anchored snapshots require canonical order and disjoint identities")
    func snapshotInvariants() throws {
        let first = try summary(id: firstID)
        let second = try summary(id: secondID)
        let tombstone = try RecordingTombstone(
            canonicalID: secondID,
            revision: EntityRevision(2),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        #expect(throws: DomainValidationError.self) {
            try AnchoredLibrarySnapshot(
                libraryID: LibraryID.random(),
                anchor: .zero,
                recordings: [second, first],
                tombstones: []
            )
        }
        #expect(throws: DomainValidationError.self) {
            try AnchoredLibrarySnapshot(
                libraryID: LibraryID.random(),
                anchor: .zero,
                recordings: [first, second],
                tombstones: [tombstone]
            )
        }

        let valid = try AnchoredLibrarySnapshot(
            libraryID: LibraryID.random(),
            anchor: .zero,
            recordings: [first],
            tombstones: [tombstone]
        )
        #expect(try JSONDecoder().decode(
            AnchoredLibrarySnapshot.self,
            from: JSONEncoder().encode(valid)
        ) == valid)
    }

    @Test("Change descriptors use nonzero cursors and carry tombstone state")
    func changeDescriptor() throws {
        #expect(throws: DomainValidationError.self) {
            try LibraryChangeDescriptor(
                cursor: .zero,
                canonicalID: firstID,
                revision: .initial,
                operation: .upsert,
                changedAt: Date()
            )
        }
        let tombstone = try LibraryChangeDescriptor(
            cursor: ChangeCursor(1),
            canonicalID: firstID,
            revision: EntityRevision(2),
            operation: .tombstone,
            changedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        #expect(tombstone.isTombstone)
    }

    @Test("Compare-and-swap conflict retains the typed current value")
    func typedConflict() throws {
        #expect(throws: DomainValidationError.matchingConflictRevisions) {
            try RevisionConflict(
                canonicalID: firstID,
                expectedRevision: .initial,
                currentRevision: .initial,
                currentValue: "Host title"
            )
        }

        let conflict = try RevisionConflict(
            canonicalID: firstID,
            expectedRevision: .initial,
            currentRevision: EntityRevision(2),
            currentValue: "Host title"
        )
        let result: CompareAndSwapResult<String> = .conflict(conflict)
        #expect(result == .conflict(conflict))

        let applied = RevisionedValue(
            value: "Mine",
            revision: try EntityRevision(3),
            changeCursor: ChangeCursor(9)
        )
        #expect(CompareAndSwapResult.applied(applied) == .applied(applied))
    }
}
