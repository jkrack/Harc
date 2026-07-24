import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("TranscriptWriter")
struct TranscriptWriterTests {
    private func tempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-tw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("writeSiblings creates OKF .md and .json next to the .wav")
    func writesSiblings() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let wavURL = base.appendingPathComponent("13-14-15.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data([0x00]))

        let transcript = SessionTranscript(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_005),
            audioPath: wavURL.path,
            joinedText: "hello world",
            words: [
                Word(text: "hello", startMs: 0, endMs: 500),
                Word(text: "world", startMs: 500, endMs: 1000),
            ],
            speakers: [],
            chunks: []
        )

        try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)

        let mdURL = base.appendingPathComponent("13-14-15.md")
        let jsonURL = base.appendingPathComponent("13-14-15.json")
        #expect(FileManager.default.fileExists(atPath: mdURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let md = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(md.hasPrefix("---\ntype: Meeting Transcript\n"))
        #expect(md.contains("resource: ./13-14-15.wav"))
        #expect(OKFMarkdown.extractTranscript(from: md) == "hello world")

        let json = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SessionTranscript.self, from: json)
        #expect(decoded == transcript)
    }

    @Test("writeSiblings regenerates the day index listing the new document")
    func writesDayIndex() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let wavURL = base.appendingPathComponent("09-00-00.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data())

        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: wavURL.path,
            joinedText: "short",
            words: [],
            speakers: [],
            chunks: []
        )
        try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)

        let index = try String(
            contentsOf: base.appendingPathComponent("index.md"), encoding: .utf8
        )
        #expect(index.contains("(./09-00-00.md)"))
    }

    @Test("writeSiblings is atomic — a failed write doesn't leave partial files")
    func atomicSemantics() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let wavURL = base.appendingPathComponent("hh-mm-ss.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data())

        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: wavURL.path,
            joinedText: "short",
            words: [],
            speakers: [],
            chunks: []
        )

        try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)
        let md = try String(contentsOf: base.appendingPathComponent("hh-mm-ss.md"), encoding: .utf8)
        #expect(OKFMarkdown.extractTranscript(from: md) == "short")
    }
}
