import CryptoKit
import GRDB
import HarcDomain
import Foundation
import Testing
@testable import HarcStore
@testable import HarcUI

@Suite("People review mutation failures")
@MainActor
struct PersonDetailViewModelTests {
    @Test func manualCorrectionsReportStorageFailureAndOnlyCommitSuccess() async throws {
        let store = try await RecordingStore.inMemory()
        let source = try await store.createPerson(displayName: "Original")
        let target = try await store.createPerson(displayName: "Target")
        let vm = PersonDetailViewModel(store: store)
        await vm.load(personID: source)
        let db = await store.uncoordinatedDB
        try await db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_person_update BEFORE UPDATE ON people
                BEGIN SELECT RAISE(ABORT, 'injected update failure'); END
                """)
        }
        await vm.rename(to: "Failed rename")
        #expect(vm.mutationFailure?.action == .renameSpeaker)
        #expect(vm.person?.displayName == "Original")
        await vm.updateThreshold(0.9)
        #expect(vm.mutationFailure?.action == .updateSpeakerThreshold)
        #expect(vm.person?.matchThreshold == nil)
        #expect(try await store.fetchPeople().first(where: { $0.id == source })?.displayName == "Original")
        try await db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_person_update")
            try db.execute(sql: """
                CREATE TRIGGER reject_person_delete BEFORE DELETE ON people
                BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
                """)
        }
        #expect(await !vm.merge(into: target))
        #expect(vm.mutationFailure?.action == .mergePeople)
        #expect(try await store.fetchPeople().count == 2)
        #expect(await !vm.deleteWithFeedback())
        #expect(vm.mutationFailure?.action == .deletePerson)
        #expect(vm.person?.id == source)
        try await db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_person_delete")
            try db.execute(sql: """
                CREATE TRIGGER reject_person_insert BEFORE INSERT ON people
                BEGIN SELECT RAISE(ABORT, 'injected split failure'); END
                """)
        }
        #expect(await !vm.split(slots: [(123, 0)], newName: "Split"))
        #expect(vm.mutationFailure?.action == .splitSpeakerEvidence)
        #expect(try await store.fetchPeople().count == 2)
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_person_insert") }
        await vm.rename(to: "  Saved name  ")
        #expect(vm.mutationFailure == nil)
        #expect(vm.person?.displayName == "Saved name")
        await vm.updateThreshold(0.8)
        #expect(vm.mutationFailure == nil)
        #expect(vm.person?.matchThreshold == 0.8)
        #expect(try await store.fetchPeople().first(where: { $0.id == source })?.matchThreshold == 0.8)
        #expect(await vm.merge(into: target))
        #expect(vm.mutationFailure == nil)
        #expect(try await store.fetchPeople().map(\.id) == [target])
        await vm.load(personID: target)
        #expect(await vm.deleteWithFeedback())
        #expect(vm.mutationFailure == nil)
        #expect(try await store.fetchPeople().isEmpty)
    }

    @Test func publishedHostSuggestionUsesCapturedEvidenceAndRejectsFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harc-people-bound-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.inMemory()
        let queue = await store.uncoordinatedDB
        let recording = try await queue.write { db in
            let row = Recording(wavPath: root.appendingPathComponent("master.wav").path, startedAt: Date(),
                canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 1, count: 32)), canonicalPCMFrames: 96000)
            try row.insert(db)
            return try #require(try Recording.fetchOne(db, key: db.lastInsertedRowID))
        }
        let id = try #require(recording.id)
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let data = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"sample"}"#.utf8)
        let evidence = try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
            canonicalPCMHash: #require(recording.canonicalPCMHash), producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127, 0, 0]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "sample", modelID: "test", structuredTranscriptData: data)
        _ = try await store.retainSpeakerEvidence(evidence)
        try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.9)
        let vm = PersonDetailViewModel(store: store)
        await vm.load(personID: alice)
        let suggestionToConfirm = try #require(vm.pendingSuggestions.first)
        await vm.confirm(suggestionToConfirm)
        #expect(vm.mutationFailure != nil, "Unpublished evidence must not fall back to legacy enrollment")
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256) == nil)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id, speakerEvidence: [0: evidence.evidenceSHA256])
        await vm.load(personID: alice)
        let dismissedReview = try #require(vm.pendingSuggestions.first)
        try await store.dismissSuggestion(personID: alice, recordingID: id, speakerIndex: 0)
        await vm.confirm(dismissedReview)
        #expect(vm.mutationFailure != nil, "A dismissed proposal must invalidate its retained review")
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256) == nil)
        try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.9)
        await vm.load(personID: alice)
        let stale = try #require(vm.pendingSuggestions.first)
        try await store.linkSpeaker(personID: bob, recordingID: id, speakerIndex: 0)
        await vm.confirm(stale)
        #expect(vm.mutationFailure != nil)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == bob)
        try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.9)
        await vm.load(personID: alice)
        let freshSuggestion = try #require(vm.pendingSuggestions.first)
        await vm.confirm(freshSuggestion)
        #expect(vm.mutationFailure == nil)
        #expect(vm.pendingSuggestions.isEmpty)
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == alice)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == alice)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "Alice")
        try await store.insertPendingSuggestion(personID: bob, recordingID: id, speakerIndex: 0, score: 0.95)
        let inspectorSuggestions = try await store.fetchPendingSuggestionsForRecording(id)
        let inspectorReviews = await SpeakerSuggestionReviewBatch.load(inspectorSuggestions, store: store)
        let inspectorSuggestion = try #require(inspectorSuggestions.first)
        let needsLegacyLabel = try await inspectorReviews.confirm(inspectorSuggestion, store: store)
        #expect(!needsLegacyLabel, "Bound confirmation already commits the visible name")
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "Bob")
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == bob)
        do {
            try await inspectorReviews.confirm(inspectorSuggestion, store: store)
            Issue.record("The consumed review must not remain valid after the assignment changes")
        } catch { }
        let staleSlots = await SpeakerSlotReviewBatch.load(recordingID: id, indices: [0], store: store)
        try await store.linkSpeaker(personID: alice, recordingID: id, speakerIndex: 0)
        do {
            _ = try await staleSlots.unlink(recordingID: id, speakerIndex: 0, store: store)
            Issue.record("Stale unlink must not remove a newer correction")
        } catch { }
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == bob)
        let slots = await SpeakerSlotReviewBatch.load(recordingID: id, indices: [0], store: store)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_unlink_label BEFORE UPDATE OF speaker_names ON recordings
                BEGIN SELECT RAISE(ABORT, 'injected unlink failure'); END
                """)
        }
        do {
            _ = try await slots.unlink(recordingID: id, speakerIndex: 0, store: store)
            Issue.record("Failed label removal must roll back voice unenrollment")
        } catch { }
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == bob)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == alice)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_unlink_label") }
        let needsLegacyClear = try await slots.unlink(recordingID: id, speakerIndex: 0, store: store)
        #expect(!needsLegacyClear)
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256) == nil)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).isEmpty)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == nil)
        #expect(try await store.retainedSpeakerEvidence(sha256: evidence.evidenceSHA256) == evidence)
        do {
            try await store.unlinkSpeaker(recordingID: id, speakerIndex: 0)
            Issue.record("Legacy unlink must remain unavailable after withdrawing the last bound sample")
        } catch { }
        let relinkReview = await SpeakerSlotReviewBatch.load(recordingID: id, indices: [0], store: store)
        let needsLegacyMirror = try await relinkReview.link(personID: bob, recordingID: id, speakerIndex: 0, store: store)
        #expect(!needsLegacyMirror)
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == bob)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "Bob")
        do {
            _ = try await relinkReview.link(personID: alice, recordingID: id, speakerIndex: 0, store: store)
            Issue.record("A stale picker action must not overwrite the newly linked person")
        } catch { }
        do {
            _ = try await relinkReview.createPerson(displayName: "Stale", recordingID: id, speakerIndex: 0, store: store)
            Issue.record("A stale create action must not leave an orphan person")
        } catch { }
        #expect(try await store.fetchPeople().count == 2)
        let createReview = await SpeakerSlotReviewBatch.load(recordingID: id, indices: [0], store: store)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_create_label BEFORE UPDATE OF speaker_names ON recordings
                BEGIN SELECT RAISE(ABORT, 'injected create failure'); END
                """)
        }
        do {
            _ = try await createReview.createPerson(displayName: "Carol", recordingID: id, speakerIndex: 0, store: store)
            Issue.record("A failed label write must roll back person creation and enrollment")
        } catch { }
        #expect(try await store.fetchPeople().count == 2)
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == bob)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_create_label") }
        let created = try await createReview.createPerson(displayName: " Carol ", recordingID: id, speakerIndex: 0, store: store)
        #expect(!created.needsLegacyLabel)
        #expect(try await store.fetchPeople().count == 3)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "Carol")
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == created.personID)
        #expect(try await store.speakerEvidenceAssignment(sha256: evidence.evidenceSHA256)?.personID == created.personID)
        let splitVM = PersonDetailViewModel(store: store)
        await splitVM.load(personID: created.personID)
        #expect(splitVM.enrolledEvidence.count == 1)
        await splitVM.splitEvidence(ids: [Data(repeating: 99, count: 32)], newName: "Invalid split")
        #expect(splitVM.mutationFailure?.action == .splitSpeakerEvidence)
        #expect(try await store.fetchPeople().count == 3)
        await splitVM.splitEvidence(ids: [evidence.evidenceSHA256], newName: "Reviewed split")
        #expect(splitVM.mutationFailure == nil)
        #expect(splitVM.enrolledEvidence.isEmpty)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "Reviewed split")
    }

    @Test func legacyPersonCreationRollsBackAndCommitsNameWithLink() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(wavPath: "/tmp/legacy-create-review.wav", startedAt: Date()))
        let id = try #require(recording.id)
        let review = await SpeakerSlotReviewBatch.load(recordingID: id, indices: [0], store: store)
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_legacy_create BEFORE UPDATE OF speaker_names ON recordings
                BEGIN SELECT RAISE(ABORT, 'injected legacy failure'); END
                """)
        }
        do {
            _ = try await review.createPerson(displayName: "New person", recordingID: id, speakerIndex: 0, store: store)
            Issue.record("Legacy creation must also roll back on a label failure")
        } catch { }
        #expect(try await store.fetchPeople().isEmpty)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).isEmpty)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_legacy_create") }
        let created = try await review.createPerson(displayName: "New person", recordingID: id, speakerIndex: 0, store: store)
        #expect(!created.needsLegacyLabel)
        #expect(try await store.fetch(id: id)?.speakerNames[0] == "New person")
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == created.personID)
    }

    @Test func staleConfirmationIsVisibleAndDoesNotOverwriteCorrection() async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let recording = try await store.upsert(Recording(wavPath: "/tmp/person-review.wav", startedAt: Date()))
        let id = try #require(recording.id)
        try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.9)
        let vm = PersonDetailViewModel(store: store)
        await vm.load(personID: alice)
        let stale = try #require(vm.pendingSuggestions.first)
        try await store.linkSpeaker(personID: bob, recordingID: id, speakerIndex: 0)
        await vm.confirm(stale)
        #expect(vm.mutationFailure?.action == .confirmSpeakerSuggestion)
        #expect(vm.pendingSuggestions.isEmpty)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == bob)
        try await store.unlinkSpeaker(recordingID: id, speakerIndex: 0)
        try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.9)
        await vm.load(personID: alice)
        let fresh = try #require(vm.pendingSuggestions.first)
        await vm.confirm(fresh)
        #expect(vm.mutationFailure == nil)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == alice)
    }

    @Test(arguments: [0, 1])
    func confirmAllStopsAtFailureAndRefreshesRemainingSuggestions(failureIndex: Int) async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        var ids: [Int64] = []
        for index in 0..<3 {
            let row = try await store.upsert(Recording(wavPath: "/tmp/person-review-batch-\(index).wav", startedAt: Date()))
            let id = try #require(row.id); ids.append(id)
            try await store.insertPendingSuggestion(personID: alice, recordingID: id, speakerIndex: 0, score: 0.99 - Double(index) * 0.1)
        }
        let vm = PersonDetailViewModel(store: store)
        await vm.load(personID: alice)
        try await store.linkSpeaker(personID: bob, recordingID: ids[failureIndex], speakerIndex: 0)
        await vm.confirmAll()
        #expect(vm.mutationFailure?.action == .confirmSpeakerSuggestion)
        #expect(vm.pendingSuggestions.map(\.recordingID) == Array(ids[(failureIndex + 1)...]))
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: ids[failureIndex]).first?.personID == bob)
        for id in ids.prefix(failureIndex) {
            #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).first?.personID == alice)
        }
        for id in ids.suffix(from: failureIndex + 1) {
            #expect(try await store.fetchPersonSpeakerLinks(recordingID: id).isEmpty)
        }
    }
}
