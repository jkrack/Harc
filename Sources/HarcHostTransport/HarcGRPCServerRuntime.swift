#if canImport(Network)
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices

package enum HarcGRPCServerRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case servedIdentityGenerationMismatch
}

package typealias HarcGRPCUnexpectedExitHandler = @Sendable (
    _ generationID: UUID
) async -> Void

package protocol HarcGRPCServerProcessBoundary: Sendable {
    func serve() async throws
    func beginGracefulShutdown()
}

private final class HarcConcreteGRPCServerProcess:
    HarcGRPCServerProcessBoundary, Sendable
{
    private typealias Transport =
        HTTP2ServerTransport.Custom<HarcGRPCNWListenerFactory>
    private typealias Server = GRPCServer<Transport>

    private let server: Server

    init(
        listenerFactory: HarcGRPCNWListenerFactory,
        services: [any RegistrableRPCService],
        sourceBindingProvider: HarcHostRPCSourceBindingProvider
    ) {
        let transport = Transport(
            listenerFactory: listenerFactory,
            config: HarcGRPCServerRuntime.bootstrapTransportConfiguration(
                sourceBindingProvider: sourceBindingProvider
            )
        )
        self.server = Server(transport: transport, services: services)
    }

    func serve() async throws {
        try await server.serve()
    }

    func beginGracefulShutdown() {
        server.beginGracefulShutdown()
    }
}

