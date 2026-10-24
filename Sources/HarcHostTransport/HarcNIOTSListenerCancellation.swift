#if canImport(Network)
import NIOCore

/// Once a listener is handed to NIOTS, only its channel may cancel it.
/// NIOTS transitions the channel to closed before cancelling NWListener;
/// cancelling NWListener directly violates its state machine's invariant.
actor HarcNIOTSListenerCancellation {
    private var channel: (any Channel)?
    private var isCancelled = false

    func canBeginBinding() -> Bool { !isCancelled }

    func register(_ channel: any Channel) throws {
        self.channel = channel
        if isCancelled {
            channel.close(promise: nil)
            throw CancellationError()
        }
    }

    func cancel() {
        isCancelled = true
        // The runtime owns the bounded completion join. Enqueue NIO's close
        // without waiting here, so an unresponsive event loop cannot hide the
        // runtime's startup or hard-stop deadline.
        channel?.close(promise: nil)
    }
}
#endif
