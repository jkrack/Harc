import Testing
import Foundation
import HarcClient
import HarcCore
import HarcStore
@testable import HarcUI

@Suite("TranscriptDocument")
struct TranscriptDocumentTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-doc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSON(_ transcript: SessionTranscript, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: url)
    }

    @Test("loads .txt + .json happy path")
    func happyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("10-00-00.wav")
        let txtURL = dir.appendingPathComponent("10-00-00.txt")
        let jsonURL = dir.appendingPathComponent("10-00-00.json")
        try Data().write(to: wavURL)  // fake but present
        try "hello world".write(to: txtURL, atomically: true, encoding: .utf8)
        try writeJSON(SessionTranscript(
            startedAt: Date(), endedAt: Date(), audioPath: wavURL.path,
            joinedText: "hello world",
            words: [Word(text: "hello", startMs: 0, endMs: 500),
                    Word(text: "world", startMs: 500, endMs: 1000)],
            speakers: [],
            chunks: []
        ), to: jsonURL)

        let rec = Recording(
            wavPath: wavURL.path,
            txtPath: txtURL.path,
            jsonPath: jsonURL.path,
            startedAt: Date()
        )
        let doc = TranscriptDocument.load(recording: rec)
        #expect(doc.initialText == "hello world")
        #expect(doc.words.count == 2)
        #expect(doc.audioAvailable)
        #expect(doc.jsonAvailable)
        #expect(doc.wordIndex.entries.count == 2)
    }

    @Test("missing .txt falls back to joinedText from .json")
    func missingTxtFallsBackToJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("a.wav")
        let jsonURL = dir.appendingPathComponent("a.json")
        try Data().write(to: wavURL)
        try writeJSON(SessionTranscript(
            startedAt: Date(), endedAt: Date(), audioPath: wavURL.path,
            joinedText: "from the json",
            words: [], speakers: [], chunks: []
        ), to: jsonURL)

        let rec = Recording(
            wavPath: wavURL.path,
            jsonPath: jsonURL.path,
            startedAt: Date()
        )
        let doc = TranscriptDocument.load(recording: rec)
        #expect(doc.initialText == "from the json")
    }

    @Test("missing audio → audioAvailable false, wavURL nil")
    func missingAudio() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = Recording(
            wavPath: dir.appendingPathComponent("missing.wav").path,
            startedAt: Date(),
            transcriptText: "text only"
        )
        let doc = TranscriptDocument.load(recording: rec)
        #expect(!doc.audioAvailable)
        #expect(doc.wavURL == nil)
        #expect(doc.initialText == "text only")
    }

    @Test("save round-trip: write .txt, stamp manualEditAt on JSON")
    func saveRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("s.wav")
        let txtURL = dir.appendingPathComponent("s.txt")
        let jsonURL = dir.appendingPathComponent("s.json")
        try Data().write(to: wavURL)
        try "original".write(to: txtURL, atomically: true, encoding: .utf8)
        try writeJSON(SessionTranscript(
            startedAt: Date(), endedAt: Date(), audioPath: wavURL.path,
            joinedText: "original", words: [], speakers: [], chunks: []
        ), to: jsonURL)

        let rec = Recording(
            wavPath: wavURL.path,
            txtPath: txtURL.path,
            jsonPath: jsonURL.path,
            startedAt: Date()
        )
        let doc = TranscriptDocument.load(recording: rec)
        _ = try doc.save(editedText: "edited")

        let reread = try String(contentsOf: txtURL, encoding: .utf8)
        #expect(reread == "edited")

        // manualEditAt stamped
        let jsonData = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let transcript = try decoder.decode(SessionTranscript.self, from: jsonData)
        #expect(transcript.manualEditAt != nil)
    }

    @Test("save succeeds even when JSON is missing (no stamp, no throw)")
    func saveWithoutJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("s.wav")
        let txtURL = dir.appendingPathComponent("s.txt")
        try Data().write(to: wavURL)
        try "x".write(to: txtURL, atomically: true, encoding: .utf8)

        let rec = Recording(
            wavPath: wavURL.path,
            txtPath: txtURL.path,
            startedAt: Date()
        )
        let doc = TranscriptDocument.load(recording: rec)
        _ = try doc.save(editedText: "y")
        #expect(try String(contentsOf: txtURL, encoding: .utf8) == "y")
    }
}