private actor HarcRuntimeCompletionRace {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

/// Owns one live gRPC server generation over the lifecycle-bound
/// Network.framework listener. Services are constructed per generation from
/// that generation's one-shot served-identity binding; no adapter or binding
/// survives certificate rotation.
package actor HarcGRPCServerRuntime {
    /// The transport decoder accepts at most the frozen audio-message ceiling.
    /// `HarcGRPCRequestPayloadGateHandler`, installed ahead of the gRPC stream
    /// decoder, retains the 1 MiB ceiling for every non-audio method.
    package static let maximumRequestPayloadBytes =
        HarcGRPCRequestPayloadGate.maximumAudioPayloadBytes

    package static func bootstrapTransportConfiguration(
        sourceBindingProvider: HarcHostRPCSourceBindingProvider
    ) -> HTTP2ServerTransport.Custom<HarcGRPCNWListenerFactory>.Config {
        var configuration = HTTP2ServerTransport.Custom<
            HarcGRPCNWListenerFactory
        >.Config.defaults
        // Bootstrap protobufs are never gRPC-compressed. Keeping compression
        // disabled also makes the decoder ceiling identical to the wire payload
        // ceiling instead of permitting a compressed expansion before decode.
        configuration.compression = .defaults
        configuration.rpc = HTTP2ServerTransport.Config.RPC(
            maxRequestPayloadSize: maximumRequestPayloadBytes
        )
        configuration.channelDebuggingCallbacks.onAcceptHTTP2Stream = {
            channel in
            HarcGRPCTransportSourceBridge.initializeStream(
                channel: channel,
                sourceBindingProvider: sourceBindingProvider
            )
        }
        return configuration
    }

    private struct Running: Sendable {
        let runtimeID: UUID
        let generationID: UUID
        let listenerFactory: HarcGRPCNWListenerFactory
        let process: any HarcGRPCServerProcessBoundary
        let task: Task<Void, any Error>
        let unexpectedExitHandler: HarcGRPCUnexpectedExitHandler
    }

    private enum StopKind: Sendable {
        case startupCancellation
        case graceful
        case immediate
    }

    private enum State: Sendable {
        case idle
        case starting(Running)
        case running(Running)
        case stopping(Running, StopKind)
    }

    private let servicesForGeneration: @Sendable (
        HarcGRPCServedIdentityBinding
    ) throws -> [any RegistrableRPCService]
    private let processFactory: @Sendable (
        HarcGRPCNWListenerFactory,
        [any RegistrableRPCService]
    ) -> any HarcGRPCServerProcessBoundary
    private let bindTimeout: Duration
    private let gracefulDrainTimeout: Duration
    private let hardStopTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var state = State.idle

    /// Production initializer. The factory is the sole owner of bootstrap
    /// source authentication and malformed-input cooldown state.
    package init(
        bootstrapServiceFactory: HarcBootstrapGRPCServiceFactoryV1,
        bindTimeout: Duration = .seconds(10),
        gracefulDrainTimeout: Duration = .seconds(10),
        hardStopTimeout: Duration = .seconds(2)
    ) {
        self.servicesForGeneration = { binding in
            bootstrapServiceFactory.makeServices(
                servedIdentityBinding: binding
            ).registrableServices
        }
        self.bindTimeout = bindTimeout
        self.gracefulDrainTimeout = gracefulDrainTimeout
        self.hardStopTimeout = hardStopTimeout
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.processFactory = { listenerFactory, services in
            HarcConcreteGRPCServerProcess(
                listenerFactory: listenerFactory,
                services: services,
                sourceBindingProvider:
                    bootstrapServiceFactory.sourceBindingProvider
            )
        }
    }

    /// Test-only seam for focused transport integration tests.
    init(
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        servicesForGeneration: @escaping @Sendable (
            HarcGRPCServedIdentityBinding,
            HarcHostRPCSourceBindingProvider
        ) throws -> [any RegistrableRPCService],
        bindTimeout: Duration = .seconds(10),
        gracefulDrainTimeout: Duration = .seconds(10),
        hardStopTimeout: Duration = .seconds(2)
    ) {
        self.servicesForGeneration = { binding in
            try servicesForGeneration(binding, sourceBindingProvider)
        }
        self.bindTimeout = bindTimeout
        self.gracefulDrainTimeout = gracefulDrainTimeout
        self.hardStopTimeout = hardStopTimeout
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.processFactory = { listenerFactory, services in
            HarcConcreteGRPCServerProcess(
                listenerFactory: listenerFactory,
                services: services,
                sourceBindingProvider: sourceBindingProvider
            )
        }
    }

    init(
        bindTimeout: Duration = .seconds(10),
        gracefulDrainTimeout: Duration = .seconds(10),
        hardStopTimeout: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        processFactory: @escaping @Sendable (
            HarcGRPCNWListenerFactory,
            [any RegistrableRPCService]
        ) -> any HarcGRPCServerProcessBoundary
    ) {
        self.servicesForGeneration = { _ in [] }
        self.processFactory = processFactory
        self.bindTimeout = bindTimeout
        self.gracefulDrainTimeout = gracefulDrainTimeout
        self.hardStopTimeout = hardStopTimeout
        self.sleep = sleep
    }

    /// Returns only after Harc's own listener signal reports a completed bind.
    /// No gRPC `listeningAddress` future participates in startup readiness.
    package func start(
        generationID: UUID,
        listenerFactory: HarcGRPCNWListenerFactory,
        unexpectedExitHandler: @escaping HarcGRPCUnexpectedExitHandler
    ) async throws {
        guard case .idle = state else {
            throw HarcGRPCServerRuntimeError.alreadyRunning
        }
        guard listenerFactory.servedIdentityBinding.generationID
                == generationID else {
            listenerFactory.invalidateServedIdentity()
            throw HarcGRPCServerRuntimeError.servedIdentityGenerationMismatch
        }

        let services: [any RegistrableRPCService]
        do {
            services = try servicesForGeneration(
                listenerFactory.servedIdentityBinding
            )
        } catch {
            listenerFactory.invalidateServedIdentity()
            throw error
        }
        let process = processFactory(listenerFactory, services)
        let task = Task {
            do {
                try await process.serve()
                await listenerFactory.reportServerExitedBeforeBinding(error: nil)
            } catch {
                await listenerFactory.reportServerExitedBeforeBinding(error: error)
                throw error
            }
        }
        let generation = Running(
            runtimeID: UUID(),
            generationID: generationID,
            listenerFactory: listenerFactory,
            process: process,
            task: task,
            unexpectedExitHandler: unexpectedExitHandler
        )
        state = .starting(generation)
        Task { [weak self] in
            await self?.observeCompletion(of: generation)
        }

        let timeoutTask = Task {
            do {
                try await sleep(bindTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await listenerFactory.cancelBinding(reason: .bindingTimedOut)
            task.cancel()
        }

        do {
            try await withTaskCancellationHandler {
                try await listenerFactory.waitUntilBound()
            } onCancel: {
                task.cancel()
                Task {
                    await listenerFactory.cancelBinding(
                        reason: .bindingCancelled
                    )
                }
            }
            timeoutTask.cancel()
            _ = await timeoutTask.result
            try Task.checkCancellation()
            guard case .starting(let current) = state,
                  current.runtimeID == generation.runtimeID else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            state = .running(generation)
        } catch {
            timeoutTask.cancel()
            _ = await timeoutTask.result
            await listenerFactory.cancelBinding(reason: .bindingCancelled)
            task.cancel()
            let completed = await taskCompletes(
                task,
                before: hardStopTimeout
            )
            clearStartupGeneration(generation.runtimeID, ifCompleted: completed)
            throw error
        }
    }

    /// Stops gRPC admission without waiting for in-flight RPCs. If startup is
    /// still binding, cancellation is used instead of calling gRPC's graceful
    /// API in its `notStarted` state.
    package func stopAcceptingNewConnections() async {
        switch state {
        case .idle, .stopping:
            return
        case .starting(let generation):
            state = .stopping(generation, .startupCancellation)
            await generation.listenerFactory.cancelBinding(
                reason: .bindingCancelled
            )
            generation.task.cancel()
        case .running(let generation):
            state = .stopping(generation, .graceful)
            generation.process.beginGracefulShutdown()
        }
    }

    /// Waits a bounded interval for graceful drain, then escalates to task and
    /// listener cancellation. A still-unwinding process remains in `stopping`,
    /// preventing a replacement generation from overlapping it.
    package func finishGracefulShutdown() async {
        guard case .stopping(let generation, let kind) = state else { return }

        let gracefulCompletion: Bool
        switch kind {
        case .graceful:
            gracefulCompletion = await taskCompletes(
                generation.task,
                before: gracefulDrainTimeout
            )
        case .startupCancellation, .immediate:
            gracefulCompletion = false
        }

        var completed = gracefulCompletion
        if !completed {
            generation.listenerFactory.invalidateServedIdentity()
            generation.task.cancel()
            completed = await taskCompletes(
                generation.task,
                before: hardStopTimeout
            )
        }
        if completed {
            generation.listenerFactory.invalidateServedIdentity()
        }
        clearStoppingGeneration(generation.runtimeID, ifCompleted: completed)
    }

    package func stopImmediately() async {
        let generation: Running
        switch state {
        case .idle:
            return
        case .starting(let value), .running(let value):
            generation = value
            state = .stopping(value, .immediate)
        case .stopping(let value, _):
            generation = value
            state = .stopping(value, .immediate)
        }
        await generation.listenerFactory.cancelBinding(reason: .bindingCancelled)
        generation.task.cancel()
        let completed = await taskCompletes(
            generation.task,
            before: hardStopTimeout
        )
        clearStoppingGeneration(generation.runtimeID, ifCompleted: completed)
    }

    package var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    package var isStopping: Bool {
        if case .stopping = state { return true }
        return false
    }

    private func observeCompletion(of generation: Running) async {
        _ = await generation.task.result
        // Teardown of the process is terminal for this one-shot binding even
        // if another waiter won actor scheduling and already cleared state.
        generation.listenerFactory.invalidateServedIdentity()
        let unexpected: Bool
        switch state {
        case .starting(let current)
            where current.runtimeID == generation.runtimeID:
            state = .idle
            unexpected = false
        case .running(let current)
            where current.runtimeID == generation.runtimeID:
            state = .idle
            unexpected = true
        case .stopping(let current, _)
            where current.runtimeID == generation.runtimeID:
            state = .idle
            unexpected = false
        default:
            return
        }

        if unexpected {
            await generation.unexpectedExitHandler(generation.generationID)
        }
    }

    private func taskCompletes(
        _ task: Task<Void, any Error>,
        before timeout: Duration
    ) async -> Bool {
        let race = HarcRuntimeCompletionRace()
        let completionTask = Task {
            _ = await task.result
            await race.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await race.resolve(false)
        }
        let completed = await race.value()
        timeoutTask.cancel()
        if completed { completionTask.cancel() }
        return completed
    }

    private func clearStartupGeneration(
        _ runtimeID: UUID,
        ifCompleted completed: Bool
    ) {
        guard completed else {
            if case .starting(let current) = state,
               current.runtimeID == runtimeID {
                state = .stopping(current, .immediate)
            }
            return
        }
        switch state {
        case .starting(let current) where current.runtimeID == runtimeID,
             .stopping(let current, _) where current.runtimeID == runtimeID:
            state = .idle
        default:
            break
        }
    }

    private func clearStoppingGeneration(
        _ runtimeID: UUID,
        ifCompleted completed: Bool
    ) {
        guard completed,
              case .stopping(let current, _) = state,
              current.runtimeID == runtimeID else { return }
        state = .idle
    }
}
#endif
