import Foundation
import HarcCore
import HarcStore
import MCP

/// Tool definitions and handlers for the harc-mcp server. Thin wrappers
/// over `RecordingStore` — every write goes through the store's mutators,
/// so the OKF `.md` projections regenerate exactly as they do for in-app
/// edits. Transcripts are read-only by design.
struct HarcTools {
    let store: RecordingStore

    /// Posted after every successful write so a running Harc app can
    /// refresh: GRDB's ValueObservation cannot see another process's
    /// commits.
    static let changeNotification = RecordingStore.externalChangeNotification

    // MARK: - Definitions

    static let definitions: [Tool] = [
        Tool(
            name: "search_notes",
            description: """
                Search the user's meeting transcripts. Combines keyword (BM25) and \
                semantic chunk matching; falls back to keyword-only when the semantic \
                index hasn't been built yet. Returns matching recordings with snippets.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("What to look for — words, names, topics."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results (default 10)."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "get_recording",
            description: """
                Fetch one recording in full: metadata, tags, resolved speaker names, \
                summary, action items, and the complete transcript. The transcript is \
                read-only — there is no tool that edits it, by design.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object([
                        "type": .string("integer"),
                        "description": .string("The recording's id, from search_notes or list_recent."),
                    ]),
                    "wav_path": .object([
                        "type": .string("string"),
                        "description": .string("Alternative lookup by the recording's wav path."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "list_recent",
            description: """
                List recent recordings (metadata only, no transcripts). Optionally \
                scoped to one day.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results (default 20)."),
                    ]),
                    "day": .object([
                        "type": .string("string"),
                        "description": .string("Optional local day filter, YYYY-MM-DD."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "update_summary",
            description: """
                Replace a recording's summary (and optionally its action items) with \
                agent-written markdown. The recording's .md file regenerates from the \
                database after the write.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object(["type": .string("integer")]),
                    "summary_markdown": .object([
                        "type": .string("string"),
                        "description": .string("The new summary, markdown."),
                    ]),
                    "action_items_markdown": .object([
                        "type": .string("string"),
                        "description": .string("Optional action items, markdown list."),
                    ]),
                ]),
                "required": .array([.string("recording_id"), .string("summary_markdown")]),
            ])
        ),
        Tool(
            name: "update_title",
            description: "Set a recording's title. Empty title clears it back to the derived suggestion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object(["type": .string("integer")]),
                    "title": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("recording_id"), .string("title")]),
            ])
        ),
        Tool(
            name: "update_tags",
            description: "Replace a recording's tag list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object(["type": .string("integer")]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("recording_id"), .string("tags")]),
            ])
        ),
        Tool(
            name: "append_note",
            description: """
                Append a note to a recording's Notes section — extra context, \
                follow-ups, links, or conclusions worth keeping next to the \
                transcript. Append-only: existing notes (including the user's own) \
                are never modified. Each note is stamped with your name and the \
                date. Renders under ## Notes in the recording's .md file.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object(["type": .string("integer")]),
                    "note": .object([
                        "type": .string("string"),
                        "description": .string("The note to append, markdown."),
                    ]),
                    "author": .object([
                        "type": .string("string"),
                        "description": .string("Who is writing — e.g. \"Claude\". Defaults to \"agent\"."),
                    ]),
                ]),
                "required": .array([.string("recording_id"), .string("note")]),
            ])
        ),
        Tool(
            name: "set_speaker_name",
            description: """
                Name a diarized speaker in one recording ("Speaker 1" → "Jason"). \
                speaker_index is zero-based.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recording_id": .object(["type": .string("integer")]),
                    "speaker_index": .object(["type": .string("integer")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([
                    .string("recording_id"), .string("speaker_index"), .string("name"),
                ]),
            ])
        ),
    ]

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "search_notes":
                return try await searchNotes(arguments)
            case "get_recording":
                return try await getRecording(arguments)
            case "list_recent":
                return try await listRecent(arguments)
            case "update_summary":
                return try await updateSummary(arguments)
            case "update_title":
                return try await updateTitle(arguments)
            case "update_tags":
                return try await updateTags(arguments)
            case "append_note":
                return try await appendNote(arguments)
            case "set_speaker_name":
                return try await setSpeakerName(arguments)
            default:
                return failure("Unknown tool: \(name)")
            }
        } catch {
            return failure(friendlyMessage(for: error))
        }
    }

    // MARK: - Reads

    private func searchNotes(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let query = args?["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure("search_notes needs a non-empty 'query'.")
        }
        let limit = args?["limit"]?.intValue ?? 10
        let hits = try await store.hybridSearch(
            query: query,
            embedder: HashedLexicalEmbedder(),
            limit: max(1, min(limit, 50))
        )
        let payload = hits.prefix(max(1, min(limit, 50))).map(ToolPayloads.hit(for:))
        if payload.isEmpty {
            return success("No recordings matched \"\(query)\".")
        }
        return success(try ToolPayloads.encode(Array(payload)))
    }

    private func getRecording(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let rec = try await resolveRecording(args) else {
            return failure("Pass 'recording_id' (from search_notes/list_recent) or 'wav_path'.")
        }
        var speakers = rec.speakerNames
        if let id = rec.id {
            for link in (try? await store.fetchPersonSpeakerLinks(recordingID: id)) ?? [] {
                if let name = try? await store.resolvedSpeakerName(
                    recordingID: id, speakerIndex: link.speakerIndex
                ) {
                    speakers[link.speakerIndex] = name
                }
            }
        }
        return success(try ToolPayloads.encode(ToolPayloads.detail(for: rec, speakers: speakers)))
    }

    private func listRecent(_ args: [String: Value]?) async throws -> CallTool.Result {
        let limit = max(1, min(args?["limit"]?.intValue ?? 20, 100))
        let recordings: [Recording]
        if let dayKey = args?["day"]?.stringValue {
            guard let day = Self.date(fromDayKey: dayKey) else {
                return failure("'day' must be YYYY-MM-DD.")
            }
            recordings = try await store.recordings(onDay: day)
        } else {
            recordings = try await store.fetchAll(pinnedFirst: false)
        }
        let payload = recordings.prefix(limit).map(ToolPayloads.summary(for:))
        return success(try ToolPayloads.encode(Array(payload)))
    }

    // MARK: - Writes (store-mediated; OKF regenerates automatically)

    private func updateSummary(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let id = args?["recording_id"]?.intValue.map(Int64.init),
              let summary = args?["summary_markdown"]?.stringValue else {
            return failure("update_summary needs 'recording_id' and 'summary_markdown'.")
        }
        let rec = try await store.fetch(id: id)
        let wordCount = rec?.transcriptText?
            .split(whereSeparator: { $0.isWhitespace }).count ?? 0
        try await store.updateSummary(
            id: id,
            markdown: summary,
            actionItemsMarkdown: args?["action_items_markdown"]?.stringValue ?? "",
            modelID: "mcp-agent",
            generatedAt: Date(),
            sourceWordCount: wordCount
        )
        postChangeNotification()
        return success("Summary updated. The recording's .md file has been regenerated.")
    }

    private func updateTitle(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let id = args?["recording_id"]?.intValue.map(Int64.init),
              let title = args?["title"]?.stringValue else {
            return failure("update_title needs 'recording_id' and 'title'.")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await store.rename(id: id, title: trimmed.isEmpty ? nil : trimmed)
        postChangeNotification()
        return success(trimmed.isEmpty ? "Title cleared." : "Title set to \"\(trimmed)\".")
    }

    private func updateTags(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let id = args?["recording_id"]?.intValue.map(Int64.init),
              let values = args?["tags"]?.arrayValue else {
            return failure("update_tags needs 'recording_id' and 'tags'.")
        }
        let tags = values.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try await store.updateTags(id: id, tags: tags)
        postChangeNotification()
        return success("Tags set: \(tags.isEmpty ? "(none)" : tags.joined(separator: ", ")).")
    }

    private func appendNote(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let id = args?["recording_id"]?.intValue.map(Int64.init),
              let note = args?["note"]?.stringValue,
              !note.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure("append_note needs 'recording_id' and a non-empty 'note'.")
        }
        let author = args?["author"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.attributionStamp(author: (author?.isEmpty == false) ? author! : "agent")
        let block = note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + stamp
        try await store.appendNote(id: id, block: block)
        postChangeNotification()
        return success("Note appended to the recording's Notes section.")
    }

    /// "*— Claude, Aug 1, 2026*" — one quiet line under each agent note so
    /// the file records what came from an agent and when.
    static func attributionStamp(author: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "*— \(author), \(f.string(from: date))*"
    }

    private func setSpeakerName(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let id = args?["recording_id"]?.intValue.map(Int64.init),
              let index = args?["speaker_index"]?.intValue,
              let name = args?["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure("set_speaker_name needs 'recording_id', 'speaker_index', and a non-empty 'name'.")
        }
        guard let rec = try await store.fetch(id: id) else {
            return failure("No recording with id \(id).")
        }
        var names = rec.speakerNames
        names[index] = name
        try await store.updateSpeakerNames(id: id, names: names)
        postChangeNotification()
        return success("Speaker \(index + 1) is now \"\(name)\".")
    }

    // MARK: - Helpers

    private func resolveRecording(_ args: [String: Value]?) async throws -> Recording? {
        if let id = args?["recording_id"]?.intValue.map(Int64.init) {
            if let rec = try await store.fetch(id: id), rec.deletedAt == nil { return rec }
            return nil
        }
        if let path = args?["wav_path"]?.stringValue {
            if let rec = try await store.fetchByWavPath(path), rec.deletedAt == nil { return rec }
            return nil
        }
        return nil
    }

    private func postChangeNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.changeNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func friendlyMessage(for error: Error) -> String {
        if case StoreError.notFound = error {
            return "That recording doesn't exist (it may have been deleted)."
        }
        return error.localizedDescription
    }

    private func success(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text)], isError: false)
    }

    private func failure(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text)], isError: true)
    }

    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return Calendar.current.date(from: comps)
    }
}
