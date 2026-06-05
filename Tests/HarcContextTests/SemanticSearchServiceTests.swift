import Foundation
import Testing
import HarcStore
@testable import HarcContext

@Suite("Semantic search service")
struct SemanticSearchServiceTests {
    @Test("codec round trips float vectors")
    func codecRoundTripsFloatVectors() throws {
        let vector: [Float] = [1.0, -0.25, 0.5, 42.0]

        let decoded = try EmbeddingVectorCodec.decode(EmbeddingVectorCodec.encode(vector))

        #expect(decoded == vector)
    }

    @Test("search ranks transcript chunks with local embeddings")
    func searchRanksTranscriptChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let pricing = try await store.upsert(Recording(
            wavPath: "/tmp/pricing.wav",
            startedAt: Date(timeIntervalSince1970: 2),
            transcriptText: "Sarah raised pricing concerns."
        ))
        let roadmap = try await store.upsert(Recording(
            wavPath: "/tmp/roadmap.wav",
            startedAt: Date(timeIntervalSince1970: 3),
            transcriptText: "The roadmap depends on margin work."
        ))

        try await store.upsertTranscriptChunks(recordingID: pricing.id!, chunks: [
            chunk(recordingID: pricing.id!, text: "Sarah raised pricing concerns.", vector: [1, 0, 0, 0]),
        ])
        try await store.upsertTranscriptChunks(recordingID: roadmap.id!, chunks: [
            chunk(recordingID: roadmap.id!, text: "The roadmap depends on margin work.", vector: [0, 1, 0, 0]),
        ])

        let hits = try await SemanticSearchService(store: store, embedder: KeywordEmbedder())
            .search(query: "pricing concern", limit: 2)

