import Foundation
import Testing
import HarcClient
import HarcCore
@testable import HarcAudio

@Suite("RecordingCommitter")
struct RecordingCommitterTests {
    private enum TestFailure: Error { case unexpectedCommitOutcome }

    private actor FakeOutboxCommitter: RecordingCommitter {
        private(set) var accepted: [CapturedRecording] = []

        func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
            accepted.append(captured)
            return .acceptedForDeferredPublication(localMasterURL: captured.localMasterURL)
        }

        var acceptedCount: Int { accepted.count }
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/harc-committer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeMaster(in root: URL, bytes: Data = Data("durable-master".utf8)) throws -> URL {
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let master = cache.appendingPathComponent("capture.wav")
        try bytes.write(to: master)
        return master
    }

    @Test("standalone publication atomically removes cache identity and rewrites transcript path")
    func standalonePublicationPreservesCompatibilityResult() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let master = try makeMaster(in: root)
        let destination = RecordingDestination(
            baseDirectory: root.appendingPathComponent("published", isDirectory: true)
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(42)
        let transcript = SessionTranscript(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: master.path,
            joinedText: "A durable transcript.",
            words: [],
            speakers: [],
            chunks: []
        )
        let embedding = SpeakerEmbeddingRow(
            speakerIndex: 0,
            vector: [0.25, 0.5],
            totalMs: 42_000,
            segmentCount: 2
        )
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: transcript,
            speakerEmbeddings: [embedding],
            warnings: [.diarizationFailed(message: "retry diarization")]
        )

        let outcome = try await StandaloneRecordingCommitter(destination: destination).commit(captured)
        guard case .standalonePublished(let acceptedCapture, let result) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(acceptedCapture.startedAt == startedAt)
        #expect(acceptedCapture.endedAt == endedAt)
        #expect(!FileManager.default.fileExists(atPath: master.path))
        #expect(FileManager.default.fileExists(atPath: result.wavURL.path))
        #expect(try Data(contentsOf: result.wavURL) == Data("durable-master".utf8))
        #expect(result.speakerEmbeddings == [embedding])
        #expect(result.diarizationError == "retry diarization")
        let txtURL = try #require(result.txtURL)
        let jsonURL = try #require(result.jsonURL)
        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let persisted = try decoder.decode(
            SessionTranscript.self,
            from: Data(contentsOf: jsonURL)
        )
        #expect(persisted.audioPath == result.wavURL.path)
        #expect(abs(persisted.startedAt.timeIntervalSince(startedAt)) < 0.000_001)
        #expect(abs(persisted.endedAt.timeIntervalSince(endedAt)) < 0.000_001)
    }

    @Test("capture without transcript publishes WAV with nil sibling URLs")
    func noTranscriptPublishesOnlyWAV() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let master = try makeMaster(in: root)
        let destination = RecordingDestination(
            baseDirectory: root.appendingPathComponent("published", isDirectory: true)
        )
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let outcome = try await StandaloneRecordingCommitter(destination: destination).commit(captured)
        guard case .standalonePublished(_, let result) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(FileManager.default.fileExists(atPath: result.wavURL.path))
        #expect(!FileManager.default.fileExists(atPath: master.path))
        #expect(result.txtURL == nil)
        #expect(result.jsonURL == nil)
    }

    @Test("existing destination collision selects suffix without replacing existing WAV")
    func collisionSelectsSuffixAndPreservesExistingFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let newBytes = Data("new-master".utf8)
        let master = try makeMaster(in: root, bytes: newBytes)
        let destination = RecordingDestination(
            baseDirectory: root.appendingPathComponent("published", isDirectory: true)
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let occupiedURL = try destination.publicPath(for: startedAt)
        try FileManager.default.createDirectory(
            at: occupiedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingBytes = Data("existing-master".utf8)
        try existingBytes.write(to: occupiedURL)
        let expectedSuffixedURL = occupiedURL.deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(
                occupiedURL.deletingPathExtension().lastPathComponent + "-1.wav"
            )
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1)
        )

        let outcome = try await StandaloneRecordingCommitter(destination: destination).commit(captured)
        guard case .standalonePublished(_, let result) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(result.wavURL == expectedSuffixedURL)
        #expect(try Data(contentsOf: occupiedURL) == existingBytes)
        #expect(try Data(contentsOf: result.wavURL) == newBytes)
        #expect(!FileManager.default.fileExists(atPath: master.path))
    }

    @Test("sibling write failure is best effort after WAV publication")
    func siblingFailureKeepsPublishedWAV() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("published-before-sidecars".utf8)
        let master = try makeMaster(in: root, bytes: bytes)
        let destination = RecordingDestination(
            baseDirectory: root.appendingPathComponent("published", isDirectory: true)
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedWAVURL = try destination.publicPath(for: startedAt)
        try FileManager.default.createDirectory(
            at: expectedWAVURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // TranscriptWriter writes Markdown first. Reserving that exact path as
        // a directory forces a deterministic sibling failure after the WAV's
        // successful move without making the destination directory unwritable.
        let blockedMarkdownURL = expectedWAVURL.deletingPathExtension().appendingPathExtension("md")
        try FileManager.default.createDirectory(at: blockedMarkdownURL, withIntermediateDirectories: false)
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1),
            transcript: SessionTranscript(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(1),
                audioPath: master.path,
                joinedText: "Sidecar failure must not unpublish audio.",
                words: [],
                speakers: [],
                chunks: []
            )
        )

        let outcome = try await StandaloneRecordingCommitter(destination: destination).commit(captured)
        guard case .standalonePublished(_, let result) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(result.wavURL == expectedWAVURL)
        #expect(try Data(contentsOf: result.wavURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: master.path))
        #expect(result.txtURL == nil)
        #expect(result.jsonURL == nil)
    }

    @Test("failed standalone move leaves cache master recoverable")
    func failedPublicationPreservesMaster() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("must-survive".utf8)
        let master = try makeMaster(in: root, bytes: bytes)

        // A regular file cannot contain the destination hierarchy, forcing
        // the move to fail before the cache source changes identity.
        let blockedBase = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedBase)
        let committer = StandaloneRecordingCommitter(
            destination: RecordingDestination(baseDirectory: blockedBase)
        )
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        await #expect(throws: (any Error).self) {
            _ = try await committer.commit(captured)
        }
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(try Data(contentsOf: master) == bytes)
    }

    @Test("outbox-like committer accepts capture without moving its master")
    func deferredCommitterRetainsLocalMaster() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let master = try makeMaster(in: root)
        let captured = CapturedRecording(
            localMasterURL: master,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let outbox = FakeOutboxCommitter()

        let outcome = try await outbox.commit(captured)
        guard case .acceptedForDeferredPublication(let retainedURL) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(retainedURL == master)
        #expect(await outbox.acceptedCount == 1)
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(try Data(contentsOf: master) == Data("durable-master".utf8))
    }
}
