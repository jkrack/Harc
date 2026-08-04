import Foundation
import HarcDomain
import HarcStore

/// Connects receipt publication to the app's daemon-backed processing worker.
///
/// The durable queue is the canonical `recordings` row, which is committed as
/// `pending` before HarcHost calls this scheduler. `schedule` revalidates the
/// complete artifact binding and then only wakes the worker. On launch the app
/// scans `RecordingStore.hostProcessingBacklog()`, so a crash at any point is
/// recovered without maintaining a second queue.
public actor HarcCanonicalLibraryProcessingScheduler:
    HostReceiptDurableProcessingScheduling
{
    public typealias WakeHandler = @Sendable (
        HostDurableProcessingRequest
    ) async -> Void

    private let store: RecordingStore
    private let wakeHandler: WakeHandler

    public init(
        store: RecordingStore,
        wakeHandler: @escaping WakeHandler
    ) {
        self.store = store
        self.wakeHandler = wakeHandler
    }

    public func schedule(_ request: HostDurableProcessingRequest) async throws {
        guard let recording = try await store.fetch(
            canonicalID: request.canonicalRecordingID
        ), recording.deletedAt == nil,
           recording.originID != nil,
           recording.wavPath == request.canonicalWAVURL.path,
           recording.canonicalPCMHash == request.canonicalPCMHash,
           recording.canonicalPCMFrames == request.canonicalPCMFrames,
           recording.id != nil
        else {
            throw HarcHostError.canonicalArtifactIdentityMismatch
        }

        try request.artifactIdentity.validatePathBinding(
            at: request.canonicalWAVURL
        )

        guard recording.processing.state != .ready else { return }
        await wakeHandler(request)
    }
}