        #expect(hits.map(\.recording.wavPath).first == "/tmp/pricing.wav")
        #expect(hits.first?.chunk.text == "Sarah raised pricing concerns.")
        #expect((hits.first?.score ?? 0) > 0.99)
    }

    @Test("context pack builder can use semantic chunks before FTS fallback")
    func contextPackBuilderUsesSemanticChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/semantic-context.wav",
            startedAt: Date(),
            transcriptText: "This transcript does not contain the natural query term.",
            summaryMarkdown: "Pricing risk needs owner follow-up.",
            actionItemsMarkdown: "- Sarah to review enterprise pricing."
        ))
        _ = try await store.upsert(Recording(
            wavPath: "/tmp/exact-context.wav",
            startedAt: Date(),
            title: "Customer rollout",
            transcriptText: "Neal owns the customer rollout."
        ))
        try await store.upsertTranscriptChunks(recordingID: recording.id!, chunks: [
            chunk(
                recordingID: recording.id!,
                text: "Sarah raised pricing concerns for enterprise buyers.",
                vector: [1, 0, 0, 0]
            ),
        ])

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "pricing Neal concern", limit: 4)

        #expect(pack.blocks.contains { $0.text.contains("enterprise buyers") })
        #expect(pack.blocks.contains { $0.text.contains("customer rollout") })
        #expect(pack.blocks.contains { $0.kind == .summary })
        #expect(pack.blocks.contains { $0.kind == .actionItems })
    }

    @Test("knowledge indexer adds notes to vec1-backed semantic context")
    func knowledgeIndexerAddsNotesToSemanticContext() async throws {
        let store = try await RecordingStore.inMemory()
        let noteStore = NoteStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-vec1-notes-\(UUID().uuidString)", isDirectory: true))
        var note = try await noteStore.create(
            title: "Atlas notes",
            body: "Neal thinks the Atlas migration should be staged."
        )
        note.tags = ["project:Atlas"]
        note = try await noteStore.update(note)

        try await KnowledgeIndexer(store: store, embedder: KeywordEmbedder()).index(note: note)

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(
            store: store,
            noteStore: noteStore,
            semanticSearch: semanticSearch
        )
        .build(query: "What does Neal think about Atlas?", limit: 4)

        #expect(pack.sources.map(\.kind) == [.note])
        #expect(pack.blocks.contains { $0.text.localizedCaseInsensitiveContains("staged") })
    }

    @Test("wiki knowledge is returned as synthesis before raw evidence")
    func wikiKnowledgeReturnedAsSynthesis() async throws {
        let store = try await RecordingStore.inMemory()
        try await store.upsertKnowledgeChunks(
            sourceKind: .wikiPage,
            sourceID: "/tmp/wiki/projects/atlas.md",
            chunks: [
                KnowledgeChunk(
                    sourceKind: .wikiPage,
                    sourceID: "/tmp/wiki/projects/atlas.md",
                    ordinal: 0,
                    title: "Atlas",
                    text: "Atlas migration should be staged before launch.",
                    embedding: EmbeddingVectorCodec.encode([0, 0, 1, 0]),
                    embeddingModelID: "keyword-local-embedder",
                    contentHash: "hash"
                ),
            ]
        )

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "Atlas migration", limit: 4)

        #expect(pack.sources.map(\.kind) == [.wikiPage])
        #expect(pack.blocks.map(\.kind) == [.synthesis])
        #expect(pack.blocks.first?.text.contains("staged") == true)
    }

    @Test("indexer adds raw and repo files as searchable knowledge chunks")
    func indexerAddsLocalSourceDocuments() async throws {
        let store = try await RecordingStore.inMemory()
        let root = LocalSourceRoot(
            id: "repo-1",
            path: "/tmp/AtlasRepo",
            displayName: "AtlasRepo",
            kind: .repository,
            readOnly: true
        )
        let document = ScannedSourceDocument(
            title: "Architecture",
            text: "Atlas migration depends on staged rollout notes.",
            provenance: SourceProvenance(
                rootID: root.id,
                rootPath: root.path,
                relativePath: "docs/architecture.md",
                absolutePath: "/tmp/AtlasRepo/docs/architecture.md",
                lineStart: 1,
                lineEnd: 1,
                contentHash: "doc-hash",
                documentKind: .markdown,
                scannedAt: Date()
            )
        )

        try await KnowledgeIndexer(store: store, embedder: KeywordEmbedder())
            .index(sourceDocument: document, sourceKind: .repoFile)

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "Atlas rollout", limit: 4)

        #expect(pack.sources.map(\.kind) == [.repoFile])
        #expect(pack.sources.first?.notePath == "/tmp/AtlasRepo/docs/architecture.md")
        #expect(pack.blocks.contains { $0.text.contains("staged rollout") })
    }

    @Test("indexer adds approved wiki pages as synthesis chunks")
    func indexerAddsWikiPages() async throws {
        let store = try await RecordingStore.inMemory()
        let page = WikiPage(
            id: "projects/atlas",
            title: "Atlas",
            section: .projects,
            fileURL: URL(fileURLWithPath: "/tmp/wiki/projects/atlas.md"),
            body: "# Atlas\n\nAtlas migration should be staged before launch.",
            updatedAt: Date()
        )

        try await KnowledgeIndexer(store: store, embedder: KeywordEmbedder()).index(wikiPage: page)

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "Atlas launch", limit: 4)

        #expect(pack.sources.map(\.kind) == [.wikiPage])
        #expect(pack.blocks.map(\.kind) == [.synthesis])
        #expect(pack.blocks.first?.text.contains("staged") == true)
    }

    @Test("query context ranks approved wiki knowledge before raw evidence")
    func queryContextRanksApprovedWikiBeforeEvidence() async throws {
        let store = try await RecordingStore.inMemory()
        let page = WikiPage(
            id: "projects/atlas",
            title: "Atlas",
            section: .projects,
            fileURL: URL(fileURLWithPath: "/tmp/wiki/projects/atlas.md"),
            body: "# Atlas\n\nApproved Atlas launch knowledge says stage the rollout.",
            updatedAt: Date()
        )
        let root = LocalSourceRoot(
            id: "repo",
            path: "/tmp/AtlasRepo",
            displayName: "AtlasRepo",
            kind: .repository,
            readOnly: true
        )
        let document = ScannedSourceDocument(
            title: "README",
            text: "Raw Atlas launch evidence mentions the rollout.",
            provenance: SourceProvenance(
                rootID: root.id,
                rootPath: root.path,
                relativePath: "README.md",
                absolutePath: "/tmp/AtlasRepo/README.md",
                lineStart: 1,
                lineEnd: 1,
                contentHash: "raw-atlas",
                documentKind: .markdown,
                scannedAt: Date()
            )
        )

        let indexer = KnowledgeIndexer(store: store, embedder: KeywordEmbedder())
        try await indexer.index(wikiPage: page)
        try await indexer.index(sourceDocument: document, sourceKind: .repoFile)

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "Atlas launch rollout", limit: 4)

        #expect(pack.blocks.first?.source.kind == .wikiPage)
        #expect(pack.approvedKnowledge.first?.source.title == "Atlas")
        #expect(pack.supportingEvidence.contains { $0.source.kind == .repoFile })
    }

    @Test("search rejects mismatched vector dimensions")
    func searchRejectsMismatchedDimensions() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/bad-vector.wav",
            startedAt: Date(),
            transcriptText: "pricing"
        ))
        try await store.upsertTranscriptChunks(recordingID: recording.id!, chunks: [
            chunk(recordingID: recording.id!, text: "pricing", vector: [1, 0]),
        ])

        await #expect(throws: SemanticSearchError.self) {
            try await SemanticSearchService(store: store, embedder: KeywordEmbedder())
                .search(query: "pricing")
        }
    }

    private func chunk(recordingID: Int64, text: String, vector: [Float]) -> TranscriptChunk {
        TranscriptChunk(
            recordingID: recordingID,
            ordinal: 0,
            startMs: 0,
            endMs: 0,
            text: text,
            embedding: EmbeddingVectorCodec.encode(vector),
            embeddingModelID: "keyword-local-embedder"
        )
    }
}

private struct KeywordEmbedder: LocalTextEmbedder {
    let modelID = "keyword-local-embedder"

    func embed(texts: [String]) async throws -> [Data] {
        texts.map { text in
            let lowercased = text.lowercased()
            if lowercased.contains("pricing") {
                return EmbeddingVectorCodec.encode([1, 0, 0, 0])
            }
            if lowercased.contains("margin") || lowercased.contains("roadmap") {
                return EmbeddingVectorCodec.encode([0, 1, 0, 0])
            }
            if lowercased.contains("atlas") || lowercased.contains("neal") {
                return EmbeddingVectorCodec.encode([0, 0, 1, 0])
            }
            return EmbeddingVectorCodec.encode([0, 0, 0, 1])
        }
    }
}
