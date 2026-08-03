#if canImport(Network)
import Foundation
import GRPCNIOTransportHTTP2TransportServices
import HarcHost
import HarcProtocol
import NIOCore
import NIOTransportServices
import Network

/// The concrete server composition implements this narrow boundary around its
/// running gRPC server, upload pipeline, and Bonjour publisher. `activate` must
/// bind/start both supplied listeners and publish discovery only afterward.
package protocol HarcTransportGenerationDriver: Sendable {
    func withdrawAdvertisementAndDrainGeneration() async throws

    func activateGeneration(
        id: UUID,
        grpcFactory: HarcGRPCNWListenerFactory,
        uploadListener: NWListener,
        terminationReporter: HostTransportGenerationTerminationReporter
    ) async throws

    func stopGenerationImmediately() async
}

/// Bridges the authority-owned generation state machine to the two concrete
/// Network.framework listeners. It never exposes a raw identity or reusable
/// readiness snapshot.
package enum HarcTransportGenerationControllerError: Error, Equatable, Sendable {
    case bonjourUploadPortMismatch
}

package actor HarcTransportGenerationController: HostTransportGenerationBoundary {
    private let controlPort: NWEndpoint.Port
    private let uploadPort: NWEndpoint.Port
    private let bonjourHints: HarcBonjourServiceHintsV1
    private let eventLoopGroup: any EventLoopGroup
    private let driver: any HarcTransportGenerationDriver

    package init(
        controlPort: NWEndpoint.Port,
        uploadPort: NWEndpoint.Port,
        bonjourHints: HarcBonjourServiceHintsV1,
        eventLoopGroup: any EventLoopGroup =
            NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
        driver: any HarcTransportGenerationDriver
    ) throws {
        if let uploadPortHint = bonjourHints.uploadPortHint,
           uploadPortHint != uploadPort.rawValue {
            throw HarcTransportGenerationControllerError
                .bonjourUploadPortMismatch
        }
        self.controlPort = controlPort
        self.uploadPort = uploadPort
        self.bonjourHints = bonjourHints
        self.eventLoopGroup = eventLoopGroup
        self.driver = driver
    }

    package func withdrawAdvertisementAndDrainGeneration() async throws {
        try await driver.withdrawAdvertisementAndDrainGeneration()
    }

    package func activateGeneration(
        _ generation: HostTransportServingGeneration
    ) async throws {
        let servedIdentityBinding = HarcGRPCServedIdentityBinding(
            generationID: generation.generationID
        )
        let grpcFactory = HarcGRPCNWListenerFactory(
            lease: generation.grpcControl,
            port: controlPort,
            bonjourHints: bonjourHints,
            servedIdentityBinding: servedIdentityBinding,
            eventLoopGroup: eventLoopGroup
        )
        let uploadListener = try await HarcHTTP11UploadTransportAPI.makeListener(
            lease: generation.backgroundUpload,
            port: uploadPort
        )
        try await activateConstructedGeneration(
            id: generation.generationID,
            grpcFactory: grpcFactory,
            uploadListener: uploadListener,
            terminationReporter: generation.terminationReporter
        )
    }

    /// Testable post-construction seam. Activation rollback belongs to the
    /// driver and is generation-scoped. The controller must never issue an
    /// unqualified stop after a rejected overlapping activation because that
    /// could tear down an unrelated valid generation.
    package func activateConstructedGeneration(
        id: UUID,
        grpcFactory: HarcGRPCNWListenerFactory,
        uploadListener: NWListener,
        terminationReporter: HostTransportGenerationTerminationReporter
    ) async throws {
        try await driver.activateGeneration(
            id: id,
            grpcFactory: grpcFactory,
            uploadListener: uploadListener,
            terminationReporter: terminationReporter
        )
    }

    package func stopGenerationImmediately() async {
        await driver.stopGenerationImmediately()
    }
}
#endif
