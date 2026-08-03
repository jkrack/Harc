import CryptoKit
import Foundation
import GRPCCore
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcProtocol
import Testing

@Suite("Host bootstrap gRPC service adapters")
struct BootstrapGRPCServiceAdapterTests {
    @Test("pairing begin validates protobuf and preserves source and one-shot response bytes")
    func pairingBegin() async throws {
        let deviceKey = SoftwareP256SigningKey()
        let hostKey = SoftwareP256SigningKey()
        let ticketID = UUID()
        let claimID = UUID()
        let sourceBinding = bytes(0x11)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000.125)
        let application = PairingRPCApplicationFake(
            beginResponse: BeginHostPairingClaimResponse(
                claimID: claimID,
                hostNonce: bytes(0x21),
                claimantToken: bytes(0x22),
                expiresAt: expiry
            ),
            proofResponse: try proofResponse(),
            status: .pending
        )
        let adapter = try pairingAdapter(
            application: application,
            hostKey: hostKey,
            sourceBinding: sourceBinding
        )
        let _: any Harc_V1_PairingService.ServiceProtocol = adapter

        var message = Harc_V1_BeginPairingClaimRequestV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.ticketID = Harc_V1_TicketIDV1(ticketID)
        message.ticketSecret = bytes(0x31, count: 24)
        message.clientNonce = bytes(0x32)
        message.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        message.requestedScopes = [
            .authorizationScopeLibraryMetadataRead,
            .authorizationScopeRecordingUploadOwn,
        ]
        message.deviceLabel = "Work iPhone"

        let response = try await adapter.beginPairingClaim(
            request: ServerRequest(metadata: [:], message: message),
            peer: HarcHostRPCPeer(
                remotePeer: "ipv4:192.0.2.10:50000",
                localPeer: "ipv4:192.0.2.20:443"
            )
        )
        let wire = try response.message
        let captured = try #require(await application.capturedBegin())

