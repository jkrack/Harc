import Foundation
import Testing
@testable import HarcContext

@Suite("Knowledge citations")
struct KnowledgeCitationTests {
    @Test("recording note wiki page and source file citations encode and decode")
    func citationTypesEncodeDecode() throws {
        let citations = [
            KnowledgeCitation(
                id: "recording:1",
                kind: .recording,
                title: "Pricing Review",
                timestampSeconds: 125
            ),
            KnowledgeCitation(
                id: "note:daily",
                kind: .note,
                title: "Daily Note",
                path: "/notes/daily.md"
            ),
            KnowledgeCitation(
                id: "wiki:projects/atlas",
                kind: .wikiPage,
                title: "Atlas"
            ),
            KnowledgeCitation(
                id: "source:readme",
                kind: .sourceFile,
                title: "README.md",
                path: "/repo/README.md",
                lineStart: 4,
                lineEnd: 6,
                contentHash: "abc"
            ),
        ]

        let data = try JSONEncoder().encode(citations)
        let decoded = try JSONDecoder().decode([KnowledgeCitation].self, from: data)

        #expect(decoded == citations)
        #expect(decoded[0].displayText == "Pricing Review @ 2:05")
        #expect(decoded[3].displayText == "/repo/README.md:4-6")
    }

    @Test("legacy proposals without structured citations still decode and render sources")
    func legacyProposalCompatibility() throws {
        let json = """
        {
          "id": "legacy",
          "kind": "createPage",
          "status": "pending",
          "title": "Create Atlas",
          "summary": "Legacy proposal",
          "targetSection": "projects",
          "targetTitle": "Atlas",
          "proposedMarkdown": "# Atlas\\n\\nLegacy body.",
          "sourceCitations": ["/tmp/atlas.md:3"],
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let proposal = try decoder.decode(WikiReviewProposal.self, from: Data(json.utf8))

        #expect(proposal.knowledgeCitations.isEmpty)
        #expect(proposal.sourceCitations == ["/tmp/atlas.md:3"])
        #expect(proposal.renderedCitations == ["/tmp/atlas.md:3"])
    }

    @Test("proposal rendering prefers structured citations and deduplicates legacy strings")
    func renderedCitationsDeduplicateStructuredAndLegacySources() {
        let proposal = WikiReviewProposal(
            id: "p1",
            kind: .createPage,
            title: "Create Atlas",
            summary: "Structured proposal",
            targetSection: .projects,
            targetTitle: "Atlas",
            proposedMarkdown: "# Atlas",
            sourceCitations: ["/tmp/atlas.md:4", "/tmp/other.md:1"],
            knowledgeCitations: [
                KnowledgeCitation(
                    id: "source:atlas",
                    kind: .sourceFile,
                    path: "/tmp/atlas.md",
                    lineStart: 4
                )
            ]
        )

        #expect(proposal.renderedCitations == ["/tmp/atlas.md:4", "/tmp/other.md:1"])
    }
}
