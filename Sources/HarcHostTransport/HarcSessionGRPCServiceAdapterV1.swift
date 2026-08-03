import Foundation
import GRPCCore
import HarcHost
import HarcProtocol

protocol HarcSessionRPCApplication: Sendable {
    func beginSession(
        _ request: BeginHostSessionRequest
    ) async throws -> BeginHostSessionResponse

    func openSession(
        _ request: OpenHostSessionRequest
    ) async throws -> HostOpenedSession
}

extension HarcSessionService: HarcSessionRPCApplication {}

/// Generated gRPC Swift 2 service edge for challenge/response session setup.
/// It preserves the exact negotiated-capability payload from the wire; current
/// grant, proof, epoch, and session admission decisions stay in HarcHost.
public struct HarcSessionGRPCServiceAdapterV1:
    Harc_V1_SessionService.ServiceProtocol, Sendable
{
    private let application: any HarcSessionRPCApplication
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let servedIdentityBinding: HarcGRPCServedIdentityBinding
    private let sourceBindingProvider: HarcHostRPCSourceBindingProvider
    private let preauthenticationGate: HarcBootstrapPreauthenticationGate
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        service: HarcSessionService,
        capabilityPolicy: HarcCapabilityPolicyV1,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.application = service
        self.capabilityPolicy = capabilityPolicy
        self.servedIdentityBinding = servedIdentityBinding
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = compatibility
    }

    init(
        application: any HarcSessionRPCApplication,
        capabilityPolicy: HarcCapabilityPolicyV1,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.application = application
        self.capabilityPolicy = capabilityPolicy
        self.servedIdentityBinding = servedIdentityBinding
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = compatibility
    }

    public func beginSession(
        request: ServerRequest<Harc_V1_BeginSessionRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_BeginSessionResponseV1> {
        try await beginSession(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    public func openSession(
        request: ServerRequest<Harc_V1_OpenSessionRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_OpenSessionResponseV1> {
        try await openSession(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    func beginSession(
        request: ServerRequest<Harc_V1_BeginSessionRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_BeginSessionResponseV1> {
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
                    let validated = try HarcValidatedBeginSessionRequestV1(
                        request.message,
                        compatibility: compatibility
                    )
                    let applicationRequest = try BeginHostSessionRequest(
                        protocolMajor: validated.protocolVersion.major,
                        protocolMinor: validated.protocolVersion.minor,
                        claimedDeviceID: validated.claimedDeviceID,
                        grantID: validated.grantID,
                        source: source,
                        tlsSPKISHA256: tlsSPKISHA256
                    )
                    return (validated, applicationRequest)
                }
            let response = try await application.beginSession(
                applicationRequest
            )

            var exactGrant = Harc_V1_ExactSignedObjectV1()
            exactGrant.framedBytes = response.exactSignedGrantBytes
            var wire = Harc_V1_BeginSessionResponseV1()
            wire.protocol = validated.protocolVersion.protobufV1()
            wire.challengeID = Harc_V1_ChallengeIDV1(response.challengeID)
            wire.serverNonce = response.serverNonce
            wire.expiresAtUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.expiresAt)
            wire.exactSignedDeviceGrant = exactGrant
            wire.serverTimeUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.serverTime)
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }

    func openSession(
        request: ServerRequest<Harc_V1_OpenSessionRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_OpenSessionResponseV1> {
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
                    let validated = try HarcValidatedOpenSessionRequestV1(
                        request.message,
                        capabilityPolicy: capabilityPolicy
                    )
                    let capabilities = validated.negotiatedCapabilities
                    let applicationRequest = try OpenHostSessionRequest(
                        protocolMajor: validated.protocolVersion.major,
                        protocolMinor: validated.protocolVersion.minor,
                        challengeID: validated.challengeID,
                        clientNonce: validated.clientNonce,
                        exactCapabilitiesBytes:
                            capabilities.exactPayload.exactBytes,
                        capabilitiesSHA256: capabilities.exactSHA256,
                        clientSignature: validated.clientSignature,
                        tlsSPKISHA256: tlsSPKISHA256
                    )
                    return (validated, applicationRequest)
                }
            let response = try await application.openSession(
                applicationRequest
            )

            var wire = Harc_V1_OpenSessionResponseV1()
            wire.protocol = validated.protocolVersion.protobufV1()
            wire.sessionCredential = response.credential
            wire.issuedAtUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.issuedAt)
            wire.expiresAtUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.expiresAt)
            wire.serverTimeUnixMs = wire.issuedAtUnixMs
            wire.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: response.capabilitiesSHA256
            )
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }
}
