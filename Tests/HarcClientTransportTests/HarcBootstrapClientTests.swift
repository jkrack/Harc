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

@Suite("Client bootstrap, pairing, and session application layer")
struct HarcBootstrapClientTests {
    @Test("pairing claim presentation expires at its exact signed deadline")
    func pairingClaimDeadline() async throws {
        let fixture = try BootstrapClientFixture()
        let client = try fixture.client(
            rpc: BootstrapClientFakeRPC(fixture: fixture)
        )
        let presentation = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Deadline Test"
        )
        let deadline = presentation.expiresAtUnixMilliseconds

        #expect(!presentation.isExpired(atUnixMilliseconds: deadline - 1))
        #expect(presentation.isExpired(atUnixMilliseconds: deadline))
        #expect(presentation.isExpired(atUnixMilliseconds: deadline + 1))
    }

    @Test("bootstrap failures provide actionable localized descriptions")
    func localizedErrors() {
        #expect(
            HarcBootstrapClientError.invalidRequest(field: "pairingRequest")
                .localizedDescription
                .contains("Update Harc on both Macs")
        )
        #expect(
            HarcBootstrapClientError.responseTransportSetMismatch
                .localizedDescription
                .contains("fresh pairing invitation")
        )
    }

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
        let relayRoute = try HarcRemoteRelayRouteV1(
            serviceOrigin: URL(string: "https://relay.test")!,
            hostRouteID: String(repeating: "A", count: 43),
            deviceRouteID: String(repeating: "B", count: 42) + "A",
            capability: String(repeating: "C", count: 42) + "A"
        )
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            remoteRelayRoute: relayRoute
        )
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
        guard case .approved(let adoption, let deliveredRelayRoute) = result else {
            Issue.record("Expected an approved adoption")
            return
        }
        #expect(adoption.hostTrust == fixture.hostTrust)
        #expect(adoption.transportSet.exactSignedBytes == fixture.transport.exactSignedBytes)
        #expect(adoption.grant.devicePublicKey == fixture.deviceKey.publicKey)
        #expect(adoption.grant.scopes == fixture.scopes)
        #expect(deliveredRelayRoute == relayRoute)
        #expect(await rpc.proofWasVerified())

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: fixture.deviceKey.publicKey.deviceID
        )
        _ = try store.adopt(adoption)
        let activeAdoption = try store.activeAdoption()
        let snapshot = try #require(activeAdoption)
        let revalidated = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: fixture.deviceKey.publicKey,
            at: Date(
                timeIntervalSince1970: Double(fixture.now) / 1_000
            )
        )
        #expect(revalidated == adoption)
        #expect(throws: HarcPersistedAdoptionValidationError.grantNotYetValid) {
            try HarcPersistedAdoptionValidatorV1.validate(
                snapshot,
                devicePublicKey: fixture.deviceKey.publicKey,
                at: Date(
                    timeIntervalSince1970: Double(fixture.now - 2_000) / 1_000
                )
            )
        }

        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await client.getPairingStatus()
        }
    }

    @Test("a proved pairing claim resumes on a replacement transport client")
    func pairingClaimResumesAfterReconnect() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let original = try fixture.client(rpc: rpc)

        _ = try await original.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Reconnect Mac"
        )
        let resumed = try await original.resumingPairing(on: rpc)
        await original.abandonLocalPairingState()

        guard case .approved(let adoption, _) = try await resumed
            .getPairingStatus() else {
            Issue.record("Expected resumed claim approval")
            return
        }
        #expect(adoption.hostTrust == fixture.hostTrust)
        #expect(await rpc.pairingBeginCallCount() == 1)
        #expect(await rpc.pairingProofCallCount() == 1)
        #expect(await rpc.pairingStatusCallCount() == 1)
        await #expect(throws: HarcBootstrapClientError.noPairingInProgress) {
            try await original.getPairingStatus()
        }
    }

    @Test("pairing reuses authenticated Host info without a second verification RPC")
    func pairingReusesVerifiedHostInfo() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let client = try fixture.client(rpc: rpc)
        let expectation = try HarcBootstrapTrustExpectation(
            pairingTicket: fixture.ticket
        )
        let verifiedHostInfo = try await client.getHostInfo(
            expectation: expectation
        )

        _ = try await client.beginPairing(
            ticket: fixture.ticket,
            deviceSigner: fixture.deviceKey,
            requestedScopes: fixture.scopes,
            deviceLabel: "Verified Mac",
            verifiedHostInfo: verifiedHostInfo
        )

        #expect(await rpc.hostInfoCallCount() == 1)
        #expect(await rpc.pairingBeginCallCount() == 1)
        #expect(await rpc.pairingProofCallCount() == 1)
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
        guard case .approved(let adoption, _) = pairingResult else {
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
        guard case .approved(let adoption, _) = try await client.getPairingStatus() else {
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
        guard case .approved(let adoption, _) = try await client.getPairingStatus() else {
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
        guard case .approved(let adoption, _) = try await client.getPairingStatus() else {
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

    @Test("an authenticated Host dummy grant requires pairing repair")
    func sessionDummyGrantRequiresRepair() async throws {
        let fixture = try BootstrapClientFixture()
        let rpc = BootstrapClientFakeRPC(
            fixture: fixture,
            beginSessionGrantOverride: Data(repeating: 0xA5, count: 512)
        )
        let client = try fixture.client(rpc: rpc)
        let adoption = try await approvedAdoption(
            fixture: fixture,
            client: client
        )

        await #expect(throws: HarcBootstrapClientError.sessionGrantUnavailable) {
            try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: fixture.negotiated,
                deviceSigner: fixture.deviceKey
            )
        }
        #expect(await rpc.sessionBeginCallCount() == 1)
        #expect(await rpc.sessionOpenCallCount() == 0)
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

        guard case .approved(let adoption, _) = try await client.getPairingStatus() else {
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
        guard case .approved(let adoption, _) = try await client.getPairingStatus() else {
            throw BootstrapClientFakeError.invalidProof
        }
        return adoption
    }
}

#endif
