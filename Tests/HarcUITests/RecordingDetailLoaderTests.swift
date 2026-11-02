import Testing
import Foundation
import HarcClient
import HarcCore
import HarcStore
import HarcExport
@testable import HarcUI

@Suite("Library recording detail loading")
struct RecordingDetailLoaderTests {
    private static func snapshot(_ recording: Recording) -> RecordingDetailSnapshot {
        let url = URL(fileURLWithPath: recording.wavPath)
        let document = TranscriptDocument(recordingID: recording.id,
            initialText: recording.wavPath, words: [], speakers: [], wavURL: nil,
            txtURL: url.deletingPathExtension().appendingPathExtension("md"), jsonURL: nil,
            audioAvailable: false, jsonAvailable: false)
        return RecordingDetailSnapshot(recording: recording, document: document,
            turnSpeakerIndices: [], speakerIndices: [], transcriptText: recording.wavPath,
            transcriptLoadError: nil)
    }

    @Test("file-backed work runs off the UI actor") @MainActor
    func readsDoNotBlockUIActor() async {
        let recording = Recording(wavPath: "/missing/off-main.wav", startedAt: .now)
        let snapshot = await RecordingDetailSnapshot.load(recording: recording) { recording in
            #expect(!Thread.isMainThread)
            return Self.snapshot(recording).document
        }
        #expect(snapshot.wavPath == recording.wavPath)
    }

    @Test("a late A cannot replace B or a newer selection of A") @MainActor
    func rapidReselectionRejectsOldResults() async {
        let reads = ControlledReads()
        let loader = RecordingDetailLoader(read: { await reads.read($0) })
        var started = reads.started.makeAsyncIterator()
        let a = Recording(wavPath: "/a.wav", startedAt: .now)
        let b = Recording(wavPath: "/b.wav", startedAt: .now)
        let firstA = Task { await loader.load(recording: a) }
        let a1 = await started.next()!
        let firstB = Task { await loader.load(recording: b) }
        let b1 = await started.next()!
        let secondA = Task { await loader.load(recording: a) }
        let a2 = await started.next()!
        await reads.finish(a2)
        #expect(await secondA.value?.wavPath == a.wavPath)
        await reads.finish(a1)
        await reads.finish(b1)
        #expect(await firstA.value == nil)
        #expect(await firstB.value == nil)
    }

    @Test("leaving the recording or cancelling its task rejects a late read") @MainActor
    func cancellationRejectsLateResults() async {
        let reads = ControlledReads()
        let loader = RecordingDetailLoader(read: { await reads.read($0) })
        var started = reads.started.makeAsyncIterator()
        let recording = Recording(wavPath: "/a.wav", startedAt: .now)
        let leaving = Task { await loader.load(recording: recording) }
        let first = await started.next()!
        loader.cancel()
        await reads.finish(first)
        #expect(await leaving.value == nil)
        let cancelled = Task { await loader.load(recording: recording) }
        let second = await started.next()!
        cancelled.cancel()
        await reads.finish(second)
        #expect(await cancelled.value == nil)
    }

