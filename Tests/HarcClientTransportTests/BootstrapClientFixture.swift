#if canImport(Network)
import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing
@testable import HarcClientTransport
import HarcRemoteTransport

// Same registry mirror checks as the package-only convenience signer, using
// public APIs so this synthetic fixture is also usable by the iOS app tests.
func signBootstrapFixtureObject(
    header: HarcSignedEnvelopeV1,
    exactPayloadBytes: Data,
    payloadBindings: HarcSignedPayloadBindingsV1,
    using signer: any P256DigestSigner
) throws -> HarcSignedObjectV1 {
    let registration = try HarcRegisteredSignedObjectV1.registered(
        messageType: header.messageType, payloadType: header.payloadType
    )
    try registration.validateTuple(header: header, payload: payloadBindings)
    return try HarcSignedObjectV1.sign(
        header: header, exactPayloadBytes: exactPayloadBytes, using: signer
    )
}

private struct FixedBootstrapRandomness: HarcClientBootstrapRandomness {
    let bytes: Data

    func randomBytes(count: Int) throws -> Data {
        guard count == bytes.count else {
            throw BootstrapClientFakeError.invalidRequest
        }
        return bytes
    }
}

enum BootstrapClientFakeError: Error, Equatable {
    case disconnected
    case invalidRequest
    case invalidProof
}

enum BootstrapClientBlockedRPC: Equatable, Sendable {
    case hostInfo
    case capabilityNegotiation
    case pairingBegin
    case pairingProof
    case pairingStatus
    case sessionBegin
    case sessionOpen
}

struct BootstrapClientFixture: Sendable {
    let now = TransportTrustFixtures.nowMilliseconds
    let authorityKey: SoftwareP256SigningKey
    let deviceKey: SoftwareP256SigningKey
    let transport: VerifiedHostTransportSetV1
    let acceptedTrust: HarcAcceptedServerTrust
    let hostTrust: RecordingHostTrustBinding
    let ticket: PairingTicketV1
    let policy: HarcCapabilityPolicyV1
    let offer: Harc_V1_CapabilityOfferV1
    let validatedOffer: HarcValidatedCapabilityOfferV1
    let negotiated: HarcValidatedNegotiatedCapabilitiesV1
    let grantClaims: DeviceGrantClaims
    let exactGrant: Data
    let claimID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let claimantToken = Data(repeating: 0x62, count: 32)
    let hostNonce = Data(repeating: 0x63, count: 32)
    let clientNonce = Data(repeating: 0x64, count: 32)
    let challengeID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
    let serverNonce = Data(repeating: 0x65, count: 32)
    let sessionCredential = Data([0x01])
        + Data(repeating: 0x66, count: 15)
        + Data(repeating: 0x67, count: 32)
    let scopes: [AuthorizationScope] = [
        .processingSubmitOwn,
        .recordingReadOwn,
        .recordingUploadOwn,
    ]

