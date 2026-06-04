import Foundation
import Testing
@testable import HarcContext

@Suite("Source wiki proposal generator")
struct SourceWikiProposalGeneratorTests {
    @Test("repository scans generate synthesized project, source, decision, and question proposals")
    func repositoryScanGeneratesSynthesizedProposals() throws {
        let root = LocalSourceRoot(
            id: "atlas-root",
            path: "/tmp/Atlas",
            displayName: "Atlas",
            kind: .repository,
            readOnly: true
        )
        let docs = [
            document(
                root: root,
                relativePath: "README.md",
                text: """
                # Atlas
                Atlas coordinates local meeting memory and wiki synthesis.
                The team decided to keep raw repositories read-only.
                """
            ),
            document(
                root: root,
                relativePath: "Sources/Indexer.swift",
                text: """
                struct Indexer {
                    // TODO: add incremental delete handling?
                    let mode = "local"
                }
                """
            ),
            document(
                root: root,
                relativePath: "Tests/IndexerTests.swift",
                text: "final class IndexerTests {}"
            ),
        ]

        let proposals = SourceWikiProposalGenerator.proposals(
            for: root,
            documents: docs,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(proposals.contains { $0.targetSection == .projects && $0.targetTitle == "Atlas Project Map" })
        #expect(proposals.contains { $0.targetSection == .sources && $0.targetTitle == "Atlas Source Overview" })
        #expect(proposals.contains { $0.targetSection == .decisions && $0.proposedMarkdown.contains("raw repositories read-only") })
        #expect(proposals.contains { $0.targetSection == .openQuestions && $0.proposedMarkdown.contains("incremental delete handling") })
        #expect(proposals.allSatisfy { !$0.sourceCitations.isEmpty })
        #expect(proposals.allSatisfy { !$0.knowledgeCitations.isEmpty })
        #expect(proposals.flatMap(\.knowledgeCitations).allSatisfy { $0.kind == .sourceFile })
        #expect(proposals.contains { proposal in
            proposal.targetSection == .decisions
                && proposal.knowledgeCitations.contains { $0.displayText == "/tmp/Atlas/README.md:3" }
        })
    }

    @Test("folder scans skip repository project maps")
    func folderScanSkipsProjectMap() throws {
        let root = LocalSourceRoot(
            id: "folder-root",
            path: "/tmp/Context",
            displayName: "Context",
            kind: .folder,
            readOnly: true
        )
        let docs = [
            document(
                root: root,
                relativePath: "notes.md",
                text: "Personal context note with enough words to become a summary line."
            )
        ]

        let proposals = SourceWikiProposalGenerator.proposals(for: root, documents: docs)

        #expect(proposals.contains { $0.targetSection == .sources && $0.targetTitle == "Context Source Overview" })
        #expect(!proposals.contains { $0.targetSection == .projects })
    }

    private func document(
        root: LocalSourceRoot,
        relativePath: String,
        text: String
    ) -> ScannedSourceDocument {
        ScannedSourceDocument(
            title: URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
            text: text,
            provenance: SourceProvenance(
                rootID: root.id,
                rootPath: root.path,
                relativePath: relativePath,
                absolutePath: "\(root.path)/\(relativePath)",
                lineStart: 1,
                lineEnd: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                contentHash: "\(relativePath)-hash",
                documentKind: relativePath.hasSuffix(".swift") ? .sourceCode : .markdown,
                scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }
}
