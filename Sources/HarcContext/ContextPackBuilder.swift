import Foundation
import HarcStore

public actor ContextPackBuilder {
    private let store: RecordingStore
    private let noteStore: NoteStore?
    private let semanticSearch: SemanticSearchService?

    public init(
        store: RecordingStore,
        noteStore: NoteStore? = nil,
        semanticSearch: SemanticSearchService? = nil
    ) {
        self.store = store
        self.noteStore = noteStore
        self.semanticSearch = semanticSearch
    }

    public func build(
        query rawQuery: String,
        limit: Int = 8,
        generatedAt: Date = Date()
    ) async throws -> ContextPack {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ContextPack(
                query: query,
                retrievalQueries: [],
                intent: .general,
                generatedAt: generatedAt,
                blocks: []
            )
        }

        let plan = ContextQueryPlanner.plan(for: query)
        let intent = Self.inferIntent(from: query)
        let noteBlocks = try await searchNotes(using: plan.retrievalQueries, limit: limit)
            .flatMap { Self.blocks(for: $0, plan: plan) }
        let blocks: [ContextBlock]
        if let semanticSearch {
            let semanticHits = try await semanticSearch.searchKnowledge(
                query: query,
                noteStore: noteStore,
                limit: limit
            )
            if semanticHits.isEmpty {
                let hits = try await search(using: plan.retrievalQueries, limit: limit)
                blocks = Self.rankedBlocks(Self.deduplicatedBlocks(
                    Array(hits.prefix(max(0, limit))).flatMap { Self.blocks(for: $0, plan: plan) } + noteBlocks
                ))
            } else {
                var semanticBlocks = semanticHits.flatMap(Self.blocks(for:))
                if semanticHits.count < limit {
                    let hits = try await search(using: plan.retrievalQueries, limit: limit)
                    semanticBlocks += Array(hits.prefix(max(0, limit)))
                        .flatMap { Self.blocks(for: $0, plan: plan) }
                    semanticBlocks += noteBlocks
                }
                blocks = Self.rankedBlocks(Self.deduplicatedBlocks(semanticBlocks))
            }
        } else {
            let hits = try await search(using: plan.retrievalQueries, limit: limit)
            blocks = Self.rankedBlocks(Self.deduplicatedBlocks(
                Array(hits.prefix(max(0, limit))).flatMap { Self.blocks(for: $0, plan: plan) } + noteBlocks
            ))
        }

        return ContextPack(
            query: query,
            retrievalQueries: plan.retrievalQueries,
            intent: intent,
            generatedAt: generatedAt,
            blocks: blocks
        )
    }

    public static func build(
        wikiPage page: WikiPage,
        query rawQuery: String? = nil,
        generatedAt: Date = Date()
    ) -> ContextPack {
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty ?? page.title
        let wikiSource = ContextSource(
            kind: .wikiPage,
            sourceID: page.id,
            title: page.title,
            path: page.fileURL.path,
            startedAt: page.updatedAt
        )
        var blocks: [ContextBlock] = [
            ContextBlock(
                id: "wiki:\(page.id):approved",
                kind: .synthesis,
                source: wikiSource,
                text: bodyWithoutFrontMatter(page.body),
                score: 1
            ),
        ]

        for (index, sourceText) in frontMatterSources(in: page.body).enumerated() {
            let source = ContextSource(
                kind: sourceText.contains("/.git/") ? .repoFile : .rawFile,
                sourceID: sourceText,
                title: sourceTitle(sourceText),
                path: sourceText,
                startedAt: page.updatedAt
            )
            blocks.append(
                ContextBlock(
                    id: "wiki:\(page.id):source-\(index)",
                    kind: .directEvidence,
                    source: source,
                    text: sourceText,
                    score: 0.8
                )
            )
        }

        return ContextPack(
            query: query,
            retrievalQueries: [query],
            intent: inferIntent(from: query),
            generatedAt: generatedAt,
            blocks: rankedBlocks(blocks)
        )
    }

    private func search(using queries: [String], limit: Int) async throws -> [TranscriptHit] {
        var ranked: [TranscriptHit] = []
        var seen: Set<String> = []

        for query in queries {
            let hits = try await store.search(query: query)
            for hit in hits where !seen.contains(hit.id) {
                seen.insert(hit.id)
                ranked.append(hit)
            }
            if ranked.count >= limit { break }
        }

        return ranked
    }

    private func searchNotes(using queries: [String], limit: Int) async throws -> [Note] {
        guard let noteStore else { return [] }

        var ranked: [Note] = []
        var seen: Set<String> = []

        for query in queries {
            let hits = try await noteStore.search(query: query)
            for hit in hits where !seen.contains(hit.id) {
                seen.insert(hit.id)
                ranked.append(hit)
            }
            if ranked.count >= limit { break }
        }

        return Array(ranked.prefix(max(0, limit)))
    }

    private static func deduplicatedBlocks(_ blocks: [ContextBlock]) -> [ContextBlock] {
        var seen: Set<String> = []
        var result: [ContextBlock] = []
        for block in blocks where seen.insert(block.id).inserted {
            result.append(block)
        }
        return result
    }

    private static func rankedBlocks(_ blocks: [ContextBlock]) -> [ContextBlock] {
        blocks.sorted {
            if blockRank($0) != blockRank($1) {
                return blockRank($0) < blockRank($1)
            }
            return $0.score > $1.score
        }
    }

    private static func blockRank(_ block: ContextBlock) -> Int {
        if block.kind == .synthesis && block.source.kind == .wikiPage { return 0 }
        switch block.kind {
        case .synthesis: return 1
        case .directEvidence: return 2
        case .summary: return 3
        case .actionItems: return 4
        }
    }

    private static func blocks(for hit: TranscriptHit, plan: ContextQueryPlan) -> [ContextBlock] {
        let source = ContextSource(recording: hit.recording)
        let stableID = hit.recording.id.map(String.init) ?? hit.recording.wavPath
        let evidence = ContextEvidenceExtractor.extract(
            from: hit.recording.transcriptText,
            queryPlan: plan,
            fallbackSnippet: hit.snippet
        )

        var blocks: [ContextBlock] = []
        if !evidence.isEmpty {
            blocks.append(
                ContextBlock(
                    id: "\(stableID):evidence",
                    kind: .directEvidence,
                    source: source,
                    text: evidence,
                    score: hit.score
                )
            )
        }

        if let summary = hit.recording.summaryMarkdown?.trimmedNonEmpty {
            blocks.append(
                ContextBlock(
                    id: "\(stableID):summary",
                    kind: .summary,
                    source: source,
                    text: summary,
                    score: hit.score * 0.9
                )
            )
        }

        if let actionItems = hit.recording.actionItemsMarkdown?.trimmedNonEmpty {
            blocks.append(
                ContextBlock(
                    id: "\(stableID):actions",
                    kind: .actionItems,
                    source: source,
                    text: actionItems,
                    score: hit.score * 0.85
                )
            )
        }

        return blocks
    }

    private static func blocks(for hit: SemanticTranscriptHit) -> [ContextBlock] {
        let source = ContextSource(recording: hit.recording)
        let stableID = hit.recording.id.map(String.init) ?? hit.recording.wavPath
        var blocks: [ContextBlock] = [
            ContextBlock(
                id: "\(stableID):chunk-\(hit.chunk.ordinal):evidence",
                kind: .directEvidence,
                source: source,
                text: hit.chunk.text,
                score: hit.score
            ),
        ]

        if let summary = hit.recording.summaryMarkdown?.trimmedNonEmpty {
            blocks.append(
                ContextBlock(
                    id: "\(stableID):summary",
                    kind: .summary,
                    source: source,
                    text: summary,
                    score: hit.score * 0.9
                )
            )
        }

        if let actionItems = hit.recording.actionItemsMarkdown?.trimmedNonEmpty {
            blocks.append(
                ContextBlock(
                    id: "\(stableID):actions",
                    kind: .actionItems,
                    source: source,
                    text: actionItems,
                    score: hit.score * 0.85
                )
            )
        }

        return blocks
    }

    private static func blocks(for hit: SemanticKnowledgeHit) -> [ContextBlock] {
        switch hit.chunk.sourceKind {
        case .recording:
            guard let recording = hit.recording else { return [] }
            return blocks(
                for: SemanticTranscriptHit(
                    recording: recording,
                    chunk: TranscriptChunk(
                        id: hit.chunk.id,
                        recordingID: recording.id ?? -1,
                        ordinal: hit.chunk.ordinal,
                        startMs: 0,
                        endMs: 0,
                        text: hit.chunk.text,
                        embedding: hit.chunk.embedding,
                        embeddingModelID: hit.chunk.embeddingModelID,
                        createdAt: hit.chunk.createdAt
                    ),
                    score: hit.score
                )
            )
        case .note:
            guard let note = hit.note else { return [] }
            return [
                ContextBlock(
                    id: "note:\(note.id):chunk-\(hit.chunk.ordinal):evidence",
                    kind: .directEvidence,
                    source: ContextSource(note: note),
                    text: hit.chunk.text,
                    score: hit.score
                ),
            ]
        case .rawFile, .repoFile, .wikiPage:
            guard let source = hit.externalSource else { return [] }
            return [
                ContextBlock(
                    id: "\(hit.chunk.sourceKind.rawValue):\(hit.chunk.sourceID):chunk-\(hit.chunk.ordinal):evidence",
                    kind: hit.chunk.sourceKind == .wikiPage ? .synthesis : .directEvidence,
                    source: source,
                    text: hit.chunk.text,
                    score: hit.score
                ),
            ]
        }
    }

    private static func blocks(for note: Note, plan: ContextQueryPlan) -> [ContextBlock] {
        let source = ContextSource(note: note)
        let searchable = [note.title, note.body, note.tags.joined(separator: " "), note.people.joined(separator: " ")]
            .joined(separator: "\n")
        let evidence = ContextEvidenceExtractor.extract(
            from: searchable,
            queryPlan: plan,
            fallbackSnippet: note.preview
        )
        let text = evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? note.preview
            : evidence
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        return [
            ContextBlock(
                id: "note:\(note.id):evidence",
                kind: .directEvidence,
                source: source,
                text: text,
                score: 1
            ),
        ]
    }

    static func inferIntent(from query: String) -> ContextIntent {
        let q = query.lowercased()
        if q.contains("action item") || q.contains("follow up") || q.contains("todo") {
            return .actionItems
        }
        if q.contains("decision") || q.contains("decide") || q.contains("decided") {
            return .decision
        }
        if q.contains("prep") || q.contains("before my meeting") || q.contains("meeting with") {
            return .meetingPrep
        }
        if q.contains("project") || q.contains("workstream") || q.contains("roadmap") {
            return .project
        }
        if q.contains("person") || q.contains("with ") || q.contains("said") {
            return .person
        }
        return .general
    }

    private static func bodyWithoutFrontMatter(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontMatterSources(in body: String) -> [String] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return []
        }
        let header = Array(lines[1..<end])
        guard let sourceIndex = header.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "sources:" }) else {
            return []
        }
        var result: [String] = []
        for line in header.dropFirst(sourceIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                result.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            } else if !trimmed.isEmpty {
                break
            }
        }
        return result
    }

    private static func sourceTitle(_ source: String) -> String {
        let withoutLine = source.split(separator: ":").first.map(String.init) ?? source
        let filename = URL(fileURLWithPath: withoutLine).lastPathComponent
        return filename.isEmpty ? source : filename
    }

}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
