#if os(macOS) && canImport(Network)
import CryptoKit
import Darwin
import Foundation
import GRPCCore
import HarcClientStore
@testable import HarcClientTransport
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
@testable import HarcIdentity
import HarcProtocol
@testable import HarcRemoteTransport
import HarcStore
import HarcTransfer
@preconcurrency import Network
import Testing

private let pairingLifecycleE2EMarkerURL = URL(
    fileURLWithPath:
        "/tmp/harc-run-pairing-lifecycle-e2e-\(getuid())"
)

// This suite owns a real loopback listener and temporary Keychain certificate.
// Keep it out of the ordinary parallel Swift Testing run: Network.framework's
// listener channel is process-global enough to assert when unrelated transport
// suites tear down concurrently. The dedicated script opts in and filters this
// suite into an isolated process.
@Suite(
    "Pairing lifecycle over pinned gRPC TLS",
    .serialized,
    .enabled(
        if: FileManager.default.fileExists(
            atPath: pairingLifecycleE2EMarkerURL.path
        ),
        "Run scripts/test-pairing-lifecycle.sh"
    )
)
struct PairingLifecycleLoopbackIntegrationTests {
    @Test("pair, authorize, Host-revoke, forget, and same-key re-pair")
    func completeDesktopLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HarcPairingLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingStore = try await RecordingStore.inMemory()
        let libraryID = try await recordingStore.libraryMetadata().libraryID
        let cryptographicStateStore = InMemoryHostCryptographicStateStore()
        let hostState = try await cryptographicStateStore.loadOrCreate(
            libraryID: libraryID
        )
        let now = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1_000)
        let metadata = HarcHostMetadata(
            libraryID: libraryID,
            hostAuthorityID: hostState.tuple.hostAuthorityID,
            hostStateID: hostState.tuple.hostStateID
        )
        let hostStore = try await HarcHostStore.inMemory(
            stagingRoot: root.appendingPathComponent("HostStaging"),
            metadata: metadata,
            highWaterMarkStore: KeychainSecurityRegistryHighWaterMarkStore(
                cryptographicStateStore: cryptographicStateStore,
                tuple: hostState.tuple
            ),
            localOSAuthenticationBoundary:
                AllowingPairingLifecycleLocalAuthenticationBoundary()
        )

        let tlsKey = try HostSecurityP256SigningKey
            .createLegacyKeychainTestFixture(
                applicationTag: Data(
                    "com.harc.tests.pairing-lifecycle.\(UUID())".utf8
                )
            )
        defer { tlsKey.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(
            key: .securityFramework(tlsKey)
        )
        let notBeforeMilliseconds = nowMilliseconds - 60_000
        let notAfterMilliseconds = nowMilliseconds + 3_600_000
        let transportSet = try VerifiedHostTransportSetV1.issue(
            libraryID: libraryID,
            hostAuthorityID: hostState.tuple.hostAuthorityID,
            setEpoch: 1,
            issuedAtUnixMilliseconds: nowMilliseconds,
            entries: [
                try HostTransportEntryV1(
                    tlsSPKISHA256: tlsIdentity.tlsSPKISHA256,
                    notBeforeUnixMilliseconds: notBeforeMilliseconds,
                    notAfterUnixMilliseconds: notAfterMilliseconds
                ),
            ],
            using: hostState.authorityIdentity
        )
        let validatedTransportSet = try HostValidatedTransportSet(
            exactSignedBytes: transportSet.exactSignedBytes,
            objectID: Data(SHA256.hash(data: transportSet.exactSignedBytes)),
            libraryID: libraryID,
            hostAuthorityID: hostState.tuple.hostAuthorityID,
            setEpoch: 1,
            issuedAtUnixMilliseconds: nowMilliseconds,
            entries: [
                try HostValidatedTransportSetEntry(
                    tlsSPKISHA256: tlsIdentity.tlsSPKISHA256,
                    notBeforeUnixMilliseconds: notBeforeMilliseconds,
                    notAfterUnixMilliseconds: notAfterMilliseconds
                ),
            ]
        )
        try await hostStore.prepareTransportSetPublication(
            validatedTransportSet,
            kind: .initial,
            expectedActiveSPKISHA256: tlsIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: now
        )
        let pendingTransport = try #require(
            try await hostStore.transportDatabaseSnapshot().pending
        )
        try await hostStore.applyPendingTransportSetPublication(
            expected: pendingTransport,
            verified: validatedTransportSet,
            at: now
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
            serialNumber: Data([0x50, 0x41, 0x49, 0x52])
        )
        defer {
            HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
                certificateDER: serverIdentity.certificate.certificateDER
            )
        }
        let tlsOptions = try HarcNetworkTLS13Policy.serverOptions(
            identity: serverIdentity.securityIdentity,
            protocol: .grpcHTTP2
        )
        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }

        let capabilityPolicy = try Self.capabilityPolicy()
        let hostInfo = try HarcHostInfoService(
            store: hostStore,
            displayName: "Harc Pairing Lifecycle Host",
            hostAuthorityPublicKey: hostState.authorityIdentity.publicKey,
            protocolBoundary: try HarcHostInfoProtocolAdapterV1(
                capabilityPolicy: capabilityPolicy,
                hostOffer: Self.capabilityOffer()
            )
        )
        let authenticationProtocol = try
            HarcHostAuthenticationProtocolAdapterV1(
                capabilityPolicy: capabilityPolicy
            )
        let pairingService = try HarcPairingClaimService(
            store: hostStore,
            protocolBoundary: authenticationProtocol
        )
        let sessionService = HarcSessionService(
            store: hostStore,
            protocolBoundary: authenticationProtocol
        )
        let approvalService = HarcLocalPairingApprovalService(
            store: hostStore,
            issuer: HarcHostPairingGrantIssuerV1(
                cryptographicStateStore: cryptographicStateStore,
                expectedTuple: hostState.tuple
            )
        )
        let libraryService = HarcHostLibraryService(
            store: recordingStore,
            hostStore: hostStore
        )
        let sourceBindingProvider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0x51, count: 32)
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
            hostInfoApplication: hostInfo,
            pairingApplication: pairingService,
            sessionApplication: sessionService,
            recordingApplication:
                UnavailableRecordingTransferFactoryApplication(),
            recordingSessionAuthenticator: sessionService,
            libraryAdapterForBinding: { binding in
                HarcLibraryGRPCServiceAdapterV1(
                    service: libraryService,
                    sessionService: sessionService,
                    servedIdentityBinding: binding,
                    compatibility: capabilityPolicy.compatibility
                )
            },
            hostAuthorityPublicKey: hostState.authorityIdentity.publicKey,
            capabilityPolicy: capabilityPolicy,
            sourceBindingProvider: sourceBindingProvider
        )
        let runtime = HarcGRPCServerRuntime(
            bootstrapServiceFactory: serviceFactory,
            bindTimeout: .seconds(5),
            gracefulDrainTimeout: .seconds(5),
            hardStopTimeout: .seconds(2)
        )
        try await runtime.start(
            generationID: generationID,
            listenerFactory: listenerFactory
        ) { _ in }

        var connection: HarcPinnedGRPCConnection?
        var relayTunnel: RelayEmulatorTunnel?
        do {
            let port = try #require(listener.port).rawValue
            let trust = try HarcTransportTrustCoordinator(
                pairingExactQRTransportSet: transportSet.exactSignedBytes,
                hostAuthorityPublicKey:
                    hostState.authorityIdentity.publicKey
            )
            let connectionHost: String
            let connectionPort: Int
            if let originText = ProcessInfo.processInfo.environment[
                "HARC_RELAY_EMULATOR_ORIGIN"
            ] {
                let origin = try #require(URL(string: originText))
                let tunnel = try await RelayEmulatorTunnel.open(
                    origin: origin,
                    hostTLSPort: port,
                    recorder: RelayFrameRecorder()
                )
                relayTunnel = tunnel
                connectionHost = tunnel.localHost
                connectionPort = Int(tunnel.localPort)
            } else {
                connectionHost = "127.0.0.1"
                connectionPort = Int(port)
            }
            let openedConnection = try await HarcPinnedGRPCConnection.connect(
                host: connectionHost,
                port: connectionPort,
                serverHostname: "localhost",
                trustCoordinator: trust,
                transportLifetime: relayTunnel
            )
            connection = openedConnection
            let client = HarcBootstrapClient(
                rpc: openedConnection,
                capabilityPolicy: capabilityPolicy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let identityResolution = try await InstallationIdentityManager(
                keyStore: InMemorySoftwareInstallationKeyStore()
            ).resolve(evidence: .cleanInstallation)
            guard case .available(let deviceIdentity, _) = identityResolution
            else {
                Issue.record("Expected an installation identity")
                return
            }

            let first = try await completePairing(
                client: client,
                deviceIdentity: deviceIdentity,
                hostStore: hostStore,
                approvalService: approvalService,
                transportSet: transportSet,
                hostAuthorityPublicKey:
                    hostState.authorityIdentity.publicKey,
                port: port
            )
            #expect(first.presentation.sas.words == first.pending.sasWords)
            #expect(first.issued.claims.scopes == Self.desktopScopes)

            let clientRoot = root.appendingPathComponent(
                "Client",
                isDirectory: true
            )
            let clientStore = try HarcTransferStore(
                rootDirectory: clientRoot,
                installationDeviceID: deviceIdentity.deviceID
            )
            _ = try clientStore.adoptApprovedForegroundPairing(
                first.adoption
            )
            let reopenedClientStore = try HarcTransferStore(
                rootDirectory: clientRoot,
                installationDeviceID: deviceIdentity.deviceID
            )
            let persistedFirst = try #require(
                try reopenedClientStore.activeAdoption()
            )
            let validatedFirst = try HarcPersistedAdoptionValidatorV1
                .validate(
                    persistedFirst,
                    devicePublicKey: deviceIdentity.publicKey
                )
            let negotiatedFirst = try await client.negotiateCapabilities(
                clientOffer: try Self.validatedCapabilityOffer(
                    policy: capabilityPolicy
                ),
                expectation: HarcBootstrapTrustExpectation(
                    adoption: validatedFirst
                )
            )
            let firstSession = try await client.openSession(
                adoption: validatedFirst,
                negotiatedCapabilities: negotiatedFirst.negotiated,
                deviceSigner: deviceIdentity
            )
            let firstAuthorization = try HarcLibraryAuthorization(
                openedSession: firstSession
            )
            let initialSnapshot = try await openedConnection
                .beginLibrarySnapshot(
                    Self.snapshotRequest(),
                    authorization: firstAuthorization
                )
            #expect(initialSnapshot.recordingCount == 0)

            try await Self.atStage("Host revocation") {
                try await hostStore.revokeDevice(
                    deviceIdentity.deviceID,
                    revocationID: UUID(),
                    reasonCode: "user.revoked",
                    exactRevocationBytes: Data("loopback-revocation".utf8)
                )
            }
            let revokedDevice = try #require(
                try await hostStore.pairedDevices().first
            )
            #expect(revokedDevice.status == .revoked)
            let revokedEntry = try #require(
                try await hostStore.deviceRegistryEntry(
                    deviceID: deviceIdentity.deviceID
                )
            )
            #expect(
                revokedEntry.currentGrantEpoch.rawValue
                    == first.issued.claims.grantEpoch.rawValue + 1
            )
            do {
                _ = try await openedConnection.beginLibrarySnapshot(
                    Self.snapshotRequest(),
                    authorization: firstAuthorization
                )
                Issue.record("Expected Host revocation to reject the session")
            } catch let error as RPCError {
                #expect(error.code == .unauthenticated)
            }
            do {
                _ = try await client.openSession(
                    adoption: validatedFirst,
                    negotiatedCapabilities: negotiatedFirst.negotiated,
                    deviceSigner: deviceIdentity
                )
                Issue.record("Expected Host revocation to reject a new session")
            } catch {
                // The Host deliberately returns an indistinguishable dummy
                // challenge for revoked and unknown credentials.
            }

            #expect(try reopenedClientStore.forgetActiveHost())
            #expect(try reopenedClientStore.activeAdoption() == nil)
            let second = try await completePairing(
                client: client,
                deviceIdentity: deviceIdentity,
                hostStore: hostStore,
                approvalService: approvalService,
                transportSet: transportSet,
                hostAuthorityPublicKey:
                    hostState.authorityIdentity.publicKey,
                port: port
            )
            #expect(!second.pending.requiresTransportTrustRepair)
            #expect(
                second.issued.claims.grantID
                    != first.issued.claims.grantID
            )
            #expect(
                second.issued.claims.grantEpoch.rawValue
                    == revokedEntry.currentGrantEpoch.rawValue + 1
            )
            _ = try reopenedClientStore.adoptApprovedForegroundPairing(
                second.adoption
            )
            let validatedSecond = try HarcPersistedAdoptionValidatorV1
                .validate(
                    try #require(
                        try reopenedClientStore.activeAdoption()
                    ),
                    devicePublicKey: deviceIdentity.publicKey
                )
            let negotiatedSecond = try await client.negotiateCapabilities(
                clientOffer: try Self.validatedCapabilityOffer(
                    policy: capabilityPolicy
                ),
                expectation: HarcBootstrapTrustExpectation(
                    adoption: validatedSecond
                )
            )
            let secondSession = try await client.openSession(
                adoption: validatedSecond,
                negotiatedCapabilities: negotiatedSecond.negotiated,
                deviceSigner: deviceIdentity
            )
            _ = try await openedConnection.beginLibrarySnapshot(
                Self.snapshotRequest(),
                authorization: try HarcLibraryAuthorization(
                    openedSession: secondSession
                )
            )
            #expect(
                try await hostStore.deviceRegistryEntry(
                    deviceID: deviceIdentity.deviceID
                )?.status == .active
            )

            try await openedConnection.shutdownGracefully()
            connection = nil
            await runtime.stopAcceptingNewConnections()
            await runtime.finishGracefulShutdown()
            #expect(!(await runtime.isRunning))
        } catch {
            if let connection {
                await connection.shutdownImmediately()
            } else if let relayTunnel {
                await relayTunnel.shutdown()
            }
            await runtime.stopImmediately()
            throw error
        }
    }

    private struct CompletedPairing {
        let presentation: HarcPairingClaimPresentation
        let pending: HostPendingPairingClaim
        let issued: HostPairingIssuedGrant
        let adoption: ValidatedClientAdoptionEvidence
    }

    private func completePairing(
        client: HarcBootstrapClient,
        deviceIdentity: InstallationSigningIdentity,
        hostStore: HarcHostStore,
        approvalService: HarcLocalPairingApprovalService,
        transportSet: VerifiedHostTransportSetV1,
        hostAuthorityPublicKey: P256X963PublicKey,
        port: UInt16
    ) async throws -> CompletedPairing {
        let nowMilliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
        let expiresMilliseconds = nowMilliseconds + 120_000
        let ticketID = UUID()
        let secret = Data((0 ..< 24).map { _ in UInt8.random(in: 0 ... 255) })
        let ticket = try PairingTicketV1(
            ticketID: ticketID,
            libraryID: transportSet.transportSet.libraryID,
            hostAuthorityID: transportSet.transportSet.hostAuthorityID,
            hostAuthorityPublicKey: hostAuthorityPublicKey,
            verifiedTransportSet: transportSet,
            ticketSecret: secret,
            issuedAtUnixMilliseconds: nowMilliseconds,
            expiresAtUnixMilliseconds: expiresMilliseconds,
            endpoints: [try .dnsHost("localhost", port: port)]
        )
        try await Self.atStage("ticket insertion") {
            try await hostStore.insertPairingTicketPlaceholder(
                try PairingTicketPlaceholder(
                    ticketID: ticketID,
                    ticketSecretBindingSHA256:
                        ticket.ticketSecretBindingSHA256,
                    clientKind: .macClient,
                    issuedAt: Date(
                        timeIntervalSince1970:
                            Double(nowMilliseconds) / 1_000
                    ),
                    expiresAt: Date(
                        timeIntervalSince1970:
                            Double(expiresMilliseconds) / 1_000
                    )
                )
            )
        }
        let expectation = try HarcBootstrapTrustExpectation(
            pairingTicket: ticket
        )
        let verifiedHostInfo = try await Self.atStage(
            "authenticated route verification"
        ) {
            try await client.getHostInfo(expectation: expectation)
        }
        let presentation = try await Self.atStage("claim begin") {
            try await client.beginPairing(
                ticket: ticket,
                deviceSigner: deviceIdentity,
                requestedScopes: Self.desktopScopes,
                deviceLabel: "Loopback Work Mac",
                verifiedHostInfo: verifiedHostInfo
            )
        }
        let pending = try await approvalService.pendingClaim(
            presentation.claimID
        )
        #expect(presentation.sas.digest == pending.sasDigest)
        let issued = try await Self.atStage("local approval") {
            try await approvalService.approve(presentation.claimID)
        }
        let status = try await Self.atStage("approved grant delivery") {
            try await client.getPairingStatus()
        }
        guard case .approved(let adoption, let relay) = status else {
            throw PairingLifecycleLoopbackError.approvalNotDelivered
        }
        #expect(relay == nil)
        return CompletedPairing(
            presentation: presentation,
            pending: pending,
            issued: issued,
            adoption: adoption
        )
    }

    private static let desktopScopes = AuthorizationScope.allCases.sorted()

    private static func capabilityPolicy() throws
        -> HarcCapabilityPolicyV1
    {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
    }

    private static func capabilityOffer()
        -> Harc_V1_CapabilityOfferV1
    {
        var offer = Harc_V1_CapabilityOfferV1()
        offer.protocolMajor = 1
        offer.minimumProtocolMinor = 0
        offer.maximumProtocolMinor = 0
        offer.supportedDescriptorSchemaIds = [
            ChunkDescriptorSchema.v1.rawValue,
        ]
        offer.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.cafALAC),
        ]
        offer.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return offer
    }

    private static func validatedCapabilityOffer(
        policy: HarcCapabilityPolicyV1
    ) throws -> HarcValidatedCapabilityOfferV1 {
        try HarcValidatedCapabilityOfferV1(
            capabilityOffer(),
            policy: policy
        )
    }

    private static func snapshotRequest()
        -> Harc_V1_BeginLibrarySnapshotRequestV1
    {
        var request = Harc_V1_BeginLibrarySnapshotRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.preferredPageSize = 25
        return request
    }

    private static func atStage<Value>(
        _ stage: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            throw PairingLifecycleLoopbackError.stage(
                stage,
                String(reflecting: error)
            )
        }
    }
}

private struct AllowingPairingLifecycleLocalAuthenticationBoundary:
    HostLocalOSAuthenticationBoundary
{
    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeSameKeyReadoption(
        for deviceID: DeviceID
    ) async throws -> Bool { true }
}

private enum PairingLifecycleLoopbackError: Error {
    case approvalNotDelivered
    case stage(String, String)
}
#endif
