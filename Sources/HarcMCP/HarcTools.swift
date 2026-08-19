import Foundation
import HarcCore
import HarcHost
import HarcStore
import MCP

/// MCP-SDK adapter around the transport-independent Host allowlist.
struct HarcTools {
    private let caller: any HarcMCPToolCalling

    init(store: RecordingStore) {
        caller = HarcMCPToolService(store: store)
    }

    init(caller: any HarcMCPToolCalling) {
        self.caller = caller
    }

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
            let response = await caller.call(HarcMCPToolRequest(
                name: name,
                arguments: try arguments?.mapValues(Self.toolValue(from:))
            ))
            return CallTool.Result(
                content: [.text(text: response.text, annotations: nil, _meta: nil)],
                isError: response.isError
            )
        } catch {
            return failure("The MCP request contains an unsupported value.")
        }
    }

    private static func toolValue(from value: Value) throws -> HarcMCPToolValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(try values.map(toolValue(from:)))
        case .object(let values): return .object(try values.mapValues(toolValue(from:)))
        case .data: throw HarcMCPToolAdapterError.unsupportedDataValue
        }
    }

    static func attributionStamp(author: String, date: Date = Date()) -> String {
        HarcMCPToolService.attributionStamp(author: author, date: date)
    }

    private func success(_ text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private func failure(_ text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    static func date(fromDayKey key: String) -> Date? {
        HarcMCPToolService.date(fromDayKey: key)
    }
}

private enum HarcMCPToolAdapterError: Error {
    case unsupportedDataValue
}
