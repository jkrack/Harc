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

    @Test("editing markdown marks proposal edited and approval writes edited body")
    func editThenApproveWritesEditedBody() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-review-edit-approve-\(UUID().uuidString)", isDirectory: true)
        let wikiStore = HarcWikiStore(rootURL: rootURL)
        let store = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: wikiStore
        )
        let proposal = WikiReviewProposal(
            id: "p3",
            kind: .createPage,
            title: "Create Atlas page",
            summary: "Capture Atlas context.",
            targetSection: .projects,
            targetTitle: "Atlas",
            proposedMarkdown: "# Atlas\n\nOriginal body.",
            sourceCitations: ["/tmp/atlas.md:8"]
        )

        _ = try await store.upsert(proposal)
        let edited = try await store.updateMarkdown(
            id: "p3",
            proposedMarkdown: "# Atlas\n\nEdited body with user correction."
        )
        let approved = try await store.approve(id: "p3")
        let pages = try await wikiStore.fetchPages(section: .projects)

        #expect(edited.status == .edited)
        #expect(approved.status == .approved)
        #expect(pages[0].body.contains("Edited body with user correction."))
        #expect(!pages[0].body.contains("Original body."))
    }

    @Test("dismissed edited proposals retain edited markdown")
    func dismissedEditedProposalRetainsMarkdown() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-review-edit-dismiss-\(UUID().uuidString)", isDirectory: true)
        let store = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: rootURL)
        )
        let proposal = WikiReviewProposal(
            id: "p4",
            kind: .createPage,
            title: "Create Atlas page",
            summary: "Capture Atlas context.",
            targetSection: .projects,
            targetTitle: "Atlas",
            proposedMarkdown: "# Atlas\n\nOriginal body.",
            sourceCitations: []
        )

        _ = try await store.upsert(proposal)
        _ = try await store.updateMarkdown(id: "p4", proposedMarkdown: "# Atlas\n\nEdited then dismissed.")
        let dismissed = try await store.updateStatus(id: "p4", status: .dismissed)
        let all = try await store.fetchAll()

        #expect(dismissed.status == .dismissed)
        #expect(all[0].proposedMarkdown.contains("Edited then dismissed."))
    }

    @Test("upsert if reviewable does not recreate dismissed proposals")
    func upsertIfReviewableDoesNotRecreateDismissedProposal() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-review-dismissed-dedupe-\(UUID().uuidString)", isDirectory: true)
        let store = WikiReviewStore(
            fileURL: rootURL.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: rootURL)
        )
        let proposal = WikiReviewProposal(
            id: "stable-content-id",
            kind: .createPage,
            title: "Create Atlas page",
            summary: "Original summary.",
            targetSection: .projects,
            targetTitle: "Atlas",
            proposedMarkdown: "# Atlas\n\nOriginal body.",
            sourceCitations: []
        )

        _ = try await store.upsert(proposal)
        _ = try await store.updateStatus(id: proposal.id, status: .dismissed)
        var regenerated = proposal
        regenerated.summary = "Regenerated summary."
        regenerated.proposedMarkdown = "# Atlas\n\nRegenerated body."
        let result = try await store.upsertIfReviewable(regenerated)
        let all = try await store.fetchAll()

        #expect(result.status == .dismissed)
        #expect(all.count == 1)
        #expect(all[0].summary == "Original summary.")
        #expect(all[0].proposedMarkdown.contains("Original body."))
    }
}
