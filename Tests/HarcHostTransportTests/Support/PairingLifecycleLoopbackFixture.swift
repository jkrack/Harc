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

struct FreshSpeakerLoopbackConnection: Sendable {
    let connection: HarcPinnedGRPCConnection
    let session: HarcOpenedClientSession
}

struct BoundSpeakerLoopbackContext: Sendable {
    let connection: HarcPinnedGRPCConnection
    let session: HarcOpenedClientSession
    let identity: InstallationSigningIdentity
    let adoption: ValidatedClientAdoptionEvidence
    let root: URL
    let origin: OriginRecordingID
    let canonicalID: CanonicalRecordingID
    let canonicalPCMHash: CanonicalPCMHash
    let exactSignedMetadata: Data
    let exactBundle: Data
    let recordingStore: RecordingStore
    let recordingID: Int64
    let replyFailureGate: SpeakerReplyFailureGate
    let openFreshConnection: @Sendable () async throws -> FreshSpeakerLoopbackConnection
}

struct PairingLifecycleLoopbackFixture {
    func run(onSelectedArtifact: (@Sendable (BoundSpeakerLoopbackContext) async throws -> Void)? = nil) async throws {
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
        let processingService = HarcHostProcessingArtifactService(hostStore: hostStore,
            recordingStore: recordingStore, sessionService: sessionService,
            acceptedEngineRevisions: ["overlap.loopback.v1"])
        let replyFailureGate = SpeakerReplyFailureGate()
        let serviceFactory = HarcBootstrapGRPCServiceFactoryV1(
            hostInfoApplication: hostInfo,
            pairingApplication: pairingService,
            sessionApplication: sessionService,
            recordingApplication:
                UnavailableRecordingTransferFactoryApplication(),
            recordingSessionAuthenticator: sessionService,
            libraryAdapterForBinding: { binding in
                SpeakerReplyFailureService(base: HarcLibraryGRPCServiceAdapterV1(
                    service: libraryService,
                    sessionService: sessionService,
                    processingService: processingService,
                    servedIdentityBinding: binding,
                    compatibility: capabilityPolicy.compatibility
                ), gate: replyFailureGate)
            },
            processingAdapterForBinding: { binding in
                HarcProcessingGRPCServiceAdapterV1(
                    service: processingService,
                    sessionService: sessionService, servedIdentityBinding: binding,
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

            let relayOriginText = ProcessInfo.processInfo.environment["HARC_RELAY_EMULATOR_ORIGIN"]
            let openFreshConnection: @Sendable () async throws -> FreshSpeakerLoopbackConnection = {
                let freshTrust = try HarcTransportTrustCoordinator(pairingExactQRTransportSet: transportSet.exactSignedBytes,
                    hostAuthorityPublicKey: hostState.authorityIdentity.publicKey)
                var freshTunnel: RelayEmulatorTunnel?
                var freshConnection: HarcPinnedGRPCConnection?
                do {
                    let freshHost: String, freshPort: Int
                    if let relayOriginText {
                        let tunnel = try await RelayEmulatorTunnel.open(origin: try #require(URL(string: relayOriginText)),
                            hostTLSPort: port, recorder: RelayFrameRecorder())
                        freshTunnel = tunnel
                        freshHost = tunnel.localHost; freshPort = Int(tunnel.localPort)
                    } else {
                        freshHost = "127.0.0.1"; freshPort = Int(port)
                    }
                    let connected = try await HarcPinnedGRPCConnection.connect(host: freshHost, port: freshPort,
                        serverHostname: "localhost", trustCoordinator: freshTrust, transportLifetime: freshTunnel)
                    freshConnection = connected
                    let freshClient = HarcBootstrapClient(rpc: connected, capabilityPolicy: capabilityPolicy,
                        sasDictionary: try HarcSASDictionaryV1.bundled())
                    let freshNegotiated = try await freshClient.negotiateCapabilities(
                        clientOffer: Self.validatedCapabilityOffer(policy: capabilityPolicy),
                        expectation: HarcBootstrapTrustExpectation(adoption: validatedSecond))
                    let freshSession = try await freshClient.openSession(adoption: validatedSecond,
                        negotiatedCapabilities: freshNegotiated.negotiated, deviceSigner: deviceIdentity)
                    return FreshSpeakerLoopbackConnection(connection: connected, session: freshSession)
                } catch {
                    if let freshConnection { await freshConnection.shutdownImmediately() }
                    else if let freshTunnel { await freshTunnel.shutdown() }
                    throw error
                }
            }

            try await verifyOverlapSubmission(connection: openedConnection, session: secondSession,
                identity: deviceIdentity, claims: second.issued.claims,
                recordingStore: recordingStore, root: root)
            try await verifyOverlapSubmission(connection: openedConnection, session: secondSession,
                identity: deviceIdentity, claims: second.issued.claims,
                recordingStore: recordingStore, root: root, includesSpeakerTurns: true,
                adoption: second.adoption, replyFailureGate: replyFailureGate,
                openFreshConnection: openFreshConnection, onSelectedArtifact: onSelectedArtifact)

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

    private func verifyOverlapSubmission(
        connection: HarcPinnedGRPCConnection, session: HarcOpenedClientSession,
        identity: InstallationSigningIdentity, claims: DeviceGrantClaims,
        recordingStore: RecordingStore, root: URL, includesSpeakerTurns: Bool = false,
        adoption: ValidatedClientAdoptionEvidence? = nil,
        replyFailureGate: SpeakerReplyFailureGate? = nil,
        openFreshConnection: (@Sendable () async throws -> FreshSpeakerLoopbackConnection)? = nil,
        onSelectedArtifact: (@Sendable (BoundSpeakerLoopbackContext) async throws -> Void)? = nil
    ) async throws {
        func bytes(_ id: UUID) -> Data { var value = id.uuid; return withUnsafeBytes(of: &value) { Data($0) } }
        let origin = OriginRecordingID(deviceID: identity.deviceID, recordingUUID: UUID())
        let audioHash = Data(SHA256.hash(data: Data(repeating: 0, count: 16000)))
        // Seed an already-canonical recording; this exercise qualifies processing
        // delivery, not the independent audio upload/codec boundary.
        let capture = try await recordingStore.reconcileClientCapture(
            originID: origin, canonicalPCMHash: try CanonicalPCMHash(audioHash),
            canonicalPCMFrames: 8000,
            masterURL: root.appendingPathComponent("canonical-\(UUID().uuidString).wav"),
            startedAt: Date(), endedAt: Date().addingTimeInterval(0.5),
            transcriptText: nil, transcriptJSONURL: nil, transcriptMarkdownURL: nil,
            sttModelID: nil, transcribedAt: nil)
        let recordingID = try #require(capture.recording.id)
        // Canonical Host ingest queues derived work. The Client recovery helper
        // used to seed this fixture defaults to ready, so set the real ingress state.
        try await recordingStore.updateProcessing(id: recordingID, descriptor: .pending)
        let seeded = try #require(try await recordingStore.fetch(originID: origin))
        #expect(seeded.canonicalPCMHash?.rawBytes == audioHash)
        #expect(seeded.canonicalPCMFrames == 8000)
        let artifactID = UUID(), operationID = UUID()
        var transcript = Harc_V1_TranscriptArtifactV1()
        transcript.protocol = HarcProtocolVersion.v1.protobufV1()
        transcript.protocol.requirements.criticalFieldNumbers = [4]
        transcript.locale = "en-US"
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "mixed words"; utterance.endFrameExclusive = 8000
        var word = Harc_V1_TranscriptWordV1()
        word.text = "mixed words"; word.endFrameExclusive = 8000
        utterance.words = [word]; transcript.utterances = [utterance]
        var overlap = Harc_V1_CanonicalFrameRangeV1()
        overlap.startFrame = 1600; overlap.endFrameExclusive = 6400
        transcript.overlapAssessment.ranges = [overlap]
        var coverage = Harc_V1_ArtifactCoverageV1()
        var covered = Harc_V1_CanonicalFrameRangeV1(); covered.endFrameExclusive = 8000
        coverage.coveredRanges = [covered]
        var coverageArtifact = Harc_V1_CoverageArtifactV1()
        coverageArtifact.protocol = HarcProtocolVersion.v1.protobufV1(); coverageArtifact.coverage = coverage
        var diarization = Harc_V1_DiarizationArtifactV1()
        diarization.protocol = HarcProtocolVersion.v1.protobufV1()
        if includesSpeakerTurns {
            var turn = Harc_V1_SpeakerTurnV1()
            turn.startFrame = 0; turn.endFrameExclusive = 1600; turn.localClusterID = "speaker-0"
            var secondTurn = Harc_V1_SpeakerTurnV1()
            secondTurn.startFrame = 6400; secondTurn.endFrameExclusive = 8000; secondTurn.localClusterID = "speaker-1"
            diarization.turns = [turn, secondTurn]
        }
        let payloads = try [transcript.serializedData(), diarization.serializedData(), coverageArtifact.serializedData()]
        var header = Harc_V1_ProcessingBundleHeaderV1()
        header.protocol = HarcProtocolVersion.v1.protobufV1()
        header.artifactID.value = bytes(artifactID); header.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
        header.canonicalAudioSha256.value = audioHash
        let types: [Harc_V1_ProcessingBundleEntryTypeV1] = [.processingBundleEntryTypeTranscript, .processingBundleEntryTypeDiarization, .processingBundleEntryTypeCoverage]
        header.entries = zip(types, payloads).map { type, data in
            var descriptor = Harc_V1_ProcessingBundleEntryDescriptorV1()
            descriptor.entryType = type; descriptor.schemaVersion = 1
            descriptor.payloadByteLength = UInt64(data.count)
            descriptor.payloadSha256.value = Data(SHA256.hash(data: data)); return descriptor
        }
        let bundle = try HarcProcessingBundleV1.create(header: header, exactEntryPayloads: payloads, totalCanonicalFrames: 8000)
        let issuedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        var metadata = Harc_V1_ProcessingArtifactV1()
        metadata.protocol = HarcProtocolVersion.v1.protobufV1()
        metadata.libraryID = Harc_V1_LibraryIDV1(claims.libraryID)
        metadata.hostAuthorityID = Harc_V1_HostAuthorityIDV1(claims.hostAuthorityID)
        metadata.artifactID.value = bytes(artifactID); metadata.originRecordingID = header.originRecordingID
        metadata.canonicalAudioSha256.value = audioHash
        metadata.producingDeviceID = Harc_V1_DeviceIDV1(identity.deviceID)
        metadata.grantID.value = bytes(claims.grantID.rawValue); metadata.grantEpoch = claims.grantEpoch.rawValue
        metadata.operationID.value = bytes(operationID)
        metadata.issuedAtUnixMs = issuedAt; metadata.submissionExpiresAtUnixMs = issuedAt + 60000
        metadata.engineRevision = "overlap.loopback.v1"; metadata.buildRevision = "test.v1"
        metadata.diarizationRevision = "test.v1"; metadata.vadRevision = "test.v1"
        metadata.vocabularyRevision = "test.v1"; metadata.promptRevision = "test.v1"
        metadata.wordTimingSchemaID = "harc.word-timing.v1"; metadata.coverage = coverage
        metadata.exactBundleByteLength = UInt64(bundle.exactBytes.count)
        metadata.exactBundleSha256.value = Data(SHA256.hash(data: bundle.exactBytes))
        let payload = try metadata.serializedData()
        let envelope = try HarcSignedEnvelopeV1(messageType: .processingArtifact,
            libraryID: claims.libraryID, hostAuthorityID: claims.hostAuthorityID,
            signerDeviceID: identity.deviceID, grantID: claims.grantID.rawValue,
            grantEpoch: claims.grantEpoch.rawValue, operationID: operationID,
            issuedAtUnixMilliseconds: issuedAt, expiresAtUnixMilliseconds: issuedAt + 60000,
            payloadType: .processingArtifact, expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload))
        let signed = try HarcSignedObjectV1.sign(header: envelope, exactPayloadBytes: payload, using: identity)
        var begin = Harc_V1_SubmitOwnArtifactRequestV1()
        begin.protocol = HarcProtocolVersion.v1.protobufV1()
        begin.begin.exactSignedProcessingArtifact.framedBytes = signed.exactFramedBytes
        var frame = Harc_V1_SubmitOwnArtifactRequestV1()
        frame.protocol = HarcProtocolVersion.v1.protobufV1(); frame.frame.frameIndex = 0
        frame.frame.byteOffset = 0; frame.frame.data = bundle.exactBytes
        let requests = [begin, frame]
        let authorization = try HarcProcessingAuthorization(openedSession: session)
        for replay in [false, true] {
            let response = try await connection.submitOwnArtifact(authorization: authorization) { writer in
                for request in requests { try await writer.write(request) }
            }
            #expect(response.disposition == (replay ? .processingSubmissionDispositionExactReplay :
                includesSpeakerTurns ? .processingSubmissionDispositionHostProcessingScheduled :
                .processingSubmissionDispositionAcceptedEdgeArtifact))
            #expect(response.hasStatus)
            #expect(response.status.hasSelectedEdgeBundleSha256 == !includesSpeakerTurns)
            if !includesSpeakerTurns {
                #expect(response.status.selectedEdgeBundleSha256.value == bundle.exactSHA256)
            }
        }
        let stored = try #require(try await recordingStore.fetch(id: recordingID))
        if includesSpeakerTurns {
            #expect(stored.processing == seeded.processing)
            #expect(stored.processing != .ready)
            #expect(stored.transcriptText == nil)
            #expect(stored.jsonPath == nil)
            #expect(try await recordingStore.hostProcessingBacklog().contains { $0.id == recordingID })
            print("Pinned-TLS speaker-bearing artifact deferred to Host, exact replay verified, no lossy projection published")
            // Explicit trusted fixture selection tests the negotiated admission path
            // without opening production speaker-bearing acceptance policy.
            let authenticated = try signed.authenticateRegisteredPayload(using: identity.publicKey, purpose: .historicalEvidence)
            let retained = try HarcValidatedRetainedProcessingArtifactV1(authenticatedMetadata: authenticated,
                exactBundleBytes: bundle.exactBytes,
                selectedSignedMetadataSHA256: Data(SHA256.hash(data: signed.exactFramedBytes)),
                selectedBundleSHA256: bundle.exactSHA256, totalCanonicalFrames: 8000)
            let map = try retained.speakerClusterMap(canonicalRecordingID: stored.canonicalID)
            let projected = try HarcHostProcessingArtifactService.acceptedTranscriptData(transcript,
                recording: stored, clusterMap: map, turns: diarization.turns)
            let metadataURL = root.appendingPathComponent("selected-bound-metadata.bin")
            let bundleURL = root.appendingPathComponent("selected-bound-bundle.bin")
            try signed.exactFramedBytes.write(to: metadataURL)
            try bundle.exactBytes.write(to: bundleURL)
            let source = try SelectedEdgeArtifactSource(signedMetadataURL: metadataURL, bundleURL: bundleURL,
                signedMetadataSHA256: Data(SHA256.hash(data: signed.exactFramedBytes)), bundleSHA256: bundle.exactSHA256)
            try await recordingStore.applyAcceptedEdgeTranscript(recordingID: recordingID, text: "mixed words",
                modelID: "overlap.loopback.v1", structuredTranscriptData: projected, clusterMap: map, artifactSource: source)
            var statusRequest = Harc_V1_GetProcessingStatusRequestV1()
            statusRequest.protocol = HarcProtocolVersion.v1.protobufV1()
            statusRequest.originRecordingID = header.originRecordingID
            let status = try await connection.getProcessingStatus(statusRequest, authorization: authorization)
            #expect(status.status.selectedEdgeBundleSha256.value == bundle.exactSHA256)
            let evidence = try SpeakerEvidenceSnapshot(canonicalRecordingID: stored.canonicalID,
                canonicalPCMHash: CanonicalPCMHash(audioHash), producerDeviceID: identity.deviceID,
                processingArtifactSHA256: bundle.exactSHA256, localClusterID: "speaker-0",
                embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127,0,1]), scale: 0.5),
                modelID: "wespeaker_v2", speechDurationMs: 100, segmentCount: 1)
            let observation = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: stored.canonicalID,
                speakerIndex: 99, embedding: evidence.embedding, modelID: evidence.modelID,
                speechDurationMs: evidence.speechDurationMs, segmentCount: evidence.segmentCount)
            let bound = try BoundSpeakerEmbeddingObservation(observation: observation, evidence: evidence)
            let request = try HarcSpeakerObservationRequestV1.boundRequest(bound,
                negotiatedFeatureIDs: [HarcSpeakerObservationRequestV1.boundFeatureID])
            let libraryAuthorization = try HarcLibraryAuthorization(openedSession: session)
            let first = try await connection.submitSpeakerObservation(request, authorization: libraryAuthorization)
            let decision = try first.decision.domainValue()
            #expect(decision.operationID == observation.operationID)
            #expect(decision.disposition != .matched)
            let replay = try await connection.submitSpeakerObservation(request, authorization: libraryAuthorization)
            #expect(try replay.decision.domainValue() == decision)
            let review = try await recordingStore.currentHostSpeakerReview(recordingID: recordingID, speakerIndex: 0)
            #expect(review?.evidence == evidence)
            #expect(try await recordingStore.currentHostSpeakerReview(recordingID: recordingID, speakerIndex: 99) == nil)
            try Data("changed selected metadata".utf8).write(to: metadataURL)
            do {
                _ = try await connection.submitSpeakerObservation(request, authorization: libraryAuthorization)
                Issue.record("Changed retained metadata must reject bound replay over TLS")
            } catch {}
            print("Pinned-TLS negotiated bound speaker admission and exact replay passed; client index 99 mapped to canonical 0; tampered retained evidence rejected")
            try signed.exactFramedBytes.write(to: metadataURL)
            if let onSelectedArtifact {
                try await onSelectedArtifact(BoundSpeakerLoopbackContext(connection: connection,
                    session: session, identity: identity, adoption: try #require(adoption),
                    root: root, origin: origin, canonicalID: stored.canonicalID,
                    canonicalPCMHash: try CanonicalPCMHash(audioHash), exactSignedMetadata: signed.exactFramedBytes,
                    exactBundle: bundle.exactBytes, recordingStore: recordingStore, recordingID: recordingID,
                    replyFailureGate: try #require(replyFailureGate),
                    openFreshConnection: try #require(openFreshConnection)))
            }
            return
        }
        #expect(stored.processing == .ready)
        #expect(stored.transcriptText?.contains("Overlapping voices detected.") == true)
        let jsonPath = try #require(stored.jsonPath)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jsonPath))) as? [String: Any])
        #expect(object["joinedText"] as? String == "mixed words")
        #expect((object["overlapRanges"] as? [[String: Int]]) == [["startMs":100,"endMs":400]])
        #expect((object["words"] as? [[String: Any]])?.count == 1)
        print("Pinned-TLS overlap artifact accepted, exact replay verified, structured sidecar retained")
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
            supportedFeatureIDs: [HarcSpeakerObservationRequestV1.boundFeatureID],
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
        offer.supportedFeatureIds = [HarcSpeakerObservationRequestV1.boundFeatureID]
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
