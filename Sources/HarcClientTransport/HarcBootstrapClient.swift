import Foundation
import HarcIdentity
import HarcProtocol
import HarcRemoteTransport
import HarcTransfer

public enum HarcBootstrapClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(field: String)
    case invalidResponse(field: String)
    case hostTrustMismatch
    case responseTransportSetMismatch
    case pairingAlreadyInProgress
    case noPairingInProgress
    case pairingClaimMismatch
    case pairingProofNotPending
    case grantBindingMismatch(field: String)
    case capabilitySelectionNotOffered
    case sessionTrustChanged

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field):
            if field == "pairingRequest" {
                return "This Mac could not create a valid pairing request. Update Harc on both Macs, create a fresh Mac client invitation, and try again."
            }
            return "Harc could not create a valid Host request (\(field))."
        case .invalidResponse(let field):
            return "The Host returned an incomplete or unsupported response (\(field)). Update Harc on both Macs and try again."
        case .hostTrustMismatch:
            return "The Host identity does not match this invitation. Do not approve it; create a fresh invitation on the intended Host."
        case .responseTransportSetMismatch:
            return "The Host connection changed after this invitation was created. Create a fresh pairing invitation and try again."
        case .pairingAlreadyInProgress:
            return "A pairing attempt is already in progress. Cancel it before opening another invitation."
        case .noPairingInProgress:
            return "This pairing attempt is no longer active. Create a fresh invitation on the Host."
        case .pairingClaimMismatch:
            return "The Host returned a different pairing claim. Do not approve it; create a fresh invitation."
        case .pairingProofNotPending:
            return "The Host did not accept this pairing proof as pending. Create a fresh invitation and try again."
        case .grantBindingMismatch(let field):
            return "The Host grant does not match this Mac's pairing request (\(field)). Do not use the grant; create a fresh invitation."
        case .capabilitySelectionNotOffered:
            return "The Host selected capabilities it did not offer. Update Harc on both Macs and try again."
        case .sessionTrustChanged:
            return "The Host identity changed while opening the session. Reconnect using a fresh pairing invitation."
        }
    }
}

public protocol HarcClientBootstrapRandomness: Sendable {
    func randomBytes(count: Int) throws -> Data
}

public struct SystemHarcClientBootstrapRandomness: HarcClientBootstrapRandomness {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        guard count > 0, count <= 4_096 else {
            throw HarcBootstrapClientError.invalidRequest(field: "randomByteCount")
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}

/// The identity tuple expected before a bootstrap response is interpreted.
/// Pairing additionally requires exact equality with the QR transport object;
/// adopted mode leaves transport epoch advancement to the TLS coordinator.
public struct HarcBootstrapTrustExpectation: Equatable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let requiredExactTransportSet: Data?

    public init(
        hostTrust: RecordingHostTrustBinding,
        requiredExactTransportSet: Data? = nil
    ) {
        self.hostTrust = hostTrust
        self.requiredExactTransportSet = requiredExactTransportSet
    }

    public init(pairingTicket: PairingTicketV1) throws {
        self.init(
            hostTrust: try RecordingHostTrustBinding(
                libraryID: pairingTicket.libraryID,
                hostAuthorityID: pairingTicket.hostAuthorityID,
                hostAuthorityPublicKey: pairingTicket.hostAuthorityPublicKey
            ),
            requiredExactTransportSet: pairingTicket.exactTransportObjectBytes
        )
    }

    public init(adoption: ValidatedClientAdoptionEvidence) {
        self.init(hostTrust: adoption.hostTrust)
    }
}

public struct HarcValidatedHostBootstrapInfo: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let displayName: String
    public let hostTrust: RecordingHostTrustBinding
    public let offers: [HarcValidatedCapabilityOfferV1]
    public let verifiedTransportSet: VerifiedHostTransportSetV1
    public let serverTimeUnixMilliseconds: UInt64
    public let tlsSPKISHA256: Data
}

public struct HarcNegotiatedBootstrapCapabilities: Sendable {
    public let hostInfo: HarcValidatedHostBootstrapInfo
    public let negotiated: HarcValidatedNegotiatedCapabilitiesV1
    public let transportSet: ValidatedTransportSetEvidence
    public let serverTimeUnixMilliseconds: UInt64
    public let tlsSPKISHA256: Data
}

