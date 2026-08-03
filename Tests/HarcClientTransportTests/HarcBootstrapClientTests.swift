#if canImport(Network)
import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing
@testable import HarcClientTransport

@Suite("Client bootstrap, pairing, and session application layer")
struct HarcBootstrapClientTests {
    @Test("host info and negotiated capabilities stay bound to authenticated transport")
    func hostInfoAndCapabilityNegotiation() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let client = try fixture.client(rpc: rpc)

        let result = try await client.negotiateCapabilities(
            clientOffer: fixture.validatedOffer,
            expectation: HarcBootstrapTrustExpectation(pairingTicket: fixture.ticket)
        )

        #expect(result.hostInfo.displayName == "Harc Test Host")
        #expect(result.hostInfo.hostTrust == fixture.hostTrust)
        #expect(result.negotiated.exactSHA256 == fixture.negotiated.exactSHA256)
        #expect(result.transportSet.exactSignedBytes == fixture.transport.exactSignedBytes)
        #expect(result.tlsSPKISHA256 == fixture.acceptedTrust.leaf.fullDERSPKISHA256)
    }

    @Test("pairing proves the exact TLS-bound transcript and returns persistable adoption")
    func pairingClaimAndAdoption() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let client = try fixture.client(rpc: rpc)

        let presentation = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test iPhone"
        )
        #expect(presentation.claimID == fixture.claimID)
        #expect(presentation.sas.words.count == 4)
        #expect(presentation.hostDisplayName == "Harc Test Host")

        let result = try await client.getPairingStatus()
        guard case .approved(let adoption) = result else {
            Issue.record("Expected an approved adoption")
            return
        }
        #expect(adoption.hostTrust == fixture.hostTrust)
        #expect(adoption.transportSet.exactSignedBytes == fixture.transport.exactSignedBytes)
        #expect(adoption.grant.devicePublicKey == fixture.deviceKey.publicKey)
        #expect(adoption.grant.scopes == fixture.scopes)
        #expect(await rpc.proofWasVerified())

        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("session verifies the current signed grant and signs the exact challenge")
    func sessionChallengeResponse() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let client = try fixture.client(rpc: rpc)

        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test Mac"
        )
        let pairingResult = try await client.getPairingStatus()
        guard case .approved(let adoption) = pairingResult else {
            Issue.record("Expected an approved adoption")
            return
        }

        let session = try await client.openSession(
            adoption: adoption,
            negotiatedCapabilities: fixture.negotiated,
            deviceSigner: fixture.deviceKey
        )
        #expect(session.credential == fixture.sessionCredential)
        #expect(session.authorizationHeader.hasPrefix("HarcSession "))
        #expect(session.grant.grantID == fixture.grantClaims.grantID)
        #expect(session.negotiatedCapabilities.exactSHA256
            == fixture.negotiated.exactSHA256)
        #expect(await rpc.sessionProofWasVerified())
    }

    @Test("host info cannot substitute transport bytes not authenticated by TLS")
    func hostInfoTransportSubstitutionFails() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            hostInfoTransportOverride: Data([0x01, 0x02])
        )
        let client = try fixture.client(rpc: rpc)

        await #expect(throws: HarcBootstrapClientError.responseTransportSetMismatch) {
            try await client.getHostInfo(
                expectation: HarcBootstrapTrustExpectation(
                    pairingTicket: fixture.ticket
                )
            )
        }
    }

    @Test("session rejects a valid host grant with a substituted grant identifier")
    func sessionGrantContinuity() async throws {
        let fixture = try BootstrapClientFixture()
        let replacementGrant = try fixture.signedGrant(
            grantID: GrantID(
                UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
            ),
            epoch: 2
        )
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            beginSessionGrantOverride: replacementGrant
        )
        let client = try fixture.client(rpc: rpc)
        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test Mac"
        )
        guard case .approved(let adoption) = try await client.getPairingStatus() else {
            Issue.record("Expected an approved adoption")
            return
        }

        await #expect(throws: HarcBootstrapClientError.grantBindingMismatch(
            field: "sessionGrantContinuity"
        )) {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
    }

    @Test("session rejects a current grant incompatible with negotiated protocol")
    func sessionCurrentGrantProtocolCompatibility() async throws {
        let fixture = try BootstrapClientFixture()
        let compatibility = HarcProtobufCompatibilityPolicy(
            versionPolicy: HarcProtocolVersionPolicy(
                major: 1,
                supportedMinorRange: 0 ... 1
            ),
            supportedRequiredFeatures: []
        )
        let policy = try HarcCapabilityPolicyV1(
            compatibility: compatibility,
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
        let replacementGrant = try fixture.signedGrant(
            grantID: fixture.grantClaims.grantID,
            epoch: 2,
            protocolVersion: try IdentityProtocolVersion(minor: 1),
            minimumCompatibleProtocolMinor: 1,
            maximumCompatibleProtocolMinor: 1,
            versionPolicy: compatibility.versionPolicy
        )
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            beginSessionGrantOverride: replacementGrant
        )
        let client = try fixture.client(rpc: rpc, capabilityPolicy: policy)
        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test Mac"
        )
        guard case .approved(let adoption) = try await client.getPairingStatus() else {
            Issue.record("Expected an approved adoption")
            return
        }

        await #expect(throws: HarcBootstrapClientError.grantBindingMismatch(
            field: "sessionGrantProtocolCompatibility"
        )) {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
    }

    @Test("session rejects an all-zero credential secret")
    func sessionCredentialSecretIsNonzero() async throws {
        let fixture = try BootstrapClientFixture()
        let zeroSecretCredential = Data([0x01])
            + Data(repeating: 0x02, count: 15)
            + Data(repeating: 0, count: 32)
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            sessionCredentialOverride: zeroSecretCredential
        )
        let client = try fixture.client(rpc: rpc)
        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test Mac"
        )
        guard case .approved(let adoption) = try await client.getPairingStatus() else {
            Issue.record("Expected an approved adoption")
            return
        }

        await #expect(throws: HarcBootstrapClientError.invalidResponse(
            field: "openSession"
        )) {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
    }

    @Test("already-cancelled bootstrap operations emit no RPCs")
    func alreadyCancelledBootstrapOperationsEmitNoRPCs() async throws {
        let fixture = try BootstrapClientFixture()
        let expectation = try HarcBootstrapTrustExpectation(
            pairingTicket: fixture.ticket
        )

        let hostInfoRPC = BootstrapClientFakeRPC(fixture: fixture)
        let hostInfoClient = try fixture.client(rpc: hostInfoRPC)
        let hostInfo = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await hostInfoClient.getHostInfo(expectation: expectation)
        }
        hostInfo.cancel()
        await #expect(throws: CancellationError.self) {
            try await hostInfo.value
        }
        #expect(await hostInfoRPC.hostInfoCallCount() == 0)

        let capabilityRPC = BootstrapClientFakeRPC(fixture: fixture)
        let capabilityClient = try fixture.client(rpc: capabilityRPC)
        let negotiation = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await capabilityClient.negotiateCapabilities(
                clientOffer: fixture.validatedOffer,
                expectation: expectation
            )
        }
        negotiation.cancel()
        await #expect(throws: CancellationError.self) {
            try await negotiation.value
        }
        #expect(await capabilityRPC.hostInfoCallCount() == 0)
        #expect(await capabilityRPC.capabilityNegotiationCallCount() == 0)

        let sessionRPC = BootstrapClientFakeRPC(fixture: fixture)
        let sessionClient = try fixture.client(rpc: sessionRPC)
        let adoption = try await approvedAdoption(
            fixture: fixture,
            client: sessionClient
        )
        let session = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await sessionClient.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
        session.cancel()
        await #expect(throws: CancellationError.self) {
            try await session.value
        }
        #expect(await sessionRPC.sessionBeginCallCount() == 0)
        #expect(await sessionRPC.sessionOpenCallCount() == 0)
    }

    @Test("cancellation after capability negotiation returns cannot produce a result")
    func capabilityNegotiationCancellationAfterRPC() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .capabilityNegotiation
        )
        let client = try fixture.client(rpc: rpc)
        let operation = Task {
            try await client.negotiateCapabilities(
                clientOffer: fixture.validatedOffer,
                expectation: HarcBootstrapTrustExpectation(
                    pairingTicket: fixture.ticket
                )
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.hostInfoCallCount() == 1)
        #expect(await rpc.capabilityNegotiationCallCount() == 1)
    }

    @Test("cancellation after BeginSession returns sends no OpenSession proof")
    func sessionCancellationAfterBegin() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .sessionBegin
        )
        let client = try fixture.client(rpc: rpc)
        let adoption = try await approvedAdoption(
            fixture: fixture,
            client: client
        )
        let operation = Task {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.sessionBeginCallCount() == 1)
        #expect(await rpc.sessionOpenCallCount() == 0)
        #expect(!(await rpc.sessionProofWasVerified()))
    }

    @Test("cancellation after OpenSession returns discards the credential")
    func sessionCancellationAfterOpen() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .sessionOpen
        )
        let client = try fixture.client(rpc: rpc)
        let adoption = try await approvedAdoption(
            fixture: fixture,
            client: client
        )
        let operation = Task {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.sessionBeginCallCount() == 1)
        #expect(await rpc.sessionOpenCallCount() == 1)
        #expect(await rpc.sessionProofWasVerified())
    }

    @Test("concurrent begin and local abandon cannot resurrect a stale claim")
    func pairingBeginGenerationGuard() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .pairingBegin
        )
        let client = try fixture.client(rpc: rpc)
        let first = Task {
            try await client.beginPairing(
                ticket: fixture.ticket,
                deviceSigner: fixture.deviceKey,
                requestedScopes: fixture.scopes,
                deviceLabel: "First Mac"
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        await #expect(throws: HarcBootstrapClientError.pairingAlreadyInProgress) {
            try await client.beginPairing(
                ticket: fixture.ticket,
                deviceSigner: fixture.deviceKey,
                requestedScopes: fixture.scopes,
                deviceLabel: "Second Mac"
            )
        }
        await client.abandonLocalPairingState()
        await rpc.releaseConfiguredRPC()
        await #expect(throws: HarcBootstrapClientError.pairingClaimMismatch) {
            try await first.value
        }
        #expect(await rpc.pairingProofCallCount() == 0)
        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("cancellation after host info returns cannot begin a pairing claim")
    func pairingCancellationAfterHostInfo() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .hostInfo
        )
        let client = try fixture.client(rpc: rpc)
        let operation = Task {
            try await client.beginPairing(
                ticket: fixture.ticket,
                deviceSigner: fixture.deviceKey,
                requestedScopes: fixture.scopes,
                deviceLabel: "Cancelled iPhone"
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.pairingBeginCallCount() == 0)
        #expect(await rpc.pairingProofCallCount() == 0)
        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("cancellation after claim begin returns cannot send a proof or activate")
    func pairingCancellationAfterClaimBegin() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .pairingBegin
        )
        let client = try fixture.client(rpc: rpc)
        let operation = Task {
            try await client.beginPairing(
                ticket: fixture.ticket,
                deviceSigner: fixture.deviceKey,
                requestedScopes: fixture.scopes,
                deviceLabel: "Cancelled iPhone"
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.pairingBeginCallCount() == 1)
        #expect(await rpc.pairingProofCallCount() == 0)
        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("cancellation after claim proof returns cannot activate the claim")
    func pairingCancellationAfterClaimProof() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .pairingProof
        )
        let client = try fixture.client(rpc: rpc)
        let operation = Task {
            try await client.beginPairing(
                ticket: fixture.ticket,
                deviceSigner: fixture.deviceKey,
                requestedScopes: fixture.scopes,
                deviceLabel: "Cancelled iPhone"
            )
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        operation.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await rpc.pairingProofCallCount() == 1)
        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("cancelled approval polling retains claimant material for another poll")
    func pairingStatusCancellationRetainsClaim() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            blockedRPC: .pairingStatus
        )
        let client = try fixture.client(rpc: rpc)
        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test iPhone"
        )
        let poll = Task {
            try await client.getPairingStatus()
        }
        await rpc.waitUntilConfiguredRPCIsBlocked()

        poll.cancel()
        await rpc.releaseConfiguredRPC()

        await #expect(throws: CancellationError.self) {
            try await poll.value
        }
        #expect(await rpc.pairingStatusCallCount() == 1)

        guard case .approved(let adoption) = try await client.getPairingStatus() else {
            Issue.record("Expected the retained claim to remain pollable")
            return
        }
        #expect(adoption.grant.grantID == fixture.grantClaims.grantID)
        #expect(await rpc.pairingStatusCallCount() == 2)
    }

    @Test("the bootstrap client retains its reference transport owner")
    func bootstrapClientRetainsTransportOwner() throws {
        let fixture = try BootstrapClientFixture()
        var rpc: BootstrapClientFakeRPC? = BootstrapClientFakeRPC(
            fixture: fixture
        )
        weak var retainedRPC = rpc
        var client: HarcBootstrapClient?
        do {
            let initialRPC = try #require(rpc)
            client = try fixture.client(rpc: initialRPC)
        }

        rpc = nil
        #expect(retainedRPC != nil)
        #expect(client != nil)

        client = nil
        #expect(retainedRPC == nil)
    }

    private func approvedAdoption(
        fixture: BootstrapClientFixture,
        client: HarcBootstrapClient
    ) async throws -> ValidatedClientAdoptionEvidence {
        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Test iPhone"
        )
        guard case .approved(let adoption) = try await client.getPairingStatus() else {
            throw BootstrapClientFakeError.invalidProof
        }
        return adoption
    }
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

