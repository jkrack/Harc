import Foundation
import Testing
import HarcDomain
@testable import HarcStore

@Suite("Selected-source project evidence contract")
struct ProjectEvidenceContractTests {
    private func fixture(text: String = "We will ship the renewal plan on Friday.") async throws -> (RecordingStore, Recording, KnowledgeProject, LibraryMetadata, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-evidence-\(UUID())")
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let recording = try await store.upsert(Recording(wavPath: root.appendingPathComponent("a.wav").path, startedAt: Date(), transcriptText: text))
        let project = try await store.createKnowledgeProject(name: "Renewal")
        let metadata = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x75, count: 32)), hostStateID: .random())
        return (store, recording, project, try await store.libraryMetadata(), root)
    }
    private func snapshot(_ store: RecordingStore, _ rec: Recording, _ project: KnowledgeProject, _ host: LibraryMetadata) async throws -> ProjectEvidenceSnapshot {
        let project = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
            brief: "Customer renewal planning, pricing decisions and delivery milestones.", expectedHost: host)
        return try await store.projectEvidenceSnapshot(recordingID: rec.id!, canonicalID: rec.canonicalID,
            projectID: project.id, projectVersion: project.version, expectedHost: host)
    }

    @Test func oldProjectsDecodeWithoutFabricatedBrief() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"name\":\"Old\",\"version\":\"\(UUID())\"}".utf8)
        #expect(try JSONDecoder().decode(KnowledgeProject.self, from: data).brief == nil)
    }

    @Test func explicitBriefEditUsesCASAndInvalidatesPriorSnapshotRequest() async throws {
        let (store, rec, project, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await snapshot(store, rec, project, host)
        #expect(snap.project.version != project.version)
        await #expect(throws: ProjectRefinementError.conflict) {
            _ = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version, brief: "Different", expectedHost: host)
        }
        await #expect(throws: ProjectRefinementError.staleEvidence) {
            _ = try await store.projectEvidenceSnapshot(recordingID: rec.id!, canonicalID: rec.canonicalID,
                projectID: project.id, projectVersion: project.version, expectedHost: host)
        }
    }

    @Test func fakeResponsePreservesExactUnicodeSourceSpanAndAbstention() async throws {
        let text = "🙂 Intro. Café renewal pricing is still unresolved. End."
        let (store, rec, project, host, root) = try await fixture(text: text)
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await snapshot(store, rec, project, host)
        let raw = "{\"decision\":\"suggest\",\"quote\":\"Café renewal pricing is still unresolved.\"}"
        guard case .candidate(let evidence) = try RecordingStore.validateProjectEvidenceResponse(raw, snapshot: snap, modelID: "fake-local") else { Issue.record("Expected candidate"); return }
        #expect(String(data: Data(text.utf8)[evidence.startUTF8..<evidence.endUTF8], encoding: .utf8) == evidence.quote)
        guard case .abstain = try RecordingStore.validateProjectEvidenceResponse("{\"decision\":\"abstain\"}", snapshot: snap, modelID: "fake-local") else { Issue.record("Expected abstention"); return }
        #expect(try await store.pendingProjectReviewCards().isEmpty)
        #expect(try await store.confirmedProjectMatches(recordingID: rec.id!).isEmpty)
    }

    @Test func malformedUnsupportedAndInventedResponsesFailClosed() async throws {
        let (store, rec, project, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await snapshot(store, rec, project, host)
        for raw in ["not json", "{\"decision\":\"suggest\",\"decision\":\"abstain\"}", "{\"decision\":\"accept\"}", "{\"decision\":\"abstain\",\"confidence\":0.99}",
                    "{\"decision\":\"suggest\",\"quote\":\"Invented supporting statement\"}",
                    "{\"decision\":\"suggest\",\"quote\":\"Friday\"}",
                    "{\"decision\":\"suggest\",\"quote\":\"We will ship the renewal plan on Friday.\",\"timestamp\":42}"] {
            #expect(throws: ProjectEvidenceContractError.invalidResponse) {
                _ = try RecordingStore.validateProjectEvidenceResponse(raw, snapshot: snap, modelID: "fake-local")
            }
        }
    }

    @Test func repeatedQuotesAreAmbiguousNotInventedOffsets() async throws {
        let (store, rec, project, host, root) = try await fixture(text: "Renewal pricing is unresolved. Renewal pricing is unresolved.")
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await snapshot(store, rec, project, host)
        #expect(throws: ProjectEvidenceContractError.ambiguousQuote) {
            _ = try RecordingStore.validateProjectEvidenceResponse("{\"decision\":\"suggest\",\"quote\":\"Renewal pricing is unresolved.\"}", snapshot: snap, modelID: "fake-local")
        }
    }

    @Test func missingBriefAndOversizedSourceNeverSilentlyTruncate() async throws {
        let (store, rec, project, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ProjectEvidenceContractError.invalidBrief) {
            _ = try await store.projectEvidenceSnapshot(recordingID: rec.id!, canonicalID: rec.canonicalID, projectID: project.id, projectVersion: project.version, expectedHost: host)
        }
        let snap = try await snapshot(store, rec, project, host)
        var large = rec; large.transcriptText = String(repeating: "x", count: 32_769)
        _ = try await store.upsert(large)
        await #expect(throws: ProjectEvidenceContractError.oversizedSource) {
            _ = try await store.projectEvidenceSnapshot(recordingID: rec.id!, canonicalID: rec.canonicalID, projectID: project.id, projectVersion: snap.project.version, expectedHost: host)
        }
    }
    @Test func blankEvidenceAndEscapedDuplicateKeysFailClosed() async throws {
        let (store, rec, project, host, root) = try await fixture(text: "Prefix            suffix.")
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await snapshot(store, rec, project, host)
        let blank = "{\"decision\":\"suggest\",\"quote\":\"            \"}"
        #expect(throws: ProjectEvidenceContractError.invalidResponse) {
            _ = try RecordingStore.validateProjectEvidenceResponse(blank, snapshot: snap, modelID: "fake-local")
        }
        let escapedDuplicate = #"{"decision":"suggest","\u0064ecision":"abstain"}"#
        #expect(throws: ProjectEvidenceContractError.invalidResponse) {
            _ = try RecordingStore.validateProjectEvidenceResponse(escapedDuplicate, snapshot: snap, modelID: "fake-local")
        }
    }

}
