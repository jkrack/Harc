#if canImport(Network)
import NIOCore

/// Once a listener is handed to NIOTS, only its channel may cancel it.
/// NIOTS transitions the channel to closed before cancelling NWListener;
/// cancelling NWListener directly violates its state machine's invariant.
actor HarcNIOTSListenerCancellation {
    private var channel: (any Channel)?
    private var isCancelled = false

    func canBeginBinding() -> Bool { !isCancelled }

    func register(_ channel: any Channel) async throws {
        self.channel = channel
        if isCancelled {
            _ = try? await channel.close()
            throw CancellationError()
        }
    }

    func cancel() async {
        isCancelled = true
        if let channel {
            _ = try? await channel.close()
        }
    }
}
#endif