    init(
        deviceKey: SoftwareP256SigningKey = SoftwareP256SigningKey(),
        libraryID: LibraryID = TransportTrustFixtures.libraryID,
        authorityByte: UInt8 = 0x31
    ) throws {
        self.deviceKey = deviceKey
        authorityKey = try TransportTrustFixtures.authorityKey(authorityByte)
        let tlsKey = try TransportTrustFixtures.tlsKey()
        transport = try TransportTrustFixtures.transportSet(
            authorityKey: authorityKey,
            tlsKeys: [tlsKey],
            epoch: 1, libraryID: libraryID
        )
        hostTrust = try RecordingHostTrustBinding(
            libraryID: transport.transportSet.libraryID,
            hostAuthorityID: transport.transportSet.hostAuthorityID,
            hostAuthorityPublicKey: authorityKey.publicKey
        )
        let leaf = try HarcTLSLeafDERParser.parse(
            TransportTrustFixtures.leafCertificate(
                tlsKey: tlsKey,
                exactTransportSet: transport.exactSignedBytes
            )
        )
        acceptedTrust = HarcAcceptedServerTrust(
            hostTrust: hostTrust,
            transportSetEpoch: transport.transportSet.setEpoch,
            exactTransportSet: transport.exactSignedBytes,
            leaf: leaf
        )
        ticket = try PairingTicketV1(
            ticketID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            hostAuthorityPublicKey: authorityKey.publicKey,
            verifiedTransportSet: transport,
            ticketSecret: Data(repeating: 0x61, count: 24),
            issuedAtUnixMilliseconds: now - 1_000,
            expiresAtUnixMilliseconds: now + 119_000,
            endpoints: []
        )
        policy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
        offer = Self.makeOffer()
        validatedOffer = try HarcValidatedCapabilityOfferV1(
            offer,
            policy: policy
        )
        negotiated = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: Self.makeNegotiatedCapabilities(),
            policy: policy
        )
        grantClaims = try DeviceGrantClaims(
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            grantID: GrantID(
                UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
            ),
            devicePublicKey: deviceKey.publicKey,
            scopes: Set(scopes),
            grantEpoch: .initial,
            issuedAt: Date(timeIntervalSince1970: Double(now - 1_000) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(now + 3_600_000) / 1_000),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        exactGrant = try Self.signGrant(
            claims: grantClaims,
            authorityKey: authorityKey,
            issuedAtUnixMilliseconds: now - 1_000,
            expiresAtUnixMilliseconds: now + 3_600_000
        )
    }

    func client(
        rpc: any HarcBootstrapRPCTransport,
        capabilityPolicy: HarcCapabilityPolicyV1? = nil
    ) throws -> HarcBootstrapClient {
        HarcBootstrapClient(
            rpc: rpc,
            capabilityPolicy: capabilityPolicy ?? policy,
            randomness: FixedBootstrapRandomness(bytes: clientNonce),
            sasDictionary: try HarcSASDictionaryV1.bundled(),
            clock: { now }
        )
    }

    static func makeOffer() -> Harc_V1_CapabilityOfferV1 {
        var value = Harc_V1_CapabilityOfferV1()
        value.protocolMajor = 1
        value.minimumProtocolMinor = 0
        value.maximumProtocolMinor = 0
        value.supportedFeatureIds = ["transfer.chunk.v1"]
        value.supportedDescriptorSchemaIds = ["harc.chunk-descriptor.v1"]
        value.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture),
        ]
        value.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return value
    }

    static func makeNegotiatedCapabilities() -> Harc_V1_NegotiatedCapabilitiesV1 {
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.selectedFeatureIds = ["transfer.chunk.v1"]
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        return value
    }

    static func signGrant(
        claims: DeviceGrantClaims,
        authorityKey: SoftwareP256SigningKey,
        issuedAtUnixMilliseconds: UInt64,
        expiresAtUnixMilliseconds: UInt64,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Data {
        let exactPayload = try HarcExactProtobufPayload(
            serializingOnce: Harc_V1_DeviceGrantV1(claims)
        )
        let protocolVersion = HarcProtocolVersion(
            major: claims.protocolVersion.major,
            minor: claims.protocolVersion.minor
        )
        let header = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            protocolVersion: protocolVersion,
            libraryID: claims.libraryID,
            hostAuthorityID: claims.hostAuthorityID,
            signerDeviceID: nil,
            grantID: claims.grantID.rawValue,
            grantEpoch: claims.grantEpoch.rawValue,
            operationID: nil,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: expiresAtUnixMilliseconds,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload.exactBytes),
            versionPolicy: versionPolicy
        )
        let object = try signBootstrapFixtureObject(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: protocolVersion,
                libraryID: claims.libraryID,
                hostAuthorityID: claims.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
                grantID: claims.grantID.rawValue,
                grantEpoch: claims.grantEpoch.rawValue,
                expiresAtUnixMilliseconds: expiresAtUnixMilliseconds
            ),
            using: authorityKey
        )
        return object.exactFramedBytes
    }

    func signedGrant(
        grantID: GrantID,
        epoch: UInt64,
        protocolVersion: IdentityProtocolVersion = .v1,
        minimumCompatibleProtocolMinor: UInt16 = 0,
        maximumCompatibleProtocolMinor: UInt16 = 0,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Data {
        let claims = try DeviceGrantClaims(
            protocolVersion: protocolVersion,
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            grantID: grantID,
            devicePublicKey: deviceKey.publicKey,
            scopes: Set(scopes),
            grantEpoch: GrantEpoch(epoch),
            issuedAt: Date(timeIntervalSince1970: Double(now - 1_000) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(now + 3_600_000) / 1_000),
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
        )
        return try Self.signGrant(
            claims: claims,
            authorityKey: authorityKey,
            issuedAtUnixMilliseconds: now - 1_000,
            expiresAtUnixMilliseconds: now + 3_600_000,
            versionPolicy: versionPolicy
        )
    }
}