private enum BootstrapClientFakeError: Error {
    case invalidRequest
    case invalidProof
}

private enum BootstrapClientBlockedRPC: Equatable, Sendable {
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
    let deviceKey = SoftwareP256SigningKey()
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

    init() throws {
        authorityKey = try TransportTrustFixtures.authorityKey()
        let tlsKey = try TransportTrustFixtures.tlsKey()
        transport = try TransportTrustFixtures.transportSet(
            authorityKey: authorityKey,
            tlsKeys: [tlsKey],
            epoch: 1
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
        let object = try HarcSignedObjectV1.signRegistered(
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

private actor BootstrapClientFakeRPC: HarcBootstrapRPCTransport {
    let fixture: BootstrapClientFixture
    let hostInfoTransportOverride: Data?
    let beginSessionGrantOverride: Data?
    let sessionCredentialOverride: Data?
    let blockedRPC: BootstrapClientBlockedRPC?
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
        blockedRPC: BootstrapClientBlockedRPC? = nil
    ) {
        self.fixture = fixture
        self.hostInfoTransportOverride = hostInfoTransportOverride
        self.beginSessionGrantOverride = beginSessionGrantOverride
        self.sessionCredentialOverride = sessionCredentialOverride
        self.blockedRPC = blockedRPC
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
        return response(message)
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
        return response(message)
    }

    func beginPairingClaim(
        _ request: Harc_V1_BeginPairingClaimRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginPairingClaimResponseV1> {
        guard request.ticketSecret == fixture.ticket.ticketSecret,
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
        return response(message)
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
        return response(message)
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
        await blockIfConfigured(.pairingStatus)
        return response(message)
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
        return response(message)
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
        return response(message)
    }

    private func response<Message: Sendable>(
        _ message: Message
    ) -> HarcBootstrapRPCResponse<Message> {
        HarcBootstrapRPCResponse(
            message: message,
            serverTrust: fixture.acceptedTrust
        )
    }
}
#endif