        #expect(captured.ticketID == ticketID)
        #expect(captured.ticketSecret == message.ticketSecret)
        #expect(captured.clientNonce == message.clientNonce)
        #expect(captured.devicePublicKey == deviceKey.publicKey)
        #expect(captured.requestedScopes == [
            .libraryMetadataRead,
            .recordingUploadOwn,
        ])
        #expect(captured.source.bindingSHA256 == sourceBinding)
        #expect(captured.context.hostAuthorityPublicKey == hostKey.publicKey)
        #expect(captured.context.tlsSPKISHA256 == bytes(0x41))
        #expect(try wire.claimID.validatedUUID() == claimID)
        #expect(wire.hostNonce == bytes(0x21))
        #expect(wire.claimantToken == bytes(0x22))
        #expect(wire.expiresAtUnixMs == 1_800_000_000_125)
    }

    @Test("pairing proof and status require one canonical bearer and preserve exact grant bytes")
    func pairingProofAndStatus() async throws {
        let deviceKey = SoftwareP256SigningKey()
        let hostKey = SoftwareP256SigningKey()
        let claimID = UUID()
        let token = bytes(0x51)
        let signature = try deviceKey.sign(
            digest: P256SHA256Digest(bytes(0x52))
        )
        let application = PairingRPCApplicationFake(
            beginResponse: BeginHostPairingClaimResponse(
                claimID: UUID(),
                hostNonce: bytes(0x01),
                claimantToken: bytes(0x02),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            proofResponse: try proofResponse(),
            status: .approved(exactGrantBytes: Data("HARCSO1\0grant".utf8))
        )
        let adapter = try pairingAdapter(
            application: application,
            hostKey: hostKey,
            sourceBinding: bytes(0x53)
        )
        var metadata = Metadata()
        metadata.addString(
            "HarcPairing \(base64URL(token))",
            forKey: "authorization"
        )

        var proof = Harc_V1_ProvePairingClaimRequestV1()
        proof.protocol = HarcProtocolVersion.v1.protobufV1()
        proof.claimID = Harc_V1_ClaimIDV1(claimID)
        proof.clientSignatureRaw = signature.rawBytes
        let proofResponse = try await adapter.provePairingClaim(
            request: ServerRequest(metadata: metadata, message: proof),
            peer: peer()
        )
        let proofWire = try proofResponse.message
        let capturedProof = try #require(await application.capturedProof())
        #expect(capturedProof.claimID == claimID)
        #expect(capturedProof.claimantToken == token)
        #expect(capturedProof.clientSignature == signature)
        #expect(proofWire.state == .pairingClaimStatePending)
        #expect(proofWire.expiresAtUnixMs == 1_800_000_030_000)

        var status = Harc_V1_GetPairingStatusRequestV1()
        status.protocol = HarcProtocolVersion.v1.protobufV1()
        status.claimID = Harc_V1_ClaimIDV1(claimID)
        let statusResponse = try await adapter.getPairingStatus(
            request: ServerRequest(metadata: metadata, message: status),
            peer: peer()
        )
        let statusWire = try statusResponse.message
        let capturedStatus = try #require(await application.capturedStatus())
        #expect(capturedStatus.claimID == claimID)
        #expect(capturedStatus.token == token)
        #expect(statusWire.state == .pairingClaimStateApproved)
        #expect(statusWire.exactSignedDeviceGrant.framedBytes
            == Data("HARCSO1\0grant".utf8))
    }

    @Test("pairing bearer ambiguity is rejected before HarcHost is called")
    func pairingBearerRejection() async throws {
        let application = PairingRPCApplicationFake(
            beginResponse: BeginHostPairingClaimResponse(
                claimID: UUID(),
                hostNonce: bytes(0x01),
                claimantToken: bytes(0x02),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            proofResponse: try proofResponse(),
            status: .pending
        )
        let adapter = try pairingAdapter(
            application: application,
            hostKey: SoftwareP256SigningKey(),
            sourceBinding: bytes(0x61)
        )
        var status = Harc_V1_GetPairingStatusRequestV1()
        status.protocol = HarcProtocolVersion.v1.protobufV1()
        status.claimID = Harc_V1_ClaimIDV1(UUID())
        var metadata = Metadata()
        metadata.addString(
            "HarcPairing \(base64URL(bytes(0x62)))",
            forKey: "authorization"
        )
        metadata.addString(
            "HarcPairing \(base64URL(bytes(0x63)))",
            forKey: "Authorization"
        )

        do {
            _ = try await adapter.getPairingStatus(
                request: ServerRequest(metadata: metadata, message: status),
                peer: peer()
            )
            Issue.record("Expected duplicate Authorization metadata to fail")
        } catch let error as RPCError {
            #expect(error.code == .unauthenticated)
        }
        #expect(await application.capturedStatus() == nil)
    }

    @Test("session adapters preserve lookup facts and exact negotiated capability bytes")
    func sessionBootstrap() async throws {
        let deviceKey = SoftwareP256SigningKey()
        let grantID = GrantID.random()
        let challengeID = UUID()
        let sourceBinding = bytes(0x71)
        let tlsSPKI = bytes(0x72)
        let capability = try exactCapabilities()
        let signature = try deviceKey.sign(
            digest: P256SHA256Digest(bytes(0x73))
        )
        let application = SessionRPCApplicationFake(
            beginResponse: BeginHostSessionResponse(
                challengeID: challengeID,
                serverNonce: bytes(0x74),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                exactSignedGrantBytes: Data("HARCSO1\0device".utf8),
                serverTime: Date(timeIntervalSince1970: 1_800_000_000.875)
            ),
            openResponse: HostOpenedSession(
                credential: bytes(0x75, count: 48),
                issuedAt: Date(timeIntervalSince1970: 1_800_000_001.25),
                expiresAt: Date(timeIntervalSince1970: 1_800_001_801.25),
                capabilitiesSHA256: capability.sha256
            )
        )
        let adapter = HarcSessionGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            servedIdentityBinding: try servedIdentity(tlsSPKI),
            sourceBindingProvider: sourceProvider(sourceBinding),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        let _: any Harc_V1_SessionService.ServiceProtocol = adapter

        var begin = Harc_V1_BeginSessionRequestV1()
        begin.protocol = HarcProtocolVersion.v1.protobufV1()
        begin.claimedDeviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        begin.grantID = Harc_V1_GrantIDV1(grantID)
        let beginResponse = try await adapter.beginSession(
            request: ServerRequest(metadata: [:], message: begin),
            peer: HarcHostRPCPeer(remotePeer: "remote", localPeer: "local")
        )
        let beginWire = try beginResponse.message
        let capturedBegin = try #require(await application.capturedBegin())
        #expect(capturedBegin.claimedDeviceID == deviceKey.publicKey.deviceID)
        #expect(capturedBegin.grantID == grantID)
        #expect(capturedBegin.source.bindingSHA256 == sourceBinding)
        #expect(capturedBegin.tlsSPKISHA256 == tlsSPKI)
        #expect(try beginWire.challengeID.validatedUUID() == challengeID)
        #expect(beginWire.serverNonce == bytes(0x74))
        #expect(beginWire.exactSignedDeviceGrant.framedBytes
            == Data("HARCSO1\0device".utf8))
        #expect(beginWire.serverTimeUnixMs == 1_800_000_000_875)

        var open = Harc_V1_OpenSessionRequestV1()
        open.protocol = HarcProtocolVersion.v1.protobufV1()
        open.challengeID = Harc_V1_ChallengeIDV1(challengeID)
        open.clientNonce = bytes(0x76)
        open.exactNegotiatedCapabilitiesPayload = capability.bytes
        open.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: capability.sha256
        )
        open.clientSignatureRaw = signature.rawBytes
        let openResponse = try await adapter.openSession(
            request: ServerRequest(metadata: [:], message: open),
            peer: peer()
        )
        let openWire = try openResponse.message
        let capturedOpen = try #require(await application.capturedOpen())
        #expect(capturedOpen.challengeID == challengeID)
        #expect(capturedOpen.exactCapabilitiesBytes == capability.bytes)
        #expect(capturedOpen.capabilitiesSHA256 == capability.sha256)
        #expect(capturedOpen.clientSignature == signature)
        #expect(capturedOpen.tlsSPKISHA256 == tlsSPKI)
        #expect(openWire.sessionCredential == bytes(0x75, count: 48))
        #expect(openWire.serverTimeUnixMs == openWire.issuedAtUnixMs)
        #expect(openWire.negotiatedCapabilitiesSha256.value == capability.sha256)
    }

    @Test("OpenSession rejects an incorrect exact-payload hash before application admission")
    func openSessionHashRejection() async throws {
        let capability = try exactCapabilities()
        let application = SessionRPCApplicationFake(
            beginResponse: BeginHostSessionResponse(
                challengeID: UUID(),
                serverNonce: bytes(0x01),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                exactSignedGrantBytes: bytes(0x02),
                serverTime: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            openResponse: HostOpenedSession(
                credential: bytes(0x03, count: 48),
                issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_800_001_800),
                capabilitiesSHA256: capability.sha256
            )
        )
        let adapter = HarcSessionGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            servedIdentityBinding: try servedIdentity(bytes(0x81)),
            sourceBindingProvider: sourceProvider(bytes(0x82)),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        let deviceKey = SoftwareP256SigningKey()
        var open = Harc_V1_OpenSessionRequestV1()
        open.protocol = HarcProtocolVersion.v1.protobufV1()
        open.challengeID = Harc_V1_ChallengeIDV1(UUID())
        open.clientNonce = bytes(0x83)
        open.exactNegotiatedCapabilitiesPayload = capability.bytes
        var wrongHash = capability.sha256
        wrongHash[0] ^= 0xff
        open.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: wrongHash
        )
        open.clientSignatureRaw = try deviceKey.sign(
            digest: P256SHA256Digest(bytes(0x84))
        ).rawBytes

        do {
            _ = try await adapter.openSession(
                request: ServerRequest(metadata: [:], message: open),
                peer: peer()
            )
            Issue.record("Expected the mismatched capability hash to fail")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
        }
        #expect(await application.capturedOpen() == nil)
    }

    @Test("pairing metadata and session protocol failures share one source cooldown")
    func sharedMalformedBootstrapCooldown() async throws {
        let sourceBinding = bytes(0x91)
        let sourceProvider = sourceProvider(sourceBinding)
        let pairingApplication = PairingRPCApplicationFake(
            beginResponse: BeginHostPairingClaimResponse(
                claimID: UUID(),
                hostNonce: bytes(0x92),
                claimantToken: bytes(0x93),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            proofResponse: try proofResponse(),
            status: .pending
        )
        let capability = try exactCapabilities()
        let sessionApplication = SessionRPCApplicationFake(
            beginResponse: BeginHostSessionResponse(
                challengeID: UUID(),
                serverNonce: bytes(0x95),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
                exactSignedGrantBytes: bytes(0x96),
                serverTime: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            openResponse: HostOpenedSession(
                credential: bytes(0x97, count: 48),
                issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_800_001_800),
                capabilitiesSHA256: capability.sha256
            )
        )
        let factory = HarcBootstrapGRPCServiceFactoryV1(
            hostInfoApplication: UnavailableHostInfoRPCApplication(),
            pairingApplication: pairingApplication,
            sessionApplication: sessionApplication,
            recordingApplication:
                UnavailableRecordingTransferFactoryApplication(),
            recordingSessionAuthenticator:
                UnavailableRecordingTransferFactoryAuthenticator(),
            hostAuthorityPublicKey: SoftwareP256SigningKey().publicKey,
            capabilityPolicy: try capabilityPolicy(),
            sourceBindingProvider: sourceProvider,
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        let services = factory.makeServices(
            servedIdentityBinding: try servedIdentity(bytes(0x94))
        )
        #expect(services.registrableServices.count == 4)
        let _: any Harc_V1_RecordingTransferService.ServiceProtocol =
            services.recording
        let pairing = services.pairing
        let session = services.session

        var status = Harc_V1_GetPairingStatusRequestV1()
        status.protocol = HarcProtocolVersion.v1.protobufV1()
        status.claimID = Harc_V1_ClaimIDV1(UUID())
        for _ in 0..<30 {
            do {
                _ = try await pairing.getPairingStatus(
                    request: ServerRequest(metadata: [:], message: status),
                    peer: peer()
                )
                Issue.record("Expected missing pairing metadata to fail")
            } catch let error as RPCError {
                #expect(error.code == .unauthenticated)
            }
        }

        for _ in 0..<30 {
            do {
                _ = try await session.beginSession(
                    request: ServerRequest(
                        metadata: [:],
                        message: Harc_V1_BeginSessionRequestV1()
                    ),
                    peer: peer()
                )
                Issue.record("Expected missing session protocol to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
        }

        var metadata = Metadata()
        metadata.addString(
            "HarcPairing \(base64URL(bytes(0x98)))",
            forKey: "authorization"
        )
        do {
            _ = try await pairing.getPairingStatus(
                request: ServerRequest(metadata: metadata, message: status),
                peer: peer()
            )
            Issue.record("Expected the shared source cooldown to reject")
        } catch let error as RPCError {
            #expect(error.code == .resourceExhausted)
            #expect(error.message == "The request rate limit was exceeded.")
        }
        #expect(await pairingApplication.capturedStatus() == nil)
        #expect(await sessionApplication.capturedBegin() == nil)
    }

    private func pairingAdapter(
        application: PairingRPCApplicationFake,
        hostKey: SoftwareP256SigningKey,
        sourceBinding: Data
    ) throws -> HarcPairingGRPCServiceAdapterV1 {
        HarcPairingGRPCServiceAdapterV1(
            application: application,
            hostAuthorityPublicKey: hostKey.publicKey,
            servedIdentityBinding: try servedIdentity(bytes(0x41)),
            sourceBindingProvider: sourceProvider(sourceBinding),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
    }

    private func servedIdentity(
        _ tlsSPKISHA256: Data
    ) throws -> HarcGRPCServedIdentityBinding {
        try HarcGRPCServedIdentityBinding(
            generationID: UUID(),
            testTLSSPKISHA256: tlsSPKISHA256
        )
    }

    private func peer() -> HarcHostRPCPeer {
        HarcHostRPCPeer(
            remotePeer: "ipv4:192.0.2.10:50000",
            localPeer: "ipv4:192.0.2.20:443"
        )
    }

    private func sourceProvider(
        _ sourceBinding: Data
    ) -> HarcHostRPCSourceBindingProvider {
        HarcHostRPCSourceBindingProvider { _ in
            try HostPreauthenticationSource(bindingSHA256: sourceBinding)
        }
    }

    private func proofResponse() throws -> HostPairingClaimProofResponse {
        try HostPairingClaimProofResponse(
            proof: HostPairingProofResult(
                sasDigest: bytes(0x42),
                sasWordIndexes: [1, 2, 3, 4],
                sasWords: ["able", "baker", "cable", "delta"]
            ),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_030)
        )
    }

    private func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func exactCapabilities() throws -> (bytes: Data, sha256: Data) {
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.selectedFeatureIds = ["transfer.chunk.v1"]
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let exactBytes = try value.serializedData()
        return (exactBytes, Data(SHA256.hash(data: exactBytes)))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func bytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }
}

private struct UnavailableHostInfoRPCApplication: HarcHostInfoRPCApplication {
    func getHostInfo(
        _ request: GetHostInfoRequest
    ) async throws -> GetHostInfoResponse {
        throw UnavailableHostInfoRPCApplicationError.unexpectedCall
    }

    func negotiateCapabilities(
        _ request: NegotiateHostCapabilitiesRequest
    ) async throws -> NegotiateHostCapabilitiesResponse {
        throw UnavailableHostInfoRPCApplicationError.unexpectedCall
    }
}

private enum UnavailableHostInfoRPCApplicationError: Error {
    case unexpectedCall
}

private actor PairingRPCApplicationFake: HarcPairingClaimRPCApplication {
    private let beginResponse: BeginHostPairingClaimResponse
    private let proofResponse: HostPairingClaimProofResponse
    private let status: HostPairingClaimStatus
    private var beginRequest: BeginHostPairingClaimRequest?
    private var proofRequest: ProveHostPairingClaimRequest?
    private var statusRequest: (claimID: UUID, token: Data)?

    init(
        beginResponse: BeginHostPairingClaimResponse,
        proofResponse: HostPairingClaimProofResponse,
        status: HostPairingClaimStatus
    ) {
        self.beginResponse = beginResponse
        self.proofResponse = proofResponse
        self.status = status
    }

    func beginPairingClaim(
        _ request: BeginHostPairingClaimRequest
    ) async throws -> BeginHostPairingClaimResponse {
        beginRequest = request
        return beginResponse
    }

    func provePairingClaim(
        _ request: ProveHostPairingClaimRequest
    ) async throws -> HostPairingClaimProofResponse {
        proofRequest = request
        return proofResponse
    }

    func pairingStatus(
        claimID: UUID,
        claimantToken: Data
    ) async throws -> HostPairingClaimStatus {
        statusRequest = (claimID, claimantToken)
        return status
    }

    func capturedBegin() -> BeginHostPairingClaimRequest? { beginRequest }
    func capturedProof() -> ProveHostPairingClaimRequest? { proofRequest }
    func capturedStatus() -> (claimID: UUID, token: Data)? { statusRequest }
}

private actor SessionRPCApplicationFake: HarcSessionRPCApplication {
    private let beginResponse: BeginHostSessionResponse
    private let openResponse: HostOpenedSession
    private var beginRequest: BeginHostSessionRequest?
    private var openRequest: OpenHostSessionRequest?

    init(
        beginResponse: BeginHostSessionResponse,
        openResponse: HostOpenedSession
    ) {
        self.beginResponse = beginResponse
        self.openResponse = openResponse
    }

    func beginSession(
        _ request: BeginHostSessionRequest
    ) async throws -> BeginHostSessionResponse {
        beginRequest = request
        return beginResponse
    }

    func openSession(
        _ request: OpenHostSessionRequest
    ) async throws -> HostOpenedSession {
        openRequest = request
        return openResponse
    }

    func capturedBegin() -> BeginHostSessionRequest? { beginRequest }
    func capturedOpen() -> OpenHostSessionRequest? { openRequest }
}
