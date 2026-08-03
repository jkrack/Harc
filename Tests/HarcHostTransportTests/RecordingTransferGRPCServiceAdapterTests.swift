import CryptoKit
import Foundation
import GRPCCore
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing

@Suite("Recording transfer gRPC service adapter")
struct RecordingTransferGRPCServiceAdapterTests {
    @Test("BeginUpload authenticates exact capabilities and projects creation")
    func beginUpload() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let application = try fixture.application()
        let authenticator = RecordingTransferSessionAuthenticatorFake(
            session: fixture.session
        )
        let adapter = fixture.adapter(
            application: application,
            authenticator: authenticator
        )
        let _: any Harc_V1_RecordingTransferService.ServiceProtocol = adapter

        let wire = try await adapter.beginUpload(
            request: ServerRequest(
                metadata: fixture.metadata,
                message: fixture.beginUploadRequest()
            )
        ).message
        let captured = try #require(await application.capturedBegin())

        #expect(captured.context == fixture.session.context)
        #expect(
            captured.capabilities.exactCapabilitiesSHA256.rawBytes
                == fixture.exactCapabilitiesSHA256
        )
        #expect(captured.capabilities.protocolVersion.minor == 0)
        #expect(captured.capabilities.encoding == .cafALAC)
        #expect(captured.request.uploadID == fixture.uploadID)
        #expect(captured.request.originRecordingID == fixture.originRecordingID)
        #expect(captured.request.frozenProfile.profileSHA256 == fixture.profileSHA256)
        #expect(wire.disposition == .beginUploadDispositionCreated)
        #expect(try wire.uploadID.domainValue() == fixture.uploadID)
        #expect(wire.uploadGeneration == UploadGeneration.initial.rawValue)
        #expect(wire.reconciliation.firstBeganAtUnixMs == 2_000_000_000_000)
        #expect(wire.reconciliation.generationBeganAtUnixMs == 2_000_000_000_000)
        #expect(wire.generationExpiresAtUnixMs == 2_000_000_060_000)
        #expect(wire.hasReconciliation)
    }

    @Test("BeginUpload canonicalizes a sub-millisecond host clock")
    func beginUploadCanonicalizesHostClock() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let application = try fixture.application()
        let adapter = fixture.adapter(
            application: application,
            authenticator: RecordingTransferSessionAuthenticatorFake(
                session: fixture.session
            ),
            now: {
                Date(timeIntervalSince1970: 2_000_000_000.123_789)
            }
        )

        _ = try await adapter.beginUpload(
            request: ServerRequest(
                metadata: fixture.metadata,
                message: fixture.beginUploadRequest()
            )
        )
        let captured = try #require(await application.capturedBegin())

        #expect(
            captured.request.beganAt
                == Date(timeIntervalSince1970: 2_000_000_000.123)
        )
    }

    @Test("DeclareChunks projects the durable typed conflict")
    func declarationConflict() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let existing = try fixture.declarationDescriptor(hashByte: 0x41)
        let attempted = try fixture.declarationDescriptor(hashByte: 0x42)
        let conflict = try ChunkDeclarationConflict(
            existing: existing,
            attempted: attempted
        )
        let application = try fixture.application(
            declarationDisposition: .conflictBlocked(conflict)
        )
        let adapter = fixture.adapter(
            application: application,
            authenticator: RecordingTransferSessionAuthenticatorFake(
                session: fixture.session
            )
        )

        var request = Harc_V1_DeclareChunksRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        request.uploadGeneration = UploadGeneration.initial.rawValue
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.profileSHA256.rawBytes
        )
        request.descriptors = [try Harc_V1_ChunkDescriptorV1(attempted)]

        let wire = try await adapter.declareChunks(request: ServerRequest(
            metadata: fixture.metadata,
            message: request
        )).message
        #expect(
            wire.disposition
                == .chunkDeclarationDispositionConflictBlocked
        )
        #expect(wire.hasConflict)
        let validated = try HarcValidatedDeclareChunksResponseV1(
            wire,
            expectedRequest: HarcValidatedDeclareChunksRequestV1(request)
        )
        #expect(validated.disposition == .conflictBlocked(conflict))
    }

    @Test("GetRecordingStatus resolves an owner-scoped key and projects state")
    func getRecordingStatus() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let application = try fixture.application()
        let adapter = fixture.adapter(
            application: application,
            authenticator: RecordingTransferSessionAuthenticatorFake(
                session: fixture.session
            )
        )

        let wire = try await adapter.getRecordingStatus(
            request: ServerRequest(
                metadata: fixture.metadata,
                message: fixture.statusRequest(protocolMinor: 0)
            )
        ).message

        #expect(
            await application.capturedStatusKey()
                == .originRecordingID(fixture.originRecordingID)
        )
        #expect(try wire.uploadID.domainValue() == fixture.uploadID)
        #expect(
            try wire.originRecordingID.domainValue()
                == fixture.originRecordingID
        )
        #expect(wire.ingestState == .recordingIngestStateReceiving)
        #expect(!wire.hasCanonicalRecordingID)
        #expect(!wire.hasExactRecordingReceipt)
    }

    @Test("request protocol must equal the authenticated session protocol")
    func requestProtocolMismatch() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let application = try fixture.application()
        let adapter = fixture.adapter(
            application: application,
            authenticator: RecordingTransferSessionAuthenticatorFake(
                session: fixture.session
            )
        )

        do {
            _ = try await adapter.getRecordingStatus(
                request: ServerRequest(
                    metadata: fixture.metadata,
                    message: fixture.statusRequest(protocolMinor: 1)
                )
            )
            Issue.record("Expected protocol/session mismatch to fail")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
            #expect(error.message == "The request is malformed.")
        }
        #expect(await application.capturedStatusKey() == nil)
    }

    @Test("UploadChunks reauthenticates each message and bounds host fragments")
    func uploadChunks() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let application = try fixture.application()
        let authenticator = RecordingTransferSessionAuthenticatorFake(
            session: fixture.session
        )
        let adapter = fixture.adapter(
            application: application,
            authenticator: authenticator
        )
        let encodedChunk = Data(
            repeating: 0x5a,
            count: 2 * 256 * 1_024 + 13
        )
        let request = ServerRequest(
            metadata: fixture.metadata,
            message: try fixture.uploadChunkRequest(encodedChunk: encodedChunk)
        )
        let response = try await adapter.uploadChunks(
            request: StreamingServerRequest(single: request)
        )
        let contents = try response.accepted.get()
        let (responses, continuation) = AsyncStream.makeStream(
            of: Harc_V1_UploadChunkResponseV1.self
        )

        _ = try await contents.producer(
            RPCWriter(
                wrapping: RecordingTransferResponseWriter(
                    continuation: continuation
                )
            )
        )
        continuation.finish()

        var iterator = responses.makeAsyncIterator()
        let wire = try #require(await iterator.next())
        #expect(await iterator.next() == nil)
        #expect(wire.protocol.major == HarcProtocolVersion.v1.major)
        #expect(wire.protocol.minor == HarcProtocolVersion.v1.minor)
        guard case .acknowledgement(let acknowledgement)? = wire.result else {
            Issue.record("Expected a durable chunk acknowledgement")
            return
        }
        #expect(acknowledgement.durableChunk.chunkIndex == 7)
        #expect(
            await application.capturedFragmentSizes()
                == [256 * 1_024, 256 * 1_024, 13]
        )
        #expect(await authenticator.callCount() >= 2)
    }

    @Test("MintBackgroundCapability authenticates, binds, and projects transport evidence")
    func mintBackgroundCapability() async throws {
        let fixture = try RecordingTransferAdapterFixture()
        let batchID = AudioBatchID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000005")!
        )
        let bodySHA256 = try ImmutableBatchSHA256(
            Data(repeating: 0xe5, count: 32)
        )
        let path = "/v1/uploads/\(fixture.uploadID)/batches/\(batchID)"
        let result = HostBackgroundCapabilityMintResult(
            capabilityID: UUID(),
            absoluteUploadURL: URL(
                string: "https://harc-host.local:7444\(path)"
            )!,
            opaqueCapabilityCredential: Data(repeating: 0xf6, count: 48),
            issuedAt: Date(timeIntervalSince1970: 2_000_000_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_003_600),
            byteCeiling: 4_096,
            minimumTransportSetEpoch: 7,
            exactSignedTransportSet: Data([0x48, 0x41, 0x52, 0x43]),
            uploadID: fixture.uploadID,
            generation: .initial,
            batchID: batchID,
            exactBatchBodySHA256: bodySHA256,
            httpMethod: "PUT",
            httpPath: path,
            expiryWasClamped: true
        )
        let application = try fixture.application(mintResult: result)
        let adapter = fixture.adapter(
            application: application,
            authenticator: RecordingTransferSessionAuthenticatorFake(
                session: fixture.session
            )
        )

        let wire = try await adapter.mintBackgroundCapability(
            request: ServerRequest(
                metadata: fixture.metadata,
                message: try fixture.mintRequest(
                    batchID: batchID,
                    bodySHA256: bodySHA256
                )
            )
        ).message
        let captured = try #require(await application.capturedMintRequest())

        #expect(captured.uploadID == fixture.uploadID)
        #expect(captured.generation == .initial)
        #expect(captured.batchID == batchID)
        #expect(captured.exactBatchBodySHA256 == bodySHA256)
        #expect(wire.absoluteUploadURL == result.absoluteUploadURL.absoluteString)
        #expect(wire.opaqueCapabilityCredential == result.opaqueCapabilityCredential)
        #expect(wire.minimumTransportSetEpoch == 7)
        #expect(wire.exactSignedTransportSet.framedBytes == result.exactSignedTransportSet)
        #expect(wire.httpMethod == "PUT")
        #expect(wire.httpPath == path)
        #expect(wire.expiryWasClamped)
    }
}

