#if canImport(Network)
import Foundation
import HarcHost
@testable import HarcHostTransport
import NIOTransportServices
import Network
import Testing

@Suite("Transport generation controller")
struct TransportGenerationControllerTests {
    @Test("rejected activation never issues an unqualified stop")
    func rejectedActivationDoesNotStopUnrelatedGeneration() async throws {
        let driver = RejectingControllerDriver()
        let controller = HarcTransportGenerationController(
            controlPort: 8_443,
            uploadPort: 8_444,
            eventLoopGroup: NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
            driver: driver
        )
        let generationID = UUID()
        let factory = HarcGRPCNWListenerFactory(
            servedIdentityBinding: HarcGRPCServedIdentityBinding(
                generationID: generationID
            ),
            unreadyListenerProvider: { try NWListener(using: .tcp) }
        )

        await #expect(throws: ControllerTestError.activationRejected) {
            try await controller.activateConstructedGeneration(
                id: generationID,
                grpcFactory: factory,
                uploadListener: try NWListener(using: .tcp),
                terminationReporter:
                    HostTransportGenerationTerminationReporter(
                        generationID: generationID,
                        report: {}
                    )
            )
        }

        #expect(await driver.stopCount == 0)
        #expect(await driver.activeGenerationID != nil)
    }
}

private enum ControllerTestError: Error, Equatable {
    case activationRejected
}

private actor RejectingControllerDriver: HarcTransportGenerationDriver {
    private(set) var stopCount = 0
    private(set) var activeGenerationID: UUID? = UUID()

    func withdrawAdvertisementAndDrainGeneration() async throws {
        activeGenerationID = nil
    }

    func activateGeneration(
        id _: UUID,
        grpcFactory _: HarcGRPCNWListenerFactory,
        uploadListener _: NWListener,
        terminationReporter _: HostTransportGenerationTerminationReporter
    ) async throws {
        throw ControllerTestError.activationRejected
    }

    func stopGenerationImmediately() {
        stopCount += 1
        activeGenerationID = nil
    }
}
#endif
