import Foundation
import HarcStore

/// The complete, transport-independent local MCP allowlist. Host IPC and the
/// Standalone helper both call this exact service, so transport selection can
/// never broaden canonical-library authority.
public actor HarcMCPToolService: HarcMCPToolCalling {
    public static let allowedToolNames: Set<String> = [
        "search_notes",
        "get_recording",
        "list_recent",
        "update_summary",
        "update_title",
        "update_tags",
        "append_note",
        "set_speaker_name",
    ]

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse {
        do {
            switch request.name {
            case "search_notes": return try await searchNotes(request.arguments)
            case "get_recording": return try await getRecording(request.arguments)
            case "list_recent": return try await listRecent(request.arguments)
            case "update_summary": return try await updateSummary(request.arguments)
            case "update_title": return try await updateTitle(request.arguments)
            case "update_tags": return try await updateTags(request.arguments)
            case "append_note": return try await appendNote(request.arguments)
            case "set_speaker_name": return try await setSpeakerName(request.arguments)
            default: return failure("Unknown tool: \(request.name)")
            }
        } catch {
            if case StoreError.notFound = error {
                return failure("That recording doesn't exist (it may have been deleted).")
            }
            if let storeError = error as? StoreError,
               storeError == .writerLeaseUnavailable
                || storeError == .staleHostWriterMarker {
                return failure(
                    "The canonical library authority changed before this tool ran.",
                    reason: .authorityUnavailable
                )
            }
            return failure(error.localizedDescription)
        }
    }

    private func searchNotes(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let query = arguments?["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure("search_notes needs a non-empty 'query'.")
        }
        let limit = arguments?["limit"]?.intValue ?? 10
        let boundedLimit = max(1, min(limit, 50))
        let hits = try await store.hybridSearch(
            query: query,
            embedder: HashedLexicalEmbedder(),
            limit: boundedLimit
        )
        let payload = hits.prefix(boundedLimit).map(HarcMCPToolPayloads.hit(for:))
        if payload.isEmpty {
            return success("No recordings matched \"\(query)\".")
        }
        return success(try HarcMCPToolPayloads.encode(Array(payload)))
    }

    private func getRecording(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let recording = try await resolveRecording(arguments) else {
            return failure("Pass 'recording_id' (from search_notes/list_recent) or 'wav_path'.")
        }
        var speakers = recording.speakerNames
        if let id = recording.id {
            for link in (try? await store.fetchPersonSpeakerLinks(recordingID: id)) ?? [] {
                if let name = try? await store.resolvedSpeakerName(
                    recordingID: id,
                    speakerIndex: link.speakerIndex
                ) {
                    speakers[link.speakerIndex] = name
                }
            }
        }
        return success(try HarcMCPToolPayloads.encode(
            HarcMCPToolPayloads.detail(for: recording, speakers: speakers)
        ))
    }

    private func listRecent(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        let limit = max(1, min(arguments?["limit"]?.intValue ?? 20, 100))
        let recordings: [Recording]
        if let dayKey = arguments?["day"]?.stringValue {
            guard let day = Self.date(fromDayKey: dayKey) else {
                return failure("'day' must be YYYY-MM-DD.")
            }
            recordings = try await store.recordings(onDay: day)
        } else {
            recordings = try await store.fetchAll(pinnedFirst: false)
        }
        return success(try HarcMCPToolPayloads.encode(
            Array(recordings.prefix(limit).map(HarcMCPToolPayloads.summary(for:)))
        ))
    }

    private func updateSummary(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let id = arguments?["recording_id"]?.intValue.map(Int64.init),
              let summary = arguments?["summary_markdown"]?.stringValue else {
            return failure("update_summary needs 'recording_id' and 'summary_markdown'.")
        }
        let recording = try await store.fetch(id: id)
        let wordCount = recording?.transcriptText?
            .split(whereSeparator: { $0.isWhitespace }).count ?? 0
        try await store.updateSummary(
            id: id,
            markdown: summary,
            actionItemsMarkdown: arguments?["action_items_markdown"]?.stringValue ?? "",
            modelID: "mcp-agent",
            generatedAt: Date(),
            sourceWordCount: wordCount
        )
        postChangeNotification()
        return success("Summary updated. The recording's .md file has been regenerated.")
    }

    private func updateTitle(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let id = arguments?["recording_id"]?.intValue.map(Int64.init),
              let title = arguments?["title"]?.stringValue else {
            return failure("update_title needs 'recording_id' and 'title'.")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await store.rename(id: id, title: trimmed.isEmpty ? nil : trimmed)
        postChangeNotification()
        return success(trimmed.isEmpty ? "Title cleared." : "Title set to \"\(trimmed)\".")
    }

    private func updateTags(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let id = arguments?["recording_id"]?.intValue.map(Int64.init),
              let values = arguments?["tags"]?.arrayValue else {
            return failure("update_tags needs 'recording_id' and 'tags'.")
        }
        let tags = values.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try await store.updateTags(id: id, tags: tags)
        postChangeNotification()
        return success("Tags set: \(tags.isEmpty ? "(none)" : tags.joined(separator: ", ")).")
    }

    private func appendNote(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let id = arguments?["recording_id"]?.intValue.map(Int64.init),
              let note = arguments?["note"]?.stringValue,
              !note.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure("append_note needs 'recording_id' and a non-empty 'note'.")
        }
        let author = arguments?["author"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.attributionStamp(
            author: author?.isEmpty == false ? author! : "agent"
        )
        let block = note.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + stamp
        try await store.appendNote(id: id, block: block)
        postChangeNotification()
        return success("Note appended to the recording's Notes section.")
    }

    private func setSpeakerName(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> HarcMCPToolResponse {
        guard let id = arguments?["recording_id"]?.intValue.map(Int64.init),
              let index = arguments?["speaker_index"]?.intValue,
              let name = arguments?["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return failure(
                "set_speaker_name needs 'recording_id', 'speaker_index', and a non-empty 'name'."
            )
        }
        guard let recording = try await store.fetch(id: id) else {
            return failure("No recording with id \(id).")
        }
        var names = recording.speakerNames
        names[index] = name
        try await store.updateSpeakerNames(id: id, names: names)
        postChangeNotification()
        return success("Speaker \(index + 1) is now \"\(name)\".")
    }

    private func resolveRecording(
        _ arguments: [String: HarcMCPToolValue]?
    ) async throws -> Recording? {
        if let id = arguments?["recording_id"]?.intValue.map(Int64.init) {
            guard let recording = try await store.fetch(id: id),
                  recording.deletedAt == nil else { return nil }
            return recording
        }
        if let path = arguments?["wav_path"]?.stringValue {
            guard let recording = try await store.fetchByWavPath(path),
                  recording.deletedAt == nil else { return nil }
            return recording
        }
        return nil
    }

    private func postChangeNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(RecordingStore.externalChangeNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func success(_ text: String) -> HarcMCPToolResponse {
        HarcMCPToolResponse(text: text, isError: false)
    }

    private func failure(
        _ text: String,
        reason: HarcMCPToolResponse.FailureReason? = nil
    ) -> HarcMCPToolResponse {
        HarcMCPToolResponse(
            text: text,
            isError: true,
            failureReason: reason
        )
    }

    public static func attributionStamp(
        author: String,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "*— \(author), \(formatter.string(from: date))*"
    }

    public static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }
}
