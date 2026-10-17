#if os(macOS) && canImport(Network)
import CryptoKit
import Foundation
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

// This suite owns process-global Keychain material and a real TCP listener.
// Keeping it serialized makes its cleanup and loopback resource use explicit.
@Suite("Pinned gRPC TLS loopback", .serialized)
struct PinnedGRPCLoopbackIntegrationTests {
    @Test("Pinned TLS carries bootstrap, Library, and resumed upload RPCs")
    func getHostInfoOverPinnedTLS13Loopback() async throws {
        let authority = SoftwareP256SigningKey()
        let recordingStore = try await RecordingStore.inMemory()
        let libraryID = try await recordingStore.libraryMetadata().libraryID
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
        let postSession = try LoopbackPostSessionFixture(
            libraryID: libraryID,
            hostAuthorityID: authority.publicKey.hostAuthorityID,
            tlsSPKISHA256: tlsIdentity.tlsSPKISHA256,
            capabilityPolicy: capabilityPolicy
        )
        let sessionAuthenticator = LoopbackSessionAuthenticator(
            credential: postSession.credential,
            tlsSPKISHA256: tlsIdentity.tlsSPKISHA256,
            session: postSession.session
        )
        let resumableUpload = LoopbackResumableUploadApplication(
            fixture: postSession
        )
        let libraryService = HarcHostLibraryService(store: recordingStore)

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
            recordingApplication: resumableUpload,
            recordingSessionAuthenticator: sessionAuthenticator,
            libraryAdapterForBinding: { binding in
                HarcLibraryGRPCServiceAdapterV1(
                    service: libraryService,
                    sessionAuthenticator: sessionAuthenticator,
                    servedIdentityBinding: binding,
                    compatibility: capabilityPolicy.compatibility
                )
            },
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
        var relayTunnel: RelayEmulatorTunnel?
        var relayFrames: RelayFrameRecorder?
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
            let connectionHost: String
            let connectionPort: Int
            if let originText = ProcessInfo.processInfo.environment[
                "HARC_RELAY_EMULATOR_ORIGIN"
            ] {
                let origin = try #require(URL(string: originText))
                let recorder = RelayFrameRecorder()
                let tunnel = try await RelayEmulatorTunnel.open(
                    origin: origin,
                    hostTLSPort: boundPort.rawValue,
                    recorder: recorder
                )
                relayTunnel = tunnel
                relayFrames = recorder
                connectionHost = tunnel.localHost
                connectionPort = Int(tunnel.localPort)
            } else {
                connectionHost = "127.0.0.1"
                connectionPort = Int(boundPort.rawValue)
            }
            let openedConnection = try await HarcPinnedGRPCConnection.connect(
                host: connectionHost,
                port: connectionPort,
                serverHostname: "localhost",
                trustCoordinator: trustCoordinator,
                transportLifetime: relayTunnel
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

            var snapshotRequest = Harc_V1_BeginLibrarySnapshotRequestV1()
            snapshotRequest.protocol = HarcProtocolVersion.v1.protobufV1()
            snapshotRequest.preferredPageSize = 25
            let snapshot = try await openedConnection.beginLibrarySnapshot(
                snapshotRequest,
                authorization: postSession.libraryAuthorization
            )
            #expect(snapshot.recordingCount == 0)
            #expect(snapshot.tombstoneCount == 0)

            let began = try await openedConnection.beginUpload(
                postSession.beginUploadRequest(),
                authorization: postSession.recordingAuthorization
            )
            #expect(began.uploadID == Harc_V1_UploadIDV1(postSession.uploadID))

            let firstAudio = postSession.firstAudio
            let secondAudio = postSession.secondAudio
            _ = try await openedConnection.declareChunks(
                try postSession.declareChunksRequest(),
                authorization: postSession.recordingAuthorization
            )
            try await openedConnection.uploadChunks(
                authorization: postSession.recordingAuthorization,
                requestProducer: { writer in
                    try await writer.write(
                        try postSession.uploadChunkRequest(
                            index: 0,
                            data: firstAudio
                        )
                    )
                },
                responseConsumer: { _ in }
            )
            let interrupted = try await openedConnection.reconcileUpload(
                postSession.reconcileRequest(),
                authorization: postSession.recordingAuthorization
            )
            #expect(interrupted.durableChunks.map(\.chunkIndex) == [0])

            try await openedConnection.uploadChunks(
                authorization: postSession.recordingAuthorization,
                requestProducer: { writer in
                    try await writer.write(
                        try postSession.uploadChunkRequest(
                            index: 1,
                            data: secondAudio
                        )
                    )
                },
                responseConsumer: { _ in }
            )
            let resumed = try await openedConnection.reconcileUpload(
                postSession.reconcileRequest(),
                authorization: postSession.recordingAuthorization
            )
            #expect(resumed.durableChunks.map(\.chunkIndex) == [0, 1])
            if let relayFrames {
                let frames = await relayFrames.snapshot()
                #expect(!frames.isEmpty)
                #expect(
                    !frames.containsPlaintext(
                        Data("Harc Loopback Host".utf8)
                    )
                )
                #expect(
                    !frames.containsPlaintext(
                        Data(
                            "/harc.v1.HostInfoService/GetHostInfo".utf8
                        )
                    )
                )
                #expect(!frames.containsPlaintext(firstAudio))
                #expect(!frames.containsPlaintext(secondAudio))
                #expect(
                    !frames.containsPlaintext(postSession.credential)
                )
            }

            try await openedConnection.shutdownGracefully()
            connection = nil
            await runtime.stopAcceptingNewConnections()
            await runtime.finishGracefulShutdown()

            #expect(!(await runtime.isRunning))
            #expect(await unexpectedExits.values().isEmpty)
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

    private func deleteCertificate(_ der: Data) {
        HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
            certificateDER: der
        )
    }
}

