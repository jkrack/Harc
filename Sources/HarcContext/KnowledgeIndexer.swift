import CryptoKit
import Foundation
import HarcStore

public actor KnowledgeIndexer {
    private let store: RecordingStore
    private let embedder: any LocalTextEmbedder

    public init(store: RecordingStore, embedder: any LocalTextEmbedder) {
        self.store = store
        self.embedder = embedder
    }

    public func index(recordingID: Int64, indexedAt: Date = Date()) async throws {
        try await SemanticIndexer(store: store, embedder: embedder)
            .index(recordingID: recordingID, indexedAt: indexedAt)
    }

    public func index(note: Note, indexedAt: Date = Date()) async throws {
        let prepared = Self.preparedNoteChunks(note)
        let embeddings = try await embedder.embed(texts: prepared.map(\.text))
        guard embeddings.count == prepared.count else {
            throw SemanticIndexError.embeddingCountMismatch(expected: prepared.count, actual: embeddings.count)
        }

        let chunks = zip(prepared, embeddings).map { chunk, embedding in
            KnowledgeChunk(
                sourceKind: .note,
                sourceID: note.id,
                ordinal: chunk.ordinal,
                title: note.title,
                text: chunk.text,
                embedding: embedding,
                embeddingModelID: embedder.modelID,
                contentHash: Self.contentHash(for: note),
                createdAt: indexedAt,
                updatedAt: indexedAt
            )
        }
        try await store.upsertKnowledgeChunks(
            sourceKind: .note,
            sourceID: note.id,
            chunks: chunks
        )
    }

    public func index(
        sourceDocument document: ScannedSourceDocument,
        sourceKind: KnowledgeSourceKind,
        indexedAt: Date = Date()
    ) async throws {
        precondition(sourceKind == .rawFile || sourceKind == .repoFile, "sourceDocument indexing only supports rawFile or repoFile")
        let prepared = Self.preparedSourceDocumentChunks(document)
        let embeddings = try await embedder.embed(texts: prepared.map(\.text))
        guard embeddings.count == prepared.count else {
            throw SemanticIndexError.embeddingCountMismatch(expected: prepared.count, actual: embeddings.count)
        }

        let sourceID = document.provenance.absolutePath
        let chunks = zip(prepared, embeddings).map { chunk, embedding in
            KnowledgeChunk(
                sourceKind: sourceKind,
                sourceID: sourceID,
                ordinal: chunk.ordinal,
                title: document.title,
                text: chunk.text,
                embedding: embedding,
                embeddingModelID: embedder.modelID,
                contentHash: document.provenance.contentHash,
                createdAt: indexedAt,
                updatedAt: indexedAt
            )
        }
        try await store.upsertKnowledgeChunks(
            sourceKind: sourceKind,
            sourceID: sourceID,
            chunks: chunks
        )
    }

    public func index(wikiPage: WikiPage, indexedAt: Date = Date()) async throws {
        let prepared = Self.preparedWikiPageChunks(wikiPage)
        let embeddings = try await embedder.embed(texts: prepared.map(\.text))
        guard embeddings.count == prepared.count else {
            throw SemanticIndexError.embeddingCountMismatch(expected: prepared.count, actual: embeddings.count)
        }

        let sourceID = wikiPage.fileURL.path
        let hash = Self.contentHash(title: wikiPage.title, body: wikiPage.body, extra: wikiPage.section.rawValue)
        let chunks = zip(prepared, embeddings).map { chunk, embedding in
            KnowledgeChunk(
                sourceKind: .wikiPage,
                sourceID: sourceID,
                ordinal: chunk.ordinal,
                title: wikiPage.title,
                text: chunk.text,
                embedding: embedding,
                embeddingModelID: embedder.modelID,
                contentHash: hash,
                createdAt: indexedAt,
                updatedAt: indexedAt
            )
        }
        try await store.upsertKnowledgeChunks(
            sourceKind: .wikiPage,
            sourceID: sourceID,
            chunks: chunks
        )
    }

    static func preparedNoteChunks(_ note: Note) -> [PreparedTranscriptChunk] {
        let metadata = [
            note.title,
            note.tags.joined(separator: " "),
            note.people.joined(separator: " "),
        ]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let text = [metadata, note.body]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return SemanticTranscriptChunker.split(transcript: text)
    }

    static func preparedSourceDocumentChunks(_ document: ScannedSourceDocument) -> [PreparedTranscriptChunk] {
        let metadata = [
            document.title,
            "source_path: \(document.provenance.relativePath)",
            "source_root: \(document.provenance.rootPath)",
            "source_kind: \(document.provenance.documentKind.rawValue)",
        ].joined(separator: "\n")
        return SemanticTranscriptChunker.split(transcript: [metadata, document.text].joined(separator: "\n\n"))
    }

    static func preparedWikiPageChunks(_ page: WikiPage) -> [PreparedTranscriptChunk] {
        let metadata = [
            page.title,
            "wiki_section: \(page.section.rawValue)",
            "wiki_path: \(page.fileURL.path)",
        ].joined(separator: "\n")
        return SemanticTranscriptChunker.split(transcript: [metadata, page.body].joined(separator: "\n\n"))
    }

    static func contentHash(for note: Note) -> String {
        let material = [
            note.title,
            note.body,
            note.tags.joined(separator: "\u{1f}"),
            note.people.joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func contentHash(title: String, body: String, extra: String = "") -> String {
        let material = [title, body, extra].joined(separator: "\u{1e}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