    @Test("speaker metadata reuses one decoded sidecar, including overlap and gaps")
    func snapshotKeepsProjectionWithoutFurtherFileReads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("recording.json")
        let markdown = dir.appendingPathComponent("recording.md")
        let words: [Word] = [.init(text: "one", startMs: 0, endMs: 500),
                             .init(text: "mixed", startMs: 600, endMs: 1000),
                             .init(text: "three", startMs: 1200, endMs: 1500)]
        var transcript = SessionTranscript(startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1002),
            audioPath: dir.appendingPathComponent("recording.wav").path,
            joinedText: "one mixed three", words: words,
            speakers: [.init(speaker: 2, startMs: 0, endMs: 500),
                       .init(speaker: 7, startMs: 600, endMs: 1000),
                       .init(speaker: 2, startMs: 1200, endMs: 1500)], chunks: [])
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 600, endMs: 1000)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(transcript).write(to: json)
        try "Personally corrected transcript".write(to: markdown, atomically: true, encoding: .utf8)
        let recording = Recording(wavPath: transcript.audioPath, txtPath: markdown.path,
                                  jsonPath: json.path, startedAt: .now)
        let expected = ExportInputBuilder.build(from: recording).segments.compactMap(\.speaker)
        let snapshot = await RecordingDetailSnapshot.load(recording: recording)
        #expect(snapshot.document.initialText == "Personally corrected transcript")
        #expect(snapshot.document.words == words)
        #expect(snapshot.document.overlapRanges == transcript.overlapRanges)
        #expect(snapshot.turnSpeakerIndices == expected)
        #expect(snapshot.speakerIndices == [2])
        try FileManager.default.removeItem(at: json)
        #expect(snapshot.document.replacingInitialText("new edit").structuredTranscript == transcript)
        #expect(ExportInputBuilder.build(from: recording,
            transcript: snapshot.document.structuredTranscript).segments.compactMap(\.speaker) == expected)
        #expect(snapshot.speakerIndices == [2])
    }

    @Test("empty and missing sidecars keep the tolerant document fallback")
    func missingSidecars() async {
        let rec = Recording(wavPath: "/not-present.wav", startedAt: .now,
                            transcriptText: "cached transcript")
        let snapshot = await RecordingDetailSnapshot.load(recording: rec)
        #expect(snapshot.document.initialText == "cached transcript")
        #expect(snapshot.transcriptText == "cached transcript")
        #expect(snapshot.speakerIndices.isEmpty)
        #expect(!snapshot.document.audioAvailable)
    }

    @Test("long transcript metadata remains usable after its sidecar disappears")
    func longTranscriptProjectionIsReused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("long.json")
        let md = dir.appendingPathComponent("long.md")
        let count = 16000
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
        let snapshot = await RecordingDetailSnapshot.load(recording: rec)
        let snapshotMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        #expect(snapshot.turnSpeakerIndices == projected)
        #expect(snapshot.speakerIndices == [0, 1, 2])
        #expect(snapshot.document.words.count == count)
        try FileManager.default.removeItem(at: json)
        let lookupStart = ProcessInfo.processInfo.systemUptime
        var total = 0
        for _ in 0..<1000 { total += snapshot.speakerIndices.count }
        let lookupMS = (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000
        #expect(total == 3000)
        print("HARC_DETAIL_BENCHMARK words=\(count) turns=\(speakers.count) legacy_one_speaker_lookup_ms=\(legacyMS) background_snapshot_ms=\(snapshotMS) cached_1000_lookups_ms=\(lookupMS)")
    }

    @Test("new transcript generations invalidate metadata, while summary/title edits do not")
    func sourceInvalidation() {
        let rec = Recording(wavPath: "/a.wav", startedAt: .now, transcriptText: "first")
        let snapshot = Self.snapshot(rec)
        var updated = rec
        updated.title = "A renamed meeting"
        updated.summaryMarkdown = "New summary"
        #expect(snapshot.matchesSource(recording: updated))
        updated.transcriptText = "new transcript"
        #expect(!snapshot.matchesSource(recording: updated))
        updated = rec
        updated.jsonPath = "/new-generation.json"
        #expect(!snapshot.matchesSource(recording: updated))
        updated = rec
        updated.transcribedAt = .now
        #expect(!snapshot.matchesSource(recording: updated))
    }

    private actor ControlledReads {
        nonisolated let started: AsyncStream<Int>
        private let continuation: AsyncStream<Int>.Continuation
        private var nextID = 0
        private var pending: [Int: (Recording, CheckedContinuation<RecordingDetailSnapshot, Never>)] = [:]
        init() {
            let pair = AsyncStream<Int>.makeStream()
            started = pair.stream
            continuation = pair.continuation
        }
        func read(_ recording: Recording) async -> RecordingDetailSnapshot {
            nextID += 1
            let id = nextID
            return await withCheckedContinuation { reply in
                pending[id] = (recording, reply)
                continuation.yield(id)
            }
        }
        func finish(_ id: Int) {
            guard let (recording, reply) = pending.removeValue(forKey: id) else { return }
            reply.resume(returning: RecordingDetailLoaderTests.snapshot(recording))
        }
    }
}
