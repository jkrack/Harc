import Foundation
import Combine
import HarcDomain
import HarcStore

struct ProjectPreviewSelection: Sendable {
    let recordingID: Int64
    let canonicalID: CanonicalRecordingID
    let projectID: UUID
    let projectVersion: UUID
    let expectedHost: LibraryMetadata
}
struct ProjectPreviewResponseToken: Equatable, Sendable { fileprivate let id: UUID }

/// No app caller, model invocation, confirmation or Store mutation. The future
/// UI must explicitly select/dismiss and forward resident Host availability.
/// Real Store changes are observed while this selected-source session is open.
@MainActor
final class SelectedProjectPreviewController: ObservableObject {
    enum State: Equatable { case idle, preparing, awaitingResponse, processingResponse, showingPreview, abstained, invalidated }
    @Published private(set) var preview: UntrustedProjectLinkPreview?
    @Published private(set) var state: State = .idle
    private var residentHostAvailable = false
    private var generation = UUID()
    private var session: UntrustedProjectPreviewSession?
    private var snapshot: ProjectEvidenceSnapshot?
    private var ticket: ProjectPreviewTicket?
    private var responseToken: ProjectPreviewResponseToken?
    private var observation: ProjectPreviewChangeObservation?
    private var observationTask: Task<Void, Never>?
    private var externalChangeSubscription: AnyCancellable?
    private let readSnapshot: @Sendable (ProjectPreviewSelection) async throws -> ProjectEvidenceSnapshot
    private let current: @Sendable (ProjectEvidenceSnapshot) async throws -> Bool
    private let watch: @Sendable (ProjectPreviewSelection) async -> ProjectPreviewChangeObservation

    convenience init(store: RecordingStore, externalChanges: NotificationCenter = DistributedNotificationCenter.default()) {
        self.init(readSnapshot: { selection in
            try await store.projectEvidenceSnapshot(recordingID: selection.recordingID, canonicalID: selection.canonicalID,
                projectID: selection.projectID, projectVersion: selection.projectVersion, expectedHost: selection.expectedHost)
        }, current: { try await store.projectPreviewIsCurrent($0) }, watch: {
            await store.observeProjectPreviewChanges(recordingID: $0.recordingID, projectID: $0.projectID)
        }, externalChanges: externalChanges)
    }

    // Injection seam for suspended-read tests; no model callback exists.
    init(readSnapshot: @escaping @Sendable (ProjectPreviewSelection) async throws -> ProjectEvidenceSnapshot,
         current: @escaping @Sendable (ProjectEvidenceSnapshot) async throws -> Bool,
         watch: @escaping @Sendable (ProjectPreviewSelection) async -> ProjectPreviewChangeObservation,
         externalChanges: NotificationCenter = NotificationCenter()) {
        self.readSnapshot = readSnapshot; self.current = current; self.watch = watch
        externalChangeSubscription = externalChanges.publisher(for: Notification.Name(RecordingStore.externalChangeNotification))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.invalidate() } }
    }

    deinit { observationTask?.cancel(); observation?.cancel() }

    func residentHostAvailabilityChanged(_ available: Bool) {
        guard available != residentHostAvailable else { return }
        residentHostAvailable = available
        invalidate() // Changing true also requires a new explicit selection.
    }
    func selectionDidChange() { invalidate() }
    func dismiss() { clear(state: .idle) }
    func invalidate() { clear(state: .invalidated) }

    private func clear(state: State) {
        generation = UUID()
        preview = nil; snapshot = nil; ticket = nil; responseToken = nil
        self.state = state
        observationTask?.cancel(); observationTask = nil
        observation?.cancel(); observation = nil
        let old = session; session = nil
        // Each generation owns its own session, so delayed disposal cannot
        // invalidate a newer session created while this actor call is queued.
        if let old { Task { await old.dismiss() } }
    }

    func begin(_ selection: ProjectPreviewSelection) async -> ProjectPreviewResponseToken? {
        clear(state: .preparing)
        guard residentHostAvailable, !Task.isCancelled else { invalidate(); return nil }
        let version = generation
        return await withTaskCancellationHandler {
            await prepare(selection, version: version)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == version else { return }
                self.invalidate()
            }
        }
    }

    private func prepare(_ selection: ProjectPreviewSelection, version: UUID) async -> ProjectPreviewResponseToken? {
        let ownedSession = UntrustedProjectPreviewSession()
        session = ownedSession
        // Registration completes before the first snapshot read.
        let registered = await watch(selection)
        guard generation == version, residentHostAvailable, !Task.isCancelled else { registered.cancel(); if generation == version { invalidate() }; return nil }
        observation = registered
        observationTask = Task { [weak self, registered] in
            for await _ in registered.changes {
                guard let self, self.generation == version else { return }
                self.invalidate(); return
            }
            // Error, explicit cancellation or normal termination is never a
            // reason to leave an unobserved preview visible.
            guard let self, self.generation == version else { return }
            self.invalidate()
        }
        do {
            let captured = try await readSnapshot(selection)
            guard generation == version, residentHostAvailable, !Task.isCancelled else { if generation == version { invalidate() }; return nil }
            let ownedTicket = await ownedSession.begin(snapshot: captured)
            guard generation == version, residentHostAvailable, !Task.isCancelled else { await ownedSession.dismiss(); if generation == version { invalidate() }; return nil }
            snapshot = captured; ticket = ownedTicket
            let token = ProjectPreviewResponseToken(id: UUID())
            responseToken = token; state = .awaitingResponse
            return token
        } catch {
            if generation == version { invalidate() }
            return nil
        }
    }

    func receive(rawResponse: String, unverifiedModelLabel: String, token: ProjectPreviewResponseToken) async {
        guard residentHostAvailable, state == .awaitingResponse, token == responseToken,
              let ownedSession = session, let captured = snapshot, let ownedTicket = ticket else { return }
        // Claim this response synchronously before the first suspension. A
        // concurrent replay must not consume the actor ticket twice and clear
        // the legitimate in-flight preview on the second completion's error.
        responseToken = nil
        state = .processingResponse
        let version = generation
        await withTaskCancellationHandler {
            await finish(rawResponse: rawResponse, unverifiedModelLabel: unverifiedModelLabel,
                ownedSession: ownedSession, captured: captured, ownedTicket: ownedTicket, version: version)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == version else { return }
                self.invalidate()
            }
        }
    }

    private func finish(rawResponse: String, unverifiedModelLabel: String,
                        ownedSession: UntrustedProjectPreviewSession, captured: ProjectEvidenceSnapshot,
                        ownedTicket: ProjectPreviewTicket, version: UUID) async {
        do {
            guard try await current(captured), generation == version, residentHostAvailable, !Task.isCancelled else {
                if generation == version { invalidate() }; return
            }
            let outcome = try await ownedSession.finish(rawResponse: rawResponse, unverifiedModelLabel: unverifiedModelLabel, ticket: ownedTicket)
            guard generation == version, residentHostAvailable, !Task.isCancelled else { if generation == version { invalidate() }; return }
            switch outcome {
            case .abstained: clear(state: .abstained)
            case .suggestionReady:
                let value = await ownedSession.preview(for: captured.previewSelectionKey)
                guard generation == version, residentHostAvailable, !Task.isCancelled else { if generation == version { invalidate() }; return }
                guard try await current(captured), generation == version, residentHostAvailable, !Task.isCancelled else {
                    if generation == version { invalidate() }; return
                }
                preview = value; state = .showingPreview
            }
        } catch { if generation == version { invalidate() } }
    }
}
