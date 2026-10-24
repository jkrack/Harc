#if os(macOS) && canImport(Network)
import Foundation
@testable import HarcHostTransport
import HarcTestSupport
import Network
import NIOCore
import NIOTransportServices
import Testing

@Suite("gRPC listener cancellation ownership", .serialized, .processWideSystemResource)
struct GRPCListenerCancellationIntegrationTests {
    @Test("cancellation before channel registration closes a late channel")
    func cancellationBeforeRegistration() async throws {
        let cancellation = HarcNIOTSListenerCancellation()
        await cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            let _: NIOAsyncChannel<Void, Never> = try await NIOTSListenerBootstrap(
                group: NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup
            )
            .serverChannelInitializer { channel in
                channel.eventLoop.makeFutureWithTask {
                    try await cancellation.register(channel)
                }
            }
            .withNWListener(try NWListener(using: .tcp)) { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
        }
    }

    @Test("immediate stop closes the NIO channel before cancelling its listener")
    func immediateStopAfterBind() async throws {
        // Exercise the concrete gRPC process, unlike the runtime state-machine
        // fixtures. No certificate or Keychain material is needed for teardown.
        let source = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0xC1, count: 32)
        )
        let runtime = HarcGRPCServerRuntime(
            sourceBindingProvider: source,
            servicesForGeneration: { _, _ in [] }
        )
        for _ in 0..<20 {
            let generationID = UUID()
            let factory = HarcGRPCNWListenerFactory(
                servedIdentityBinding: .init(generationID: generationID),
                unreadyListenerProvider: {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: "127.0.0.1", port: .any
                    )
                    return try NWListener(using: parameters)
                }
            )
            try await runtime.start(
                generationID: generationID,
                listenerFactory: factory,
                unexpectedExitHandler: { _ in Issue.record("Unexpected server exit") }
            )
            await runtime.stopImmediately()
            #expect(!(await runtime.isRunning))
            #expect(!(await runtime.isStopping))
        }
    }
}
#endif
