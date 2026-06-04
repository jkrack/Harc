import Foundation
import Testing
@testable import HarcContext

@Suite("Wiki merger")
struct WikiMergerTests {
    @Test("creates missing pages from a managed template")
    func createsMissingPages() async throws {
        let rootURL = temporaryWikiRoot()
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let merger = WikiMerger(wikiStore: wikiStore)

        let result = try await merger.merge(proposal(
            id: "create-atlas",
            title: "Atlas",
            markdown: "# Atlas\n\nAtlas is the active customer workspace.",
            sources: ["/notes/atlas.md:4"]
        ))

        #expect(result.didChange)
        #expect(result.page.body.contains("title: Atlas"))
        #expect(result.page.body.contains("section: projects"))
        #expect(result.page.body.contains("  - /notes/atlas.md:4"))
        #expect(result.page.body.contains("# Atlas"))
        #expect(result.page.body.contains("<!-- harc:managed:start id=\"create-atlas\""))
        #expect(result.page.body.contains("Atlas is the active customer workspace."))
    }

    @Test("appends managed updates while preserving user-authored body exactly")
    func appendsManagedUpdatesAndPreservesUserBody() async throws {
        let rootURL = temporaryWikiRoot()
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let existing = """
        ---
        title: Atlas
        section: projects
        sources:
          - /notes/original.md:1
        ---

        # Atlas

        User paragraph with deliberate spacing.

        ## Manual Notes

        Keep this text exactly.
        """

        _ = try await wikiStore.writePage(section: .projects, title: "Atlas", body: existing)
        let result = try await WikiMerger(wikiStore: wikiStore).merge(proposal(
            id: "append-atlas",
            title: "Atlas",
            markdown: "# Atlas\n\nNew machine-managed update.",
            sources: ["/notes/original.md:1", "/notes/new.md:2"]
        ))

        let page = try #require(try await wikiStore.fetchPage(id: "projects/atlas"))
        #expect(result.didChange)
        #expect(page.body.contains("  - /notes/original.md:1"))
        #expect(page.body.contains("  - /notes/new.md:2"))
        #expect(page.body.contains("User paragraph with deliberate spacing.\n\n## Manual Notes\n\nKeep this text exactly."))
        #expect(page.body.contains("## Updates\n\n<!-- harc:managed:start id=\"append-atlas\""))
        #expect(page.body.contains("New machine-managed update."))
    }

    @Test("reapproving equivalent content does not duplicate managed updates")
    func equivalentContentDoesNotDuplicate() async throws {
        let rootURL = temporaryWikiRoot()
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let merger = WikiMerger(wikiStore: wikiStore)

        _ = try await merger.merge(proposal(
            id: "first",
            title: "Atlas",
            markdown: "# Atlas\n\nSame durable fact.",
            sources: ["/notes/a.md:1"]
        ))
        let second = try await merger.merge(proposal(
            id: "second",
            title: "Atlas",
            markdown: "# Atlas\n\nSame durable fact.",
            sources: ["/notes/a.md:1", "/notes/b.md:2"]
        ))

        let page = try #require(try await wikiStore.fetchPage(id: "projects/atlas"))
        #expect(second.didChange)
        #expect(page.body.ranges(of: "Same durable fact.").count == 1)
        #expect(page.body.ranges(of: "<!-- harc:managed:start").count == 1)
        #expect(page.body.contains("  - /notes/a.md:1"))
        #expect(page.body.contains("  - /notes/b.md:2"))
    }

    @Test("same proposal updates its managed block in place")
    func sameProposalUpdatesInPlace() async throws {
        let rootURL = temporaryWikiRoot()
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let merger = WikiMerger(wikiStore: wikiStore)

        _ = try await merger.merge(proposal(
            id: "stable",
            title: "Atlas",
            markdown: "# Atlas\n\nOld managed fact.",
            sources: ["/notes/a.md:1"]
        ))
        _ = try await merger.merge(proposal(
            id: "stable",
            title: "Atlas",
            markdown: "# Atlas\n\nUpdated managed fact.",
            sources: ["/notes/a.md:1"]
        ))

        let page = try #require(try await wikiStore.fetchPage(id: "projects/atlas"))
        #expect(!page.body.contains("Old managed fact."))
        #expect(page.body.contains("Updated managed fact."))
        #expect(page.body.ranges(of: "<!-- harc:managed:start id=\"stable\"").count == 1)
    }

    @Test("review approval uses merger instead of clobbering existing wiki page")
    func reviewApprovalUsesMerger() async throws {
        let rootURL = temporaryWikiRoot()
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let reviewStore = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: wikiStore
        )

        _ = try await wikiStore.writePage(
            section: .projects,
            title: "Atlas",
            body: "# Atlas\n\nManual page text."
        )
        _ = try await reviewStore.upsert(proposal(
            id: "approve",
            title: "Atlas",
            markdown: "# Atlas\n\nApproved machine update.",
            sources: ["/notes/source.md:9"]
        ))

        let approved = try await reviewStore.approve(id: "approve")
        let page = try #require(try await wikiStore.fetchPage(id: "projects/atlas"))

        #expect(approved.status == .approved)
        #expect(page.body.contains("Manual page text."))
        #expect(page.body.contains("Approved machine update."))
    }

    private func temporaryWikiRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-wiki-merge-\(UUID().uuidString)", isDirectory: true)
    }

    private func proposal(
        id: String,
        title: String,
        markdown: String,
        sources: [String]
    ) -> WikiReviewProposal {
        WikiReviewProposal(
            id: id,
            kind: .createPage,
            title: "Update \(title)",
            summary: "Merge \(title)",
            targetSection: .projects,
            targetTitle: title,
            proposedMarkdown: markdown,
            sourceCitations: sources,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
