#if os(macOS) && canImport(Network)
import Foundation
import HarcClientTransport
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
@testable import HarcIdentity
import HarcProtocol
import HarcTransfer
@preconcurrency import Network
import Testing

// This suite owns process-global Keychain material and a real TCP listener.
// Keeping it serialized makes its cleanup and loopback resource use explicit.
@Suite("Pinned gRPC TLS loopback", .serialized)
struct PinnedGRPCLoopbackIntegrationTests {
    @Test("QR trust authenticates exact host info bytes over a real TLS 1.3 channel")
    func getHostInfoOverPinnedTLS13Loopback() async throws {
        let authority = SoftwareP256SigningKey()
        let libraryID = LibraryID.random()
        let nowSeconds = floor(Date().timeIntervalSince1970)
        let nowMilliseconds = UInt64(nowSeconds * 1_000)
        let notBeforeMilliseconds = nowMilliseconds - 60_000
        let notAfterMilliseconds = nowMilliseconds + 3_600_000

        let key = try HostSecurityP256SigningKey
            .createLegacyKeychainTestFixture(
                applicationTag: Data(
                    "com.harc.tests.grpc-loopback.\(UUID())".utf8
                )
            )
        defer { key.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(
            key: .securityFramework(key)
        )

        let entry = try HostTransportEntryV1(
            tlsSPKISHA256: tlsIdentity.tlsSPKISHA256,
            notBeforeUnixMilliseconds: notBeforeMilliseconds,
            notAfterUnixMilliseconds: notAfterMilliseconds
        )
        let transportSet = try VerifiedHostTransportSetV1.issue(
            libraryID: libraryID,
            hostAuthorityID: authority.publicKey.hostAuthorityID,
            setEpoch: 1,
            issuedAtUnixMilliseconds: nowMilliseconds,
            entries: [entry],
            using: authority
        )
        let certificateRequest = try HostTLSServerCertificateRequest(
            transportSetEntryNotBefore: Date(
                timeIntervalSince1970:
                    Double(notBeforeMilliseconds) / 1_000
            ),
            transportSetEntryNotAfter: Date(
                timeIntervalSince1970:
                    Double(notAfterMilliseconds) / 1_000
            ),
            expectedTLSSPKISHA256: tlsIdentity.tlsSPKISHA256,
            framedSignedTransportSet: transportSet.exactSignedBytes
        )
        let serverIdentity = try tlsIdentity.issueServerIdentity(
            request: certificateRequest,
            serialNumber: Data([0x12, 0x34, 0x56, 0x78])
        )
        defer {
            deleteCertificate(serverIdentity.certificate.certificateDER)
        }

        let tlsOptions = try HarcNetworkTLS13Policy.serverOptions(
            identity: serverIdentity.securityIdentity,
            protocol: .grpcHTTP2
        )
        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        // Port zero asks the kernel for a collision-free ephemeral port while
        // requiredLocalEndpoint prevents this test server leaving loopback.
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }

        let capabilityPolicy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
        let capabilityOffer = try HostInfoCapabilityOffer(
            protocolMajor: 1,
            minimumProtocolMinor: 0,
            maximumProtocolMinor: 0,
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            supportedCanonicalFormats: [.harcV1]
        )
        let sourceRecorder = LoopbackSourceRecorder()
        let application = LoopbackHostInfoApplication(
            response: GetHostInfoResponse(
                protocolMajor: 1,
                protocolMinor: 0,
                displayName: "Harc Loopback Host",
                libraryID: libraryID,
                hostAuthorityID: authority.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: authority.publicKey,
                offers: [capabilityOffer],
                exactSignedTransportSet: transportSet.exactSignedBytes,
                serverTime: Date(timeIntervalSince1970: nowSeconds)
            ),
            sourceRecorder: sourceRecorder
        )
        let sourceBindingProvider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0xA5, count: 32)
        )

        let generationID = UUID()
        let servedIdentityBinding = try HarcGRPCServedIdentityBinding(
            generationID: generationID,
            testTLSSPKISHA256: tlsIdentity.tlsSPKISHA256
        )
        let listenerFactory = HarcGRPCNWListenerFactory(
            servedIdentityBinding: servedIdentityBinding,
            bindingTimeout: .seconds(5),
            unreadyListenerProvider: { listener }
        )
        let serviceFactory = HarcBootstrapGRPCServiceFactoryV1(
            hostInfoApplication: application,
            pairingApplication: LoopbackUnavailablePairingApplication(),
            sessionApplication: LoopbackUnavailableSessionApplication(),
            hostAuthorityPublicKey: authority.publicKey,
            capabilityPolicy: capabilityPolicy,
            sourceBindingProvider: sourceBindingProvider
        )
        let runtime = HarcGRPCServerRuntime(
            bootstrapServiceFactory: serviceFactory,
            bindTimeout: .seconds(5),
            gracefulDrainTimeout: .seconds(5),
            hardStopTimeout: .seconds(2)
        )
        let unexpectedExits = LoopbackUnexpectedExitRecorder()

        try await runtime.start(
            generationID: generationID,
            listenerFactory: listenerFactory
        ) { exitedGenerationID in
            await unexpectedExits.record(exitedGenerationID)
        }

        var connection: HarcPinnedGRPCConnection?
        do {
            let boundPort = try #require(listener.port)
            #expect(boundPort.rawValue > 0)
            #expect(
                try servedIdentityBinding.requireTLSSPKISHA256(
                    generationID: generationID
                ) == tlsIdentity.tlsSPKISHA256
            )

            let trustCoordinator = try HarcTransportTrustCoordinator(
                pairingExactQRTransportSet: transportSet.exactSignedBytes,
                hostAuthorityPublicKey: authority.publicKey,
                clock: { nowMilliseconds }
            )
            let openedConnection = try await HarcPinnedGRPCConnection.connect(
                host: "127.0.0.1",
                port: Int(boundPort.rawValue),
                serverHostname: "localhost",
                trustCoordinator: trustCoordinator
            )
            connection = openedConnection

            var request = Harc_V1_GetHostInfoRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            let response = try await openedConnection.getHostInfo(request)

            let expectedLoopbackSource = try sourceBindingProvider
                .sourceBinding(
                    for: HarcHostRPCPeer(
                        remotePeer: "ipv4:127.0.0.1:1",
                        localPeer: "ipv4:127.0.0.1:1"
                    )
                )

            #expect(response.message.displayName == "Harc Loopback Host")
            #expect(
                await sourceRecorder.values() == [expectedLoopbackSource]
            )
            #expect(try response.message.libraryID.domainValue() == libraryID)
            #expect(
                try response.message.hostAuthorityID.domainValue()
                    == authority.publicKey.hostAuthorityID
            )
            #expect(
                response.message.hostAuthorityPublicKeyX963
                    == authority.publicKey.rawBytes
            )
            #expect(
                response.message.exactSignedTransportSet.framedBytes
                    == transportSet.exactSignedBytes
            )
            #expect(
                response.serverTrust.exactTransportSet
                    == transportSet.exactSignedBytes
            )
            #expect(response.serverTrust.transportSetEpoch == 1)
            #expect(
                response.serverTrust.leaf.exactSignedTransportSet
                    == transportSet.exactSignedBytes
            )
            #expect(
                response.serverTrust.leaf.fullDERSPKISHA256
                    == tlsIdentity.tlsSPKISHA256
            )
            #expect(
                response.serverTrust.leaf.certificateDER
                    == serverIdentity.certificate.certificateDER
            )

            try await openedConnection.shutdownGracefully()
            connection = nil
            await runtime.stopAcceptingNewConnections()
            await runtime.finishGracefulShutdown()

            #expect(!(await runtime.isRunning))
            #expect(await unexpectedExits.values().isEmpty)
        } catch {
            if let connection {
                await connection.shutdownImmediately()
            }
            await runtime.stopImmediately()
            throw error
        }
    }

    private func deleteCertificate(_ der: Data) {
        HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
            certificateDER: der
        )
    }
}

