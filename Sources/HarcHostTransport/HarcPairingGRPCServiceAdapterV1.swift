import Foundation
import GRPCCore
import HarcHost
import HarcIdentity
import HarcProtocol

protocol HarcPairingClaimRPCApplication: Sendable {
    func beginPairingClaim(
        _ request: BeginHostPairingClaimRequest
    ) async throws -> BeginHostPairingClaimResponse

    func provePairingClaim(
        _ request: ProveHostPairingClaimRequest
    ) async throws -> HostPairingClaimProofResponse

    func pairingStatus(
        claimID: UUID,
        claimantToken: Data
    ) async throws -> HostPairingClaimStatus
}

extension HarcPairingClaimService: HarcPairingClaimRPCApplication {}

/// Generated gRPC Swift 2 service edge for the ticket-bound pairing flow.
/// Protobuf validation and metadata decoding happen here; reservation, proof,
/// approval state, rate limits, and all authorization decisions remain in
/// HarcPairingClaimService.
public struct HarcPairingGRPCServiceAdapterV1:
    Harc_V1_PairingService.ServiceProtocol, Sendable
{
    private let application: any HarcPairingClaimRPCApplication
    private let hostAuthorityPublicKey: P256X963PublicKey
    private let servedIdentityBinding: HarcGRPCServedIdentityBinding
    private let sourceBindingProvider: HarcHostRPCSourceBindingProvider
    private let preauthenticationGate: HarcBootstrapPreauthenticationGate
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        service: HarcPairingClaimService,
        hostAuthorityPublicKey: P256X963PublicKey,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.application = service
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.servedIdentityBinding = servedIdentityBinding
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = compatibility
    }

    init(
        application: any HarcPairingClaimRPCApplication,
        hostAuthorityPublicKey: P256X963PublicKey,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.application = application
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.servedIdentityBinding = servedIdentityBinding
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = compatibility
    }

    public func beginPairingClaim(
        request: ServerRequest<Harc_V1_BeginPairingClaimRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_BeginPairingClaimResponseV1> {
        try await beginPairingClaim(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    public func provePairingClaim(
        request: ServerRequest<Harc_V1_ProvePairingClaimRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ProvePairingClaimResponseV1> {
        try await provePairingClaim(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    public func getPairingStatus(
        request: ServerRequest<Harc_V1_GetPairingStatusRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetPairingStatusResponseV1> {
        try await getPairingStatus(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    func beginPairingClaim(
        request: ServerRequest<Harc_V1_BeginPairingClaimRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_BeginPairingClaimResponseV1> {
        do {
            let source = try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: request.metadata,
                peer: peer,
                sourceBindingProvider: sourceBindingProvider,
                gate: preauthenticationGate
            )
            let tlsSPKISHA256 = try servedIdentityBinding
                .requireTLSSPKISHA256(
                    generationID: servedIdentityBinding.generationID
                )
            let (validated, applicationRequest) = try await
                HarcHostBootstrapGRPCServiceSupport.validateRequest(
                    source: source,
                    gate: preauthenticationGate
                ) {
                    try HarcHostBootstrapGRPCServiceSupport
                        .validateControlRequestBytes(
                            try request.message.serializedData()
                        )
                    let validated = try HarcValidatedBeginPairingClaimRequestV1(
                        request.message,
                        compatibility: compatibility
                    )
                    let context = try HostPairingClaimContext(
                        protocolMajor: validated.protocolVersion.major,
                        protocolMinor: validated.protocolVersion.minor,
                        hostAuthorityPublicKey: hostAuthorityPublicKey,
                        tlsSPKISHA256: tlsSPKISHA256
                    )
                    let applicationRequest = try BeginHostPairingClaimRequest(
                        ticketID: validated.ticketID,
                        ticketSecret: validated.ticketSecret,
                        clientNonce: validated.clientNonce,
                        devicePublicKey: validated.devicePublicKey,
                        requestedScopes: validated.requestedScopes,
                        deviceLabel: validated.deviceLabel,
                        source: source,
                        context: context
                    )
                    return (validated, applicationRequest)
                }
            let response = try await application.beginPairingClaim(
                applicationRequest
            )

            var wire = Harc_V1_BeginPairingClaimResponseV1()
            wire.protocol = validated.protocolVersion.protobufV1()
            wire.claimID = Harc_V1_ClaimIDV1(response.claimID)
            wire.hostNonce = response.hostNonce
            wire.claimantToken = response.claimantToken
            wire.expiresAtUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.expiresAt)
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }

    func provePairingClaim(
        request: ServerRequest<Harc_V1_ProvePairingClaimRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_ProvePairingClaimResponseV1> {
        do {
            let source = try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: request.metadata,
                peer: peer,
                sourceBindingProvider: sourceBindingProvider,
                gate: preauthenticationGate
            )
            _ = try servedIdentityBinding.requireTLSSPKISHA256(
                generationID: servedIdentityBinding.generationID
            )
            let (validated, claimantToken) = try await
                HarcHostBootstrapGRPCServiceSupport.validateRequest(
                    source: source,
                    gate: preauthenticationGate
                ) {
                    try HarcHostBootstrapGRPCServiceSupport
                        .validateControlRequestBytes(
                            try request.message.serializedData()
                        )
                    let token = try HarcHostBootstrapGRPCServiceSupport
                        .pairingClaimantToken(from: request.metadata)
                    let validated = try HarcValidatedProvePairingClaimRequestV1(
                        request.message,
                        compatibility: compatibility
                    )
                    return (validated, token)
                }
            let response = try await application.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: validated.claimID,
                    claimantToken: claimantToken,
                    clientSignature: validated.clientSignature
                )
            )

            var wire = Harc_V1_ProvePairingClaimResponseV1()
            wire.protocol = validated.protocolVersion.protobufV1()
            wire.state = .pairingClaimStatePending
            wire.expiresAtUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.expiresAt)
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }

    func getPairingStatus(
        request: ServerRequest<Harc_V1_GetPairingStatusRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_GetPairingStatusResponseV1> {
        do {
            let source = try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: request.metadata,
                peer: peer,
                sourceBindingProvider: sourceBindingProvider,
                gate: preauthenticationGate
            )
            _ = try servedIdentityBinding.requireTLSSPKISHA256(
                generationID: servedIdentityBinding.generationID
            )
            let (validated, claimantToken) = try await
                HarcHostBootstrapGRPCServiceSupport.validateRequest(
                    source: source,
                    gate: preauthenticationGate
                ) {
                    try HarcHostBootstrapGRPCServiceSupport
                        .validateControlRequestBytes(
                            try request.message.serializedData()
                        )
                    let token = try HarcHostBootstrapGRPCServiceSupport
                        .pairingClaimantToken(from: request.metadata)
                    let validated = try HarcValidatedGetPairingStatusRequestV1(
                        request.message,
                        compatibility: compatibility
                    )
                    return (validated, token)
                }
            let status = try await application.pairingStatus(
                claimID: validated.claimID,
                claimantToken: claimantToken
            )

            var wire = Harc_V1_GetPairingStatusResponseV1()
            wire.protocol = validated.protocolVersion.protobufV1()
            switch status {
            case .pending:
                wire.state = .pairingClaimStatePending
            case .approved(let exactGrantBytes):
                wire.state = .pairingClaimStateApproved
                var exactGrant = Harc_V1_ExactSignedObjectV1()
                exactGrant.framedBytes = exactGrantBytes
                wire.exactSignedDeviceGrant = exactGrant
            case .denied:
                wire.state = .pairingClaimStateDenied
            case .expired:
                wire.state = .pairingClaimStateExpired
            case .cancelled:
                wire.state = .pairingClaimStateCancelled
            }
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }
}