public struct HarcPairingClaimPresentation: Equatable, Sendable {
    public let claimID: UUID
    public let sas: HarcSASPhraseV1
    public let expiresAtUnixMilliseconds: UInt64
    public let hostDisplayName: String
}

public enum HarcPairingClaimResult: Equatable, Sendable {
    case pending
    case approved(
        ValidatedClientAdoptionEvidence,
        remoteRelayRoute: HarcRemoteRelayRouteV1?
    )
    case denied
    case expired
    case cancelled
}

public struct HarcOpenedClientSession: Sendable {
    public let credential: Data
    public let authorizationHeader: String
    public let issuedAtUnixMilliseconds: UInt64
    public let expiresAtUnixMilliseconds: UInt64
    public let serverTimeUnixMilliseconds: UInt64
    public let grant: ValidatedDeviceGrantEvidence
    public let negotiatedCapabilities: HarcValidatedNegotiatedCapabilitiesV1
    public let tlsSPKISHA256: Data
}

/// Fail-closed client application layer for HostInfo, QR adoption, and session
/// challenge/response. It owns only ephemeral claim and session material. The
/// caller persists returned adoption/session results through its client-store
/// composition boundary.
public actor HarcBootstrapClient {
    public typealias UnixMillisecondsClock = @Sendable () -> UInt64

    private struct ActivePairing: Sendable {
        let claimID: UUID
        let claimantToken: Data
        let expiresAtUnixMilliseconds: UInt64
        let expectation: HarcBootstrapTrustExpectation
        let verifiedTransportSet: VerifiedHostTransportSetV1
        let devicePublicKey: P256X963PublicKey
        let requestedScopes: [AuthorizationScope]
    }

    private enum PairingState: Sendable {
        case idle
        case beginning(UUID)
        case active(ActivePairing)
        case polling(UUID, ActivePairing)
    }

    private let rpc: any HarcBootstrapRPCTransport
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let randomness: any HarcClientBootstrapRandomness
    private let sasDictionary: HarcSASDictionaryV1
    private let clock: UnixMillisecondsClock
    private var pairingState: PairingState = .idle

    public init(
        rpc: any HarcBootstrapRPCTransport,
        capabilityPolicy: HarcCapabilityPolicyV1,
        randomness: any HarcClientBootstrapRandomness = SystemHarcClientBootstrapRandomness(),
        sasDictionary: HarcSASDictionaryV1,
        clock: @escaping UnixMillisecondsClock = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.rpc = rpc
        self.capabilityPolicy = capabilityPolicy
        self.randomness = randomness
        self.sasDictionary = sasDictionary
        self.clock = clock
    }

    public func getHostInfo(
        expectation: HarcBootstrapTrustExpectation
    ) async throws -> HarcValidatedHostBootstrapInfo {
        try Task.checkCancellation()
        var request = Harc_V1_GetHostInfoRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        _ = try HarcValidatedGetHostInfoRequestV1(request)
        try Task.checkCancellation()
        let response = try await rpc.getHostInfo(request)
        try Task.checkCancellation()
        return try Self.validateHostInfo(
            response,
            expectation: expectation,
            capabilityPolicy: capabilityPolicy
        )
    }

    public func negotiateCapabilities(
        clientOffer: HarcValidatedCapabilityOfferV1,
        expectation: HarcBootstrapTrustExpectation
    ) async throws -> HarcNegotiatedBootstrapCapabilities {
        try Task.checkCancellation()
        let hostInfo = try await getHostInfo(expectation: expectation)
        try Task.checkCancellation()

        var request = Harc_V1_NegotiateCapabilitiesRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.clientOffer = clientOffer.wireValue
        _ = try HarcValidatedNegotiateCapabilitiesRequestV1(
            request,
            policy: capabilityPolicy
        )
        try Task.checkCancellation()
        let response = try await rpc.negotiateCapabilities(request)
        try Task.checkCancellation()
        let trust = try Self.validateServerTrust(
            response.serverTrust,
            expectation: expectation
        )
        let message = response.message
        let version = try Self.validateProtocol(
            present: message.hasProtocol,
            message.protocol,
            knownFields: Set(1 ... 5),
            field: "negotiateCapabilities.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard message.hasNegotiatedCapabilitiesSha256,
              message.hasExactSignedTransportSet else {
            throw HarcBootstrapClientError.invalidResponse(
                field: "negotiateCapabilities.requiredFields"
            )
        }
        let exactTransport = message.exactSignedTransportSet.framedBytes
        guard exactTransport == response.serverTrust.exactTransportSet else {
            throw HarcBootstrapClientError.responseTransportSetMismatch
        }
        let negotiated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: message.exactNegotiatedCapabilitiesPayload,
            expectedSHA256: message.negotiatedCapabilitiesSha256.value,
            policy: capabilityPolicy
        )
        guard negotiated.protocolVersion == version else {
            throw HarcBootstrapClientError.invalidResponse(
                field: "negotiateCapabilities.protocolBinding"
            )
        }

        var selectionWasOffered = false
        for hostOffer in hostInfo.offers {
            if (try? negotiated.validateSelection(
                clientOffer: clientOffer,
                hostOffer: hostOffer
            )) != nil {
                selectionWasOffered = true
                break
            }
        }
        guard selectionWasOffered else {
            throw HarcBootstrapClientError.capabilitySelectionNotOffered
        }
        let verifiedTransport = try VerifiedHostTransportSetV1.decode(
            exactTransport,
            hostAuthorityPublicKey: trust.hostAuthorityPublicKey
        )
        return HarcNegotiatedBootstrapCapabilities(
            hostInfo: hostInfo,
            negotiated: negotiated,
            transportSet: try verifiedTransport.validatedEvidence(),
            serverTimeUnixMilliseconds: message.serverTimeUnixMs,
            tlsSPKISHA256: response.serverTrust.leaf.fullDERSPKISHA256
        )
    }

    /// Begins and proves a claim, then returns the four-word phrase which must
    /// be compared with the resident host UI. The ticket secret is not retained
    /// after this method returns.
    public func beginPairing(
        ticket: PairingTicketV1,
        deviceSigner: any P256DigestSigner,
        requestedScopes: [AuthorizationScope],
        deviceLabel: String,
        verifiedHostInfo: HarcValidatedHostBootstrapInfo? = nil
    ) async throws -> HarcPairingClaimPresentation {
        guard case .idle = pairingState else {
            throw HarcBootstrapClientError.pairingAlreadyInProgress
        }
        let operationID = UUID()
        pairingState = .beginning(operationID)
        do {
        try Task.checkCancellation()
        let now = clock()
        guard now < ticket.expiresAtUnixMilliseconds else {
            throw HarcProtocolCodecError.expired(field: "pairingTicket")
        }
        guard !requestedScopes.isEmpty,
              requestedScopes.count <= HarcProtocolLimits.pairingRequestedScopes,
              requestedScopes == requestedScopes.sorted(),
              Set(requestedScopes).count == requestedScopes.count else {
            throw HarcBootstrapClientError.invalidRequest(field: "pairingRequest")
        }

        let expectation = try HarcBootstrapTrustExpectation(pairingTicket: ticket)
        let hostInfo: HarcValidatedHostBootstrapInfo
        if let verifiedHostInfo {
            try Self.validatePreverifiedHostInfo(
                verifiedHostInfo,
                expectation: expectation
            )
            hostInfo = verifiedHostInfo
        } else {
            hostInfo = try await getHostInfo(expectation: expectation)
        }
        try requireCurrentPairingOperation(operationID)
        let clientNonce = try randomness.randomBytes(count: 32)
        guard clientNonce.count == 32 else {
            throw HarcBootstrapClientError.invalidRequest(field: "clientNonce")
        }

        var begin = Harc_V1_BeginPairingClaimRequestV1()
        begin.protocol = ticket.protocolVersion.protobufV1()
        begin.ticketID = Harc_V1_TicketIDV1(ticket.ticketID)
        begin.ticketSecret = ticket.pairingAdmissionSecret
        begin.clientNonce = clientNonce
        begin.devicePublicKeyX963 = deviceSigner.publicKey.rawBytes
        begin.requestedScopes = requestedScopes.map {
            Harc_V1_AuthorizationScopeV1($0)
        }
        begin.deviceLabel = deviceLabel
        _ = try HarcValidatedBeginPairingClaimRequestV1(begin)

        try requireCurrentPairingOperation(operationID)
        let begun = try await rpc.beginPairingClaim(begin)
        try requireCurrentPairingOperation(operationID)
        _ = try Self.validateServerTrust(
            begun.serverTrust,
            expectation: expectation
        )
        let beginMessage = begun.message
        _ = try Self.validateProtocol(
            present: beginMessage.hasProtocol,
            beginMessage.protocol,
            knownFields: Set(1 ... 5),
            field: "beginPairingClaim.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard beginMessage.hasClaimID,
              beginMessage.hostNonce.count == 32,
              beginMessage.claimantToken.count == 32,
              beginMessage.expiresAtUnixMs > now,
              beginMessage.expiresAtUnixMs <= ticket.expiresAtUnixMilliseconds else {
            throw HarcBootstrapClientError.invalidResponse(
                field: "beginPairingClaim"
            )
        }
        let claimID = try beginMessage.claimID.validatedUUID()
        let transcript = try PairingTranscriptV1(
            protocolVersion: ticket.protocolVersion,
            ticketID: ticket.ticketID,
            claimID: claimID,
            libraryID: ticket.libraryID,
            hostAuthorityID: ticket.hostAuthorityID,
            hostAuthorityPublicKey: ticket.hostAuthorityPublicKey,
            tlsSPKISHA256: begun.serverTrust.leaf.fullDERSPKISHA256,
            deviceID: deviceSigner.publicKey.deviceID,
            devicePublicKey: deviceSigner.publicKey,
            clientNonce: clientNonce,
            hostNonce: beginMessage.hostNonce,
            ticketSecretBindingSHA256: ticket.ticketSecretBindingSHA256,
            requestedScopes: requestedScopes
        )
        let signature = try transcript.signClientProof(using: deviceSigner)
        let phrase = try sasDictionary.phrase(
            for: transcript,
            clientSignature: signature
        )

        var proof = Harc_V1_ProvePairingClaimRequestV1()
        proof.protocol = ticket.protocolVersion.protobufV1()
        proof.claimID = Harc_V1_ClaimIDV1(claimID)
        proof.clientSignatureRaw = signature.rawBytes
        _ = try HarcValidatedProvePairingClaimRequestV1(proof)
        try requireCurrentPairingOperation(operationID)
        let proved = try await rpc.provePairingClaim(
            proof,
            claimantToken: beginMessage.claimantToken
        )
        try requireCurrentPairingOperation(operationID)
        _ = try Self.validateServerTrust(
            proved.serverTrust,
            expectation: expectation
        )
        let proofMessage = proved.message
        _ = try Self.validateProtocol(
            present: proofMessage.hasProtocol,
            proofMessage.protocol,
            knownFields: Set(1 ... 4),
            field: "provePairingClaim.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard proofMessage.state == .pairingClaimStatePending,
              proofMessage.expiresAtUnixMs == beginMessage.expiresAtUnixMs else {
            throw HarcBootstrapClientError.pairingProofNotPending
        }

        try requireCurrentPairingOperation(operationID)
        pairingState = .active(ActivePairing(
            claimID: claimID,
            claimantToken: beginMessage.claimantToken,
            expiresAtUnixMilliseconds: beginMessage.expiresAtUnixMs,
            expectation: expectation,
            verifiedTransportSet: ticket.verifiedTransportSet,
            devicePublicKey: deviceSigner.publicKey,
            requestedScopes: requestedScopes
        ))
        return HarcPairingClaimPresentation(
            claimID: claimID,
            sas: phrase,
            expiresAtUnixMilliseconds: beginMessage.expiresAtUnixMs,
            hostDisplayName: hostInfo.displayName
        )
        } catch {
            if case .beginning(let currentOperationID) = pairingState,
               currentOperationID == operationID {
                pairingState = .idle
            }
            throw error
        }
    }

    public func getPairingStatus() async throws -> HarcPairingClaimResult {
        let activePairing: ActivePairing
        switch pairingState {
        case .active(let active):
            activePairing = active
        case .idle:
            throw HarcBootstrapClientError.noPairingInProgress
        case .beginning, .polling:
            throw HarcBootstrapClientError.pairingClaimMismatch
        }
        let operationID = UUID()
        pairingState = .polling(operationID, activePairing)
        do {
        try requireCurrentPollingOperation(operationID)
        var request = Harc_V1_GetPairingStatusRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.claimID = Harc_V1_ClaimIDV1(activePairing.claimID)
        _ = try HarcValidatedGetPairingStatusRequestV1(request)
        let response = try await rpc.getPairingStatus(
            request,
            claimantToken: activePairing.claimantToken
        )
        try requireCurrentPollingOperation(operationID)
        _ = try Self.validateServerTrust(
            response.serverTrust,
            expectation: activePairing.expectation
        )
        let message = response.message
        _ = try Self.validateProtocol(
            present: message.hasProtocol,
            message.protocol,
            knownFields: Set(1 ... 3),
            field: "getPairingStatus.protocol",
            policy: capabilityPolicy.compatibility
        )
        switch message.state {
        case .pairingClaimStatePending:
            guard !message.hasExactSignedDeviceGrant,
                  !message.hasRemoteRelayRoute else {
                throw HarcBootstrapClientError.invalidResponse(
                    field: "pendingPairingGrant"
                )
            }
            try requireCurrentPollingOperation(operationID)
            pairingState = .active(activePairing)
            return .pending

        case .pairingClaimStateApproved:
            guard message.hasExactSignedDeviceGrant else {
                throw HarcBootstrapClientError.invalidResponse(
                    field: "approvedPairingGrant"
                )
            }
            let exactGrant = message.exactSignedDeviceGrant.framedBytes
            let grant = try Self.validateGrant(
                exactGrant,
                hostTrust: activePairing.expectation.hostTrust,
                expectedDevicePublicKey: activePairing.devicePublicKey,
                allowedScopes: Set(activePairing.requestedScopes),
                atUnixMilliseconds: clock(),
                compatibility: capabilityPolicy.compatibility
            )
            let adoptedAt = clock()
            let adoption = try ValidatedClientAdoptionEvidence(
                hostTrust: activePairing.expectation.hostTrust,
                transportSet: activePairing.verifiedTransportSet.validatedEvidence(),
                grant: grant,
                adoptedAt: Date(
                    timeIntervalSince1970: Double(adoptedAt) / 1_000
                )
            )
            let remoteRelayRoute = try message.hasRemoteRelayRoute
                ? HarcRemoteRelayRouteV1(
                    pairingWire: message.remoteRelayRoute
                )
                : nil
            try requireCurrentPollingOperation(operationID)
            pairingState = .idle
            return .approved(
                adoption,
                remoteRelayRoute: remoteRelayRoute
            )

        case .pairingClaimStateDenied:
            guard !message.hasExactSignedDeviceGrant,
                  !message.hasRemoteRelayRoute else {
                throw HarcBootstrapClientError.invalidResponse(field: "deniedPairingGrant")
            }
            try requireCurrentPollingOperation(operationID)
            pairingState = .idle
            return .denied

        case .pairingClaimStateExpired:
            guard !message.hasExactSignedDeviceGrant,
                  !message.hasRemoteRelayRoute else {
                throw HarcBootstrapClientError.invalidResponse(field: "expiredPairingGrant")
            }
            try requireCurrentPollingOperation(operationID)
            pairingState = .idle
            return .expired

        case .pairingClaimStateCancelled:
            guard !message.hasExactSignedDeviceGrant,
                  !message.hasRemoteRelayRoute else {
                throw HarcBootstrapClientError.invalidResponse(field: "cancelledPairingGrant")
            }
            try requireCurrentPollingOperation(operationID)
            pairingState = .idle
            return .cancelled

        case .pairingClaimStateUnspecified, .UNRECOGNIZED:
            throw HarcBootstrapClientError.invalidResponse(field: "pairingClaimState")
        }
        } catch {
            if case .polling(let currentOperationID, _) = pairingState,
               currentOperationID == operationID {
                pairingState = .active(activePairing)
            }
            throw error
        }
    }

    /// Drops only local ephemeral claim state. It does not claim to cancel the
    /// host reservation because V1 intentionally has no remote cancel RPC.
    public func abandonLocalPairingState() {
        pairingState = .idle
    }

    private func requireCurrentPairingOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard case .beginning(let currentOperationID) = pairingState,
              currentOperationID == operationID else {
            throw HarcBootstrapClientError.pairingClaimMismatch
        }
    }

    private func requireCurrentPollingOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard case .polling(let currentOperationID, _) = pairingState,
              currentOperationID == operationID else {
            throw HarcBootstrapClientError.pairingClaimMismatch
        }
    }

    public func openSession(
        adoption: ValidatedClientAdoptionEvidence,
        negotiatedCapabilities: HarcValidatedNegotiatedCapabilitiesV1,
        deviceSigner: any P256DigestSigner
    ) async throws -> HarcOpenedClientSession {
        try Task.checkCancellation()
        guard adoption.grant.status == .active,
              adoption.grant.devicePublicKey == deviceSigner.publicKey,
              negotiatedCapabilities.protocolVersion.major
                == adoption.grant.protocolVersion.major,
              adoption.grant.minimumCompatibleProtocolMinor
                <= negotiatedCapabilities.protocolVersion.minor,
              negotiatedCapabilities.protocolVersion.minor
                <= adoption.grant.maximumCompatibleProtocolMinor else {
            throw HarcBootstrapClientError.grantBindingMismatch(
                field: "sessionInput"
            )
        }

        var begin = Harc_V1_BeginSessionRequestV1()
        begin.protocol = negotiatedCapabilities.protocolVersion.protobufV1()
        begin.claimedDeviceID = Harc_V1_DeviceIDV1(adoption.grant.deviceID)
        begin.grantID = Harc_V1_GrantIDV1(adoption.grant.grantID)
        _ = try HarcValidatedBeginSessionRequestV1(begin)
        try Task.checkCancellation()
        let begun = try await rpc.beginSession(begin)
        try Task.checkCancellation()
        let expectation = HarcBootstrapTrustExpectation(adoption: adoption)
        _ = try Self.validateServerTrust(
            begun.serverTrust,
            expectation: expectation
        )
        let beginMessage = begun.message
        let beginVersion = try Self.validateProtocol(
            present: beginMessage.hasProtocol,
            beginMessage.protocol,
            knownFields: Set(1 ... 6),
            field: "beginSession.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard beginVersion == negotiatedCapabilities.protocolVersion,
              beginMessage.hasChallengeID,
              beginMessage.serverNonce.count == 32,
              beginMessage.hasExactSignedDeviceGrant,
              beginMessage.expiresAtUnixMs > beginMessage.serverTimeUnixMs,
              beginMessage.expiresAtUnixMs - beginMessage.serverTimeUnixMs <= 30_000 else {
            throw HarcBootstrapClientError.invalidResponse(field: "beginSession")
        }
        let challengeID = try beginMessage.challengeID.validatedUUID()
        let grant = try Self.validateGrant(
            beginMessage.exactSignedDeviceGrant.framedBytes,
            hostTrust: adoption.hostTrust,
            expectedDevicePublicKey: deviceSigner.publicKey,
            allowedScopes: nil,
            atUnixMilliseconds: beginMessage.serverTimeUnixMs,
            compatibility: capabilityPolicy.compatibility
        )
        guard grant.grantID == adoption.grant.grantID,
              grant.registryEpoch >= adoption.grant.registryEpoch else {
            throw HarcBootstrapClientError.grantBindingMismatch(
                field: "sessionGrantContinuity"
            )
        }
        guard grant.protocolVersion.major
                == negotiatedCapabilities.protocolVersion.major,
              grant.minimumCompatibleProtocolMinor
                <= negotiatedCapabilities.protocolVersion.minor,
              negotiatedCapabilities.protocolVersion.minor
                <= grant.maximumCompatibleProtocolMinor else {
            throw HarcBootstrapClientError.grantBindingMismatch(
                field: "sessionGrantProtocolCompatibility"
            )
        }
        let clientNonce = try randomness.randomBytes(count: 32)
        guard clientNonce.count == 32 else {
            throw HarcBootstrapClientError.invalidRequest(field: "clientNonce")
        }
        let beginTLSSPKI = begun.serverTrust.leaf.fullDERSPKISHA256
        let transcript = try SessionTranscriptV1(
            protocolVersion: negotiatedCapabilities.protocolVersion,
            libraryID: adoption.hostTrust.libraryID,
            hostAuthorityID: adoption.hostTrust.hostAuthorityID,
            tlsSPKISHA256: beginTLSSPKI,
            deviceID: grant.deviceID,
            grantID: grant.grantID.rawValue,
            grantEpoch: grant.registryEpoch,
            challengeID: challengeID,
            serverNonce: beginMessage.serverNonce,
            clientNonce: clientNonce,
            capabilitiesSHA256: negotiatedCapabilities.exactSHA256
        )
        let signature = try transcript.signClientProof(using: deviceSigner)

        var open = Harc_V1_OpenSessionRequestV1()
        open.protocol = negotiatedCapabilities.protocolVersion.protobufV1()
        open.challengeID = Harc_V1_ChallengeIDV1(challengeID)
        open.clientNonce = clientNonce
        open.exactNegotiatedCapabilitiesPayload = negotiatedCapabilities.exactPayload.exactBytes
        open.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: negotiatedCapabilities.exactSHA256
        )
        open.clientSignatureRaw = signature.rawBytes
        _ = try HarcValidatedOpenSessionRequestV1(
            open,
            capabilityPolicy: capabilityPolicy
        )
        try Task.checkCancellation()
        let opened = try await rpc.openSession(open)
        try Task.checkCancellation()
        _ = try Self.validateServerTrust(
            opened.serverTrust,
            expectation: expectation
        )
        guard opened.serverTrust.leaf.fullDERSPKISHA256 == beginTLSSPKI else {
            throw HarcBootstrapClientError.sessionTrustChanged
        }
        let openMessage = opened.message
        let openVersion = try Self.validateProtocol(
            present: openMessage.hasProtocol,
            openMessage.protocol,
            knownFields: Set(1 ... 6),
            field: "openSession.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard openVersion == beginVersion,
              openMessage.hasNegotiatedCapabilitiesSha256,
              openMessage.negotiatedCapabilitiesSha256.value
                == negotiatedCapabilities.exactSHA256,
              openMessage.sessionCredential.count == 48,
              !openMessage.sessionCredential.prefix(16).allSatisfy({ $0 == 0 }),
              !openMessage.sessionCredential.suffix(32).allSatisfy({ $0 == 0 }),
              openMessage.issuedAtUnixMs <= openMessage.serverTimeUnixMs,
              openMessage.serverTimeUnixMs < openMessage.expiresAtUnixMs,
              openMessage.expiresAtUnixMs - openMessage.issuedAtUnixMs
                <= 30 * 60 * 1_000 else {
            throw HarcBootstrapClientError.invalidResponse(field: "openSession")
        }
        try Task.checkCancellation()
        return HarcOpenedClientSession(
            credential: openMessage.sessionCredential,
            authorizationHeader: try HarcBootstrapAuthorization.sessionHeader(
                credential: openMessage.sessionCredential
            ),
            issuedAtUnixMilliseconds: openMessage.issuedAtUnixMs,
            expiresAtUnixMilliseconds: openMessage.expiresAtUnixMs,
            serverTimeUnixMilliseconds: openMessage.serverTimeUnixMs,
            grant: grant,
            negotiatedCapabilities: negotiatedCapabilities,
            tlsSPKISHA256: beginTLSSPKI
        )
    }
}

private extension HarcBootstrapClient {
    /// Accepts only an authenticated result produced for this exact pairing
    /// invitation. Route selection can therefore carry its successful
    /// `GetHostInfo` result into claim creation without a second network RPC.
    static func validatePreverifiedHostInfo(
        _ hostInfo: HarcValidatedHostBootstrapInfo,
        expectation: HarcBootstrapTrustExpectation
    ) throws {
        guard hostInfo.hostTrust == expectation.hostTrust else {
            throw HarcBootstrapClientError.hostTrustMismatch
        }
        if let requiredTransport = expectation.requiredExactTransportSet,
           hostInfo.verifiedTransportSet.exactSignedBytes
                != requiredTransport {
            throw HarcBootstrapClientError.responseTransportSetMismatch
        }
    }

    static func validateHostInfo(
        _ response: HarcBootstrapRPCResponse<Harc_V1_GetHostInfoResponseV1>,
        expectation: HarcBootstrapTrustExpectation,
        capabilityPolicy: HarcCapabilityPolicyV1
    ) throws -> HarcValidatedHostBootstrapInfo {
        let trust = try validateServerTrust(
            response.serverTrust,
            expectation: expectation
        )
        let message = response.message
        let version = try validateProtocol(
            present: message.hasProtocol,
            message.protocol,
            knownFields: Set(1 ... 8),
            field: "getHostInfo.protocol",
            policy: capabilityPolicy.compatibility
        )
        guard message.hasLibraryID,
              message.hasHostAuthorityID,
              message.hasExactSignedTransportSet,
              !message.displayName.isEmpty,
              message.displayName.utf8.count <= 256,
              message.displayName == message.displayName.precomposedStringWithCanonicalMapping,
              !message.displayName.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }),
              !message.offers.isEmpty,
              message.offers.count <= 32 else {
            throw HarcBootstrapClientError.invalidResponse(field: "getHostInfo")
        }
        guard try message.libraryID.domainValue() == trust.libraryID,
              try message.hostAuthorityID.domainValue() == trust.hostAuthorityID,
              message.hostAuthorityPublicKeyX963 == trust.hostAuthorityPublicKey.rawBytes else {
            throw HarcBootstrapClientError.hostTrustMismatch
        }
        let exactTransport = message.exactSignedTransportSet.framedBytes
        guard exactTransport == response.serverTrust.exactTransportSet else {
            throw HarcBootstrapClientError.responseTransportSetMismatch
        }
        let verifiedTransport = try VerifiedHostTransportSetV1.decode(
            exactTransport,
            hostAuthorityPublicKey: trust.hostAuthorityPublicKey
        )
        let offers = try message.offers.map {
            try HarcValidatedCapabilityOfferV1($0, policy: capabilityPolicy)
        }
        return HarcValidatedHostBootstrapInfo(
            protocolVersion: version,
            displayName: message.displayName,
            hostTrust: trust,
            offers: offers,
            verifiedTransportSet: verifiedTransport,
            serverTimeUnixMilliseconds: message.serverTimeUnixMs,
            tlsSPKISHA256: response.serverTrust.leaf.fullDERSPKISHA256
        )
    }

    static func validateServerTrust(
        _ accepted: HarcAcceptedServerTrust,
        expectation: HarcBootstrapTrustExpectation
    ) throws -> RecordingHostTrustBinding {
        guard accepted.hostTrust == expectation.hostTrust else {
            throw HarcBootstrapClientError.hostTrustMismatch
        }
        if let exact = expectation.requiredExactTransportSet,
           accepted.exactTransportSet != exact {
            throw HarcBootstrapClientError.responseTransportSetMismatch
        }
        return accepted.hostTrust
    }

    static func validateProtocol(
        present: Bool,
        _ value: Harc_V1_ProtocolVersionV1,
        knownFields: Set<UInt32>,
        field: String,
        policy: HarcProtobufCompatibilityPolicy
    ) throws -> HarcProtocolVersion {
        guard present else {
            throw HarcProtobufConversionError.missingField(field)
        }
        return try policy.validate(
            value,
            knownCriticalFieldNumbers: knownFields
        ).0
    }

    static func validateGrant(
        _ exactBytes: Data,
        hostTrust: RecordingHostTrustBinding,
        expectedDevicePublicKey: P256X963PublicKey,
        allowedScopes: Set<AuthorizationScope>?,
        atUnixMilliseconds now: UInt64,
        compatibility: HarcProtobufCompatibilityPolicy
    ) throws -> ValidatedDeviceGrantEvidence {
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            exactBytes,
            using: hostTrust.hostAuthorityPublicKey,
            compatibility: compatibility,
            purpose: .historicalEvidence
        )
        guard case .deviceGrant(_, let claims) = authenticated.payload else {
            throw HarcBootstrapClientError.invalidResponse(field: "deviceGrantType")
        }
        guard claims.libraryID == hostTrust.libraryID else {
            throw HarcBootstrapClientError.grantBindingMismatch(field: "libraryID")
        }
        guard claims.hostAuthorityID == hostTrust.hostAuthorityID else {
            throw HarcBootstrapClientError.grantBindingMismatch(field: "hostAuthorityID")
        }
        guard claims.devicePublicKey == expectedDevicePublicKey,
              claims.deviceID == expectedDevicePublicKey.deviceID else {
            throw HarcBootstrapClientError.grantBindingMismatch(field: "devicePublicKey")
        }
        if let allowedScopes,
           !Set(claims.scopes).isSubset(of: allowedScopes) {
            throw HarcBootstrapClientError.grantBindingMismatch(field: "scopes")
        }
        let nowDate = Date(timeIntervalSince1970: Double(now) / 1_000)
        guard claims.issuedAt <= nowDate,
              claims.expiresAt.map({ nowDate < $0 }) ?? true else {
            throw HarcBootstrapClientError.grantBindingMismatch(field: "validity")
        }
        return try ValidatedDeviceGrantEvidence(
            hostTrust: hostTrust,
            claims: claims,
            status: .active,
            exactSignedBytes: exactBytes
        )
    }
}
