import Foundation
import Testing
import GRDB
import HarcDomain
@testable import HarcStore
@testable import HarcUI

private actor PreviewReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Selected preview lifecycle", .serialized)
@MainActor
struct SelectedProjectPreviewControllerTests {
    private let source = "We will repair the café entrance after approval. Approval is still blocked."
    private let raw = #"{"decision":"suggest","quote":"repair the café entrance after approval."}"#
    private func fixture() async throws -> (RecordingStore, Recording, KnowledgeProject, HostWriterLease, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selected-preview-" + UUID().uuidString)
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let rec = try await store.upsert(Recording(wavPath: root.appendingPathComponent("unused.wav").path, startedAt: Date(), transcriptText: source))
        let project = try await store.createKnowledgeProject(name: "Entrance")
        let metadata = try await store.libraryMetadata()
        let lease = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x71, count: 32)), hostStateID: .random())
        let updated = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
            brief: "Repair the café entrance after approval.", expectedHost: store.libraryMetadata())
        return (store, rec, updated, lease, root)
    }
    private func selection(_ store: RecordingStore, _ rec: Recording, _ project: KnowledgeProject) async throws -> ProjectPreviewSelection {
        ProjectPreviewSelection(recordingID: rec.id!, canonicalID: rec.canonicalID, projectID: project.id,
            projectVersion: project.version, expectedHost: try await store.libraryMetadata())
    }
    private func settle(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    @Test func defaultUnavailableThenFullPreviewAndDismiss() async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SelectedProjectPreviewController(store: store, externalChanges: NotificationCenter())
        let selected = try await selection(store, rec, project)
        #expect(await controller.begin(selected) == nil)
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(selected))
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "unverified fixture", token: token)
        #expect(controller.preview?.fullSourceText == source)
        #expect(controller.state == .showingPreview)
        #expect(try await store.pendingProjectReviewCards().isEmpty)
        controller.dismiss()
        #expect(controller.preview == nil)
        #expect(controller.state == .idle)
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "late", token: token)
        #expect(controller.preview == nil)
    }
    @Test(arguments: ["transcript", "project", "trash", "host", "canonical"])
    func actualStoreMutationInvalidates(kind: String) async throws {
        let (store, rec, project, lease, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SelectedProjectPreviewController(store: store, externalChanges: NotificationCenter())
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(selection(store, rec, project)))
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "fixture", token: token)
        #expect(controller.preview != nil)
        switch kind {
        case "transcript":
            var changed = rec; changed.transcriptText = source + " Changed."
            _ = try await store.upsert(changed)
        case "project":
            _ = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
                brief: "Different scope.", expectedHost: store.libraryMetadata())
        case "trash": try await store.softDelete(id: rec.id!)
        case "canonical":
            let queue = await store.uncoordinatedDB
            try await queue.write { db in
                try db.execute(sql: "UPDATE recordings SET canonical_uuid = ? WHERE id = ?",
                    arguments: [UUID().uuidString, rec.id!])
            }
        default: try await store.disableHostMode(lease)
        }
        #expect(await settle { controller.state == .invalidated })
        #expect(controller.preview == nil)
    }
    @Test(arguments: [false, true])
    func mutationOrCancellationDuringSuspendedInitialRead(cancel: Bool) async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreviewReadGate()
        let controller = SelectedProjectPreviewController(readSnapshot: { selected in
            let snapshot = try await store.projectEvidenceSnapshot(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, projectID: selected.projectID,
                projectVersion: selected.projectVersion, expectedHost: selected.expectedHost)
            await gate.wait()
            return snapshot
        }, current: { try await store.projectPreviewIsCurrent($0) }, watch: {
            await store.observeProjectPreviewChanges(recordingID: $0.recordingID, projectID: $0.projectID)
        })
        controller.residentHostAvailabilityChanged(true)
        let selected = try await selection(store, rec, project)
        let task = Task { await controller.begin(selected) }
        #expect(await settle { await gate.entered })
        if cancel {
            task.cancel()
            #expect(await settle { controller.state == .invalidated })
        } else {
            var changed = rec; changed.transcriptText = source + " Changed while read suspended."
            _ = try await store.upsert(changed)
            #expect(await settle { controller.state == .invalidated })
        }
        await gate.release()
        #expect(await task.value == nil)
        #expect(controller.state == .invalidated)
        #expect(controller.preview == nil)
    }
    @Test func runtimeLossAndExternalNotificationAndOldToken() async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = NotificationCenter()
        let controller = SelectedProjectPreviewController(store: store, externalChanges: center)
        let selected = try await selection(store, rec, project)
        controller.residentHostAvailabilityChanged(true)
        let old = try #require(await controller.begin(selected))
        controller.selectionDidChange()
        let fresh = try #require(await controller.begin(selected))
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "old", token: old)
        #expect(controller.state == .awaitingResponse)
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "fresh", token: fresh)
        #expect(controller.preview?.unverifiedModelLabel == "fresh")
        controller.residentHostAvailabilityChanged(false)
        #expect(controller.preview == nil)
        controller.residentHostAvailabilityChanged(true)
        _ = await controller.begin(selected)
        center.post(name: Notification.Name(RecordingStore.externalChangeNotification), object: nil)
        #expect(await settle { controller.state == .invalidated })
    }
    @Test func normalObservationEndInvalidatesWithoutSourceChange() async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let lease = ProjectPreviewChangeObservation(changes: stream, cancel: { continuation.finish() })
        let controller = SelectedProjectPreviewController(readSnapshot: { selected in
            try await store.projectEvidenceSnapshot(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, projectID: selected.projectID,
                projectVersion: selected.projectVersion, expectedHost: selected.expectedHost)
        }, current: { try await store.projectPreviewIsCurrent($0) }, watch: { _ in lease })
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(selection(store, rec, project)))
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "fixture", token: token)
        #expect(controller.preview != nil)
        continuation.finish()
        #expect(await settle { controller.state == .invalidated })
        #expect(controller.preview == nil)
    }

    @Test func cancelledSuspendedFreshnessCheckCannotPublish() async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreviewReadGate()
        let controller = SelectedProjectPreviewController(readSnapshot: { selected in
            try await store.projectEvidenceSnapshot(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, projectID: selected.projectID,
                projectVersion: selected.projectVersion, expectedHost: selected.expectedHost)
        }, current: { snapshot in
            await gate.wait()
            return try await store.projectPreviewIsCurrent(snapshot)
        }, watch: {
            await store.observeProjectPreviewChanges(recordingID: $0.recordingID, projectID: $0.projectID)
        })
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(selection(store, rec, project)))
        let task = Task { await controller.receive(rawResponse: raw, unverifiedModelLabel: "fixture", token: token) }
        #expect(await settle { await gate.entered })
        task.cancel()
        #expect(await settle { controller.state == .invalidated })
        await gate.release()
        await task.value
        #expect(controller.preview == nil)
    }

    @Test func concurrentDuplicateResponseCannotInvalidateLegitimatePreview() async throws {
        let (store, rec, project, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreviewReadGate()
        let controller = SelectedProjectPreviewController(readSnapshot: { selected in
            try await store.projectEvidenceSnapshot(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, projectID: selected.projectID,
                projectVersion: selected.projectVersion, expectedHost: selected.expectedHost)
        }, current: { snapshot in
            if !(await gate.entered) { await gate.wait() }
            return try await store.projectPreviewIsCurrent(snapshot)
        }, watch: {
            await store.observeProjectPreviewChanges(recordingID: $0.recordingID, projectID: $0.projectID)
        })
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(selection(store, rec, project)))
        let first = Task { await controller.receive(rawResponse: raw, unverifiedModelLabel: "first", token: token) }
        #expect(await settle { await gate.entered })
        #expect(controller.state == .processingResponse)
        // First response is suspended inside freshness validation. The replay
        // must return without validating or consuming the session ticket.
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "duplicate", token: token)
        #expect(controller.state == .processingResponse)
        await gate.release()
        await first.value
        #expect(controller.state == .showingPreview)
        #expect(controller.preview?.unverifiedModelLabel == "first")
        #expect(controller.preview?.fullSourceText == source)
        await controller.receive(rawResponse: raw, unverifiedModelLabel: "late duplicate", token: token)
        #expect(controller.state == .showingPreview)
    }

}
