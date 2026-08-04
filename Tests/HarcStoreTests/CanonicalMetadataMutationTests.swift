import Foundation
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Canonical metadata mutation idempotency")
struct CanonicalMetadataMutationTests {
    @Test("compare-and-swap result replays without another revision")
    func appliedReplay() async throws {
        let store = try await RecordingStore.inMemory()
        let inserted = try await store.upsert(
            Recording(
                wavPath: "/tmp/metadata-mutation.wav",
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                title: "Before"
            )
        )
        let operationID = OperationID(UUID())
        let digest = Data(repeating: 0x41, count: 32)
        let result = try await store.applyCanonicalMetadataMutation(
            operationID: operationID,
            exactRequestSHA256: digest,
            canonicalID: inserted.canonicalID,
            expectedRevision: inserted.revision,
            mutation: .setTitle("After"),
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )
        guard case .applied(let revision, let cursor) = result else {
            Issue.record("Expected applied result")
            return
        }
        #expect(revision.rawValue == inserted.revision.rawValue + 1)
        #expect(cursor.rawValue > 0)

        let replay = try await store.applyCanonicalMetadataMutation(
            operationID: operationID,
            exactRequestSHA256: digest,
            canonicalID: inserted.canonicalID,
            expectedRevision: inserted.revision,
            mutation: .setTitle("After"),
            at: Date(timeIntervalSince1970: 1_800_000_200)
        )
        #expect(replay == result)
        let stored = try #require(
            try await store.fetch(canonicalID: inserted.canonicalID)
        )
        #expect(stored.title == "After")
        #expect(stored.revision == revision)
    }

    @Test("stale revision returns a durable field-specific conflict")
    func conflictReplay() async throws {
        let store = try await RecordingStore.inMemory()
        let inserted = try await store.upsert(
            Recording(
                wavPath: "/tmp/metadata-conflict.wav",
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                title: "Host value"
            )
        )
        try await store.rename(id: try #require(inserted.id), title: "Newer Host value")
        let operationID = OperationID(UUID())
        let digest = Data(repeating: 0x42, count: 32)
        let result = try await store.applyCanonicalMetadataMutation(
            operationID: operationID,
            exactRequestSHA256: digest,
            canonicalID: inserted.canonicalID,
            expectedRevision: inserted.revision,
            mutation: .setTitle("Client value"),
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )
        guard case .conflict(let revision, let value) = result else {
            Issue.record("Expected conflict result")
            return
        }
        #expect(revision.rawValue == inserted.revision.rawValue + 1)
        #expect(value == .title("Newer Host value"))
        #expect(try await store.applyCanonicalMetadataMutation(
            operationID: operationID,
            exactRequestSHA256: digest,
            canonicalID: inserted.canonicalID,
            expectedRevision: inserted.revision,
            mutation: .setTitle("Client value"),
            at: Date(timeIntervalSince1970: 1_800_000_200)
        ) == result)
    }
}
