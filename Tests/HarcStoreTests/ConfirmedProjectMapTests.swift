import Foundation
import Testing
import GRDB
import HarcDomain
@testable import HarcStore

@Suite("Read-only accepted project map")
struct ConfirmedProjectMapTests {
    private func fixture() async throws -> (RecordingStore, Recording, LibraryMetadata, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("confirmed-map-" + UUID().uuidString)
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let recording = try await store.upsert(Recording(wavPath: "/tmp/unused-map-\(UUID()).wav",
            startedAt: Date(timeIntervalSince1970: 1), title: "Synthetic source",
            transcriptText: "We discussed the entrance project, but approval is blocked."))
        let metadata = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x45, count: 32)), hostStateID: .random())
        return (store, recording, try await store.libraryMetadata(), root)
    }
    private func add(_ store: RecordingStore, _ recording: Recording, _ decision: ProjectReviewDecision) async throws -> ProjectMatchReview {
        let project = try await store.createKnowledgeProject(name: "Entrance")
        let review = try await store.proposeProjectMatch(recordingID: recording.id!, projectID: project.id,
            quote: "approval is blocked", generatorID: "synthetic")
        if decision != .pending {
            _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version,
                decision: decision, operationID: UUID())
        }
        return review
    }
    @Test func onlyAcceptedSelectedSourceAndNoWrites() async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for decision in [ProjectReviewDecision.accepted, .pending, .rejected, .unsure] {
            _ = try await add(store, recording, decision)
        }
        let other = try await store.upsert(Recording(wavPath: "/tmp/unused-other.wav", startedAt: Date(),
            transcriptText: "approval is blocked"))
        _ = try await add(store, other, .accepted)
        let before = try await store.db.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        let map = try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host)
        #expect(map.connections.count == 1)
        #expect(map.connections.first?.evidenceIsCurrent == true)
        #expect(map.recordingTitle == "Synthetic source")
        #expect(!map.hasMore)
        #expect(try await store.db.read { try Int.fetchOne($0, sql: "SELECT total_changes()") } == before)
    }
    @Test func changedProjectUsesCurrentNameAndMarksEvidenceStale() async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try await add(store, recording, .accepted)
        let renamed = KnowledgeProject(id: review.project.id, name: "Renamed entrance", version: UUID())
        try await store.db.write { db in
            try db.execute(sql: "UPDATE knowledge_projects SET payload = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(renamed), renamed.id.uuidString])
        }
        let map = try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host)
        #expect(map.connections.first?.projectName == "Renamed entrance")
        #expect(map.connections.first?.evidenceIsCurrent == false)
        #expect(try await store.projectMatchReview(id: review.id).decision == .accepted)
    }
    @Test func changedTranscriptRetainsAcceptedLinkButNotCurrentEvidence() async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await add(store, recording, .accepted)
        try await store.db.write { try $0.execute(sql: "UPDATE recordings SET transcript_text = 'Correction: canceled' WHERE id = ?", arguments: [recording.id!]) }
        let map = try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host)
        #expect(map.connections.count == 1)
        #expect(map.connections.first?.evidenceIsCurrent == false)
        #expect(map.connections.first?.originalQuote == "approval is blocked")
    }
    @Test func boundedSnapshotReportsMoreWithoutConflatingEmpty() async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host).connections.isEmpty)
        _ = try await add(store, recording, .accepted)
        _ = try await add(store, recording, .accepted)
        let map = try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host, limit: 1)
        #expect(map.connections.count == 1)
        #expect(map.hasMore)
    }
    @Test func wrongCanonicalTrashAndHostFailClosed() async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ProjectRefinementError.missing) {
            try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: .random(), expectedHost: host)
        }
        try await store.db.write { try $0.execute(sql: "UPDATE recordings SET deleted_at = 1 WHERE id = ?", arguments: [recording.id!]) }
        await #expect(throws: ProjectRefinementError.missing) {
            try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host)
        }
        let otherStore = try await RecordingStore.inMemory()
        let wrongHost = try await otherStore.libraryMetadata()
        await #expect(throws: ProjectRefinementError.hostUnavailable) {
            try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: wrongHost)
        }
    }
    @Test(arguments: ["id", "recordingID", "canonicalID", "project", "projectPayload"])
    func corruptBindingsNeverExposeAnEdge(field: String) async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try await add(store, recording, .accepted)
        try await store.db.write { db in
            if field == "projectPayload" {
                let foreign = KnowledgeProject(id: UUID(), name: "Foreign", version: UUID())
                try db.execute(sql: "UPDATE knowledge_projects SET payload = ? WHERE id = ?",
                    arguments: [try JSONEncoder().encode(foreign), review.project.id.uuidString])
            } else {
                let data = try Data.fetchOne(db, sql: "SELECT payload FROM project_match_reviews WHERE id = ?",
                    arguments: [review.id.uuidString])!
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                switch field {
                case "id": object["id"] = UUID().uuidString
                case "recordingID": object["recordingID"] = recording.id! + 100
                case "canonicalID":
                    let foreign = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CanonicalRecordingID.random()), options: .fragmentsAllowed)
                    object["canonicalID"] = foreign
                default:
                    var project = object["project"] as! [String: Any]
                    project["id"] = UUID().uuidString
                    object["project"] = project
                }
                try db.execute(sql: "UPDATE project_match_reviews SET payload = ? WHERE id = ?",
                    arguments: [try JSONSerialization.data(withJSONObject: object), review.id.uuidString])
            }
        }
        await #expect(throws: ProjectRefinementError.invalidEvidence) {
            try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: host)
        }
    }

    @Test(arguments: ["library", "authority", "state"])
    func staleHostTupleFailsClosed(component: String) async throws {
        let (store, recording, host, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await add(store, recording, .accepted)
        let stale = try LibraryMetadata(libraryID: component == "library" ? .random() : host.libraryID,
            writerMode: .host,
            hostAuthorityID: component == "authority" ? HostAuthorityID(Data(repeating: 0x46, count: 32)) : host.hostAuthorityID,
            hostStateID: component == "state" ? .random() : host.hostStateID,
            currentChangeCursor: host.currentChangeCursor)
        await #expect(throws: ProjectRefinementError.hostUnavailable) {
            try await store.confirmedProjectMap(recordingID: recording.id!, canonicalID: recording.canonicalID, expectedHost: stale)
        }
    }

}
