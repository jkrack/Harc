import Testing
import Foundation
@testable import HarcUI

@Suite("RecordingsIndex")
@MainActor
struct RecordingsIndexTests {
    private func tempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-idx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func fakeRecording(base: URL, year: String, day: String, time: String, withSiblings: Bool) throws -> URL {
        let dir = base.appendingPathComponent(year).appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("\(time).wav")
        try "fake".write(to: wav, atomically: true, encoding: .utf8)
        if withSiblings {
            try "hello world\n".write(to: dir.appendingPathComponent("\(time).txt"), atomically: true, encoding: .utf8)
            try "{}".write(to: dir.appendingPathComponent("\(time).json"), atomically: true, encoding: .utf8)
        }
        return wav
    }

    @Test("refresh returns recordings sorted newest-first")
    func newestFirst() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-15", time: "10-00-00", withSiblings: true)
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "09-30-15", withSiblings: true)
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-16", time: "14-22-00", withSiblings: false)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()

        #expect(index.entries.count == 3)
        #expect(index.entries[0].date.contains("2026-04-17"))
        #expect(index.entries[1].date.contains("2026-04-16"))
        #expect(index.entries[2].date.contains("2026-04-15"))
    }

    @Test("entry includes txt preview when sibling exists")
    func textPreview() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00", withSiblings: true)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()
        let entry = try #require(index.entries.first)
        #expect(entry.preview?.contains("hello world") == true)
    }

    @Test("entries without siblings still appear with nil preview")
    func missingSiblings() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00", withSiblings: false)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()
        let entry = try #require(index.entries.first)
        #expect(entry.preview == nil)
    }
}