actor BootstrapClientFakeRPC: HarcBootstrapRPCTransport {
    let fixture: BootstrapClientFixture
    let hostInfoTransportOverride: Data?
    let beginSessionGrantOverride: Data?
    let sessionCredentialOverride: Data?
    let blockedRPC: BootstrapClientBlockedRPC?
    let remoteRelayRoute: HarcRemoteRelayRouteV1?
    private var disconnected = false
    func disconnect() { disconnected = true }
    func isDisconnected() -> Bool { disconnected }

    private var pairingRequest: Harc_V1_BeginPairingClaimRequestV1?
    private var hostInfoCalls = 0
    private var capabilityNegotiationCalls = 0
    private var pairingBeginCalls = 0
    private var pairingProofCalls = 0
    private var pairingStatusCalls = 0
    private var sessionBeginCalls = 0
    private var sessionOpenCalls = 0
    private var pairingProofVerified = false
    private var sessionProofVerified = false
    private var configuredRPCDidBlock = false
    private var configuredRPCRelease: CheckedContinuation<Void, Never>?
    private var configuredRPCWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        fixture: BootstrapClientFixture,
        hostInfoTransportOverride: Data? = nil,
        beginSessionGrantOverride: Data? = nil,
        sessionCredentialOverride: Data? = nil,
        blockedRPC: BootstrapClientBlockedRPC? = nil,
        remoteRelayRoute: HarcRemoteRelayRouteV1? = nil
    ) {
        self.fixture = fixture
        self.hostInfoTransportOverride = hostInfoTransportOverride
        self.beginSessionGrantOverride = beginSessionGrantOverride
        self.sessionCredentialOverride = sessionCredentialOverride
        self.blockedRPC = blockedRPC
        self.remoteRelayRoute = remoteRelayRoute
    }

    func proofWasVerified() -> Bool { pairingProofVerified }
    func hostInfoCallCount() -> Int { hostInfoCalls }
    func capabilityNegotiationCallCount() -> Int { capabilityNegotiationCalls }
    func pairingBeginCallCount() -> Int { pairingBeginCalls }
    func pairingProofCallCount() -> Int { pairingProofCalls }
    func pairingStatusCallCount() -> Int { pairingStatusCalls }
    func sessionBeginCallCount() -> Int { sessionBeginCalls }
    func sessionOpenCallCount() -> Int { sessionOpenCalls }
    func sessionProofWasVerified() -> Bool { sessionProofVerified }

    func waitUntilConfiguredRPCIsBlocked() async {
        if configuredRPCDidBlock { return }
        await withCheckedContinuation { continuation in
            configuredRPCWaiters.append(continuation)
        }
    }

    func releaseConfiguredRPC() {
        configuredRPCRelease?.resume()
        configuredRPCRelease = nil
    }

    private func blockIfConfigured(_ boundary: BootstrapClientBlockedRPC) async {
        guard blockedRPC == boundary, !configuredRPCDidBlock else { return }
        configuredRPCDidBlock = true
        let waiters = configuredRPCWaiters
        configuredRPCWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            configuredRPCRelease = continuation
        }
    }

    func getHostInfo(
        _ request: Harc_V1_GetHostInfoRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetHostInfoResponseV1> {
        guard request.hasProtocol else { throw BootstrapClientFakeError.invalidRequest }
        hostInfoCalls += 1
        var message = Harc_V1_GetHostInfoResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.displayName = "Harc Test Host"
        message.libraryID = Harc_V1_LibraryIDV1(fixture.hostTrust.libraryID)
        message.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            fixture.hostTrust.hostAuthorityID
        )
        message.hostAuthorityPublicKeyX963 = fixture.authorityKey.publicKey.rawBytes
        message.offers = [fixture.offer]
        var exact = Harc_V1_ExactSignedObjectV1()
        exact.framedBytes = hostInfoTransportOverride
            ?? fixture.transport.exactSignedBytes
        message.exactSignedTransportSet = exact
        message.serverTimeUnixMs = fixture.now
        await blockIfConfigured(.hostInfo)
        return try response(message)
    }

    func negotiateCapabilities(
        _ request: Harc_V1_NegotiateCapabilitiesRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_NegotiateCapabilitiesResponseV1> {
        guard request.hasClientOffer else { throw BootstrapClientFakeError.invalidRequest }
        capabilityNegotiationCalls += 1
        var message = Harc_V1_NegotiateCapabilitiesResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.exactNegotiatedCapabilitiesPayload = fixture.negotiated
            .exactPayload.exactBytes
        message.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.negotiated.exactSHA256
        )
        var exact = Harc_V1_ExactSignedObjectV1()
        exact.framedBytes = fixture.transport.exactSignedBytes
        message.exactSignedTransportSet = exact
        message.serverTimeUnixMs = fixture.now
        await blockIfConfigured(.capabilityNegotiation)
        return try response(message)
    }

    func beginPairingClaim(
        _ request: Harc_V1_BeginPairingClaimRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginPairingClaimResponseV1> {
        guard request.ticketSecret == fixture.ticket.pairingAdmissionSecret,
              request.clientNonce == fixture.clientNonce else {
            throw BootstrapClientFakeError.invalidRequest
        }
        pairingBeginCalls += 1
        pairingRequest = request
        await blockIfConfigured(.pairingBegin)
        var message = Harc_V1_BeginPairingClaimResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.claimID = Harc_V1_ClaimIDV1(fixture.claimID)
        message.hostNonce = fixture.hostNonce
        message.claimantToken = fixture.claimantToken
        message.expiresAtUnixMs = fixture.ticket.expiresAtUnixMilliseconds
        return try response(message)
    }

    func provePairingClaim(
        _ request: Harc_V1_ProvePairingClaimRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_ProvePairingClaimResponseV1> {
        pairingProofCalls += 1
        guard let pairingRequest,
              claimantToken == fixture.claimantToken,
              try request.claimID.validatedUUID() == fixture.claimID else {
            throw BootstrapClientFakeError.invalidRequest
        }
        let publicKey = try P256X963PublicKey(pairingRequest.devicePublicKeyX963)
        let transcript = try PairingTranscriptV1(
            ticketID: fixture.ticket.ticketID,
            claimID: fixture.claimID,
            libraryID: fixture.hostTrust.libraryID,
            hostAuthorityID: fixture.hostTrust.hostAuthorityID,
            hostAuthorityPublicKey: fixture.authorityKey.publicKey,
            tlsSPKISHA256: fixture.acceptedTrust.leaf.fullDERSPKISHA256,
            deviceID: publicKey.deviceID,
            devicePublicKey: publicKey,
            clientNonce: pairingRequest.clientNonce,
            hostNonce: fixture.hostNonce,
            ticketSecretBindingSHA256: fixture.ticket.ticketSecretBindingSHA256,
            requestedScopes: try pairingRequest.requestedScopes.map {
                try $0.domainValue()
            }
        )
        try transcript.verifyClientProof(
            P256RawSignature(request.clientSignatureRaw)
        )
        pairingProofVerified = true
        var message = Harc_V1_ProvePairingClaimResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.state = .pairingClaimStatePending
        message.expiresAtUnixMs = fixture.ticket.expiresAtUnixMilliseconds
        await blockIfConfigured(.pairingProof)
        return try response(message)
    }

    func getPairingStatus(
        _ request: Harc_V1_GetPairingStatusRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetPairingStatusResponseV1> {
        pairingStatusCalls += 1
        guard claimantToken == fixture.claimantToken,
              try request.claimID.validatedUUID() == fixture.claimID else {
            throw BootstrapClientFakeError.invalidRequest
        }
        var message = Harc_V1_GetPairingStatusResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.state = .pairingClaimStateApproved
        var exact = Harc_V1_ExactSignedObjectV1()
        exact.framedBytes = fixture.exactGrant
        message.exactSignedDeviceGrant = exact
        if let remoteRelayRoute {
            message.remoteRelayRoute = try remoteRelayRoute.pairingWireV1()
        }
        await blockIfConfigured(.pairingStatus)
        return try response(message)
    }

    func beginSession(
        _ request: Harc_V1_BeginSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginSessionResponseV1> {
        guard try request.claimedDeviceID.domainValue() == fixture.deviceKey.publicKey.deviceID,
              try request.grantID.domainValue() == fixture.grantClaims.grantID else {
            throw BootstrapClientFakeError.invalidRequest
        }
        sessionBeginCalls += 1
        var message = Harc_V1_BeginSessionResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.challengeID = Harc_V1_ChallengeIDV1(fixture.challengeID)
        message.serverNonce = fixture.serverNonce
        message.expiresAtUnixMs = fixture.now + 30_000
        var exact = Harc_V1_ExactSignedObjectV1()
        exact.framedBytes = beginSessionGrantOverride ?? fixture.exactGrant
        message.exactSignedDeviceGrant = exact
        message.serverTimeUnixMs = fixture.now
        await blockIfConfigured(.sessionBegin)
        return try response(message)
    }

    func openSession(
        _ request: Harc_V1_OpenSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_OpenSessionResponseV1> {
        guard try request.challengeID.validatedUUID() == fixture.challengeID,
              request.negotiatedCapabilitiesSha256.value
                == fixture.negotiated.exactSHA256 else {
            throw BootstrapClientFakeError.invalidRequest
        }
        sessionOpenCalls += 1
        let transcript = try SessionTranscriptV1(
            libraryID: fixture.hostTrust.libraryID,
            hostAuthorityID: fixture.hostTrust.hostAuthorityID,
            tlsSPKISHA256: fixture.acceptedTrust.leaf.fullDERSPKISHA256,
            deviceID: fixture.deviceKey.publicKey.deviceID,
            grantID: fixture.grantClaims.grantID.rawValue,
            grantEpoch: fixture.grantClaims.grantEpoch.rawValue,
            challengeID: fixture.challengeID,
            serverNonce: fixture.serverNonce,
            clientNonce: request.clientNonce,
            capabilitiesSHA256: fixture.negotiated.exactSHA256
        )
        try transcript.verifyClientProof(
            P256RawSignature(request.clientSignatureRaw),
            using: fixture.deviceKey.publicKey
        )
        sessionProofVerified = true
        var message = Harc_V1_OpenSessionResponseV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.sessionCredential = sessionCredentialOverride
            ?? fixture.sessionCredential
        message.issuedAtUnixMs = fixture.now
        message.expiresAtUnixMs = fixture.now + 30 * 60 * 1_000
        message.serverTimeUnixMs = fixture.now
        message.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.negotiated.exactSHA256
        )
        await blockIfConfigured(.sessionOpen)
        return try response(message)
    }

    private func response<Message: Sendable>(
        _ message: Message
    ) throws -> HarcBootstrapRPCResponse<Message> {
        guard !disconnected else { throw BootstrapClientFakeError.disconnected }
        return HarcBootstrapRPCResponse(
            message: message,
            serverTrust: fixture.acceptedTrust
        )
    }
}
#endif
