#if canImport(Network)
import Foundation
import HarcHost
import Network

package protocol HarcGRPCServerRuntimeBoundary: Sendable {
    func start(
        generationID: UUID,
        listenerFactory: HarcGRPCNWListenerFactory,
        unexpectedExitHandler: @escaping HarcGRPCUnexpectedExitHandler
    ) async throws

    func stopAcceptingNewConnections() async
    func finishGracefulShutdown() async
    func stopImmediately() async
}

extension HarcGRPCServerRuntime: HarcGRPCServerRuntimeBoundary {}

package protocol HarcBackgroundUploadListenerRuntimeBoundary: Sendable {
    func start(listener: NWListener) async throws
    func stopAcceptingNewConnections() async
    func finishGracefulShutdown() async
    func stopImmediately() async
}

package enum HarcResidentTransportGenerationDriverError:
    Error, Equatable, Sendable
{
    case generationAlreadyActive
    case activationSuperseded
    case terminationReporterGenerationMismatch
}

private actor HarcGenerationLifetime {
    private var activationFinished = false
    private var teardownFinished = false
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []

    func finishActivation() {
        guard !activationFinished else { return }
        activationFinished = true
        for waiter in activationWaiters { waiter.resume() }
        activationWaiters.removeAll()
    }

    func waitForActivationToUnwind() async {
        guard !activationFinished else { return }
        await withCheckedContinuation { activationWaiters.append($0) }
    }

    func finishTeardown() {
        guard !teardownFinished else { return }
        teardownFinished = true
        for waiter in teardownWaiters { waiter.resume() }
        teardownWaiters.removeAll()
    }

    func waitForTeardown() async {
        guard !teardownFinished else { return }
        await withCheckedContinuation { teardownWaiters.append($0) }
    }
}

