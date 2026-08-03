#if canImport(Network)
import Foundation
import GRPCNIOTransportHTTP2TransportServices
import HarcHost
import NIOCore
import NIOTransportServices
import Network

package enum HarcGRPCListenerReadinessError: Error, Equatable, Sendable {
    case bindingCancelled
    case bindingTimedOut
    case serverExitedBeforeBinding
}

/// Harc-owned one-shot readiness. This deliberately does not use the custom
/// transport's `listeningAddress`: that promise is non-cancellable and `nil`
/// means both "closed" and "bound without a socket address".
package actor HarcGRPCListenerReadinessSignal {
    private enum State {
        case pending([CheckedContinuation<Void, any Error>])
        case resolved(Result<Void, any Error>)
    }

    private var state: State = .pending([])

    package func waitUntilBound() async throws {
        switch state {
        case .pending:
            try await withCheckedThrowingContinuation { continuation in
                guard case .pending(var waiters) = state else {
                    if case .resolved(let result) = state {
                        continuation.resume(with: result)
                    }
                    return
                }
                waiters.append(continuation)
                state = .pending(waiters)
            }
        case .resolved(let result):
            try result.get()
        }
    }

    @discardableResult
    package func markBound() -> Bool {
        resolve(.success(()))
    }

    @discardableResult
    package func markFailed(_ error: any Error) -> Bool {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, any Error>) -> Bool {
        guard case .pending(let waiters) = state else { return false }
        state = .resolved(result)
        for waiter in waiters {
            waiter.resume(with: result)
        }
        return true
    }
}

private actor HarcGRPCListenerBindingControl {
    private var listener: NWListener?
    private var isCancelled = false

    func register(_ listener: NWListener) -> Bool {
        guard !isCancelled else {
            listener.cancel()
            return false
        }
        self.listener = listener
        return true
    }

    func cancel() {
        isCancelled = true
        listener?.cancel()
    }
}

/// Adapts a process-owned `NWListener` to gRPC Swift's custom HTTP/2 server
/// transport. The host owns listener construction so it can apply Harc's exact
/// TLS policy and attach `_harc._tcp` Bonjour metadata before gRPC starts it.
public struct HarcGRPCNWListenerFactory: HTTP2ServerTransport.ListenerFactory {
    public let eventLoopGroup: any EventLoopGroup

    package let servedIdentityBinding: HarcGRPCServedIdentityBinding
    package let readiness: HarcGRPCListenerReadinessSignal

    private let listenerProvider: @Sendable () async throws -> NWListener
    private let bindingControl: HarcGRPCListenerBindingControl
    private let bindingTimeout: Duration
    private let nioBindingTimeout: TimeAmount
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Only the resident generation controller receives this one-shot lease.
    /// The served-identity binding is populated inside the same lifecycle bind
    /// transform that releases the concrete TLS identity.
    package init(
        lease: HostTransportListenerLease,
        port: NWEndpoint.Port,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        eventLoopGroup: any EventLoopGroup = NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
        bindingTimeout: Duration = .seconds(10)
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.servedIdentityBinding = servedIdentityBinding
        self.readiness = HarcGRPCListenerReadinessSignal()
        self.bindingControl = HarcGRPCListenerBindingControl()
        self.bindingTimeout = bindingTimeout
        self.nioBindingTimeout = Self.nioTimeAmount(bindingTimeout)
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.listenerProvider = {
            let material = try await lease.consume(for: .grpcControl)
            let parameters = try await material.bindServerIdentity(
                for: .grpcControl
            ) { identity in
                try servedIdentityBinding.bindFromListenerIdentity(
                    identity,
                    generationID: lease.generationID
                )
                let tls = try HarcNetworkTLS13Policy.serverOptions(
                    identity: identity.securityIdentity,
                    protocol: .grpcHTTP2
                )
                return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            }
            return try NWListener(using: parameters, on: port)
        }
    }

    /// Compile-only and lifecycle-test seam. Production composition cannot
    /// access this unready path outside the module.
    init(
        eventLoopGroup: any EventLoopGroup = NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
        servedIdentityBinding: HarcGRPCServedIdentityBinding = .init(
            generationID: UUID()
        ),
        readiness: HarcGRPCListenerReadinessSignal = .init(),
        bindingTimeout: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        unreadyListenerProvider: @Sendable @escaping () throws -> NWListener
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.servedIdentityBinding = servedIdentityBinding
        self.readiness = readiness
        self.bindingControl = HarcGRPCListenerBindingControl()
        self.bindingTimeout = bindingTimeout
        self.nioBindingTimeout = Self.nioTimeAmount(bindingTimeout)
        self.sleep = sleep
        self.listenerProvider = { try unreadyListenerProvider() }
    }

    public func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
    ) async throws -> NIOAsyncChannel<
        HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel,
        Never
    > {
        let listener: NWListener
        do {
            listener = try await listenerProvider()
        } catch {
            invalidateServedIdentity()
            await readiness.markFailed(error)
            throw error
        }

        guard await bindingControl.register(listener) else {
            let error = HarcGRPCListenerReadinessError.bindingCancelled
            invalidateServedIdentity()
            await readiness.markFailed(error)
            throw error
        }

        let readiness = self.readiness
        let bindingControl = self.bindingControl
        let binding = servedIdentityBinding
        let generationID = binding.generationID
        let timeoutTask = Task {
            do {
                try await sleep(bindingTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = try? binding.invalidate(generationID: generationID)
            await bindingControl.cancel()
            await readiness.markFailed(
                HarcGRPCListenerReadinessError.bindingTimedOut
            )
        }
        defer { timeoutTask.cancel() }

        do {
            let channel = try await NIOTSListenerBootstrap(group: eventLoopGroup)
                .bindTimeout(nioBindingTimeout)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    listenerConfigurator.configure(channel: channel)
                }
                .withNWListener(listener) { channel in
                    connectionConfigurator.configure(
                        channel: channel,
                        tls: .configured(requireALPN: true)
                    )
                }

            guard await readiness.markBound() else {
                try? await channel.channel.close()
                try await readiness.waitUntilBound()
                throw HarcGRPCListenerReadinessError.bindingCancelled
            }
            return channel
        } catch {
            invalidateServedIdentity()
            await bindingControl.cancel()
            await readiness.markFailed(error)
            throw error
        }
    }

    package func waitUntilBound() async throws {
        try await readiness.waitUntilBound()
    }

    package func reportBound() async throws {
        guard await readiness.markBound() else {
            try await readiness.waitUntilBound()
            return
        }
    }

    package func reportServerExitedBeforeBinding(
        error: (any Error)?
    ) async {
        let reported = error
            ?? HarcGRPCListenerReadinessError.serverExitedBeforeBinding
        await readiness.markFailed(reported)
    }

    package func cancelBinding(
        reason: HarcGRPCListenerReadinessError
    ) async {
        invalidateServedIdentity()
        await bindingControl.cancel()
        await readiness.markFailed(reason)
    }

    package func invalidateServedIdentity() {
        _ = try? servedIdentityBinding.invalidate(
            generationID: servedIdentityBinding.generationID
        )
    }

    private static func nioTimeAmount(_ duration: Duration) -> TimeAmount {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return .nanoseconds(0)
        }
        let maximumSeconds = Int64.max / 1_000_000_000
        guard components.seconds <= maximumSeconds else {
            return .nanoseconds(Int64.max)
        }
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return .nanoseconds(nanoseconds)
    }
}
#endif
