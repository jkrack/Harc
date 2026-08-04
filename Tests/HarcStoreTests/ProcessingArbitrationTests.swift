import Foundation
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Host and edge processing arbitration")
struct ProcessingArbitrationTests {
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
        #expect(FileManager.default.fileExists(atPath: stored.jsonPath!))
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
        #expect(FileManager.default.fileExists(atPath: stored.jsonPath!))
    }

    private func makeFixture() async throws -> Fixture {
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
        recording.processing = .pending
        recording.projection = .pending
        let store = try await RecordingStore.inMemory()
        let inserted = try await store.upsert(recording)
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