/// Coordinates readiness and teardown of the three resident pieces that make
/// one advertised generation. Bonjour is armed first, the upload listener is
/// made ready, and then the real gRPC listener is started with its service
/// attached. Withdrawal always precedes concurrent admission stop.
package actor HarcResidentTransportGenerationDriver:
    HarcTransportGenerationDriver
{
    private enum Phase: Equatable, Sendable {
        case activating
        case active
        case drainingActivation
        case drainingActive
    }

    private struct CurrentGeneration: Sendable {
        let id: UUID
        let lifetime: HarcGenerationLifetime
        let terminationReporter: HostTransportGenerationTerminationReporter
        var phase: Phase
    }

    private let grpcRuntime: any HarcGRPCServerRuntimeBoundary
    private let uploadRuntime: any HarcBackgroundUploadListenerRuntimeBoundary
    private let publisher: any HarcBonjourGenerationPublisherBoundary
    private var current: CurrentGeneration?

    package init(
        grpcRuntime: any HarcGRPCServerRuntimeBoundary,
        uploadRuntime: any HarcBackgroundUploadListenerRuntimeBoundary,
        publisher: any HarcBonjourGenerationPublisherBoundary =
            HarcNWListenerBonjourGenerationPublisher()
    ) {
        self.grpcRuntime = grpcRuntime
        self.uploadRuntime = uploadRuntime
        self.publisher = publisher
    }

    package func activateGeneration(
        id: UUID,
        grpcFactory: HarcGRPCNWListenerFactory,
        uploadListener: NWListener,
        terminationReporter: HostTransportGenerationTerminationReporter
    ) async throws {
        guard terminationReporter.generationID == id else {
            throw HarcResidentTransportGenerationDriverError
                .terminationReporterGenerationMismatch
        }
        guard current == nil else {
            throw HarcResidentTransportGenerationDriverError
                .generationAlreadyActive
        }
        let lifetime = HarcGenerationLifetime()
        current = CurrentGeneration(
            id: id,
            lifetime: lifetime,
            terminationReporter: terminationReporter,
            phase: .activating
        )

        do {
            try await publisher.prepareAdvertisement(
                forGenerationID: id,
                listenerFactory: grpcFactory
            )
            try requireActivation(id)
            try await uploadRuntime.start(listener: uploadListener)
            try requireActivation(id)
            try await grpcRuntime.start(
                generationID: id,
                listenerFactory: grpcFactory
            ) { [weak self] failedID in
                await self?.grpcExitedUnexpectedly(generationID: failedID)
            }
            try requireActivation(id)

            await lifetime.finishActivation()
            try requireActivation(id)
            current?.phase = .active
        } catch {
            let ownsCleanup = claimActivationFailureCleanup(id: id)
            if ownsCleanup {
                await stopComponentsImmediately(generationID: id)
            }
            await lifetime.finishActivation()
            if ownsCleanup {
                clearGenerationIfCurrent(id)
                await lifetime.finishTeardown()
            }
            throw error
        }
    }

    package func withdrawAdvertisementAndDrainGeneration() async throws {
        guard var generation = current else { return }
        switch generation.phase {
        case .drainingActivation, .drainingActive:
            await generation.lifetime.waitForTeardown()
            return
        case .activating:
            generation.phase = .drainingActivation
        case .active:
            generation.phase = .drainingActive
        }
        current = generation

        await publisher.withdrawAdvertisement(forGenerationID: generation.id)
        await stopAdmissionConcurrently()
        await finishGracefulShutdownConcurrently()
        if generation.phase == .drainingActivation {
            await generation.lifetime.waitForActivationToUnwind()
            // A listener start suspended across the first admission stop can
            // return afterward. Reassert hard stop only after activation has
            // fully unwound so no late component survives the generation.
            await stopComponentsImmediately(generationID: generation.id)
        }
        clearGenerationIfCurrent(generation.id)
        await generation.lifetime.finishTeardown()
    }

    package func stopGenerationImmediately() async {
        guard var generation = current else { return }
        switch generation.phase {
        case .drainingActivation, .drainingActive:
            await generation.lifetime.waitForTeardown()
            return
        case .activating:
            generation.phase = .drainingActivation
        case .active:
            generation.phase = .drainingActive
        }
        current = generation

        await stopComponentsImmediately(generationID: generation.id)
        if generation.phase == .drainingActivation {
            await generation.lifetime.waitForActivationToUnwind()
            await stopComponentsImmediately(generationID: generation.id)
        }
        clearGenerationIfCurrent(generation.id)
        await generation.lifetime.finishTeardown()
    }

    package var activeGenerationID: UUID? {
        guard let current, current.phase == .active else { return nil }
        return current.id
    }

    package var generationIDBeingTornDown: UUID? {
        guard let current else { return nil }
        switch current.phase {
        case .drainingActivation, .drainingActive:
            return current.id
        case .activating, .active:
            return nil
        }
    }

    private func grpcExitedUnexpectedly(generationID: UUID) async {
        guard var generation = current,
              generation.id == generationID else { return }
        switch generation.phase {
        case .drainingActivation, .drainingActive:
            return
        case .activating:
            generation.phase = .drainingActivation
        case .active:
            generation.phase = .drainingActive
        }
        current = generation

        await stopComponentsImmediately(generationID: generationID)
        if generation.phase == .drainingActivation {
            await generation.lifetime.waitForActivationToUnwind()
            await stopComponentsImmediately(generationID: generationID)
        }
        clearGenerationIfCurrent(generationID)
        // Release any driver teardown waiters before entering the lifecycle
        // reporter. It may need HostTransportLifecycle's operation gate,
        // whose current operation can itself be awaiting this teardown.
        await generation.lifetime.finishTeardown()
        await generation.terminationReporter.reportUnexpectedTermination()
    }

    private func requireActivation(_ id: UUID) throws {
        guard let current,
              current.id == id,
              current.phase == .activating else {
            throw HarcResidentTransportGenerationDriverError
                .activationSuperseded
        }
    }

    private func claimActivationFailureCleanup(id: UUID) -> Bool {
        guard var generation = current, generation.id == id else { return false }
        switch generation.phase {
        case .activating:
            generation.phase = .drainingActivation
            current = generation
            return true
        case .drainingActivation, .drainingActive, .active:
            return false
        }
    }

    private func clearGenerationIfCurrent(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }

    private func stopAdmissionConcurrently() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.grpcRuntime.stopAcceptingNewConnections() }
            group.addTask { await self.uploadRuntime.stopAcceptingNewConnections() }
        }
    }

    private func finishGracefulShutdownConcurrently() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.grpcRuntime.finishGracefulShutdown() }
            group.addTask { await self.uploadRuntime.finishGracefulShutdown() }
        }
    }

    private func stopComponentsImmediately(generationID: UUID) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.publisher.withdrawAdvertisement(
                    forGenerationID: generationID
                )
            }
            group.addTask { await self.uploadRuntime.stopImmediately() }
            group.addTask { await self.grpcRuntime.stopImmediately() }
        }
    }
}
#endif