private struct LoopbackPostSessionFixture: Sendable {
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let deviceID: DeviceID
    let uploadID: UploadID
    let originRecordingID: OriginRecordingID
    let profileSHA256: UploadProfileSHA256
    let exactProfile: Data
    let credential: Data
    let session: HostAuthenticatedSession
    let libraryAuthorization: HarcLibraryAuthorization
    let recordingAuthorization: HarcRecordingTransferAuthorization
    let beganAt: Date
    let firstAudio: Data
    let secondAudio: Data

    init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        tlsSPKISHA256: Data,
        capabilityPolicy: HarcCapabilityPolicyV1
    ) throws {
        guard tlsSPKISHA256.count == 32 else {
            throw LoopbackPostSessionError.unauthorized
        }
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        deviceID = try DeviceID(Data(repeating: 0x92, count: 32))
        uploadID = UploadID(
            UUID(uuidString: "23000000-0000-4000-8000-000000000001")!
        )
        originRecordingID = OriginRecordingID(
            deviceID: deviceID,
            recordingUUID: UUID(
                uuidString: "23000000-0000-4000-8000-000000000002"
            )!
        )
        beganAt = Date()
        firstAudio = Self.evenBytes(
            "RIFF-HARC-RELAY-AUDIO-PLAINTEXT-FIRST"
        )
        secondAudio = Self.evenBytes(
            "fLaC-HARC-RELAY-AUDIO-PLAINTEXT-RESUMED"
        )

        var capabilities = Harc_V1_NegotiatedCapabilitiesV1()
        capabilities.protocol = HarcProtocolVersion.v1.protobufV1()
        capabilities.selectedFeatureIds = ["transfer.chunk.v1"]
        capabilities.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        capabilities.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            .rawPCMFixture
        )
        capabilities.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let validatedCapabilities = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: capabilities,
            policy: capabilityPolicy
        )

        var profile = Harc_V1_UploadProfileV1()
        profile.protocol = HarcProtocolVersion.v1.protobufV1()
        profile.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        profile.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            .rawPCMFixture
        )
        profile.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        profile.requiredCapabilityIds = ["transfer.chunk.v1"]
        profile.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: validatedCapabilities.exactSHA256
        )
        profile.purpose = .uploadProfilePurposeFixtureLoopback
        exactProfile = try HarcExactProtobufPayload(
            serializingOnce: profile
        ).exactBytes
        profileSHA256 = try UploadProfileSHA256(
            HarcSignedEnvelopeV1.payloadDigest(exactProfile)
        )

        credential = Data([0x01])
            + Data(repeating: 0x81, count: 15)
            + Data(repeating: 0x82, count: 32)
        let authorizationHeader = try HarcBootstrapAuthorization
            .sessionHeader(credential: credential)
        libraryAuthorization = try HarcLibraryAuthorization(
            credential: credential,
            authorizationHeader: authorizationHeader
        )
        recordingAuthorization = try HarcRecordingTransferAuthorization(
            credential: credential,
            authorizationHeader: authorizationHeader
        )
        session = HostAuthenticatedSession(
            context: AuthenticatedDeviceContext(
                libraryID: libraryID,
                hostAuthorityID: hostAuthorityID,
                authenticatedDeviceID: deviceID,
                grantID: .random(),
                grantEpoch: .initial
            ),
            scopes: [.libraryMetadataRead, .recordingUploadOwn],
            exactCapabilitiesBytes:
                validatedCapabilities.exactPayload.exactBytes,
            capabilitiesSHA256: validatedCapabilities.exactSHA256,
            protocolMinor: 0,
            selectedCodec:
                LosslessEncodingConfiguration.rawPCMFixture.codec.rawValue,
            selectedContainer:
                LosslessEncodingConfiguration.rawPCMFixture.container.rawValue,
            expiresAt: beganAt.addingTimeInterval(1_800)
        )
    }

    func beginUploadRequest() -> Harc_V1_BeginUploadRequestV1 {
        var request = Harc_V1_BeginUploadRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.libraryID = Harc_V1_LibraryIDV1(libraryID)
        request.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostAuthorityID)
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        request.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
        request.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        request.captureStartedAtUnixMs = UInt64(
            (beganAt.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        request.exactUploadProfilePayload = exactProfile
        request.uploadProfileSha256 = try! Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return request
    }

    func declareChunksRequest() throws -> Harc_V1_DeclareChunksRequestV1 {
        var request = Harc_V1_DeclareChunksRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadGeneration = UploadGeneration.initial.rawValue
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        request.descriptors = try [
            descriptor(index: 0, data: firstAudio),
            descriptor(index: 1, data: secondAudio),
        ].map(Harc_V1_ChunkDescriptorV1.init)
        return request
    }

    func uploadChunkRequest(
        index: UInt32,
        data: Data
    ) throws -> Harc_V1_UploadChunkRequestV1 {
        let descriptor = try descriptor(index: index, data: data)
        var request = Harc_V1_UploadChunkRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadGeneration = UploadGeneration.initial.rawValue
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        request.chunkIndex = index
        request.chunkID = Harc_V1_ChunkIDV1(descriptor.chunkID)
        request.encodedByteLength = UInt64(data.count)
        request.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: descriptor.encodedSHA256.rawBytes
        )
        request.encodedChunk = data
        return request
    }

    func reconcileRequest() -> Harc_V1_ReconcileUploadRequestV1 {
        var request = Harc_V1_ReconcileUploadRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadProfileSha256 = try! Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return request
    }

    func descriptor(
        index: UInt32,
        data: Data
    ) throws -> LogicalChunkDescriptor {
        let digest = Data(SHA256.hash(data: data))
        let firstFrames = UInt64(firstAudio.count / 2)
        return try LogicalChunkDescriptor(
            originRecordingID: originRecordingID,
            chunkID: chunkID(index: index),
            chunkIndex: index,
            canonicalStartFrame: index == 0 ? 0 : firstFrames,
            canonicalFrameCount: UInt64(data.count / 2),
            encoding: .rawPCMFixture,
            encodedByteLength: UInt64(data.count),
            encodedSHA256: EncodedChunkSHA256(digest),
            canonicalDecodedByteLength: UInt64(data.count),
            canonicalDecodedSHA256: CanonicalPCMHash(digest)
        )
    }

    private func chunkID(index: UInt32) -> ChunkID {
        ChunkID(
            UUID(
                uuidString: index == 0
                    ? "23000000-0000-4000-8000-000000000003"
                    : "23000000-0000-4000-8000-000000000004"
            )!
        )
    }

    private static func evenBytes(_ value: String) -> Data {
        var data = Data(value.utf8)
        if !data.count.isMultiple(of: 2) { data.append(0) }
        return data
    }
}