private struct RecordingTransferAdapterFixture {
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let deviceID: DeviceID
    let uploadID: UploadID
    let originRecordingID: OriginRecordingID
    let profileSHA256: UploadProfileSHA256
    let exactProfile: Data
    let exactCapabilitiesSHA256: Data
    let policy: HarcCapabilityPolicyV1
    let session: HostAuthenticatedSession
    let metadata: Metadata
    let servedIdentityBinding: HarcGRPCServedIdentityBinding

    init() throws {
        libraryID = LibraryID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        )
        hostAuthorityID = try HostAuthorityID(Data(repeating: 0xa1, count: 32))
        deviceID = try DeviceID(Data(repeating: 0xb2, count: 32))
        uploadID = UploadID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        )
        originRecordingID = OriginRecordingID(
            deviceID: deviceID,
            recordingUUID: UUID(
                uuidString: "20000000-0000-4000-8000-000000000003"
            )!
        )

        let compatibility = HarcProtobufCompatibilityPolicy(
            versionPolicy: HarcProtocolVersionPolicy(
                major: 1,
                supportedMinorRange: 0 ... 1
            ),
            supportedRequiredFeatures: ["transfer.chunk.v1"]
        )
        policy = try HarcCapabilityPolicyV1(
            compatibility: compatibility,
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue],
            supportedEncodings: [.cafALAC]
        )

        var capabilities = Harc_V1_NegotiatedCapabilitiesV1()
        capabilities.protocol = HarcProtocolVersion.v1.protobufV1()
        capabilities.selectedFeatureIds = ["transfer.chunk.v1"]
        capabilities.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        capabilities.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            .cafALAC
        )
        capabilities.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let validatedCapabilities = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: capabilities,
            policy: policy
        )
        exactCapabilitiesSHA256 = validatedCapabilities.exactSHA256

        var profile = Harc_V1_UploadProfileV1()
        profile.protocol = HarcProtocolVersion.v1.protobufV1()
        profile.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        profile.encoding = Harc_V1_LosslessEncodingConfigurationV1(.cafALAC)
        profile.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        profile.requiredCapabilityIds = ["transfer.chunk.v1"]
        profile.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: validatedCapabilities.exactSHA256
        )
        profile.purpose = .uploadProfilePurposeProduction
        exactProfile = try HarcExactProtobufPayload(
            serializingOnce: profile
        ).exactBytes
        profileSHA256 = try UploadProfileSHA256(
            HarcSignedEnvelopeV1.payloadDigest(exactProfile)
        )

        session = HostAuthenticatedSession(
            context: AuthenticatedDeviceContext(
                libraryID: libraryID,
                hostAuthorityID: hostAuthorityID,
                authenticatedDeviceID: deviceID,
                grantID: .random(),
                grantEpoch: .initial
            ),
            scopes: [.recordingUploadOwn],
            exactCapabilitiesBytes: validatedCapabilities.exactPayload.exactBytes,
            capabilitiesSHA256: validatedCapabilities.exactSHA256,
            protocolMinor: 0,
            selectedCodec: LosslessEncodingConfiguration.cafALAC.codec.rawValue,
            selectedContainer:
                LosslessEncodingConfiguration.cafALAC.container.rawValue,
            expiresAt: Date(timeIntervalSince1970: 2_000_001_800)
        )
        let credential = Data(repeating: 0xc3, count: 48)
        var authorizationMetadata = Metadata()
        authorizationMetadata.addString(
            "HarcSession \(Self.base64URL(credential))",
            forKey: "authorization"
        )
        metadata = authorizationMetadata
        servedIdentityBinding = try HarcGRPCServedIdentityBinding(
            generationID: UUID(),
            testTLSSPKISHA256: Data(repeating: 0xd4, count: 32)
        )
    }

    func adapter(
        application: RecordingTransferRPCApplicationFake,
        authenticator: RecordingTransferSessionAuthenticatorFake,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> HarcRecordingTransferGRPCServiceAdapterV1 {
        HarcRecordingTransferGRPCServiceAdapterV1(
            application: application,
            sessionAuthenticator: authenticator,
            capabilityPolicy: policy,
            servedIdentityBinding: servedIdentityBinding,
            compatibility: policy.compatibility,
            now: now
        )
    }

    func application(
        mintResult: HostBackgroundCapabilityMintResult? = nil,
        declarationDisposition: ChunkDeclarationDisposition? = nil
    ) throws -> RecordingTransferRPCApplicationFake {
        RecordingTransferRPCApplicationFake(
            beginDisposition: .created(try reconciliation()),
            declarationDisposition: declarationDisposition,
            recordingStatus: try HostRecordingStatusResult(
                uploadID: uploadID,
                originRecordingID: originRecordingID,
                ingestState: .receiving
            ),
            mintResult: mintResult
        )
    }

    func declarationDescriptor(
        hashByte: UInt8
    ) throws -> LogicalChunkDescriptor {
        try LogicalChunkDescriptor(
            originRecordingID: originRecordingID,
            chunkID: ChunkID(
                UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
            ),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 1,
            encoding: .cafALAC,
            encodedByteLength: 1,
            encodedSHA256: EncodedChunkSHA256(
                Data(repeating: hashByte, count: 32)
            ),
            canonicalDecodedByteLength: 2,
            canonicalDecodedSHA256: CanonicalPCMHash(
                Data(repeating: 0x43, count: 32)
            )
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
        request.captureStartedAtUnixMs = 2_000_000_000_000
        request.exactUploadProfilePayload = exactProfile
        request.uploadProfileSha256 = try! Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return request
    }

    func statusRequest(
        protocolMinor: UInt16
    ) -> Harc_V1_GetRecordingStatusRequestV1 {
        var request = Harc_V1_GetRecordingStatusRequestV1()
        request.protocol = HarcProtocolVersion(
            major: 1,
            minor: protocolMinor
        ).protobufV1()
        request.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        return request
    }

    func uploadChunkRequest(
        encodedChunk: Data
    ) throws -> Harc_V1_UploadChunkRequestV1 {
        let encodedSHA256 = Data(SHA256.hash(data: encodedChunk))
        var request = Harc_V1_UploadChunkRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadGeneration = UploadGeneration.initial.rawValue
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        request.chunkIndex = 7
        request.chunkID = Harc_V1_ChunkIDV1(
            ChunkID(
                UUID(
                    uuidString: "20000000-0000-4000-8000-000000000004"
                )!
            )
        )
        request.encodedByteLength = UInt64(encodedChunk.count)
        request.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: encodedSHA256
        )
        request.encodedChunk = encodedChunk
        return request
    }

    func mintRequest(
        batchID: AudioBatchID,
        bodySHA256: ImmutableBatchSHA256
    ) throws -> Harc_V1_MintBackgroundCapabilityRequestV1 {
        var request = Harc_V1_MintBackgroundCapabilityRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadGeneration = UploadGeneration.initial.rawValue
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        request.batchID = Harc_V1_AudioBatchIDV1(batchID)
        var chunk = Harc_V1_BackgroundChunkBindingV1()
        chunk.chunkIndex = 0
        chunk.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x7a, count: 32)
        )
        request.chunks = [chunk]
        request.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: bodySHA256.rawBytes
        )
        request.exactBatchBodyLength = 4_096
        request.requestedExpiresAtUnixMs = 2_000_003_600_000
        return request
    }

    private func reconciliation() throws -> UploadReconciliation {
        try UploadReconciliation(
            uploadID: uploadID,
            ownerDeviceID: deviceID,
            originRecordingID: originRecordingID,
            uploadProfileSHA256: profileSHA256,
            generation: .initial,
            firstBeganAt: Date(timeIntervalSince1970: 2_000_000_000),
            generationBeganAt: Date(timeIntervalSince1970: 2_000_000_000),
            generationExpiresAt: Date(timeIntervalSince1970: 2_000_000_060),
            declarations: [],
            boundManifestObjectSHA256: nil,
            durableChunks: [],
            rejectedChunks: [],
            terminalReason: nil,
            existingReceipt: nil
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor RecordingTransferRPCApplicationFake:
    HarcRecordingTransferRPCApplication
{
    struct BeginInvocation: Sendable {
        let context: AuthenticatedDeviceContext
        let capabilities: HostTransferSessionCapabilities
        let request: BeginHostUploadRequest
    }

    private let beginDisposition: BeginHostUploadDisposition
    private let declarationDisposition: ChunkDeclarationDisposition?
    private let recordingStatus: HostRecordingStatusResult
    private let mintResult: HostBackgroundCapabilityMintResult?
    private var beginInvocation: BeginInvocation?
    private var statusKey: HostRecordingStatusKey?
    private var mintRequest: HostBackgroundCapabilityMintRequest?
    private var fragmentSizes: [Int] = []

    init(
        beginDisposition: BeginHostUploadDisposition,
        declarationDisposition: ChunkDeclarationDisposition? = nil,
        recordingStatus: HostRecordingStatusResult,
        mintResult: HostBackgroundCapabilityMintResult? = nil
    ) {
        self.beginDisposition = beginDisposition
        self.declarationDisposition = declarationDisposition
        self.recordingStatus = recordingStatus
        self.mintResult = mintResult
    }

    func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        beginInvocation = BeginInvocation(
            context: context,
            capabilities: sessionCapabilities,
            request: request
        )
        return beginDisposition
    }

    func declareChunks(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition {
        guard let declarationDisposition else {
            throw RecordingTransferApplicationFakeError.unexpectedCall
        }
        return declarationDisposition
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
        var sizes: [Int] = []
        for try await fragment in body {
            sizes.append(fragment.count)
        }
        fragmentSizes = sizes
        return .durablyAccepted(
            HostDurableChunkAcknowledgement(
                uploadID: uploadID,
                generation: generation,
                uploadProfileSHA256: expectedUploadProfileSHA256,
                durableChunk: DurableChunkStatus(
                    chunkIndex: chunkIndex,
                    chunkID: claimedChunkID,
                    encodedSHA256: claimedEncodedSHA256
                ),
                durableAt: Date(timeIntervalSince1970: 2_000_000_001)
            )
        )
    }

    func reconcileUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> UploadReconciliation {
        throw RecordingTransferApplicationFakeError.unexpectedCall
    }

    func commitUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostCanonicalCommitDisposition {
        throw RecordingTransferApplicationFakeError.unexpectedCall
    }

    func abandonUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostAbandonUploadResult {
        throw RecordingTransferApplicationFakeError.unexpectedCall
    }

    func getRecordingStatus(
        context: AuthenticatedDeviceContext,
        key: HostRecordingStatusKey
    ) async throws -> HostRecordingStatusResult {
        statusKey = key
        return recordingStatus
    }

    func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: HostBackgroundCapabilityMintRequest
    ) async throws -> HostBackgroundCapabilityMintResult {
        mintRequest = request
        guard let mintResult else {
            throw RecordingTransferApplicationFakeError.unexpectedCall
        }
        return mintResult
    }

    func capturedBegin() -> BeginInvocation? { beginInvocation }
    func capturedStatusKey() -> HostRecordingStatusKey? { statusKey }
    func capturedMintRequest() -> HostBackgroundCapabilityMintRequest? {
        mintRequest
    }
    func capturedFragmentSizes() -> [Int] { fragmentSizes }
}

private actor RecordingTransferSessionAuthenticatorFake:
    HarcSessionCredentialAuthenticating
{
    private let session: HostAuthenticatedSession
    private var calls = 0

    init(session: HostAuthenticatedSession) {
        self.session = session
    }

    func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession {
        calls += 1
        return session
    }

    func callCount() -> Int { calls }
}

private struct RecordingTransferResponseWriter: RPCWriterProtocol {
    let continuation: AsyncStream<Harc_V1_UploadChunkResponseV1>.Continuation

    func write(_ element: Harc_V1_UploadChunkResponseV1) {
        continuation.yield(element)
    }

    func write(
        contentsOf elements: some Sequence<Harc_V1_UploadChunkResponseV1>
    ) {
        for element in elements {
            continuation.yield(element)
        }
    }
}

private enum RecordingTransferApplicationFakeError: Error {
    case unexpectedCall
}
