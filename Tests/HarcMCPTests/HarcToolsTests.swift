import Testing
import Foundation
import MCP
@testable import HarcMCP
@testable import HarcStore

@Suite("HarcTools")
struct HarcToolsTests {

    private func makeFixture() async throws -> (HarcTools, RecordingStore, URL) {
        let store = try await RecordingStore.inMemory()
        let day = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-mcp-tests-\(UUID().uuidString)/2026/2026-07-31")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        return (HarcTools(store: store), store, day)
    }

    @discardableResult
    private func seed(
        store: RecordingStore,
        dayDir: URL,
        time: String,
        title: String,
        transcript: String
    ) async throws -> Recording {
        let wav = dayDir.appendingPathComponent("\(time).wav")
        return try await store.upsert(Recording(
            wavPath: wav.path,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600),
            title: title,
            transcriptText: transcript
        ))
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { part in
            if case .text(let s, _, _) = part { return s }
            return nil
        }.joined()
    }

    @Test("search_notes finds seeded transcripts")
    func searchFinds() async throws {
        let (tools, store, day) = try await makeFixture()
        try await seed(store: store, dayDir: day, time: "10-00-00",
                       title: "Budget sync", transcript: "we discussed quarterly renewals")
        try await seed(store: store, dayDir: day, time: "11-00-00",
                       title: "Standup", transcript: "shipping the new parser today")

        let result = await tools.call(name: "search_notes", arguments: ["query": "renewals"])
        #expect(result.isError == false)
        let body = text(result)
        #expect(body.contains("Budget sync"))
        #expect(!body.contains("Standup"))
    }

    @Test("search_notes rejects an empty query")
    func searchRejectsEmpty() async throws {
        let (tools, _, _) = try await makeFixture()
        let result = await tools.call(name: "search_notes", arguments: ["query": "  "])
        #expect(result.isError == true)
    }

    @Test("get_recording returns detail with transcript and md path")
    func getRecordingDetail() async throws {
        let (tools, store, day) = try await makeFixture()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00",
                                 title: "Budget sync", transcript: "words here")

        let result = await tools.call(
            name: "get_recording",
            arguments: ["recording_id": .int(Int(rec.id!))]
        )
        #expect(result.isError == false)
        let body = text(result)
        #expect(body.contains("words here"))
        #expect(body.contains("10-00-00.md"))
    }

    @Test("update_title writes through the store and regenerates the md file")
    func updateTitleRegeneratesProjection() async throws {
        let (tools, store, day) = try await makeFixture()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00",
                                 title: "Old name", transcript: "some transcript")

        let result = await tools.call(
            name: "update_title",
            arguments: ["recording_id": .int(Int(rec.id!)), "title": .string("Renamed by agent")]
        )
        #expect(result.isError == false)

        let updated = try await store.fetch(id: rec.id!)
        #expect(updated?.title == "Renamed by agent")

        // The write must have reprojected the OKF doc from the MCP process.
        let md = try String(
            contentsOf: day.appendingPathComponent("10-00-00.md"), encoding: .utf8
        )
        #expect(md.contains("Renamed by agent"))
    }

    @Test("update_tags and set_speaker_name round-trip")
    func tagsAndSpeakers() async throws {
        let (tools, store, day) = try await makeFixture()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00",
                                 title: "T", transcript: "x")

        let tagResult = await tools.call(
            name: "update_tags",
            arguments: ["recording_id": .int(Int(rec.id!)), "tags": .array([.string("planning"), .string(" ")])]
        )
        #expect(tagResult.isError == false)
        #expect(try await store.fetch(id: rec.id!)?.tags == ["planning"])

        let nameResult = await tools.call(
            name: "set_speaker_name",
            arguments: [
                "recording_id": .int(Int(rec.id!)),
                "speaker_index": .int(0),
                "name": .string("Jason"),
            ]
        )
        #expect(nameResult.isError == false)
        #expect(try await store.fetch(id: rec.id!)?.speakerNames[0] == "Jason")
    }

    @Test("update_summary stamps mcp-agent provenance")
    func updateSummaryProvenance() async throws {
        let (tools, store, day) = try await makeFixture()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00",
                                 title: "T", transcript: "one two three")

        let result = await tools.call(
            name: "update_summary",
            arguments: [
                "recording_id": .int(Int(rec.id!)),
                "summary_markdown": .string("- agent summary"),
            ]
        )
        #expect(result.isError == false)
        let updated = try await store.fetch(id: rec.id!)
        #expect(updated?.summaryMarkdown == "- agent summary")
        #expect(updated?.summaryModelID == "mcp-agent")
        #expect(updated?.summarySourceWordCount == 3)
    }

    @Test("append_note stamps attribution and never rewrites prior notes")
    func appendNote() async throws {
        let (tools, store, day) = try await makeFixture()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00",
                                 title: "T", transcript: "x")
        try await store.updateNotes(id: rec.id!, markdown: "user context")

        let first = await tools.call(
            name: "append_note",
            arguments: [
                "recording_id": .int(Int(rec.id!)),
                "note": .string("Follow-up: ship the deck"),
                "author": .string("Claude"),
            ]
        )
        #expect(first.isError == false)

        let second = await tools.call(
            name: "append_note",
            arguments: ["recording_id": .int(Int(rec.id!)), "note": .string("second pass")]
        )
        #expect(second.isError == false)

        let notes = try await store.fetch(id: rec.id!)?.notesMarkdown ?? ""
        #expect(notes.hasPrefix("user context"))
        #expect(notes.contains("Follow-up: ship the deck"))
        #expect(notes.contains("*— Claude, "))
        #expect(notes.contains("second pass"))
        #expect(notes.contains("*— agent, "))

        // The projection carries the whole stack.
        let md = try String(
            contentsOf: day.appendingPathComponent("10-00-00.md"), encoding: .utf8
        )
        #expect(md.contains("## Notes\n\nuser context"))
        #expect(md.contains("Follow-up: ship the deck"))

        // get_recording surfaces the notes.
        let detail = await tools.call(
            name: "get_recording",
            arguments: ["recording_id": .int(Int(rec.id!))]
        )
        #expect(text(detail).contains("user context"))
    }

    @Test("append_note rejects empty notes and missing recordings")
    func appendNoteValidation() async throws {
        let (tools, _, _) = try await makeFixture()
        let empty = await tools.call(
            name: "append_note",
            arguments: ["recording_id": .int(1), "note": .string("  ")]
        )
        #expect(empty.isError == true)

        let missing = await tools.call(
            name: "append_note",
            arguments: ["recording_id": .int(999), "note": .string("x")]
        )
        #expect(missing.isError == true)
    }

    @Test("writes against missing recordings fail cleanly")
    func missingRecording() async throws {
        let (tools, _, _) = try await makeFixture()
        let result = await tools.call(
            name: "update_title",
            arguments: ["recording_id": .int(999), "title": .string("x")]
        )
        #expect(result.isError == true)
        #expect(text(result).contains("doesn't exist"))
    }

    @Test("unknown tool names fail cleanly")
    func unknownTool() async throws {
        let (tools, _, _) = try await makeFixture()
        let result = await tools.call(name: "explode", arguments: nil)
        #expect(result.isError == true)
    }

    @Test("date(fromDayKey:) parses and rejects")
    func dayKeyParsing() {
        #expect(HarcTools.date(fromDayKey: "2026-07-31") != nil)
        #expect(HarcTools.date(fromDayKey: "yesterday") == nil)
        #expect(HarcTools.date(fromDayKey: "2026-07") == nil)
    }
}
