import Foundation
import Testing
@testable import HarcContext

@Suite("Wiki review store")
struct WikiReviewStoreTests {
    @Test("upsert and status transitions persist review proposals")
    func upsertAndStatusTransition() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-review-\(UUID().uuidString)", isDirectory: true)
        let store = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: rootURL)
        )
        let proposal = WikiReviewProposal(
            id: "p1",
            kind: .createPage,
            title: "Create Atlas page",
            summary: "Summarize Atlas context.",
            targetSection: .projects,
            targetTitle: "Atlas",
            proposedMarkdown: "# Atlas\n\nCompiled context.",
            sourceCitations: ["/tmp/atlas.md:1"],
            createdAt: Date(timeIntervalSince1970: 100)
        )

        _ = try await store.upsert(proposal)
        let dismissed = try await store.updateStatus(id: "p1", status: .dismissed)
        let all = try await store.fetchAll()

        #expect(dismissed.status == .dismissed)
        #expect(all.count == 1)
        #expect(all[0].sourceCitations == ["/tmp/atlas.md:1"])
    }

    @Test("approve writes a wiki page and marks proposal approved")
    func approveWritesWikiPage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-review-approve-\(UUID().uuidString)", isDirectory: true)
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let store = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: wikiStore
        )
        let proposal = WikiReviewProposal(
            id: "p2",
            kind: .createPage,
            title: "Create Decision page",
            summary: "Capture the durable decision.",
            targetSection: .decisions,
            targetTitle: "Use Read Only Sources",
            proposedMarkdown: "# Use Read Only Sources\n\nRaw folders stay immutable.",
            sourceCitations: ["/tmp/source.md:4"]
        )

        _ = try await store.upsert(proposal)
        let approved = try await store.approve(id: "p2")
        let pages = try await wikiStore.fetchPages(section: .decisions)

        #expect(approved.status == .approved)
        #expect(pages.map(\.title) == ["Use Read Only Sources"])
        #expect(pages[0].body.contains("Raw folders stay immutable."))
    }
}