private actor LoopbackSessionAuthenticator:
    HarcSessionCredentialAuthenticating
{
    private let credential: Data
    private let tlsSPKISHA256: Data
    private let session: HostAuthenticatedSession

    init(
        credential: Data,
        tlsSPKISHA256: Data,
        session: HostAuthenticatedSession
    ) {
        self.credential = credential
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.session = session
    }

    func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession {
        guard credential == self.credential,
              tlsSPKISHA256 == self.tlsSPKISHA256,
              requiredScope.map(session.scopes.contains) ?? true else {
            throw LoopbackPostSessionError.unauthorized
        }
        return session
    }
}

private actor LoopbackResumableUploadApplication:
    HarcRecordingTransferRPCApplication
{
    private let fixture: LoopbackPostSessionFixture
    private var declarations: [LogicalChunkDescriptor] = []
    private var durableChunks: [DurableChunkStatus] = []

    init(fixture: LoopbackPostSessionFixture) {
        self.fixture = fixture
    }

    func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        guard context == fixture.session.context,
              request.uploadID == fixture.uploadID,
              request.originRecordingID == fixture.originRecordingID else {
            throw LoopbackPostSessionError.invalidUpload
        }
        return .created(try reconciliation())
    }

    func declareChunks(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition {
        guard context == fixture.session.context,
              uploadID == fixture.uploadID,
              generation == .initial,
              expectedUploadProfileSHA256 == fixture.profileSHA256,
              declarations.isEmpty else {
            throw LoopbackPostSessionError.invalidUpload
        }
        declarations = descriptors
        return .appended(firstIndex: 0, count: descriptors.count)
    }

    func uploadChunk(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        chunkIndex: UInt32,
        claimedChunkID: ChunkID,
        declaredEncodedLength: UInt64,
        claimedEncodedSHA256: EncodedChunkSHA256,
        body: HostChunkBody
    ) async throws -> StagedChunkDisposition {
        guard context == fixture.session.context,
              uploadID == fixture.uploadID,
              generation == .initial,
              expectedUploadProfileSHA256 == fixture.profileSHA256,
              Int(chunkIndex) < declarations.count else {
            throw LoopbackPostSessionError.invalidUpload
        }
        var bytes = Data()
        for try await fragment in body { bytes.append(fragment) }
        let descriptor = declarations[Int(chunkIndex)]
        guard descriptor.chunkID == claimedChunkID,
              descriptor.encodedByteLength == declaredEncodedLength,
              descriptor.encodedSHA256 == claimedEncodedSHA256,
              Data(SHA256.hash(data: bytes)) == claimedEncodedSHA256.rawBytes else {
            throw LoopbackPostSessionError.invalidUpload
        }
        let durable = DurableChunkStatus(
            chunkIndex: chunkIndex,
            chunkID: claimedChunkID,
            encodedSHA256: claimedEncodedSHA256
        )
        if !durableChunks.contains(durable) {
            durableChunks.append(durable)
            durableChunks.sort { $0.chunkIndex < $1.chunkIndex }
        }
        return .durablyAccepted(
            HostDurableChunkAcknowledgement(
                uploadID: uploadID,
                generation: generation,
                uploadProfileSHA256: expectedUploadProfileSHA256,
                durableChunk: durable,
                durableAt: Date()
            )
        )
    }

    func reconcileUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> UploadReconciliation {
        guard context == fixture.session.context,
              uploadID == fixture.uploadID,
              expectedUploadProfileSHA256 == fixture.profileSHA256 else {
            throw LoopbackPostSessionError.invalidUpload
        }
        return try reconciliation()
    }

    func commitUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostCanonicalCommitDisposition {
        throw LoopbackPostSessionError.unexpectedCall
    }

    func abandonUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostAbandonUploadResult {
        throw LoopbackPostSessionError.unexpectedCall
    }

    func getRecordingStatus(
        context: AuthenticatedDeviceContext,
        key: HostRecordingStatusKey
    ) async throws -> HostRecordingStatusResult {
        throw LoopbackPostSessionError.unexpectedCall
    }

    func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: HostBackgroundCapabilityMintRequest
    ) async throws -> HostBackgroundCapabilityMintResult {
        throw LoopbackPostSessionError.unexpectedCall
    }

    private func reconciliation() throws -> UploadReconciliation {
        try UploadReconciliation(
            uploadID: fixture.uploadID,
            ownerDeviceID: fixture.deviceID,
            originRecordingID: fixture.originRecordingID,
            uploadProfileSHA256: fixture.profileSHA256,
            generation: .initial,
            firstBeganAt: fixture.beganAt,
            generationBeganAt: fixture.beganAt,
            generationExpiresAt: fixture.beganAt.addingTimeInterval(600),
            declarations: declarations,
            boundManifestObjectSHA256: nil,
            durableChunks: durableChunks,
            rejectedChunks: [],
            terminalReason: nil,
            existingReceipt: nil
        )
    }
}

private enum LoopbackPostSessionError: Error {
    case unauthorized
    case invalidUpload
    case unexpectedCall
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
