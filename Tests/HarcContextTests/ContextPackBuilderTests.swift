import Foundation
import Testing
import HarcStore
@testable import HarcContext

@Suite("Context pack builder")
struct ContextPackBuilderTests {
    private func recording(
        wav: String,
        title: String,
        transcript: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Recording {
        Recording(
            wavPath: wav,
            startedAt: startedAt,
            title: title,
            transcriptText: transcript
        )
    }

    @Test("empty query returns empty pack without hitting search")
    func emptyQuery() async throws {
        let store = try await RecordingStore.inMemory()
        let builder = ContextPackBuilder(store: store)

        let pack = try await builder.build(query: "   ")

        #expect(pack.query == "")
        #expect(pack.intent == .general)
        #expect(pack.blocks.isEmpty)
    }

    @Test("builds evidence, summary, and action blocks from matching recordings")
    func buildsContextBlocks() async throws {
        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(recording(
            wav: "/tmp/pricing.wav",
            title: "Pricing Review",
            transcript: "Amy said the enterprise pricing concern is margin pressure."
        ))
        try await store.updateSummary(
            id: saved.id!,
            markdown: "The team discussed enterprise pricing risk.",
            actionItemsMarkdown: "- [ ] Amy: revisit enterprise tier margins",
            modelID: "test-model",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceWordCount: 8
        )

        let pack = try await ContextPackBuilder(store: store).build(query: "pricing concern")

        #expect(pack.intent == .general)
        #expect(pack.sources.map(\.title) == ["Pricing Review"])
        #expect(pack.blocks.contains { $0.kind == .directEvidence })
        #expect(pack.blocks.contains { $0.kind == .summary })
        #expect(pack.blocks.contains { $0.kind == .actionItems })
        #expect(pack.blocks.first?.text.contains("<mark>") == false)
    }

    @Test("plans conversational questions into retrievable terms")
    func plansConversationalQueries() {
        let plan = ContextQueryPlanner.plan(for: "What did Sarah say about pricing last month?")

        #expect(plan.original == "What did Sarah say about pricing last month?")
        #expect(plan.retrievalQueries.first == "sarah pricing")
        #expect(plan.retrievalQueries.contains("sarah"))
        #expect(plan.retrievalQueries.contains("pricing"))
    }

    @Test("uses planned query when the original conversational query would be too strict")
    func usesPlannedQueryForRetrieval() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(recording(
            wav: "/tmp/sarah.wav",
            title: "Sarah 1:1",
            transcript: "Sarah raised pricing concerns for the enterprise tier."
        ))

        let pack = try await ContextPackBuilder(store: store)
            .build(query: "What did Sarah say about pricing last month?")

        #expect(pack.retrievalQueries.first == "sarah pricing")
        #expect(pack.sources.map(\.title) == ["Sarah 1:1"])
        #expect(pack.blocks.contains { $0.text.localizedCaseInsensitiveContains("pricing") })
    }

    @Test("builds context from notes as first-class local sources")
    func buildsContextFromNotes() async throws {
        let store = try await RecordingStore.inMemory()
        let noteStore = NoteStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-context-notes-\(UUID().uuidString)", isDirectory: true))
        var note = try await noteStore.create(
            title: "Atlas notes",
            body: "Neal thinks the Atlas work needs sharper migration sequencing."
        )
        note.tags = ["project:Atlas"]
        _ = try await noteStore.update(note)

        let pack = try await ContextPackBuilder(store: store, noteStore: noteStore)
            .build(query: "What does Neal think about the Atlas work?")

        #expect(pack.sources.map(\.kind) == [.note])
        #expect(pack.sources.map(\.title) == ["Atlas notes"])
        #expect(pack.blocks.contains { $0.text.localizedCaseInsensitiveContains("migration sequencing") })
    }

    @Test("evidence extractor returns a larger transcript chunk around planned terms")
    func extractsEvidenceChunk() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(recording(
            wav: "/tmp/long.wav",
            title: "Long Pricing Meeting",
            transcript: """
            We opened with team updates and hiring notes. Sarah said the onboarding work is stable.
            Sarah raised pricing concerns for the enterprise tier because support costs are higher than expected.
            The group agreed to revisit margins before approving the launch plan. Later we discussed unrelated office logistics.
            """
        ))

        let pack = try await ContextPackBuilder(store: store)
            .build(query: "What did Sarah say about pricing last month?")
        let evidence = try #require(pack.blocks.first { $0.kind == .directEvidence })

        #expect(evidence.text.contains("Sarah raised pricing concerns"))
        #expect(evidence.text.contains("revisit margins"))
        #expect(evidence.text.count > "Sarah pricing".count)
    }

    @Test("infers action-item intent")
    func infersActionIntent() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(recording(
            wav: "/tmp/followup.wav",
            title: "Follow-up",
            transcript: "We need to follow up on onboarding tasks."
        ))

        let pack = try await ContextPackBuilder(store: store).build(query: "follow up onboarding")

        #expect(pack.intent == .actionItems)
    }

    @Test("markdown renderer groups blocks and includes sources")
    func rendersMarkdown() async throws {
        let source = ContextSource(recording: recording(
            wav: "/tmp/source.wav",
            title: "Roadmap Sync",
            transcript: "roadmap"
        ))
        let pack = ContextPack(
            query: "roadmap",
            intent: .project,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            blocks: [
                ContextBlock(
                    id: "1:evidence",
                    kind: .directEvidence,
                    source: source,
                    text: "The roadmap depends on search.",
                    score: 1
                ),
            ]
        )

        let markdown = ContextPackMarkdownRenderer.render(pack)

        #expect(markdown.contains("# Context: roadmap"))
        #expect(markdown.contains("## Relevant Evidence"))
        #expect(markdown.contains("## Sources"))
        #expect(markdown.contains("/tmp/source.wav"))
    }
}
