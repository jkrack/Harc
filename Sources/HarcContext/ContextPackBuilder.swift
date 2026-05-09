import Foundation
import HarcStore

public actor ContextPackBuilder {
    private let store: RecordingStore
    private let semanticSearch: SemanticSearchService?

    public init(store: RecordingStore, semanticSearch: SemanticSearchService? = nil) {
        self.store = store
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
        let blocks: [ContextBlock]
        if let semanticSearch {
            let semanticHits = try await semanticSearch.search(query: query, limit: limit)
            if semanticHits.isEmpty {
                let hits = try await search(using: plan.retrievalQueries, limit: limit)
                blocks = Array(hits.prefix(max(0, limit))).flatMap { Self.blocks(for: $0, plan: plan) }
            } else {
                blocks = semanticHits.flatMap(Self.blocks(for:))
            }
        } else {
            let hits = try await search(using: plan.retrievalQueries, limit: limit)
            blocks = Array(hits.prefix(max(0, limit))).flatMap { Self.blocks(for: $0, plan: plan) }
        }

        return ContextPack(
            query: query,
            retrievalQueries: plan.retrievalQueries,
            intent: intent,
            generatedAt: generatedAt,
            blocks: blocks
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

}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