private struct LoopbackHostInfoApplication: HarcHostInfoRPCApplication {
    let response: GetHostInfoResponse
    let sourceRecorder: LoopbackSourceRecorder

    func getHostInfo(
        _ request: GetHostInfoRequest
    ) async throws -> GetHostInfoResponse {
        await sourceRecorder.record(request.source)
        return response
    }

    func negotiateCapabilities(
        _ request: NegotiateHostCapabilitiesRequest
    ) async throws -> NegotiateHostCapabilitiesResponse {
        throw LoopbackApplicationError.unexpectedCapabilityNegotiation
    }
}

private struct LoopbackUnavailablePairingApplication:
    HarcPairingClaimRPCApplication
{
    func beginPairingClaim(
        _ request: BeginHostPairingClaimRequest
    ) async throws -> BeginHostPairingClaimResponse {
        throw LoopbackApplicationError.unexpectedPairing
    }

    func provePairingClaim(
        _ request: ProveHostPairingClaimRequest
    ) async throws -> HostPairingClaimProofResponse {
        throw LoopbackApplicationError.unexpectedPairing
    }

    func pairingStatus(
        claimID: UUID,
        claimantToken: Data
    ) async throws -> HostPairingClaimStatus {
        throw LoopbackApplicationError.unexpectedPairing
    }
}

private struct LoopbackUnavailableSessionApplication: HarcSessionRPCApplication {
    func beginSession(
        _ request: BeginHostSessionRequest
    ) async throws -> BeginHostSessionResponse {
        throw LoopbackApplicationError.unexpectedSession
    }

    func openSession(
        _ request: OpenHostSessionRequest
    ) async throws -> HostOpenedSession {
        throw LoopbackApplicationError.unexpectedSession
    }
}

private enum LoopbackApplicationError: Error {
    case unexpectedCapabilityNegotiation
    case unexpectedPairing
    case unexpectedSession
}

private actor LoopbackUnexpectedExitRecorder {
    private var recordedGenerationIDs: [UUID] = []

    func record(_ generationID: UUID) {
        recordedGenerationIDs.append(generationID)
    }

    func values() -> [UUID] {
        recordedGenerationIDs
    }
}

private actor LoopbackSourceRecorder {
    private var sources: [HostPreauthenticationSource] = []

    func record(_ source: HostPreauthenticationSource) {
        sources.append(source)
    }

    func values() -> [HostPreauthenticationSource] {
        sources
    }
}
#endif
