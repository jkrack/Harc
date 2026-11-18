import Foundation
import AppKit
import SwiftUI
import Testing
import GRDB
import HarcDomain
@testable import HarcStore
@testable import HarcUI

private actor MapReadGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor MapLoadCounter {
    var reads = 0
    var watches = 0
    func didRead() { reads += 1 }
    func didWatch() { watches += 1 }
}

@Suite("Accepted map lifecycle", .serialized)
@MainActor
struct ConfirmedProjectMapControllerTests {
    private func fixture() async throws -> (RecordingStore, Recording, KnowledgeProject, ProjectMatchReview, ConfirmedProjectMapSelection, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-lifecycle-" + UUID().uuidString)
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let rec = try await store.upsert(Recording(wavPath: root.appendingPathComponent("unused.wav").path,
            startedAt: Date(), transcriptText: "Approval is blocked."))
        let metadata = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x35, count: 32)), hostStateID: .random())
        let project = try await store.createKnowledgeProject(name: "Entrance")
        let review = try await store.proposeProjectMatch(recordingID: rec.id!, projectID: project.id,
            quote: "Approval is blocked.", generatorID: "synthetic")
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        let selection = ConfirmedProjectMapSelection(recordingID: rec.id!, canonicalID: rec.canonicalID, expectedHost: try await store.libraryMetadata())
        return (store, rec, project, review, selection, root)
    }
    private func settle(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return false
    }
    @Test(arguments: ["transcript", "title", "trash", "project", "decision", "newReview", "host", "canonical"])
    func storeChangesHideSnapshot(kind: String) async throws {
        let (store, rec, project, review, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ConfirmedProjectMapController(store: store, externalChanges: NotificationCenter())
        controller.residentHostAvailabilityChanged(true)
        await controller.select(selection)
        #expect(controller.state == .ready)
        #expect(controller.snapshot?.connections.count == 1)
        switch kind {
        case "transcript": var changed = rec; changed.transcriptText = "Canceled."; _ = try await store.upsert(changed)
        case "title": var changed = rec; changed.title = "Changed title"; _ = try await store.upsert(changed)
        case "trash": try await store.softDelete(id: rec.id!)
        case "project": _ = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
            brief: "Changed scope", expectedHost: selection.expectedHost)
        case "decision":
            let current = try await store.projectMatchReview(id: review.id)
            _ = try await store.decideProjectMatch(id: review.id, expectedVersion: current.version, decision: .rejected, operationID: UUID())
        case "newReview":
            let other = try await store.createKnowledgeProject(name: "Other")
            _ = try await store.proposeProjectMatch(recordingID: rec.id!, projectID: other.id, quote: "Approval is blocked.", generatorID: "synthetic")
        case "canonical": try await store.db.write { try $0.execute(sql: "UPDATE recordings SET canonical_uuid = ? WHERE id = ?", arguments: [UUID().uuidString, rec.id!]) }
        default: try await store.db.write { try $0.execute(sql: "UPDATE library_metadata SET host_state_uuid = ? WHERE id = 1", arguments: [UUID().uuidString]) }
        }
        #expect(await settle { controller.state == .invalidated })
        #expect(controller.snapshot == nil)
    }
    @Test(arguments: ["host", "selection", "external", "dismiss"])
    func lifecycleChangesClear(kind: String) async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = NotificationCenter()
        let controller = ConfirmedProjectMapController(store: store, externalChanges: notifications)
        await controller.select(selection)
        #expect(controller.snapshot == nil) // resident Host unavailable by default
        controller.residentHostAvailabilityChanged(true)
        await controller.select(selection)
        #expect(controller.snapshot != nil)
        switch kind {
        case "host": controller.residentHostAvailabilityChanged(false)
        case "selection": controller.selectionDidChange()
        case "external": notifications.post(name: Notification.Name(RecordingStore.externalChangeNotification), object: nil)
        default: controller.dismiss()
        }
        #expect(await settle { controller.snapshot == nil })
    }
    @Test(arguments: ["dismiss", "mutation", "cancel", "selection"])
    func delayedReadCannotResurrectInvalidatedMap(reason: String) async throws {
        let (store, rec, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MapReadGate()
        let controller = ConfirmedProjectMapController(read: { selection in
            let captured = try await store.confirmedProjectMap(recordingID: selection.recordingID,
                canonicalID: selection.canonicalID, expectedHost: selection.expectedHost)
            await gate.wait(); return captured
        }, watch: { await store.observeConfirmedProjectMapChanges(recordingID: $0.recordingID) })
        controller.residentHostAvailabilityChanged(true)
        let task = Task { await controller.select(selection) }
        #expect(await settle { await gate.entered })
        switch reason {
        case "mutation":
            var changed = rec; changed.transcriptText = "Canceled while reading."
            _ = try await store.upsert(changed)
            #expect(await settle { controller.state == .invalidated })
        case "cancel":
            task.cancel()
            #expect(await settle { controller.state == .invalidated })
        case "selection": controller.selectionDidChange()
        default: controller.dismiss(presentationID: controller.presentationID)
        }
        await gate.release(); await task.value
        #expect(controller.snapshot == nil)
        #expect(controller.state == (reason == "dismiss" ? .idle : .invalidated))
    }
    @Test func oldPresentationDismissalCannotClearNewSelection() async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ConfirmedProjectMapController(store: store, externalChanges: NotificationCenter())
        controller.residentHostAvailabilityChanged(true)
        await controller.select(selection)
        let oldPresentation = controller.presentationID
        let other = try await store.upsert(Recording(wavPath: root.appendingPathComponent("other-unused.wav").path,
            startedAt: Date(), transcriptText: "A separate synthetic recording."))
        let nextSelection = ConfirmedProjectMapSelection(recordingID: other.id!, canonicalID: other.canonicalID,
            expectedHost: selection.expectedHost)
        await controller.select(nextSelection)
        let currentPresentation = controller.presentationID
        #expect(oldPresentation != currentPresentation)
        #expect(!controller.ownsPresentation(oldPresentation))
        #expect(controller.ownsPresentation(currentPresentation))
        controller.dismiss(presentationID: oldPresentation)
        #expect(controller.state == .ready)
        #expect(controller.snapshot != nil)
        controller.dismiss(presentationID: currentPresentation)
        #expect(controller.state == .idle)
        #expect(controller.snapshot == nil)
        #expect(!controller.ownsPresentation(currentPresentation))
    }
    @Test func queuedOldSelectionCannotReplaceCurrentPresentation() async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = MapLoadCounter()
        let controller = ConfirmedProjectMapController(read: { selected in
            await counter.didRead()
            return try await store.confirmedProjectMap(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, expectedHost: selected.expectedHost)
        }, watch: { selected in
            await counter.didWatch()
            return await store.observeConfirmedProjectMapChanges(recordingID: selected.recordingID)
        })
        controller.residentHostAvailabilityChanged(true)
        let old = controller.prepare(selection)
        let current = controller.prepare(selection)
        #expect(controller.ownsPresentation(current.presentationID))
        await controller.load(old)
        #expect(controller.state == .loading)
        #expect(controller.ownsPresentation(current.presentationID))
        #expect(await counter.reads == 0)
        #expect(await counter.watches == 0)
        await controller.load(current)
        #expect(controller.state == .ready)
        await controller.load(old)
        await controller.load(current) // one-shot ticket must not install another observer
        #expect(controller.state == .ready)
        #expect(controller.snapshot != nil)
        #expect(await counter.reads == 1)
        #expect(await counter.watches == 1)
        #expect(controller.ownsPresentation(current.presentationID))
    }
    @Test func dismissedPreparedSelectionNeverLoads() async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = MapLoadCounter()
        let controller = ConfirmedProjectMapController(read: { selected in
            await counter.didRead()
            return try await store.confirmedProjectMap(recordingID: selected.recordingID,
                canonicalID: selected.canonicalID, expectedHost: selected.expectedHost)
        }, watch: { selected in
            await counter.didWatch()
            return await store.observeConfirmedProjectMapChanges(recordingID: selected.recordingID)
        })
        controller.residentHostAvailabilityChanged(true)
        let prepared = controller.prepare(selection)
        controller.dismiss(presentationID: prepared.presentationID)
        await controller.load(prepared)
        #expect(controller.state == .idle)
        #expect(controller.snapshot == nil)
        #expect(await counter.reads == 0)
        #expect(await counter.watches == 0)
    }
    /// Owned synthetic window only: no activation, capture, or accessibility collection.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARC_MAP_LIFECYCLE_WINDOW_QA"] == "1"))
    func swiftUIPresentationReplacementPreservesNewSelection() async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ConfirmedProjectMapController(store: store, externalChanges: NotificationCenter())
        controller.residentHostAvailabilityChanged(true)
        let first = controller.prepare(selection)
        await controller.load(first)
        #expect(controller.state == .ready)
        var disappearanceCount = 0
        var appearanceCount = 0
        let host = NSHostingView(rootView: AnyView(SelectedConfirmedProjectMapPanel(
            controller: controller, presentationID: first.presentationID)
            .onAppear { appearanceCount += 1 }
            .onDisappear { disappearanceCount += 1 }.id(first.presentationID)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic map lifecycle qualification"
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(await settle { appearanceCount == 1 })

        let other = try await store.upsert(Recording(wavPath: root.appendingPathComponent("next-unused.wav").path,
            startedAt: Date(), title: "Synthetic second recording", transcriptText: "A separate source."))
        let next = controller.prepare(.init(recordingID: other.id!, canonicalID: other.canonicalID,
            expectedHost: selection.expectedHost))
        await controller.load(next)
        host.rootView = AnyView(SelectedConfirmedProjectMapPanel(controller: controller,
            presentationID: next.presentationID)
            .onDisappear { disappearanceCount += 1 }.id(next.presentationID))
        host.layoutSubtreeIfNeeded()
        #expect(await settle { disappearanceCount == 1 })
        #expect(controller.state == .ready)
        #expect(disappearanceCount == 1)
        #expect(controller.snapshot?.recordingID == other.id)
        #expect(controller.ownsPresentation(next.presentationID))

        host.rootView = AnyView(Text("Synthetic presentation dismissed"))
        host.layoutSubtreeIfNeeded()
        #expect(await settle { controller.state == .idle && disappearanceCount == 2 })
        #expect(disappearanceCount == 2)
        #expect(controller.snapshot == nil)
    }
    @Test func observationTerminationHidesMap() async throws {
        let (store, _, _, _, selection, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let lease = ProjectPreviewChangeObservation(changes: stream, cancel: { continuation.finish() })
        let controller = ConfirmedProjectMapController(read: { selection in
            try await store.confirmedProjectMap(recordingID: selection.recordingID,
                canonicalID: selection.canonicalID, expectedHost: selection.expectedHost)
        }, watch: { _ in lease })
        controller.residentHostAvailabilityChanged(true)
        await controller.select(selection)
        #expect(controller.snapshot != nil)
        continuation.finish()
        #expect(await settle { controller.state == .invalidated })
        #expect(controller.snapshot == nil)
    }
}
