import CryptoKit
import Foundation
import XCTest
import GRDB
import HarcDomain
@testable import HarcStore

final class SpeakerEvidenceStoreTests: XCTestCase {
    private func evidence(_ recording: Recording, voice: UInt8 = 127, artifact: UInt8 = 3) throws -> SpeakerEvidenceSnapshot {
        try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
            canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash),
            producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(repeating: artifact, count: 32), localClusterID: "cluster-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([voice, 1, 0]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 2)
    }
    private func seed(_ store: RecordingStore, wavPath: String = "/tmp/evidence-master.wav") async throws -> Recording {
        // Seed canonical metadata directly: ordinary upsert intentionally rehashes
        // a real WAV and cannot establish an absent fixture's canonical identity.
        let queue = await store.uncoordinatedDB
        return try await queue.write { db in
            let recording = Recording(wavPath: wavPath, startedAt: Date(),
                canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 1, count: 32)), canonicalPCMFrames: 160_000)
            try recording.insert(db)
            return try XCTUnwrap(Recording.fetchOne(db, key: db.lastInsertedRowID))
        }
    }

    func test_hostOutcomeReviewUsesCompareAndSwapAndCurrentPack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: dbURL)
        let target = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
        let id = try XCTUnwrap(target.id)
        let source = try DeviceID(Data(repeating: 8, count: 32))
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [source.rawBytes, UUID().uuidString.lowercased(), id])
        }
        let data = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":6000}]}"#.utf8)
        let voice = try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127,0,0]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "hello",
            modelID: "test", structuredTranscriptData: data)
        _ = try await store.retainSpeakerEvidence(voice)
        _ = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
            expectedArtifactSHA256: voice.processingArtifactSHA256, speakerEvidence: [0: voice.evidenceSHA256])
        func observe(job: HostSpeakerReviewJob? = nil) async throws -> SpeakerObservationDecision {
            let request = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: target.canonicalID,
                speakerIndex: 0, embedding: voice.embedding, modelID: voice.modelID,
                speechDurationMs: voice.speechDurationMs, segmentCount: voice.segmentCount)
            if let job {
                return try await store.submitHostSpeakerReviewObservation(request, from: source,
                    expectedEvidenceSHA256: voice.evidenceSHA256, job: job,
                    expectedPackRevision: (try await store.publishedSpeakerRecognitionPack()).revision)
            }
            return try await store.submitSpeakerObservation(request, from: source,
                expectedEvidenceSHA256: voice.evidenceSHA256)
        }
        func outcome(_ decision: SpeakerObservationDecision) throws -> HostSpeakerProcessingOutcome {
            try HostSpeakerProcessingOutcome(canonicalRecordingID: target.canonicalID,
                canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: voice.producerDeviceID,
                processingArtifactSHA256: voice.processingArtifactSHA256, diarization: .completed,
                clusters: [.init(speakerIndex: 0, evidenceSHA256: voice.evidenceSHA256,
                    decisionOperationID: decision.operationID, disposition: decision.disposition,
                    recognitionPackRevision: decision.recognitionPackRevision)])
        }
        let first = try await observe()
        let original = try outcome(first)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
            speakerEvidence: [0: voice.evidenceSHA256], speakerOutcome: original, structuredTranscriptData: data)
        let reviewTime = Date(timeIntervalSince1970: 1000)
        let queued = try await store.enqueueHostSpeakerReview(recordingID: id, expected: original, notBefore: reviewTime)
        let job = try XCTUnwrap(queued)
        let deferred = try await store.deferHostSpeakerReview(job, afterFailureAt: reviewTime)
        XCTAssertTrue(deferred)
        let duplicateFailure = try await store.deferHostSpeakerReview(job, afterFailureAt: reviewTime)
        XCTAssertFalse(duplicateFailure)
        let reopenedQueue = try await RecordingStore.onDisk(url: dbURL)
        let premature = try await reopenedQueue.dueHostSpeakerReviews(at: reviewTime)
        XCTAssertTrue(premature.isEmpty)
        let due = try await reopenedQueue.dueHostSpeakerReviews(at: reviewTime.addingTimeInterval(5))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.id, job.id)
        XCTAssertEqual(due.first?.failureCount, 1)
        let reenqueued = try await reopenedQueue.enqueueHostSpeakerReview(recordingID: id,
            expected: original, notBefore: reviewTime.addingTimeInterval(-10))
        XCTAssertEqual(reenqueued, due.first)
        do {
            _ = try await observe(job: job)
            XCTFail("An old retry snapshot cannot evaluate after backoff changes")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let earlyObservation = try SpeakerEmbeddingObservation(operationID: .random(),
            canonicalRecordingID: target.canonicalID, speakerIndex: 0, embedding: voice.embedding,
            modelID: voice.modelID, speechDurationMs: voice.speechDurationMs, segmentCount: voice.segmentCount)
        do {
            _ = try await store.submitHostSpeakerReviewObservation(earlyObservation, from: source,
                expectedEvidenceSHA256: voice.evidenceSHA256, job: XCTUnwrap(due.first),
                expectedPackRevision: (try await store.publishedSpeakerRecognitionPack()).revision, at: reviewTime)
            XCTFail("Review admission must honor the persisted retry deadline")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let staleReview = try outcome(try await observe())
        _ = try await store.createPerson(displayName: "New enrollment revision")
        do {
            _ = try await store.replaceHostSpeakerProcessingOutcome(recordingID: id,
                expected: original, replacement: staleReview)
            XCTFail("An outdated pack must not complete a fresh review")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let second = try await observe(job: XCTUnwrap(due.first))
        let refreshed = try outcome(second)
        let wrongProducer = try HostSpeakerProcessingOutcome(
            canonicalRecordingID: refreshed.canonicalRecordingID,
            canonicalPCMHash: refreshed.canonicalPCMHash,
            producerDeviceID: DeviceID(Data(repeating: 9, count: 32)),
            processingArtifactSHA256: refreshed.processingArtifactSHA256,
            diarization: refreshed.diarization, clusters: refreshed.clusters)
        do {
            _ = try await store.replaceHostSpeakerProcessingOutcome(recordingID: id,
                expected: original, replacement: wrongProducer)
            XCTFail("A review cannot change the Host producer")
        } catch { XCTAssertNotNil(error as? StoreError) }
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_outcome_review BEFORE UPDATE ON host_speaker_processing_outcome
                BEGIN SELECT RAISE(ABORT, 'injected review failure'); END
                """)
        }
        do {
            _ = try await store.replaceHostSpeakerProcessingOutcome(recordingID: id,
                expected: original, replacement: refreshed)
            XCTFail("A failed write must preserve the old outcome")
        } catch { }
        let afterFailure = try await store.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertEqual(afterFailure, original)
        let queueAfterFailure = try await store.dueHostSpeakerReviews(at: reviewTime.addingTimeInterval(10))
        XCTAssertEqual(queueAfterFailure, due)
        try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_outcome_review") }
        let installed = try await store.replaceHostSpeakerProcessingOutcome(recordingID: id,
            expected: original, replacement: refreshed)
        XCTAssertTrue(installed)
        let queueAfterCommit = try await store.dueHostSpeakerReviews(at: reviewTime.addingTimeInterval(10))
        XCTAssertTrue(queueAfterCommit.isEmpty)
        for operation in [second.operationID, OperationID.random()] {
            let staleObservation = try SpeakerEmbeddingObservation(operationID: operation,
                canonicalRecordingID: target.canonicalID, speakerIndex: 0, embedding: voice.embedding,
                modelID: voice.modelID, speechDurationMs: voice.speechDurationMs, segmentCount: voice.segmentCount)
            do {
                _ = try await store.submitHostSpeakerReviewObservation(staleObservation, from: source,
                    expectedEvidenceSHA256: voice.evidenceSHA256, job: XCTUnwrap(due.first),
                    expectedPackRevision: (try await store.publishedSpeakerRecognitionPack()).revision)
                XCTFail("A superseded worker cannot name a voice or replay as current review work")
            } catch { XCTAssertNotNil(error as? StoreError) }
        }
        let oldWorker = try await store.deferHostSpeakerReview(try XCTUnwrap(due.first), afterFailureAt: reviewTime)
        XCTAssertFalse(oldWorker)
        let staleWriter = try await store.replaceHostSpeakerProcessingOutcome(recordingID: id,
            expected: original, replacement: staleReview)
        XCTAssertFalse(staleWriter)
        let reopened = try await RecordingStore.onDisk(url: dbURL)
        let retained = try await reopened.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertEqual(retained, refreshed)
        let fetchedRecording = try await reopened.fetch(id: id)
        let recording = try XCTUnwrap(fetchedRecording)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(recording.jsonPath))), data)
        let historical = try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT result_json FROM speaker_embedding_observations WHERE operation_uuid = ?",
                arguments: [first.operationID.description])
        }
        XCTAssertEqual(try JSONDecoder().decode(SpeakerObservationDecision.self, from: XCTUnwrap(historical)), first)
        let nextReview = try await reopened.enqueueHostSpeakerReview(recordingID: id,
            expected: refreshed, notBefore: reviewTime.addingTimeInterval(100))
        XCTAssertNotNil(nextReview)
        do {
            _ = try await observe(job: XCTUnwrap(due.first))
            XCTFail("A replacement queue job cannot authorize an old worker")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let reference = try await seed(store, wavPath: root.appendingPathComponent("independent-reference.wav").path)
        let person = try await store.createPerson(displayName: "Independent voice")
        let enrollment = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(enrollment)
        try await store.confirmSpeakerEvidence(sha256: enrollment.evidenceSHA256, personID: person)
        // Rechecking a confirmed target must not republish unchanged enrollment.
        // The independent reference above still supplies matching evidence;
        // the target's own confirmation must not corroborate its identity.
        let targetReviewValue = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        try await store.confirmHostSpeakerReview(XCTUnwrap(targetReviewValue), personID: person)
        let executionJob = try XCTUnwrap(nextReview)
        let executionTime = Date()
        let executionRevision = try await store.publishedSpeakerRecognitionPack(at: executionTime).revision
        let executionOperation = RecordingStore.hostSpeakerReviewOperation(jobID: executionJob.id,
            evidenceSHA256: voice.evidenceSHA256, packRevision: executionRevision)
        let decisionCountBeforeFailure = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations WHERE canonical_recording_uuid = ?",
                arguments: [target.canonicalID.description])
        }
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER interrupt_review_completion BEFORE UPDATE ON host_speaker_processing_outcome
                BEGIN SELECT RAISE(ABORT, 'after decision before completion'); END
                """)
        }
        do {
            _ = try await store.performHostSpeakerReview(executionJob, at: executionTime)
            XCTFail("Injected completion failure must leave the job retryable")
        } catch {
            XCTAssertTrue(String(describing: error).contains("after decision before completion"),
                "The test must reach the injected completion failure, not fail earlier: \(error)")
        }
        let decisionCountAfterFailure = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations WHERE canonical_recording_uuid = ?",
                arguments: [target.canonicalID.description])
        }
        let unchangedOutcome = try await store.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertEqual(unchangedOutcome, refreshed)
        XCTAssertEqual(try XCTUnwrap(decisionCountAfterFailure), try XCTUnwrap(decisionCountBeforeFailure) + 1)
        let persistedExecutionBytes = try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT result_json FROM speaker_embedding_observations WHERE operation_uuid = ?",
                arguments: [executionOperation.description])
        }
        let persistedExecution = try JSONDecoder().decode(SpeakerObservationDecision.self,
            from: XCTUnwrap(persistedExecutionBytes))
        XCTAssertEqual(persistedExecution.disposition, .matched)
        XCTAssertEqual(persistedExecution.recognitionPackRevision, executionRevision)
        let revisionAfterFailure = try await store.publishedSpeakerRecognitionPack(at: executionTime).revision
        XCTAssertEqual(revisionAfterFailure, executionRevision)
        try await queue.write { db in try db.execute(sql: "DROP TRIGGER interrupt_review_completion") }
        let retryStore = try await RecordingStore.onDisk(url: dbURL)
        let resumedJobs = try await retryStore.dueHostSpeakerReviews(at: executionTime)
        XCTAssertEqual(resumedJobs, [executionJob])
        let executed = try await retryStore.performHostSpeakerReview(executionJob, at: executionTime)
        XCTAssertTrue(executed)
        let decisionCountAfterRetry = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations WHERE canonical_recording_uuid = ?",
                arguments: [target.canonicalID.description])
        }
        XCTAssertEqual(decisionCountAfterRetry, decisionCountAfterFailure)
        let reviewedValue = try await retryStore.hostSpeakerProcessingOutcome(recordingID: id)
        let reviewed = try XCTUnwrap(reviewedValue)
        XCTAssertEqual(reviewed.clusters.first?.disposition, .matched)
        XCTAssertEqual(reviewed.clusters.first?.decisionOperationID, executionOperation)
        XCTAssertNotEqual(reviewed.clusters.first?.decisionOperationID, refreshed.clusters.first?.decisionOperationID)
        let revisionAfterRetry = try await retryStore.publishedSpeakerRecognitionPack(at: executionTime).revision
        XCTAssertEqual(revisionAfterRetry, executionRevision)
        _ = try await retryStore.enqueueHostSpeakerReview(recordingID: id, expected: reviewed, notBefore: reviewTime)
        try await reopened.updateProcessing(id: id, descriptor: .pending)
        let afterReprocessing = try await reopened.dueHostSpeakerReviews(at: reviewTime.addingTimeInterval(200))
        XCTAssertTrue(afterReprocessing.isEmpty)
        let remainingJobs = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host_speaker_review_queue WHERE recording_id = ?",
                arguments: [id])
        }
        XCTAssertEqual(remainingJobs, 0)
        let invalidated = try await reopened.replaceHostSpeakerProcessingOutcome(recordingID: id,
            expected: refreshed, replacement: refreshed)
        XCTAssertFalse(invalidated)
    }

    func test_hostOutcomeRequiresExactDecisionProvenanceAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: dbURL)
        let target = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
        let id = try XCTUnwrap(target.id)
        let source = try DeviceID(Data(repeating: 8, count: 32))
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [source.rawBytes, UUID().uuidString.lowercased(), id])
        }
        let data = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":6000}]}"#.utf8)
        let voice = try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127,0,0]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "hello",
            modelID: "test", structuredTranscriptData: data)
        _ = try await store.retainSpeakerEvidence(voice)
        _ = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
            expectedArtifactSHA256: voice.processingArtifactSHA256, speakerEvidence: [0: voice.evidenceSHA256])
        let observation = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: target.canonicalID,
            speakerIndex: 0, embedding: voice.embedding, modelID: voice.modelID,
            speechDurationMs: voice.speechDurationMs, segmentCount: voice.segmentCount)
        func makeOutcome(_ decision: SpeakerObservationDecision? = nil) throws -> HostSpeakerProcessingOutcome {
            try HostSpeakerProcessingOutcome(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: voice.producerDeviceID,
            processingArtifactSHA256: voice.processingArtifactSHA256, diarization: .completed,
            clusters: [HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0,
                evidenceSHA256: voice.evidenceSHA256, decisionOperationID: observation.operationID,
                disposition: decision?.disposition ?? .noMatch,
                recognitionPackRevision: decision?.recognitionPackRevision ?? EntityRevision(1))])
        }
        var outcome = try makeOutcome()
        do {
            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                speakerEvidence: [0: voice.evidenceSHA256], speakerOutcome: outcome, structuredTranscriptData: data)
            XCTFail("An unevaluated embedding must not complete identification work")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let decision = try await store.submitSpeakerObservation(observation, from: source,
            expectedEvidenceSHA256: voice.evidenceSHA256)
        XCTAssertNotEqual(decision.disposition, .matched, "No person is enrolled in this fixture")
        outcome = try makeOutcome(decision)
        for (disposition, revision) in [(SpeakerObservationDisposition.matched, decision.recognitionPackRevision),
            (decision.disposition, try EntityRevision(decision.recognitionPackRevision.rawValue + 1))] {
            let forged = try HostSpeakerProcessingOutcome(canonicalRecordingID: outcome.canonicalRecordingID,
                canonicalPCMHash: outcome.canonicalPCMHash, producerDeviceID: outcome.producerDeviceID,
                processingArtifactSHA256: outcome.processingArtifactSHA256, diarization: .completed,
                clusters: [.init(speakerIndex: 0, evidenceSHA256: voice.evidenceSHA256,
                    decisionOperationID: observation.operationID, disposition: disposition, recognitionPackRevision: revision)])
            do {
                _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                    speakerEvidence: [0: voice.evidenceSHA256], speakerOutcome: forged, structuredTranscriptData: data)
                XCTFail("An outcome cannot upgrade a persisted nonmatch or change its recognition revision")
            } catch { XCTAssertNotNil(error as? StoreError) }
        }
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
            speakerEvidence: [0: voice.evidenceSHA256], speakerOutcome: outcome, structuredTranscriptData: data)
        let reopened = try await RecordingStore.onDisk(url: dbURL)
        let retained = try await reopened.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertEqual(retained, outcome)
        let replay = try await reopened.submitSpeakerObservation(observation, from: source,
            expectedEvidenceSHA256: voice.evidenceSHA256)
        XCTAssertEqual(replay, decision)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM host_speaker_decision_provenance WHERE operation_uuid = ?",
                arguments: [observation.operationID.description])
        }
        do {
            _ = try await reopened.hostSpeakerProcessingOutcome(recordingID: id)
            XCTFail("A receipt must fail closed after decision provenance is lost")
        } catch { XCTAssertNotNil(error as? StoreError) }
        do {
            _ = try await reopened.submitSpeakerObservation(observation, from: source,
                expectedEvidenceSHA256: voice.evidenceSHA256)
            XCTFail("A legacy or damaged decision cannot be backfilled as a bound replay")
        } catch { XCTAssertNotNil(error as? StoreError) }
        try await reopened.updateProcessing(id: id, descriptor: .pending)
        let invalidated = try await reopened.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertNil(invalidated)
        // Even restoring generic readiness cannot recreate a deleted receipt.
        try await reopened.updateProcessing(id: id, descriptor: .ready)
        let absent = try await reopened.hostSpeakerProcessingOutcome(recordingID: id)
        XCTAssertNil(absent)
    }

    func test_selectedEdgeObservationMapsClientHintAndRejectsStaleReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let reference = try await seed(store, wavPath: root.appendingPathComponent("reference.wav").path)
        let target = try await seed(store, wavPath: root.appendingPathComponent("target.wav").path)
        let id = try XCTUnwrap(target.id)
        let person = try await store.createPerson(displayName: "Reference voice")
        let enrollment = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(enrollment)
        try await store.confirmSpeakerEvidence(sha256: enrollment.evidenceSHA256, personID: person)
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [enrollment.producerDeviceID.rawBytes, UUID().uuidString.lowercased(), id])
        }
        let snapshot = try evidence(target)
        let map = try SpeakerClusterMap(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: snapshot.producerDeviceID,
            processingArtifactSHA256: snapshot.processingArtifactSHA256, localClusterIDs: [snapshot.localClusterID])
        let data = try JSONSerialization.data(withJSONObject: ["joinedText": "mapped",
            "speakerClusterMapSHA256": map.mappingSHA256.base64EncodedString()], options: [.sortedKeys])
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "mapped", modelID: "edge",
            structuredTranscriptData: data, clusterMap: map)
        let operationID = OperationID(UUID())
        func request(index: UInt32) throws -> BoundSpeakerEmbeddingObservation {
            try BoundSpeakerEmbeddingObservation(observation: SpeakerEmbeddingObservation(
                operationID: operationID, canonicalRecordingID: target.canonicalID, speakerIndex: index,
                embedding: snapshot.embedding, modelID: snapshot.modelID,
                speechDurationMs: snapshot.speechDurationMs, segmentCount: snapshot.segmentCount), evidence: snapshot)
        }
        let original = try request(index: 99)
        // An observation journal failure must roll back the projected name too.
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_edge_decision BEFORE INSERT ON bound_speaker_observation_provenance
                BEGIN SELECT RAISE(ABORT, 'injected decision failure'); END
                """)
        }
        do {
            _ = try await store.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
                from: snapshot.producerDeviceID)
            XCTFail("Decision failure must roll back naming")
        } catch {}
        let failed = try await store.fetch(id: id)
        XCTAssertTrue(failed?.speakerNames.isEmpty == true)
        let rolledBackEvidence = try await store.retainedSpeakerEvidence(sha256: snapshot.evidenceSHA256)
        XCTAssertNil(rolledBackEvidence)
        let rolledBackDecisions = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations WHERE operation_uuid = ?",
                arguments: [operationID.description])
        }
        XCTAssertEqual(rolledBackDecisions, 0)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_edge_decision") }
        let decision = try await store.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
            from: snapshot.producerDeviceID)
        XCTAssertEqual(decision.disposition, .matched)
        let named = try await store.fetch(id: id)
        XCTAssertEqual(named?.speakerNames[0], "Reference voice")
        XCTAssertNil(named?.speakerNames[99])
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let replay = try await reopened.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
            from: snapshot.producerDeviceID)
        XCTAssertEqual(replay, decision)
        let retained = try await reopened.retainedSpeakerEvidence(sha256: snapshot.evidenceSHA256)
        XCTAssertEqual(retained, snapshot)
        let savedRequest = try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT request_json FROM bound_speaker_observation_provenance WHERE operation_uuid = ?",
                arguments: [operationID.description])
        }
        let originalBytes = try XCTUnwrap(savedRequest)
        XCTAssertEqual(try JSONDecoder().decode(BoundSpeakerEmbeddingObservation.self, from: originalBytes), original)
        do {
            try await queue.write { db in
                try db.execute(sql: "UPDATE bound_speaker_observation_provenance SET request_json = ? WHERE operation_uuid = ?",
                    arguments: [Data("changed".utf8), operationID.description])
            }
            XCTFail("Ordinary writes must not alter decision provenance")
        } catch {}
        // Simulate storage corruption only in this disposable database, after
        // verifying normal SQL cannot bypass the immutable journal.
        try await queue.write { db in
            try db.execute(sql: "DROP TRIGGER bound_speaker_observation_provenance_no_update")
            try db.execute(sql: "UPDATE bound_speaker_observation_provenance SET request_json = ? WHERE operation_uuid = ?",
                arguments: [Data("changed".utf8), operationID.description])
        }
        do {
            _ = try await reopened.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
                from: snapshot.producerDeviceID)
            XCTFail("Corrupt retained provenance must reject an otherwise exact replay")
        } catch {}
        try await queue.write { db in
            try db.execute(sql: "UPDATE bound_speaker_observation_provenance SET request_json = ? WHERE operation_uuid = ?",
                arguments: [originalBytes, operationID.description])
        }
        let savedSnapshot = try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
                arguments: [snapshot.evidenceSHA256])
        }
        let snapshotBytes = try XCTUnwrap(savedSnapshot)
        do {
            try await queue.write { db in
                try db.execute(sql: "UPDATE speaker_evidence_snapshots SET snapshot_json = ? WHERE evidence_sha256 = ?",
                    arguments: [Data("changed".utf8), snapshot.evidenceSHA256])
            }
            XCTFail("Ordinary writes must not alter retained voice evidence")
        } catch {}
        try await queue.write { db in
            try db.execute(sql: "DROP TRIGGER speaker_evidence_snapshots_no_update")
            try db.execute(sql: "UPDATE speaker_evidence_snapshots SET snapshot_json = ? WHERE evidence_sha256 = ?",
                arguments: [Data("changed".utf8), snapshot.evidenceSHA256])
        }
        do {
            _ = try await reopened.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
                from: snapshot.producerDeviceID)
            XCTFail("Corrupt retained voice sample must reject replay")
        } catch {}
        try await queue.write { db in
            try db.execute(sql: "UPDATE speaker_evidence_snapshots SET snapshot_json = ? WHERE evidence_sha256 = ?",
                arguments: [snapshotBytes, snapshot.evidenceSHA256])
        }
        do {
            _ = try await reopened.submitSelectedEdgeSpeakerObservation(request(index: 98), validatedClusterMap: map,
                from: snapshot.producerDeviceID)
            XCTFail("Changed original hint must not become an exact replay after mapping")
        } catch {}
        do {
            _ = try await reopened.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
                from: DeviceID(Data(repeating: 9, count: 32)))
            XCTFail("Different authenticated producer must not replay a naming decision")
        } catch {}
        let replacementMap = try SpeakerClusterMap(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: snapshot.producerDeviceID,
            processingArtifactSHA256: Data(repeating: 4, count: 32), localClusterIDs: [snapshot.localClusterID])
        let replacementData = try JSONSerialization.data(withJSONObject: ["joinedText": "replacement",
            "speakerClusterMapSHA256": replacementMap.mappingSHA256.base64EncodedString()], options: [.sortedKeys])
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "replacement", modelID: "edge",
            structuredTranscriptData: replacementData, clusterMap: replacementMap)
        do {
            _ = try await reopened.submitSelectedEdgeSpeakerObservation(original, validatedClusterMap: map,
                from: snapshot.producerDeviceID)
            XCTFail("Replaced selection must reject even an exact original replay")
        } catch {}
        let replaced = try await store.fetch(id: id)
        XCTAssertTrue(replaced?.speakerNames.isEmpty == true)
        let historical = try await reopened.retainedSpeakerEvidence(sha256: snapshot.evidenceSHA256)
        XCTAssertEqual(historical, snapshot)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [id])
        }
        let purged = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bound_speaker_observation_provenance WHERE operation_uuid = ?",
                arguments: [operationID.description])
        }
        XCTAssertEqual(purged, 0)
    }

    func test_edgeVoiceReviewReplacementPreservesOtherSpeakerAndHistoricalEnrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let reference = try await seed(store, wavPath: root.appendingPathComponent("reference.wav").path)
        let target = try await seed(store, wavPath: root.appendingPathComponent("target.wav").path)
        let id = try XCTUnwrap(target.id)
        let person = try await store.createPerson(displayName: "Original voice")
        let enrollment = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(enrollment)
        try await store.confirmSpeakerEvidence(sha256: enrollment.evidenceSHA256, personID: person)
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [enrollment.producerDeviceID.rawBytes, UUID().uuidString.lowercased(), id])
        }
        let map = try SpeakerClusterMap(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: enrollment.producerDeviceID,
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterIDs: ["cluster-0", "cluster-1"])
        let data = try JSONSerialization.data(withJSONObject: ["joinedText": "two voices",
            "speakerClusterMapSHA256": map.mappingSHA256.base64EncodedString()], options: [.sortedKeys])
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "two voices", modelID: "edge",
            structuredTranscriptData: data, clusterMap: map)
        do {
            _ = try await store.hostSpeakerReviewForEditing(recordingID: id, speakerIndex: 0)
            XCTFail("A selected edge map without evidence must not fall back to legacy editing")
        } catch {}
        func request(cluster: String, values: Data) throws -> BoundSpeakerEmbeddingObservation {
            let snapshot = try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
                canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: enrollment.producerDeviceID,
                processingArtifactSHA256: map.processingArtifactSHA256, localClusterID: cluster,
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: values, scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 2)
            return try BoundSpeakerEmbeddingObservation(observation: SpeakerEmbeddingObservation(
                operationID: OperationID(UUID()), canonicalRecordingID: target.canonicalID, speakerIndex: 99,
                embedding: snapshot.embedding, modelID: snapshot.modelID, speechDurationMs: 6000, segmentCount: 2),
                evidence: snapshot)
        }
        let first = try request(cluster: "cluster-0", values: Data([127,1,0]))
        let other = try request(cluster: "cluster-1", values: Data([127,1,0]))
        for value in [first, other] {
            _ = try await store.submitSelectedEdgeSpeakerObservation(value, validatedClusterMap: map,
                from: enrollment.producerDeviceID)
        }
        let fetchedReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        let review = try XCTUnwrap(fetchedReview)
        XCTAssertEqual(review.evidence, first.evidence)
        try await store.confirmHostSpeakerReview(review, personID: person)
        let confirmedReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        let confirmed = try XCTUnwrap(confirmedReview)
        let replacement = try request(cluster: "cluster-0", values: Data([0,0,127]))
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_edge_archive BEFORE INSERT ON speaker_assignment_history
                BEGIN SELECT RAISE(ABORT, 'injected archive failure'); END
                """)
        }
        do {
            _ = try await store.submitSelectedEdgeSpeakerObservation(replacement, validatedClusterMap: map,
                from: enrollment.producerDeviceID)
            XCTFail("Assignment history failure must roll back voice replacement")
        } catch {}
        let unchanged = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(unchanged, confirmed)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_edge_archive") }
        let result = try await store.submitSelectedEdgeSpeakerObservation(replacement, validatedClusterMap: map,
            from: enrollment.producerDeviceID)
        XCTAssertEqual(result.disposition, .noMatch)
        let replaced = try await store.fetch(id: id)
        XCTAssertNil(replaced?.speakerNames[0])
        XCTAssertEqual(replaced?.speakerNames[1], "Original voice")
        let otherReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 1)
        XCTAssertEqual(otherReview?.evidence, other.evidence)
        do {
            try await store.confirmHostSpeakerReview(confirmed, personID: person)
            XCTFail("Old review must not enroll the replacement voice")
        } catch {}
        do {
            _ = try await store.submitSelectedEdgeSpeakerObservation(first, validatedClusterMap: map,
                from: enrollment.producerDeviceID)
            XCTFail("Old operation cannot replay after voice evidence changes within the same artifact")
        } catch {}
        let oldSelection = try await store.speakerEvidenceAssignment(sha256: first.evidence.evidenceSHA256)
        XCTAssertEqual(oldSelection?.personID, person)
        let unconfirmed = try await store.speakerEvidenceAssignment(sha256: replacement.evidence.evidenceSHA256)
        XCTAssertNil(unconfirmed)
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let currentReview = try await reopened.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        let current = try XCTUnwrap(currentReview)
        XCTAssertEqual(current.evidence, replacement.evidence)
        let newPerson = try await reopened.createPersonForHostSpeakerReview(current, displayName: "Replacement voice")
        let selected = try await reopened.speakerEvidenceAssignment(sha256: replacement.evidence.evidenceSHA256)
        XCTAssertEqual(selected?.personID, newPerson)
        let corrected = try await reopened.fetch(id: id)
        XCTAssertEqual(corrected?.speakerNames[0], "Replacement voice")
        XCTAssertEqual(corrected?.speakerNames[1], "Original voice")
    }

    func test_selectedArtifactSourceCommitsAtomicallyAndRejectsChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let recording = try await seed(store, wavPath: root.appendingPathComponent("audio.wav").path)
        let id = try XCTUnwrap(recording.id)
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [producer.rawBytes, UUID().uuidString.lowercased(), id])
        }
        // Storage-only fixture. Signature authentication belongs to Host tests.
        let metadata = Data("metadata fixture".utf8), bundle = Data("bundle fixture".utf8)
        let metadataURL = root.appendingPathComponent("artifact.harcso")
        let bundleURL = root.appendingPathComponent("artifact.harcpb")
        try metadata.write(to: metadataURL)
        try bundle.write(to: bundleURL)
        let source = try SelectedEdgeArtifactSource(signedMetadataURL: metadataURL, bundleURL: bundleURL,
            signedMetadataSHA256: Data(SHA256.hash(data: metadata)), bundleSHA256: Data(SHA256.hash(data: bundle)))
        let map = try SpeakerClusterMap(canonicalRecordingID: recording.canonicalID,
            canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash), producerDeviceID: producer,
            processingArtifactSHA256: source.bundleSHA256, localClusterIDs: [])
        let data = try JSONSerialization.data(withJSONObject: ["joinedText": "selected",
            "speakerClusterMapSHA256": map.mappingSHA256.base64EncodedString()], options: [.sortedKeys])
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_selected_source BEFORE INSERT ON selected_edge_artifact_source
                BEGIN SELECT RAISE(ABORT, 'injected source failure'); END
                """)
        }
        do {
            try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "selected", modelID: "edge",
                structuredTranscriptData: data, clusterMap: map, artifactSource: source)
            XCTFail("Source failure must roll back transcript and map selection")
        } catch {}
        let failed = try await store.fetch(id: id)
        XCTAssertEqual(failed?.revision, recording.revision)
        XCTAssertEqual(failed?.transcriptText, recording.transcriptText)
        let missingMap = try await store.selectedSpeakerClusterMap(recordingID: id)
        XCTAssertNil(missingMap)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_selected_source") }
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "selected", modelID: "edge",
            structuredTranscriptData: data, clusterMap: map, artifactSource: source)
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let selected = try await reopened.selectedEdgeArtifactSource(recordingID: id)
        XCTAssertEqual(selected, source)
        for (url, original) in [(metadataURL, metadata), (bundleURL, bundle)] {
            try Data("altered".utf8).write(to: url)
            do {
                _ = try await reopened.selectedEdgeArtifactSource(recordingID: id)
                XCTFail("Altered selected bytes must not be returned as verified evidence")
            } catch {}
            try original.write(to: url)
        }
        let mismatched = try SelectedEdgeArtifactSource(signedMetadataURL: metadataURL, bundleURL: bundleURL,
            signedMetadataSHA256: source.signedMetadataSHA256, bundleSHA256: Data(repeating: 9, count: 32))
        do {
            try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "wrong", modelID: "edge",
                structuredTranscriptData: data, clusterMap: map, artifactSource: mismatched)
            XCTFail("An unrelated bundle must not be selected with this map")
        } catch {}
        let unchanged = try await reopened.selectedEdgeArtifactSource(recordingID: id)
        XCTAssertEqual(unchanged, source)
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "replacement", modelID: "edge")
        let invalidated = try await reopened.selectedEdgeArtifactSource(recordingID: id)
        XCTAssertNil(invalidated)
        let count = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM selected_edge_artifact_source") }
        XCTAssertEqual(count, 0)
    }

    func test_selectedClusterMapCommitsWithProjectionAndInvalidatesOnReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let recording = try await seed(store, wavPath: root.appendingPathComponent("audio.wav").path)
        let id = try XCTUnwrap(recording.id)
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                arguments: [producer.rawBytes, UUID().uuidString.lowercased(), id])
        }
        let map = try SpeakerClusterMap(canonicalRecordingID: recording.canonicalID,
            canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash), producerDeviceID: producer,
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterIDs: ["speaker-9"])
        let data = try JSONSerialization.data(withJSONObject: ["joinedText": "mapped",
            "speakerClusterMapSHA256": map.mappingSHA256.base64EncodedString()], options: [.sortedKeys])
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_map BEFORE INSERT ON selected_speaker_cluster_map
                BEGIN SELECT RAISE(ABORT, 'injected map failure'); END
                """)
        }
        do {
            try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "mapped", modelID: "edge",
                structuredTranscriptData: data, clusterMap: map)
            XCTFail("Map failure must roll back the transcript selection")
        } catch {}
        let failed = try await store.fetch(id: id)
        XCTAssertEqual(failed?.transcriptText, recording.transcriptText)
        let missing = try await store.selectedSpeakerClusterMap(recordingID: id)
        XCTAssertNil(missing)
        try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_map") }
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "mapped", modelID: "edge",
            structuredTranscriptData: data, clusterMap: map)
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let selected = try await reopened.selectedSpeakerClusterMap(recordingID: id)
        XCTAssertEqual(selected, map)
        let fetchedCurrent = try await reopened.fetch(id: id)
        let current = try XCTUnwrap(fetchedCurrent)
        let projectionURL = URL(fileURLWithPath: try XCTUnwrap(current.jsonPath))
        try Data("tampered".utf8).write(to: projectionURL)
        do {
            _ = try await reopened.selectedSpeakerClusterMap(recordingID: id)
            XCTFail("Changed projection bytes must not retain naming authority")
        } catch {}
        try data.write(to: projectionURL)
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET canonical_pcm_sha256 = ? WHERE id = ?",
                arguments: [Data(repeating: 9, count: 32), id])
        }
        let afterAudioChange = try await reopened.selectedSpeakerClusterMap(recordingID: id)
        XCTAssertNil(afterAudioChange)
        try await queue.write { db in
            try db.execute(sql: "UPDATE recordings SET canonical_pcm_sha256 = ? WHERE id = ?",
                arguments: [recording.canonicalPCMHash?.rawBytes, id])
        }
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "mapped", modelID: "edge",
            structuredTranscriptData: data, clusterMap: map)
        try await reopened.applyAcceptedEdgeTranscript(recordingID: id, text: "replacement", modelID: "edge")
        let invalidated = try await store.selectedSpeakerClusterMap(recordingID: id)
        XCTAssertNil(invalidated)
    }

    func test_stagedReplacementRetiresOldNamesBeforeRecognitionAndRejectsStaleReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.inMemory()
        let reference = try await seed(store, wavPath: root.appendingPathComponent("reference.wav").path)
        let target = try await seed(store, wavPath: root.appendingPathComponent("target.wav").path)
        let id = try XCTUnwrap(target.id)
        let person = try await store.createPerson(displayName: "New voice")
        let enrollment = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(enrollment)
        try await store.confirmSpeakerEvidence(sha256: enrollment.evidenceSHA256, personID: person)
        let data = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"unchanged words"}"#.utf8)
        let artifact = Data(SHA256.hash(data: data))
        func snapshot(_ embedding: QuantizedSpeakerEmbedding) throws -> SpeakerEvidenceSnapshot {
            try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
                canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: enrollment.producerDeviceID,
                processingArtifactSHA256: artifact, localClusterID: "host-speaker-0", embedding: embedding,
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 2)
        }
        let old = try snapshot(QuantizedSpeakerEmbedding(dimensions: 3, values: Data([0,127,0]), scale: 0.5))
        let replacement = try snapshot(enrollment.embedding)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "unchanged words",
            modelID: "test", structuredTranscriptData: data)
        _ = try await store.retainSpeakerEvidence(old)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id, speakerEvidence: [0: old.evidenceSHA256])
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "unchanged words",
            modelID: "test", structuredTranscriptData: data)
        _ = try await store.retainSpeakerEvidence(replacement)
        let staged = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
            expectedArtifactSHA256: artifact, speakerEvidence: [0: replacement.evidenceSHA256])
        XCTAssertTrue(staged)
        let observation = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: target.canonicalID,
            speakerIndex: 0, embedding: replacement.embedding, modelID: replacement.modelID,
            speechDurationMs: replacement.speechDurationMs, segmentCount: replacement.segmentCount)
        do {
            _ = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
                expectedArtifactSHA256: Data(repeating: 9, count: 32), speakerEvidence: [:])
            XCTFail("A stale transcript digest must not clear the staged evidence")
        } catch {}
        let mismatches = [
            (old.embedding, replacement.modelID, UInt64(6000), UInt32(2)),
            (replacement.embedding, "different-model", UInt64(6000), UInt32(2)),
            (replacement.embedding, replacement.modelID, UInt64(6001), UInt32(2)),
            (replacement.embedding, replacement.modelID, UInt64(6000), UInt32(3))
        ]
        for (vector, model, duration, count) in mismatches {
            let invalid = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: target.canonicalID,
                speakerIndex: 0, embedding: vector, modelID: model, speechDurationMs: duration, segmentCount: count)
            do {
                _ = try await store.submitSpeakerObservation(invalid, from: enrollment.producerDeviceID,
                    expectedEvidenceSHA256: replacement.evidenceSHA256)
                XCTFail("A digest cannot authorize different observation evidence")
            } catch {}
        }
        let queue = await store.uncoordinatedDB
        let rejectedCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations")
        }
        XCTAssertEqual(rejectedCount, 0, "Rejected evidence must not leave durable decisions")
        let decision = try await store.submitSpeakerObservation(observation, from: enrollment.producerDeviceID,
            expectedEvidenceSHA256: replacement.evidenceSHA256)
        XCTAssertEqual(decision.disposition, .matched)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
            speakerEvidence: [0: replacement.evidenceSHA256])
        let published = try await store.fetch(id: id)
        XCTAssertEqual(published?.speakerNames[0], "New voice")
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "unchanged words",
            modelID: "test", structuredTranscriptData: data)
        _ = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
            expectedArtifactSHA256: artifact, speakerEvidence: [0: old.evidenceSHA256])
        do {
            _ = try await store.submitSpeakerObservation(observation, from: enrollment.producerDeviceID,
                expectedEvidenceSHA256: replacement.evidenceSHA256)
            XCTFail("An exact request replay must still reject a replaced generation")
        } catch {}
        let after = try await store.fetch(id: id)
        XCTAssertNil(after?.speakerNames[0])
        // A ready edge winner invalidates the Host map and cannot be replaced by late Host work.
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "edge winner", modelID: "edge")
        let lateStage = try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: id,
            expectedArtifactSHA256: artifact, speakerEvidence: [0: replacement.evidenceSHA256])
        XCTAssertFalse(lateStage)
        do {
            _ = try await store.submitSpeakerObservation(observation, from: enrollment.producerDeviceID,
                expectedEvidenceSHA256: replacement.evidenceSHA256)
            XCTFail("Late Host recognition must not overwrite an edge winner")
        } catch {}
        let latePublish = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
            speakerEvidence: [0: replacement.evidenceSHA256])
        XCTAssertFalse(latePublish)
        let edge = try await store.fetch(id: id)
        XCTAssertEqual(edge?.transcriptText, "edge winner")
        XCTAssertTrue(edge?.speakerNames.isEmpty == true)

    }

    func test_replayAndReplacementPreserveExactEvidenceAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harc-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        var store: RecordingStore? = try await .onDisk(url: url)
        let recording = try await seed(store!)
        let old = try evidence(recording)
        let replacement = try evidence(recording, voice: 1, artifact: 4)
        let digest = try await store!.retainSpeakerEvidence(old)
        let replay = try await store!.retainSpeakerEvidence(old, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(digest, replay)
        _ = try await store!.retainSpeakerEvidence(replacement)
        let pack = try await store!.speakerRecognitionPack(dimensions: 3)
        XCTAssertTrue(pack.profiles.isEmpty, "Retention must not enroll evidence")
        let person = try await store!.createPerson(displayName: "Confirmed voice")
        try await store!.confirmSpeakerEvidence(sha256: digest, personID: person)
        let beforeReopen = try await store!.speakerRecognitionPack(dimensions: 3)
        store = nil
        let reopened = try await RecordingStore.onDisk(url: url)
        let savedOld = try await reopened.retainedSpeakerEvidence(sha256: digest)
        let savedNew = try await reopened.retainedSpeakerEvidence(sha256: replacement.evidenceSHA256)
        XCTAssertEqual(savedOld, old)
        XCTAssertEqual(savedNew, replacement)
        let afterReopen = try await reopened.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(afterReopen.profiles, beforeReopen.profiles)
        XCTAssertEqual(afterReopen.revision, beforeReopen.revision)
        let queue = try DatabaseQueue(path: url.path)
        let count = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speaker_evidence_snapshots") }
        XCTAssertEqual(count, 2)
        let transitioned = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bound_speaker_enrollment_sources") }
        XCTAssertEqual(transitioned, 1)
        do {
            try await queue.write { db in
                try db.execute(sql: "UPDATE speaker_evidence_snapshots SET snapshot_json = snapshot_json")
            }
            XCTFail("Retained evidence must reject updates")
        } catch { XCTAssertNotNil(error as? DatabaseError) }
        let wrongDigest = Data(repeating: 7, count: 32)
        let payload = try JSONEncoder().encode(old)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO speaker_evidence_snapshots(evidence_sha256, recording_id, snapshot_json, retained_at) VALUES (?, ?, ?, 0)",
                           arguments: [wrongDigest, recording.id, payload])
        }
        do {
            _ = try await reopened.retainedSpeakerEvidence(sha256: wrongDigest)
            XCTFail("Stored digest mismatch must not be trusted")
        } catch { XCTAssertNotNil(error as? StoreError) }

    }

    func test_unknownOrChangedCanonicalAudioCannotRetainEvidence() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await seed(store)
        var other = recording; other.canonicalPCMHash = try CanonicalPCMHash(Data(repeating: 9, count: 32))
        do { _ = try await store.retainSpeakerEvidence(evidence(other)); XCTFail("Wrong audio accepted") }
        catch { XCTAssertEqual(error as? StoreError, .canonicalArtifactIdentityMismatch) }
        other.canonicalID = .random()
        do { _ = try await store.retainSpeakerEvidence(evidence(other)); XCTFail("Unknown recording accepted") }
        catch { XCTAssertEqual(error as? StoreError, .notFound) }
        let missing = try await store.retainedSpeakerEvidence(sha256: Data(repeating: 9, count: 32))
        XCTAssertNil(missing)
    }

    func test_exactConfirmationEnrollsOnlySelectedVoiceAndRejectsStaleCorrection() async throws {
        let store = try await RecordingStore.inMemory()
        let reference = try await seed(store)
        let old = try evidence(reference)
        let selected = try evidence(reference, voice: 0, artifact: 4)
        _ = try await store.retainSpeakerEvidence(old)
        _ = try await store.retainSpeakerEvidence(selected)
        let bob = try await store.createPerson(displayName: "Bob")
        let alice = try await store.createPerson(displayName: "Alice")
        // Reproduce the mixed legacy/bound transition, not just a clean Library.
        let legacySource = try DeviceID(Data(repeating: 9, count: 32))
        for value in [old, selected] {
            _ = try await store.submitSpeakerObservation(SpeakerEmbeddingObservation(operationID: .random(),
                canonicalRecordingID: reference.canonicalID, speakerIndex: 0, embedding: value.embedding,
                modelID: value.modelID, speechDurationMs: value == old ? 20_000 : 6000, segmentCount: 2), from: legacySource)
        }
        try await store.linkSpeaker(personID: bob, recordingID: reference.id!, speakerIndex: 0)
        try await store.updateSpeakerNames(id: reference.id!, names: [0: "Recorded Bob"])
        let legacyVector = old.embedding.dequantized.withUnsafeBytes { Data($0) }
        try await store.upsertSpeakerEmbeddings(recordingID: reference.id!, rows: [
            .init(recordingID: reference.id!, speakerIndex: 0, embedding: legacyVector,
                segmentCount: 2, totalMs: 20_000, embedderKind: old.modelID)])
        let bobToken = try await store.confirmSpeakerEvidence(sha256: selected.evidenceSHA256, personID: bob)
        let localReferences = try await store.speakerRecognitionReferences(personID: bob, modelID: old.modelID, dimensions: 3)
        XCTAssertEqual(localReferences.count, 1)
        XCTAssertEqual(localReferences.first?.embedding, selected.embedding.dequantized.withUnsafeBytes { Data($0) })
        let legacySimilarityRows = try await store.allSpeakerEmbeddings(embedderKind: old.modelID)
        XCTAssertTrue(legacySimilarityRows.isEmpty)
        let pack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertNil(SpeakerRecognitionMatcher.bestMatch(embedding: old.embedding, modelID: old.modelID, pack: pack))
        XCTAssertEqual(SpeakerRecognitionMatcher.bestMatch(embedding: selected.embedding, modelID: selected.modelID, pack: pack)?.displayName, "Bob")
        try await store.confirmSpeakerEvidence(sha256: selected.evidenceSHA256, personID: bob)
        let replayPack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(replayPack.revision, pack.revision)
        XCTAssertEqual(replayPack.profiles, pack.profiles)
        let query = try await store.upsert(Recording(wavPath: "/tmp/bound-query.wav", startedAt: Date()))
        let source = try DeviceID(Data(repeating: 8, count: 32))
        func observe(_ value: SpeakerEvidenceSnapshot, on recording: Recording) async throws -> SpeakerObservationDecision {
            try await store.submitSpeakerObservation(SpeakerEmbeddingObservation(operationID: .random(),
                canonicalRecordingID: recording.canonicalID, speakerIndex: 0, embedding: value.embedding,
                modelID: value.modelID, speechDurationMs: 6000, segmentCount: 2), from: source)
        }
        let wrong = try await observe(old, on: query)
        let right = try await observe(selected, on: query)
        XCTAssertEqual(wrong.disposition, .noMatch)
        XCTAssertEqual(right.displayName, "Bob")
        let selfMatch = try await observe(selected, on: reference)
        XCTAssertEqual(selfMatch.disposition, .noMatch)
        try await store.confirmSpeakerEvidence(sha256: selected.evidenceSHA256, personID: alice, replacing: bobToken)
        do {
            try await store.confirmSpeakerEvidence(sha256: selected.evidenceSHA256, personID: bob)
            XCTFail("A stale first confirmation must not overwrite the correction")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let correctedPack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(SpeakerRecognitionMatcher.bestMatch(embedding: selected.embedding, modelID: selected.modelID, pack: correctedPack)?.displayName, "Alice")
        let correctedHost = try await observe(selected, on: query)
        XCTAssertEqual(correctedHost.displayName, "Alice")
        let retainedOld = try await store.retainedSpeakerEvidence(sha256: old.evidenceSHA256)
        XCTAssertEqual(retainedOld, old)
        let selection = try await store.speakerEvidenceAssignment(sha256: selected.evidenceSHA256)
        try await store.unconfirmSpeakerEvidence(sha256: selected.evidenceSHA256, expectedToken: XCTUnwrap(selection?.token))
        let withdrawnPack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertTrue(withdrawnPack.profiles.allSatisfy { $0.prototypes.isEmpty }, "Withdrawal cannot reactivate legacy evidence")
        let legacyReferences = try await store.fetchEmbeddingsForPerson(bob, embedderKind: old.modelID)
        XCTAssertTrue(legacyReferences.isEmpty, "Local recognition must not reuse transitioned legacy references")
        let preserved = try await store.fetch(id: reference.id!)
        XCTAssertEqual(preserved?.speakerNames[0], "Recorded Bob")
        let preservedLinks = try await store.fetchPersonSpeakerLinks(recordingID: reference.id!)
        XCTAssertEqual(preservedLinks.first?.personID, bob)
    }

    func test_confirmationTokensRejectABAAndStaleWithdrawal() async throws {
        let store = try await RecordingStore.inMemory()
        let reference = try await seed(store)
        let value = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(value)
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let a1 = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: alice)
        let b1 = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: bob, replacing: a1)
        let a2 = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: alice, replacing: b1)
        XCTAssertNotEqual(a1, a2)
        do {
            _ = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: bob, replacing: a1)
            XCTFail("A stale A token must not replace a newer A confirmation")
        } catch { XCTAssertNotNil(error as? StoreError) }
        do {
            try await store.unconfirmSpeakerEvidence(sha256: value.evidenceSHA256, expectedToken: a1)
            XCTFail("A stale removal must not withdraw newer evidence")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let before = try await store.speakerRecognitionPack(dimensions: 3)
        try await store.unconfirmSpeakerEvidence(sha256: value.evidenceSHA256, expectedToken: a2)
        let after = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertTrue(after.profiles.allSatisfy { $0.prototypes.isEmpty })
        try await store.unconfirmSpeakerEvidence(sha256: value.evidenceSHA256, expectedToken: a2)
        let repeated = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(repeated.revision, after.revision)
        let retained = try await store.retainedSpeakerEvidence(sha256: value.evidenceSHA256)
        XCTAssertEqual(retained, value)
        let a3 = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: alice)
        XCTAssertNotEqual(a2, a3)
        do {
            try await store.unconfirmSpeakerEvidence(sha256: value.evidenceSHA256, expectedToken: a2)
            XCTFail("Old removal must not delete a new confirmation")
        } catch { XCTAssertNotNil(error as? StoreError) }
    }

    func test_personLifecyclePreservesSelectedSnapshotUntilExplicitRemoval() async throws {
        let store = try await RecordingStore.inMemory()
        let reference = try await seed(store)
        let value = try evidence(reference)
        _ = try await store.retainSpeakerEvidence(value)
        let source = try await store.createPerson(displayName: "Source")
        let target = try await store.createPerson(displayName: "Target")
        let token = try await store.confirmSpeakerEvidence(sha256: value.evidenceSHA256, personID: source)
        let before = try await store.speakerRecognitionPack(dimensions: 3)
        let prototype = try XCTUnwrap(before.profiles.first { $0.displayName == "Source" }?.prototypes.first)
        try await store.renamePerson(id: source, to: "Renamed")
        let renamed = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(renamed.profiles.first { $0.displayName == "Renamed" }?.prototypes.first, prototype)
        try await store.mergePeople(sourceIDs: [source], into: target)
        let merged = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(merged.profiles.first { $0.displayName == "Target" }?.prototypes.first, prototype)
        let assignment = try await store.speakerEvidenceAssignment(sha256: value.evidenceSHA256)
        XCTAssertEqual(assignment?.personID, target)
        XCTAssertNotEqual(assignment?.token, token)
        do {
            try await store.unconfirmSpeakerEvidence(sha256: value.evidenceSHA256, expectedToken: token)
            XCTFail("A pre-merge review must not remove the merged evidence")
        } catch { XCTAssertNotNil(error as? StoreError) }
        try await store.softDelete(id: reference.id!)
        let hidden = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertTrue(hidden.profiles.allSatisfy { $0.prototypes.isEmpty })
        XCTAssertGreaterThan(hidden.revision, merged.revision)
        try await store.restore(id: reference.id!)
        let restored = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(restored.profiles.first { $0.displayName == "Target" }?.prototypes.first, prototype)
        XCTAssertGreaterThan(restored.revision, hidden.revision)
        try await store.deletePerson(id: target)
        let removed = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertTrue(removed.profiles.isEmpty)
        XCTAssertGreaterThan(removed.revision, merged.revision)
        let retained = try await store.retainedSpeakerEvidence(sha256: value.evidenceSHA256)
        XCTAssertEqual(retained, value)
    }

    func test_confirmationTokenMigrationPreservesExistingSelection() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(queue, upTo: "v22_confirmed_speaker_evidence")
        let prototype = UUID().uuidString.lowercased()
        try queue.write { db in
            let recording = Recording(id: 1, wavPath: "/tmp/token-migration.wav", startedAt: Date())
            try recording.insert(db)
            try db.execute(sql: "INSERT INTO people(id, display_name, created_at, updated_at, stable_uuid, profile_revision) VALUES (1, 'Alice', 0, 0, ?, 1)", arguments: [UUID().uuidString.lowercased()])
            // Only migration preservation is under test; this opaque payload is
            // never admitted through the validated snapshot API.
            try db.execute(sql: "INSERT INTO speaker_evidence_snapshots VALUES (zeroblob(32), 1, x'7b7d', 0)")
            try db.execute(sql: "INSERT INTO confirmed_speaker_evidence VALUES (zeroblob(32), 1, ?, 10)", arguments: [prototype])
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let row = try queue.read { try Row.fetchOne($0, sql: "SELECT * FROM confirmed_speaker_evidence") }
        XCTAssertEqual(row?["confirmation_uuid"] as String?, prototype)
        XCTAssertEqual(row?["prototype_uuid"] as String?, prototype)
        XCTAssertEqual(row?["person_id"] as Int?, 1)
        XCTAssertEqual(row?["confirmed_at"] as Double?, 10)
        let transitioned = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bound_speaker_enrollment_sources WHERE recording_id = 1") }
        XCTAssertEqual(transitioned, 1, "Existing exact selections must not keep legacy enrollment active")
    }

    func test_identicalTranscriptCannotTransferNameToDifferentVoiceEvidence() async throws {
        for droppingEvidence in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try await RecordingStore.inMemory()
            let recording = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
            let id = try XCTUnwrap(recording.id)
            let person = try await store.createPerson(displayName: "Original voice")
            let data = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"original"}"#.utf8)
            let snapshot = try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash),
                producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
                processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127, 0, 0]), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
            try await store.updateProcessing(id: id, descriptor: .pending)
            _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "original",
                modelID: "test", structuredTranscriptData: data)
            _ = try await store.retainSpeakerEvidence(snapshot)
            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                speakerEvidence: [0: snapshot.evidenceSHA256])
            let review = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
            try await store.confirmHostSpeakerReview(XCTUnwrap(review), personID: person)
            try await store.updateProcessing(id: id, descriptor: .pending)
            // A retry of the exact artifact must preserve its valid assignment.
            _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "original",
                modelID: "test", structuredTranscriptData: data)
            let retried = try await store.fetch(id: id)
            XCTAssertEqual(retried?.speakerNames[0], "Original voice")

            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                speakerEvidence: [0: snapshot.evidenceSHA256])
            let same = try await store.fetch(id: id)
            XCTAssertEqual(same?.speakerNames[0], "Original voice")
            try await store.updateProcessing(id: id, descriptor: .pending)
            _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "original",
                modelID: "test", structuredTranscriptData: data)
            let replacement = try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash),
                producerDeviceID: snapshot.producerDeviceID,
                processingArtifactSHA256: snapshot.processingArtifactSHA256, localClusterID: "host-speaker-0",
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([0, 127, 0]), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
            _ = try await store.retainSpeakerEvidence(replacement)
            do {
                _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                    speakerEvidence: [0: Data(repeating: 9, count: 32)])
                XCTFail("Unretained evidence must fail atomically")
            } catch { }
            let rejected = try await store.fetch(id: id)
            XCTAssertEqual(rejected?.speakerNames[0], "Original voice")
            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                speakerEvidence: droppingEvidence ? [:] : [0: replacement.evidenceSHA256])
            let changed = try await store.fetch(id: id)
            XCTAssertTrue(changed?.speakerNames.isEmpty == true)
            let current = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
            XCTAssertEqual(current?.evidence, droppingEvidence ? nil : replacement)
            let originalSelection = try await store.speakerEvidenceAssignment(sha256: snapshot.evidenceSHA256)
            let replacementSelection = try await store.speakerEvidenceAssignment(sha256: replacement.evidenceSHA256)
            XCTAssertEqual(originalSelection?.personID, person)
            XCTAssertNil(replacementSelection)
            let db = await store.uncoordinatedDB
            let links = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM person_speakers WHERE recording_id = ?", arguments: [id]) }
            XCTAssertEqual(links, 0)
        }
    }

    func test_hostAndEdgeReplacementArchiveNamesWithoutRebindingConfirmedVoice() async throws {
        for edge in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try await RecordingStore.inMemory()
            let recording = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
            let id = try XCTUnwrap(recording.id)
            let person = try await store.createPerson(displayName: "Original voice")
            let data = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"original"}"#.utf8)
            let snapshot = try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: XCTUnwrap(recording.canonicalPCMHash),
                producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
                processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127, 0, 0]), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
            try await store.updateProcessing(id: id, descriptor: .pending)
            _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "original",
                modelID: "test", structuredTranscriptData: data)
            _ = try await store.retainSpeakerEvidence(snapshot)
            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
                speakerEvidence: [0: snapshot.evidenceSHA256])
            let review = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
            try await store.confirmHostSpeakerReview(XCTUnwrap(review), personID: person)
            try await store.updateProcessing(id: id, descriptor: .pending)
            // A retry of the exact artifact must preserve its valid assignment.
            _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "original",
                modelID: "test", structuredTranscriptData: data)
            let retried = try await store.fetch(id: id)
            XCTAssertEqual(retried?.speakerNames[0], "Original voice")
            let replacement = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"different voice"}"#.utf8)
            let database = await store.uncoordinatedDB
            try await database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_assignment_archive BEFORE INSERT ON speaker_assignment_history
                    BEGIN SELECT RAISE(ABORT, 'injected history failure'); END
                    """)
            }
            do {
                if edge {
                    try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "different voice",
                        modelID: "edge", structuredTranscriptData: replacement)
                } else {
                    _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "different voice",
                        modelID: "host", structuredTranscriptData: replacement)
                }
                XCTFail("History failure must roll back publication")
            } catch { }
            let afterFailure = try await store.fetch(id: id)
            XCTAssertEqual(afterFailure?.speakerNames[0], "Original voice")
            XCTAssertEqual(afterFailure?.jsonPath, retried?.jsonPath)
            XCTAssertEqual(afterFailure?.revision, retried?.revision)
            try await database.write { try $0.execute(sql: "DROP TRIGGER reject_assignment_archive") }
            if edge {
                try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "different voice",
                    modelID: "edge", structuredTranscriptData: replacement)
            } else {
                _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "different voice",
                    modelID: "host", structuredTranscriptData: replacement)
            }
            let replaced = try await store.fetch(id: id)
            XCTAssertTrue(replaced?.speakerNames.isEmpty == true)
            let db = await store.uncoordinatedDB
            let counts = try await db.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person_speakers WHERE recording_id = ?", arguments: [id]),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_assignment_history WHERE recording_id = ?", arguments: [id]))
            }
            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 1)
            let selection = try await store.speakerEvidenceAssignment(sha256: snapshot.evidenceSHA256)
            XCTAssertEqual(selection?.personID, person, "The original exact voice remains enrolled")
        }
    }

    func test_currentPublicationRejectsStaleReviewsAndArtifactSubstitution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harc-speaker-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.inMemory()
        let reference = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
        let id = reference.id!
        let person = try await store.createPerson(displayName: "Bob")
        let dataA = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"a"}"#.utf8)
        let dataB = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"b"}"#.utf8)
        func snapshot(_ data: Data, voice: [UInt8]) throws -> SpeakerEvidenceSnapshot {
            try SpeakerEvidenceSnapshot(canonicalRecordingID: reference.canonicalID,
                canonicalPCMHash: XCTUnwrap(reference.canonicalPCMHash),
                producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
                processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "host-speaker-0",
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data(voice), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        }
        let a = try snapshot(dataA, voice: [127, 0, 0]), b = try snapshot(dataB, voice: [0, 127, 0])
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "a", modelID: "test", structuredTranscriptData: dataA)
        _ = try await store.retainSpeakerEvidence(a)
        let unpublished = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertNil(unpublished)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id, speakerEvidence: [0: a.evidenceSHA256])
        let review = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(review, a)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id, text: "b", modelID: "test", structuredTranscriptData: dataB)
        _ = try await store.retainSpeakerEvidence(b)
        do {
            _ = try await store.confirmCurrentHostSpeakerEvidence(recordingID: id, speakerIndex: 0,
                expectedEvidenceSHA256: a.evidenceSHA256, personID: person)
            XCTFail("Work in progress must invalidate the old review")
        } catch { XCTAssertNotNil(error as? StoreError) }
        do {
            _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id, speakerEvidence: [0: a.evidenceSHA256])
            XCTFail("Old evidence must not bind the replacement transcript")
        } catch { XCTAssertNotNil(error as? StoreError) }
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id, speakerEvidence: [0: b.evidenceSHA256])
        do {
            _ = try await store.confirmCurrentHostSpeakerEvidence(recordingID: id, speakerIndex: 0,
                expectedEvidenceSHA256: a.evidenceSHA256, personID: person)
            XCTFail("Reused speaker index must not transfer confirmation")
        } catch { XCTAssertNotNil(error as? StoreError) }
        _ = try await store.confirmCurrentHostSpeakerEvidence(recordingID: id, speakerIndex: 0,
            expectedEvidenceSHA256: b.evidenceSHA256, personID: person)
        let pack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertNil(SpeakerRecognitionMatcher.bestMatch(embedding: a.embedding, modelID: a.modelID, pack: pack))
        XCTAssertEqual(SpeakerRecognitionMatcher.bestMatch(embedding: b.embedding, modelID: b.modelID, pack: pack)?.displayName, "Bob")
        let alice = try await store.createPerson(displayName: "Alice")
        let initialReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        let staleReview = try XCTUnwrap(initialReview)
        try await store.linkSpeaker(personID: alice, recordingID: id, speakerIndex: 0)
        do {
            try await store.confirmHostSpeakerReview(staleReview, personID: person)
            XCTFail("A newer legacy person correction must invalidate review even with the same voice artifact")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let afterRejected = try await store.fetchPersonSpeakerLinks(recordingID: id)
        XCTAssertEqual(afterRejected.first?.personID, alice)
        let freshReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        let beforeInvalidTarget = try await store.speakerEvidenceAssignment(sha256: b.evidenceSHA256)
        do {
            try await store.confirmHostSpeakerReview(XCTUnwrap(freshReview), personID: Int64.max)
            XCTFail("An absent target must not partially change enrollment or labels")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let afterInvalidTarget = try await store.speakerEvidenceAssignment(sha256: b.evidenceSHA256)
        XCTAssertEqual(afterInvalidTarget?.token, beforeInvalidTarget?.token)
        XCTAssertEqual(afterInvalidTarget?.personID, person)
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_review_label BEFORE UPDATE OF speaker_names ON recordings
                BEGIN SELECT RAISE(ABORT, 'injected label failure'); END
                """)
        }
        do {
            try await store.confirmHostSpeakerReview(XCTUnwrap(freshReview), personID: alice)
            XCTFail("A label-write failure must roll back the preceding enrollment update")
        } catch { }
        let afterWriteFailure = try await store.speakerEvidenceAssignment(sha256: b.evidenceSHA256)
        XCTAssertEqual(afterWriteFailure?.personID, person)
        XCTAssertEqual(afterWriteFailure?.token, beforeInvalidTarget?.token)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_review_label") }
        try await store.confirmHostSpeakerReview(XCTUnwrap(freshReview), personID: alice)
        let assignment = try await store.speakerEvidenceAssignment(sha256: b.evidenceSHA256)
        XCTAssertEqual(assignment?.personID, alice)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: id)
        XCTAssertEqual(links.first?.personID, alice)
        let corrected = try await store.fetch(id: id)
        XCTAssertEqual(corrected?.speakerNames[0], "Alice")
        let saved = try await store.fetch(id: id)
        let path = try XCTUnwrap(saved?.jsonPath)
        try dataA.write(to: URL(fileURLWithPath: path))
        do {
            _ = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
            XCTFail("Rewritten sidecar must not preserve review authority")
        } catch { XCTAssertNotNil(error as? StoreError) }
        try dataB.write(to: URL(fileURLWithPath: path))
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "edge", modelID: "edge", structuredTranscriptData: dataB)
        let afterEdge = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertNil(afterEdge, "Even the same path cannot carry Host slot authority into edge publication")
    }

    func test_localPublicationPreservesSelectedVoiceWithoutRebindingItsSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let recording = try await seed(store, wavPath: root.appendingPathComponent("master.wav").path)
        let id = try XCTUnwrap(recording.id)
        let hash = try XCTUnwrap(recording.canonicalPCMHash)
        let frames = try XCTUnwrap(recording.canonicalPCMFrames)
        let dataA = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"original"}"#.utf8)
        let dataB = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"replacement"}"#.utf8)
        func snapshot(_ data: Data, voice: [UInt8]) throws -> SpeakerEvidenceSnapshot {
            try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID, canonicalPCMHash: hash,
                producerDeviceID: DeviceID(Data(repeating: 2, count: 32)), processingArtifactSHA256: Data(SHA256.hash(data: data)),
                localClusterID: "local-speaker-0", embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data(voice), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        }
        let a = try snapshot(dataA, voice: [127, 0, 0]), b = try snapshot(dataB, voice: [0, 127, 0])
        let invalidTimelines = [
            #"{"speakers":[],"joinedText":"original"}"#,
            #"{"speakers":[{"speaker":0,"startMs":0,"endMs":5000}],"joinedText":"original"}"#,
            #"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000},{"speaker":0,"startMs":1000,"endMs":2000}],"joinedText":"original"}"#,
            #"{"speakers":[{"speaker":0,"startMs":-1,"endMs":6000}],"joinedText":"original"}"#
        ]
        for json in invalidTimelines {
            let bytes = Data(json.utf8)
            do {
                try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: recording.revision,
                    expectedArtifactSHA256: nil, canonicalPCMHash: hash, canonicalFrames: frames,
                    structuredTranscriptData: bytes, snapshots: [snapshot(bytes, voice: [127, 0, 0])])
                XCTFail("A matching digest must not authorize a voice absent from the actual timeline")
            } catch { }
        }
        do {
            try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: recording.revision,
                expectedArtifactSHA256: nil, canonicalPCMHash: hash, canonicalFrames: frames,
                structuredTranscriptData: dataA, snapshots: [a], transcriptText: "different text", transcriptionModelID: "test")
            XCTFail("Flat text must agree with the published document")
        } catch { }
        let untouched = try await store.fetch(id: id)
        XCTAssertEqual(untouched?.revision, recording.revision)
        let rejectedEvidence = try await store.retainedSpeakerEvidence(sha256: a.evidenceSHA256)
        XCTAssertNil(rejectedEvidence)
        try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: recording.revision,
            expectedArtifactSHA256: nil, canonicalPCMHash: hash, canonicalFrames: frames,
            structuredTranscriptData: dataA, snapshots: [a], transcriptText: "original", transcriptionModelID: "old-model")
        let person = try await store.createPerson(displayName: "Original person")
        let review = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        try await store.confirmHostSpeakerReview(XCTUnwrap(review), personID: person)
        let before = try await store.fetch(id: id)
        let revision = try XCTUnwrap(before?.revision)
        let dbQueue = await store.uncoordinatedDB
        try await dbQueue.write { database in
            try database.execute(sql: """
                CREATE TEMP TRIGGER reject_local_current BEFORE INSERT ON current_speaker_evidence
                BEGIN SELECT RAISE(ABORT, 'injected current publication failure'); END
                """)
        }
        do {
            try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: revision,
                expectedArtifactSHA256: Data(SHA256.hash(data: dataA)), canonicalPCMHash: hash, canonicalFrames: frames,
                structuredTranscriptData: dataB, snapshots: [b], transcriptText: "replacement", transcriptionModelID: "new-model")
            XCTFail("A failed current-map write must roll back the whole generation")
        } catch { }
        let rolledBack = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(rolledBack, a)
        let rolledBackRecording = try await store.fetch(id: id)
        XCTAssertEqual(rolledBackRecording?.transcriptText, "original")
        XCTAssertEqual(rolledBackRecording?.sttModelID, "old-model")
        let rolledBackLinks = try await store.fetchPersonSpeakerLinks(recordingID: id)
        XCTAssertEqual(rolledBackLinks.first?.personID, person)
        let historyCount = try await dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speaker_assignment_history") }
        XCTAssertEqual(historyCount, 0)
        try await dbQueue.write { try $0.execute(sql: "DROP TRIGGER reject_local_current") }
        try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: revision,
            expectedArtifactSHA256: Data(SHA256.hash(data: dataA)), canonicalPCMHash: hash, canonicalFrames: frames,
            structuredTranscriptData: dataB, snapshots: [b], transcriptText: "replacement", transcriptionModelID: "new-model")
        let pack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(SpeakerRecognitionMatcher.bestMatch(embedding: a.embedding, modelID: a.modelID, pack: pack)?.displayName, "Original person")
        XCTAssertNil(SpeakerRecognitionMatcher.bestMatch(embedding: b.embedding, modelID: b.modelID, pack: pack))
        let links = try await store.fetchPersonSpeakerLinks(recordingID: id)
        XCTAssertTrue(links.isEmpty)
        let current = try await store.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(current, b)
        let query = try await store.speakerEmbedding(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(query?.embedding, RecordingStore.encodeFloat32(b.embedding.dequantized))
        let saved = try await store.fetch(id: id)
        XCTAssertTrue(saved?.speakerNames.isEmpty == true)
        XCTAssertEqual(saved?.transcriptText, "replacement")
        XCTAssertEqual(saved?.sttModelID, "new-model")
        XCTAssertNotNil(saved?.transcribedAt)
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let reopenedCurrent = try await reopened.currentHostSpeakerEvidence(recordingID: id, speakerIndex: 0)
        XCTAssertEqual(reopenedCurrent, b)
        let reopenedPack = try await reopened.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(reopenedPack.profiles, pack.profiles)
        let hasLocalEvidence = try await reopened.hasLocalSpeakerEvidence()
        XCTAssertTrue(hasLocalEvidence)
        let queue = await store.uncoordinatedDB
        let history = try await queue.read { try Data.fetchOne($0, sql: "SELECT assignments_json FROM speaker_assignment_history WHERE recording_id = ?", arguments: [id]) }
        XCTAssertTrue(String(data: try XCTUnwrap(history), encoding: .utf8)?.contains("Original person") == true)
        do {
            try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: revision,
                expectedArtifactSHA256: Data(SHA256.hash(data: dataA)), canonicalPCMHash: hash, canonicalFrames: frames,
                structuredTranscriptData: dataA, snapshots: [a], transcriptText: "original", transcriptionModelID: "old-model")
            XCTFail("A late generation must not replace a newer publication")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let currentReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
        try await store.confirmHostSpeakerReview(XCTUnwrap(currentReview), personID: person)
        let selections = try await store.enrolledSpeakerEvidence(personID: person)
        XCTAssertEqual(selections.count, 2)
        let ordered = [try XCTUnwrap(selections.first { $0.id == a.evidenceSHA256 }),
                       try XCTUnwrap(selections.first { $0.id == b.evidenceSHA256 })]
        try await queue.write { database in
            try database.execute(sql: """
                CREATE TEMP TRIGGER reject_split_label BEFORE UPDATE OF speaker_names ON recordings
                BEGIN SELECT RAISE(ABORT, 'injected split failure'); END
                """)
        }
        do {
            _ = try await store.splitSpeakerEvidence(ordered, personID: person, newName: "Split person")
            XCTFail("Failure updating the current label must roll back earlier historical evidence moves")
        } catch { }
        let afterFailedSplit = try await store.enrolledSpeakerEvidence(personID: person)
        XCTAssertEqual(afterFailedSplit.count, 2)
        let peopleAfterFailedSplit = try await store.fetchPeople()
        XCTAssertEqual(peopleAfterFailedSplit.count, 1)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_split_label") }
        let splitID = try await store.splitSpeakerEvidence(ordered, personID: person, newName: "Split person")
        let moved = try await store.enrolledSpeakerEvidence(personID: splitID)
        XCTAssertEqual(Set(moved.map(\.id)), Set(ordered.map(\.id)))
        let renamed = try await store.fetch(id: id)
        XCTAssertEqual(renamed?.speakerNames[0], "Split person")
        let splitPack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(SpeakerRecognitionMatcher.bestMatch(embedding: a.embedding, modelID: a.modelID, pack: splitPack)?.displayName, "Split person")
        do {
            _ = try await store.splitSpeakerEvidence(ordered, personID: person, newName: "Stale split")
            XCTFail("A stale split must not move samples again")
        } catch { XCTAssertNotNil(error as? StoreError) }
        let peopleAfterStaleSplit = try await store.fetchPeople()
        XCTAssertEqual(peopleAfterStaleSplit.count, 2)
    }

    func test_legacyMigrationDoesNotInventEvidenceBindings() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(queue, upTo: "v20_speaker_confirmation_provenance")
        try queue.write { db in
            let recording = Recording(wavPath: "/tmp/legacy-evidence.wav", startedAt: Date(), speakerNames: [0: "Alice"])
            try recording.insert(db)
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speaker_evidence_snapshots") }
        let legacy = try queue.read { try Recording.fetchOne($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(legacy?.speakerNames[0], "Alice")
    }
}
