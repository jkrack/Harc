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

    func reactivate(_ id: UUID?) throws {
        guard !captureActive else { throw PlaybackError.captureActive }
        guard let id, owner?.id == id else { throw PlaybackError.ownershipLost }
        try activate()
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
        case ownershipLost
        var errorDescription: String? {
            switch self {
            case .captureActive: "Playback is paused while recording."
            case .ownershipLost: "Another recording or player took over audio playback."
            }
        }
    }
}
