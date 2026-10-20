import CryptoKit
import Foundation
import GRDB
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Host and edge processing arbitration")
struct ProcessingArbitrationTests {
    @Test func readingHostOutcomeRejectsMissingOrInventedTranscriptClusters() async throws {
        let fixture = try await makeFixture(canonicalPCMHash: CanonicalPCMHash(Data(repeating: 7, count: 32)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":500}]}"#.utf8)
        _ = try await fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID, text: "hello", modelID: "host", structuredTranscriptData: data)
        let recording = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        func outcome(indices: [UInt32]) throws -> HostSpeakerProcessingOutcome {
            try HostSpeakerProcessingOutcome(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: #require(recording.canonicalPCMHash),
                producerDeviceID: DeviceID(Data(repeating: 9, count: 32)),
                processingArtifactSHA256: Data(SHA256.hash(data: data)), diarization: .completed,
                clusters: indices.map { try .init(speakerIndex: $0) })
        }
        let valid = try outcome(indices: [0])
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(
            recordingID: fixture.recordingID, speakerOutcome: valid, structuredTranscriptData: data))
        let queue = await fixture.store.uncoordinatedDB
        // Model a damaged persisted inventory while preserving the exact artifact
        // digest. Neither omitted concerns nor invented clusters may be served.
        for indices: [UInt32] in [[], [1], [0, 1]] {
            let bytes = try JSONEncoder().encode(outcome(indices: indices))
            try await queue.write { db in
                try db.execute(sql: "UPDATE host_speaker_processing_outcome SET outcome_json = ? WHERE recording_id = ?",
                    arguments: [bytes, fixture.recordingID])
            }
            await #expect(throws: (any Error).self) {
                try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID)
            }
        }
        let bytes = try JSONEncoder().encode(valid)
        try await queue.write { db in
            try db.execute(sql: "UPDATE host_speaker_processing_outcome SET outcome_json = ? WHERE recording_id = ?",
                arguments: [bytes, fixture.recordingID])
        }
        #expect(try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID) == valid)
    }

    @Test func hostSpeakerOutcomeAccountsForMissingVoicesAndRejectsWrongGeneration() async throws {
        let fixture = try await makeFixture(canonicalPCMHash: CanonicalPCMHash(Data(repeating: 7, count: 32)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":500}]}"#.utf8)
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID, text: "hello", modelID: "host", structuredTranscriptData: data))
        let recording = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        let pcm = try #require(recording.canonicalPCMHash)
        func outcome(_ clusters: [HostSpeakerProcessingOutcome.Cluster], digest: Data? = nil) throws -> HostSpeakerProcessingOutcome {
            try HostSpeakerProcessingOutcome(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: pcm, producerDeviceID: DeviceID(Data(repeating: 9, count: 32)),
                processingArtifactSHA256: digest ?? Data(SHA256.hash(data: data)),
                diarization: .completed, clusters: clusters)
        }
        let missing = try HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0)
        for invalid in [try outcome([]), try outcome([missing], digest: Data(repeating: 0, count: 32)),
            try outcome([HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0,
                evidenceSHA256: Data(repeating: 1, count: 32), decisionOperationID: .random(), disposition: .noMatch, recognitionPackRevision: EntityRevision(1))])] {
            await #expect(throws: (any Error).self) {
                try await fixture.store.publishHostProcessedProjectionIfNotReady(recordingID: fixture.recordingID,
                    speakerOutcome: invalid, structuredTranscriptData: data)
            }
            #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .projecting)
            #expect(try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID) == nil)
        }
        let completed = try outcome([missing])
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(recordingID: fixture.recordingID,
            speakerOutcome: completed, structuredTranscriptData: data))
        #expect(try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID) == completed)
        // Same path, different bytes must not revive a receipt for the old generation.
        try Data(#"{"speakers":[]}"#.utf8).write(to: URL(fileURLWithPath: #require(recording.jsonPath)))
        await #expect(throws: (any Error).self) {
            try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID)
        }
    }

    @Test func disabledDiarizationPublishesAnExplicitOutcome() async throws {
        let fixture = try await makeFixture(canonicalPCMHash: CanonicalPCMHash(Data(repeating: 7, count: 32)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data(#"{"words":[],"speakers":[]}"#.utf8)
        _ = try await fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
            text: "hello", modelID: "host", structuredTranscriptData: data)
        let recording = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        let disabled = try HostSpeakerProcessingOutcome(canonicalRecordingID: recording.canonicalID,
            canonicalPCMHash: #require(recording.canonicalPCMHash), producerDeviceID: DeviceID(Data(repeating: 9, count: 32)),
            processingArtifactSHA256: Data(SHA256.hash(data: data)), diarization: .disabled, clusters: [])
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(recordingID: fixture.recordingID,
            speakerOutcome: disabled, structuredTranscriptData: data))
        #expect(try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID) == disabled)
    }

    @Test func readyHostTranscriptDoesNotProveSpeakerIdentificationCompleted() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A diarized transcript can contain a cluster without a usable voice
        // embedding. Processing readiness must not become a speaker receipt.
        let data = Data(#"{"words":[{"text":"hello","startMs":0,"endMs":500}],"speakers":[{"speaker":0,"startMs":0,"endMs":500}]}"#.utf8)
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID, text: "hello", modelID: "host",
            structuredTranscriptData: data))
        let staged = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(staged.processing.state == .projecting)
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(
            recordingID: fixture.recordingID, speakerEvidence: [:]))
        let ready = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(ready.processing.state == .ready)
        #expect(ready.projection.state == .ready)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(ready.jsonPath))) == data)
        #expect(try await fixture.store.currentHostSpeakerEvidence(
            recordingID: fixture.recordingID, speakerIndex: 0) == nil)
        #expect(try await fixture.store.selectedEdgeArtifactSource(recordingID: fixture.recordingID) == nil)
    }

    @Test func structuredHostTranscriptIsDurableReusableAndProtectedFromLateWork() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data(#"{"words":[{"text":"mixed","startMs":0,"endMs":500}],"overlapRanges":[{"startMs":100,"endMs":400}]}"#.utf8)
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
            text: "mixed", modelID: "host", structuredTranscriptData: data))
        let first = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        let path = try #require(first.jsonPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
            text: "mixed", modelID: "host", structuredTranscriptData: data))
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.jsonPath == path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".harc-derived").path).count == 1)
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(recordingID: fixture.recordingID))
        #expect(try await !fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
            text: "late", modelID: "host", structuredTranscriptData: Data("different".utf8)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".harc-derived").path).count == 1)
    }

    @Test func edgeWinnerInvalidatesEarlierHostStructuredProjection() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
            text: "Host text", modelID: "host", structuredTranscriptData: Data("{}".utf8)))
        let staged = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        let hostJSON = try #require(staged.jsonPath)
        try await fixture.store.applyAcceptedEdgeTranscript(recordingID: fixture.recordingID,
            text: "Client text", modelID: "edge")
        let winner = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(winner.transcriptText == "Client text")
        #expect(winner.jsonPath == nil)
        #expect(FileManager.default.fileExists(atPath: hostJSON))
        #expect(try await !fixture.store.publishHostProcessedProjectionIfNotReady(recordingID: fixture.recordingID))
    }

    @Test func structuredPublicationFailureLeavesLibraryBindingUntouched() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        let blocker = fixture.root.appendingPathComponent(".harc-derived")
        try Data("preserve".utf8).write(to: blocker)
        do {
            _ = try await fixture.store.stageHostProcessedTranscriptIfNotReady(recordingID: fixture.recordingID,
                text: "new", modelID: "host", structuredTranscriptData: Data("{}".utf8))
            Issue.record("Expected publication failure")
        } catch { }
        let after = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(after.jsonPath == before.jsonPath)
        #expect(after.transcriptText == before.transcriptText)
        #expect(after.processing == before.processing)
        #expect(try Data(contentsOf: blocker) == Data("preserve".utf8))
    }

    @Test("accepted edge result remains terminal over late Host work and failure")
    func edgeWinsLateHostWork() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.store.beginHostProcessingIfNotReady(
            id: fixture.recordingID
        ))
        try await fixture.store.applyAcceptedEdgeTranscript(
            recordingID: fixture.recordingID,
            text: "edge transcript",
            modelID: "harc-stt.edge"
        )
        #expect(try await !fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID,
            text: "late Host transcript",
            modelID: "harc-stt.host"
        ))
        let failure = try ProcessingFailure(
            code: "host.processing_retry",
            message: "retry"
        )
        #expect(try await !fixture.store.markHostProcessingFailureIfNotReady(
            recordingID: fixture.recordingID,
            failure: failure
        ))

        let stored = try #require(
            try await fixture.store.fetch(id: fixture.recordingID)
        )
        #expect(stored.transcriptText == "edge transcript")
        #expect(stored.sttModelID == "harc-stt.edge")
        #expect(stored.processing == .ready)
        #expect(stored.projection == .readyV1)
        #expect(FileManager.default.fileExists(
            atPath: OKFProjection.markdownURL(for: stored).path
        ))
    }

    @Test("edge result supersedes staged Host transcript before publication")
    func edgeWinsStagedHostWork() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.store.beginHostProcessingIfNotReady(
            id: fixture.recordingID
        ))
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID,
            text: "Host transcript",
            modelID: "harc-stt.host"
        ))
        try await fixture.store.applyAcceptedEdgeTranscript(
            recordingID: fixture.recordingID,
            text: "edge transcript",
            modelID: "harc-stt.edge"
        )
        #expect(try await !fixture.store.publishHostProcessedProjectionIfNotReady(
            recordingID: fixture.recordingID
        ))

        let stored = try #require(
            try await fixture.store.fetch(id: fixture.recordingID)
        )
        #expect(stored.transcriptText == "edge transcript")
        #expect(stored.processing == .ready)
        #expect(stored.projection == .readyV1)
    }

    @Test("Host processing publishes when no edge artifact wins")
    func hostPublishes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.store.beginHostProcessingIfNotReady(
            id: fixture.recordingID
        ))
        #expect(try await fixture.store.stageHostProcessedTranscriptIfNotReady(
            recordingID: fixture.recordingID,
            text: "Host transcript",
            modelID: "harc-stt.host"
        ))
        #expect(try await fixture.store.publishHostProcessedProjectionIfNotReady(
            recordingID: fixture.recordingID
        ))

        let stored = try #require(
            try await fixture.store.fetch(id: fixture.recordingID)
        )
        #expect(stored.transcriptText == "Host transcript")
        #expect(stored.sttModelID == "harc-stt.host")
        #expect(stored.processing == .ready)
        #expect(stored.projection == .readyV1)
        #expect(FileManager.default.fileExists(
            atPath: OKFProjection.markdownURL(for: stored).path
        ))
    }

    private func makeFixture(canonicalPCMHash: CanonicalPCMHash? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let wav = root.appendingPathComponent("recording.wav")
        var recording = Recording(
            wavPath: wav.path,
            txtPath: root.appendingPathComponent("recording.md").path,
            jsonPath: root.appendingPathComponent("recording.json").path,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            title: "Processing arbitration",
            transcriptText: nil
        )
        recording.canonicalPCMHash = canonicalPCMHash
        recording.processing = .pending
        recording.projection = .pending
        let store = try await RecordingStore.inMemory()
        let inserted = try await store.upsert(recording)
        if let canonicalPCMHash {
            // This fixture has no actual WAV; ordinary upsert correctly refuses
            // to accept an unverified caller-supplied PCM hash.
            let queue = await store.uncoordinatedDB
            try await queue.write { database in
                try database.execute(sql: "UPDATE recordings SET canonical_pcm_sha256 = ?, canonical_pcm_frames = 16000 WHERE id = ?",
                    arguments: [canonicalPCMHash.rawBytes, inserted.id])
            }
        }
        return Fixture(
            root: root,
            store: store,
            recordingID: try #require(inserted.id)
        )
    }

    private struct Fixture {
        let root: URL
        let store: RecordingStore
        let recordingID: Int64
    }
}
