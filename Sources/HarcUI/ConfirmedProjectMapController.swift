import Foundation
import Combine
import HarcDomain
import HarcStore

struct ConfirmedProjectMapSelection: Sendable {
    let recordingID: Int64
    let canonicalID: CanonicalRecordingID
    let expectedHost: LibraryMetadata
}

/// Inactive lifecycle adapter. Explicit selection only; never refreshes, scans,
/// infers, or writes automatically. Future caller must forward Host/selection loss.
@MainActor
final class ConfirmedProjectMapController: ObservableObject {
    enum State: Equatable { case idle, loading, ready, invalidated }
    struct PreparedSelection {
        let presentationID: UUID
        fileprivate let selection: ConfirmedProjectMapSelection
    }
    @Published private(set) var snapshot: ConfirmedProjectMapSnapshot?
    @Published private(set) var state: State = .idle
    private var available = false
    private var generation = UUID()
    private var pendingSelectionID: UUID?
    private var observation: ProjectPreviewChangeObservation?
    private var observationTask: Task<Void, Never>?
    private var externalSubscription: AnyCancellable?
    private let read: @Sendable (ConfirmedProjectMapSelection) async throws -> ConfirmedProjectMapSnapshot
    private let watch: @Sendable (ConfirmedProjectMapSelection) async -> ProjectPreviewChangeObservation

    convenience init(store: RecordingStore, externalChanges: NotificationCenter = DistributedNotificationCenter.default()) {
        self.init(read: { selection in
            try await store.confirmedProjectMap(recordingID: selection.recordingID,
                canonicalID: selection.canonicalID, expectedHost: selection.expectedHost)
        }, watch: { await store.observeConfirmedProjectMapChanges(recordingID: $0.recordingID) }, externalChanges: externalChanges)
    }
    init(read: @escaping @Sendable (ConfirmedProjectMapSelection) async throws -> ConfirmedProjectMapSnapshot,
         watch: @escaping @Sendable (ConfirmedProjectMapSelection) async -> ProjectPreviewChangeObservation,
         externalChanges: NotificationCenter = NotificationCenter()) {
        self.read = read; self.watch = watch
        externalSubscription = externalChanges.publisher(for: Notification.Name(RecordingStore.externalChangeNotification))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.invalidate() } }
    }
    deinit { observationTask?.cancel(); observation?.cancel() }
    func residentHostAvailabilityChanged(_ value: Bool) {
        guard available != value else { return }
        available = value; invalidate()
    }
    func selectionDidChange() { invalidate() }
    /// Capture when presenting a map. A dismissed older view must not clear a
    /// newer selection that happens to share this controller.
    var presentationID: UUID { generation }
    func ownsPresentation(_ presentationID: UUID) -> Bool { presentationID == generation }
    func dismiss(presentationID: UUID) {
        guard presentationID == generation else { return }
        clear(.idle)
    }
    func dismiss() { clear(.idle) }
    func invalidate() { clear(.invalidated) }
    private func clear(_ state: State) {
        generation = UUID(); pendingSelectionID = nil; snapshot = nil; self.state = state
        observationTask?.cancel(); observationTask = nil
        observation?.cancel(); observation = nil
    }
    /// Prepare synchronously before presenting a wrapper or scheduling its task.
    /// A queued task for an older ticket never clears a newer selection.
    func prepare(_ selection: ConfirmedProjectMapSelection) -> PreparedSelection {
        clear(.loading)
        pendingSelectionID = generation
        return PreparedSelection(presentationID: generation, selection: selection)
    }
    func select(_ selection: ConfirmedProjectMapSelection) async {
        await load(prepare(selection))
    }
    func load(_ prepared: PreparedSelection) async {
        let token = prepared.presentationID
        guard token == generation, pendingSelectionID == token else { return }
        pendingSelectionID = nil // consume before suspension; duplicate tasks are inert
        guard available, !Task.isCancelled else { invalidate(); return }
        let selection = prepared.selection
        await withTaskCancellationHandler {
            let registered = await watch(selection)
            guard token == generation, available, !Task.isCancelled else {
                registered.cancel(); if token == generation { invalidate() }; return
            }
            observation = registered
            observationTask = Task { [weak self, registered] in
                for await _ in registered.changes {
                    guard let self, self.generation == token else { return }
                    self.invalidate(); return
                }
                guard let self, self.generation == token else { return }
                self.invalidate() // observation failure/end must hide cached data
            }
            do {
                let captured = try await read(selection)
                guard token == generation, available, !Task.isCancelled else {
                    if token == generation { invalidate() }; return
                }
                snapshot = captured; state = .ready
            } catch { if token == generation { invalidate() } }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.invalidate()
            }
        }
    }
}
