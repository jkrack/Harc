import Testing
import Foundation
import HarcClient
import HarcStore
import HarcCore
import HarcExport
@testable import HarcUI

@Suite("AmplitudeEnvelopeLoader")
@MainActor
struct AmplitudeEnvelopeLoaderTests {

    private static var fixtureURL: URL {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav")
    }

    @Test("returns array of requested sample count")
    func returnsRequestedSampleCount() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(envelope.count == 256)
    }

    @Test("all values are in [0, 1]")
    func valuesNormalized() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        for v in envelope {
            #expect(v >= 0)
            #expect(v <= 1)
        }
    }

    @Test("at least one sample exceeds 0.1 (fixture has audible speech)")
    func envelopeHasContent() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let maxVal = envelope.max() ?? 0
        #expect(maxVal > 0.1, "expected at least one envelope sample > 0.1; got max \(maxVal)")
    }

    @Test("cache returns identical contents on second call")
    func cacheHit() async throws {
        let first = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let second = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(first == second)
    }

    @Test("missing file throws")
    func missingFileThrows() async {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-a-real-harc-file-\(UUID().uuidString).wav")
        await #expect(throws: (any Error).self) {
            _ = try await AmplitudeEnvelopeLoader.load(url: bogus, samples: 64)
        }
    }
    @Test("cancellation reaches an already-running detached decoder")
    func cancellationReachesDecoder() async throws {
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await AmplitudeEnvelopeLoader.cancellableDecode {
                started.continuation.yield(())
                // Bounded wait avoids hanging the suite if propagation regresses.
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                #expect(Task.isCancelled)
                try Task.checkCancellation()
                return [1]
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("cancelled callers cannot consume a cached waveform")
    func cancelledCacheRead() async throws {
        _ = try await AmplitudeEnvelopeLoader.load(url: Self.fixtureURL, samples: 17)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AmplitudeEnvelopeLoader.load(url: Self.fixtureURL, samples: 17)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("long transcript metadata remains usable after its sidecar disappears")
    func longTranscriptProjectionIsReused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("long.json")
        let md = dir.appendingPathComponent("long.md")
        let count = 8000
        let words = (0..<count).map { Word(text: "word\($0 % 100)", startMs: $0 * 150, endMs: $0 * 150 + 120) }
        let speakers = stride(from: 0, to: count, by: 8).map {
            SpeakerSegment(speaker: ($0 / 8) % 3, startMs: $0 * 150, endMs: ($0 + 8) * 150)
        }
        let text = words.map(\.text).joined(separator: " ")
        let date = Date(timeIntervalSince1970: 1000)
        let session = SessionTranscript(startedAt: date, endedAt: date.addingTimeInterval(2400),
            audioPath: dir.appendingPathComponent("long.wav").path, joinedText: text,
            words: words, speakers: speakers, chunks: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(session).write(to: json)
        try text.write(to: md, atomically: true, encoding: .utf8)
        let rec = Recording(wavPath: session.audioPath, txtPath: md.path, jsonPath: json.path,
            startedAt: date, transcriptText: text)
        let start = ProcessInfo.processInfo.systemUptime
        let projected = ExportInputBuilder.build(from: rec).segments.compactMap(\.speaker)
        let legacyMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let loadStart = ProcessInfo.processInfo.systemUptime
        let metadata = await RecordingSpeakerMetadata.load(recording: rec)
        let cachedIndices = metadata.indices
        let snapshotMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        #expect(cachedIndices == Array(Set(projected)).sorted())
        #expect(cachedIndices == [0, 1, 2])
        try FileManager.default.removeItem(at: json)
        let lookupStart = ProcessInfo.processInfo.systemUptime
        var total = 0
        for _ in 0..<1000 { total += cachedIndices.count }
        let lookupMS = (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000
        #expect(total == 3000)
        print("HARC_DETAIL_BENCHMARK words=\(count) turns=\(speakers.count) legacy_one_speaker_lookup_ms=\(legacyMS) snapshot_preparation_ms=\(snapshotMS) cached_1000_lookups_ms=\(lookupMS)")
    }


    @Test("same-selection replacement invalidates speaker metadata without editing text")
    func metadataReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("same.json")
        let wav = directory.appendingPathComponent("same.wav")
        var transcript = SessionTranscript(startedAt: .now, endedAt: .now,
            audioPath: wav.path, joinedText: "hello", words: [.init(text: "hello", startMs: 0, endMs: 500)],
            speakers: [.init(speaker: 1, startMs: 0, endMs: 500)], chunks: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(transcript).write(to: json)
        var recording = Recording(wavPath: wav.path, jsonPath: json.path, startedAt: .now,
                                  transcriptText: "original transcript")
        let old = await RecordingSpeakerMetadata.load(recording: recording)
        transcript.speakers = [.init(speaker: 7, startMs: 0, endMs: 500)]
        try encoder.encode(transcript).write(to: json)
        recording.transcriptText = "replacement transcript"
        recording.transcribedAt = .now
        let replacement = await RecordingSpeakerMetadata.load(recording: recording)
        #expect(old.recording.wavPath == replacement.recording.wavPath)
        #expect(old.recording != recording)
        #expect(replacement.recording == recording)
        #expect(old.indices == [1])
        #expect(replacement.indices == [7])
        #expect(old.recording.transcriptText == "original transcript")
    }

}
