import Foundation
import HarcStore
import Testing
@testable import HarcContext

@Suite("Library review proposal generator")
struct LibraryReviewProposalGeneratorTests {
    @Test("completed summaries generate decision question project and person proposals")
    func completedSummaryGeneratesReviewProposals() {
        let recording = Recording(
            id: 42,
            wavPath: "/tmp/atlas.wav",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            title: "Atlas Planning",
            tags: ["project:Atlas"],
            speakerNames: [1: "Amy Chen"],
            summaryMarkdown: """
            # Summary
            The team decided to keep Atlas local-first.
            Open question: who owns the migration checklist?
            @person[Neal Patel] will follow up.
            """
        )

        let proposals = LibraryReviewProposalGenerator.recordingProposals(
            for: recording,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        #expect(proposals.contains { $0.targetSection == .decisions && $0.proposedMarkdown.contains("local-first") })
        #expect(proposals.contains { $0.targetSection == .openQuestions && $0.proposedMarkdown.contains("migration checklist") })
        #expect(proposals.contains { $0.targetSection == .projects && $0.targetTitle == "Atlas" })
        #expect(proposals.contains { $0.targetSection == .people && $0.targetTitle == "Amy Chen" })
        #expect(proposals.contains { $0.targetSection == .people && $0.targetTitle == "Neal Patel" })
        #expect(proposals.allSatisfy { $0.knowledgeCitations.contains { $0.kind == .recording } })
    }

    @Test("saved notes generate project person and topic proposals")
    func savedNotesGenerateReviewProposals() {
        let note = Note(
            id: "note-1",
            title: "Atlas Daily",
            body: """
            @project[Atlas]
            @person[Amy Chen]
            We should connect this to [[Onboarding]] and [[Support Motion]].
            """,
            tags: ["customer-success", "project:Atlas"],
            people: ["Neal Patel"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            fileURL: URL(fileURLWithPath: "/tmp/notes/atlas.md")
        )

        let proposals = LibraryReviewProposalGenerator.noteProposals(for: note)

        #expect(proposals.contains { $0.targetSection == .projects && $0.targetTitle == "Atlas" })
        #expect(proposals.contains { $0.targetSection == .people && $0.targetTitle == "Amy Chen" })
        #expect(proposals.contains { $0.targetSection == .people && $0.targetTitle == "Neal Patel" })
        #expect(proposals.contains { $0.targetSection == .topics && $0.targetTitle == "customer-success" })
        #expect(proposals.contains { $0.targetSection == .topics && $0.targetTitle == "Onboarding" })
        #expect(proposals.allSatisfy { $0.knowledgeCitations.contains { $0.kind == .note } })
    }

    @Test("combined generation is bounded to recent recordings and notes")
    func combinedGenerationIsBounded() {
        let recordings = (0..<4).map { index in
            Recording(
                id: Int64(index),
                wavPath: "/tmp/\(index).wav",
                startedAt: Date(timeIntervalSince1970: Double(index)),
                title: "Recording \(index)",
                tags: ["project:R\(index)"],
                summaryMarkdown: "The team decided item \(index)."
            )
        }
        let notes = (0..<4).map { index in
            Note(
                id: "note-\(index)",
                title: "Note \(index)",
                body: "@project[N\(index)]",
                createdAt: Date(timeIntervalSince1970: Double(index)),
                updatedAt: Date(timeIntervalSince1970: Double(index)),
                fileURL: URL(fileURLWithPath: "/tmp/note-\(index).md")
            )
        }

        let proposals = LibraryReviewProposalGenerator.proposals(
            recordings: recordings,
            notes: notes,
            maxRecordings: 2,
            maxNotes: 2
        )

        #expect(proposals.contains { $0.targetTitle == "R3" })
        #expect(proposals.contains { $0.targetTitle == "R2" })
        #expect(!proposals.contains { $0.targetTitle == "R0" })
        #expect(proposals.contains { $0.targetTitle == "N3" })
        #expect(proposals.contains { $0.targetTitle == "N2" })
        #expect(!proposals.contains { $0.targetTitle == "N0" })
    }
}
