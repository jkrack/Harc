import Foundation

/// Main-actor ownership of the shared session used by playback surfaces.
/// Revocation clears ownership before stopping a player, so stale row teardown
/// and completion callbacks cannot deactivate a newer player or capture.
@MainActor
final class HarcMobilePlaybackSession {
    private let activate: () throws -> Void
    private let deactivate: () -> Void
    private var owner: (id: UUID, revoke: () -> Void)?
    private var captureActive = false
    private(set) var captureGeneration: UInt64 = 0

    init(activate: @escaping () throws -> Void, deactivate: @escaping () -> Void) {
        self.activate = activate
        self.deactivate = deactivate
    }

    func acquire(onRevoked: @escaping () -> Void) throws -> UUID {
        guard !captureActive else { throw PlaybackError.captureActive }
        try activate()
        revokeCurrent(deactivating: false)
        let id = UUID()
        owner = (id, onRevoked)
        return id
    }

    func release(_ id: UUID) {
        guard owner?.id == id else { return }
        owner = nil
        deactivate()
    }

    func beginCapture() {
        captureActive = true
        captureGeneration &+= 1
        revokeCurrent(deactivating: true)
    }

    func endCapture() { captureActive = false }

    private func revokeCurrent(deactivating: Bool) {
        guard let previous = owner else { return }
        owner = nil
        previous.revoke()
        if deactivating { deactivate() }
    }

    private enum PlaybackError: LocalizedError {
        case captureActive
        var errorDescription: String? { "Playback is paused while recording." }
    }
}
