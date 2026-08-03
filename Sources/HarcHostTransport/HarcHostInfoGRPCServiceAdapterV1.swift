import Foundation
import GRPCCore
import HarcHost
import HarcProtocol

protocol HarcHostInfoRPCApplication: Sendable {
    func getHostInfo(
        _ request: GetHostInfoRequest
    ) async throws -> GetHostInfoResponse

    func negotiateCapabilities(
        _ request: NegotiateHostCapabilitiesRequest
    ) async throws -> NegotiateHostCapabilitiesResponse
}

extension HarcHostInfoService: HarcHostInfoRPCApplication {}

/// Generated gRPC Swift 2 edge for the only public pre-session service.
/// Source admission and public-data policy remain in HarcHost; this adapter
/// validates protobuf and emits the exact committed transport object.
public struct HarcHostInfoGRPCServiceAdapterV1:
    Harc_V1_HostInfoService.ServiceProtocol, Sendable
{
    private let application: any HarcHostInfoRPCApplication
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let sourceBindingProvider: HarcHostRPCSourceBindingProvider
    private let preauthenticationGate: HarcBootstrapPreauthenticationGate
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        service: HarcHostInfoService,
        capabilityPolicy: HarcCapabilityPolicyV1,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate
    ) {
        self.application = service
        self.capabilityPolicy = capabilityPolicy
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = capabilityPolicy.compatibility
    }

    init(
        application: any HarcHostInfoRPCApplication,
        capabilityPolicy: HarcCapabilityPolicyV1,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate
    ) {
        self.application = application
        self.capabilityPolicy = capabilityPolicy
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
        self.compatibility = capabilityPolicy.compatibility
    }

    public func getHostInfo(
        request: ServerRequest<Harc_V1_GetHostInfoRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetHostInfoResponseV1> {
        try await getHostInfo(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    public func negotiateCapabilities(
        request: ServerRequest<Harc_V1_NegotiateCapabilitiesRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_NegotiateCapabilitiesResponseV1> {
        try await negotiateCapabilities(
            request: request,
            peer: HarcHostBootstrapGRPCServiceSupport.peer(from: context)
        )
    }

    func getHostInfo(
        request: ServerRequest<Harc_V1_GetHostInfoRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_GetHostInfoResponseV1> {
        do {
            let source = try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: request.metadata,
                peer: peer,
                sourceBindingProvider: sourceBindingProvider,
                gate: preauthenticationGate
            )
            let (_, applicationRequest) = try await
                HarcHostBootstrapGRPCServiceSupport.validateRequest(
                    source: source,
                    gate: preauthenticationGate
                ) {
                    try HarcHostBootstrapGRPCServiceSupport
                        .validateControlRequestBytes(
                            try request.message.serializedData()
                        )
                    let validated = try HarcValidatedGetHostInfoRequestV1(
                        request.message,
                        compatibility: compatibility
                    )
                    let applicationRequest = GetHostInfoRequest(
                        protocolMajor: validated.protocolVersion.major,
                        protocolMinor: validated.protocolVersion.minor,
                        source: source
                    )
                    return (validated, applicationRequest)
                }
            let response = try await application.getHostInfo(
                applicationRequest
            )

            var wire = Harc_V1_GetHostInfoResponseV1()
            wire.protocol = HarcProtocolVersion(
                major: response.protocolMajor,
                minor: response.protocolMinor
            ).protobufV1()
            wire.displayName = response.displayName
            wire.libraryID = Harc_V1_LibraryIDV1(response.libraryID)
            wire.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
                response.hostAuthorityID
            )
            wire.hostAuthorityPublicKeyX963 = response.hostAuthorityPublicKey.rawBytes
            wire.offers = try response.offers.map(
                HarcHostInfoProtocolAdapterV1.wireValue
            )
            var transportSet = Harc_V1_ExactSignedObjectV1()
            transportSet.framedBytes = response.exactSignedTransportSet
            wire.exactSignedTransportSet = transportSet
            wire.serverTimeUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.serverTime)
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }

    func negotiateCapabilities(
        request: ServerRequest<Harc_V1_NegotiateCapabilitiesRequestV1>,
        peer: HarcHostRPCPeer
    ) async throws -> ServerResponse<Harc_V1_NegotiateCapabilitiesResponseV1> {
        do {
            let source = try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: request.metadata,
                peer: peer,
                sourceBindingProvider: sourceBindingProvider,
                gate: preauthenticationGate
            )
            let (_, applicationRequest) = try await
                HarcHostBootstrapGRPCServiceSupport.validateRequest(
                    source: source,
                    gate: preauthenticationGate
                ) {
                    try HarcHostBootstrapGRPCServiceSupport
                        .validateControlRequestBytes(
                            try request.message.serializedData()
                        )
                    let validated = try
                        HarcValidatedNegotiateCapabilitiesRequestV1(
                            request.message,
                            policy: capabilityPolicy
                        )
                    let applicationRequest = try
                        NegotiateHostCapabilitiesRequest(
                            protocolMajor: validated.protocolVersion.major,
                            protocolMinor: validated.protocolVersion.minor,
                            clientOffer: try HarcHostInfoProtocolAdapterV1
                                .project(validated.clientOffer),
                            source: source
                        )
                    return (validated, applicationRequest)
                }
            let response = try await application.negotiateCapabilities(
                applicationRequest
            )

            var wire = Harc_V1_NegotiateCapabilitiesResponseV1()
            wire.protocol = HarcProtocolVersion(
                major: response.protocolMajor,
                minor: response.protocolMinor
            ).protobufV1()
            wire.exactNegotiatedCapabilitiesPayload =
                response.exactNegotiatedCapabilities
            wire.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: response.negotiatedCapabilitiesSHA256
            )
            var transportSet = Harc_V1_ExactSignedObjectV1()
            transportSet.framedBytes = response.exactSignedTransportSet
            wire.exactSignedTransportSet = transportSet
            wire.serverTimeUnixMs = try HarcHostBootstrapGRPCServiceSupport
                .unixMilliseconds(response.serverTime)
            return ServerResponse(message: wire)
        } catch {
            throw HarcHostBootstrapGRPCServiceSupport.mapError(error)
        }
    }
}
