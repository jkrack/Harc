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

@Suite("HostInfo gRPC service adapter")
struct HostInfoGRPCServiceAdapterTests {
    @Test("GetHostInfo maps public facts, source binding, and exact transport bytes")
    func getHostInfoProjection() async throws {
        let hostKey = SoftwareP256SigningKey()
        let libraryID = LibraryID.random()
        let sourceBytes = bytes(0x11)
        let transportBytes = Data("HARCSO1\0transport".utf8)
        let offer = try projectedOffer()
        let application = HostInfoRPCApplicationFake(
            hostInfo: GetHostInfoResponse(
                protocolMajor: 1,
                protocolMinor: 0,
                displayName: "Studio Harc",
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                offers: [offer],
                exactSignedTransportSet: transportBytes,
                serverTime: Date(timeIntervalSince1970: 1_800_000_000.125)
            ),
            negotiation: try negotiationResponse(transportBytes: transportBytes)
        )
        let adapter = HarcHostInfoGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            sourceBindingProvider: sourceProvider(sourceBytes),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        let _: any Harc_V1_HostInfoService.ServiceProtocol = adapter
        var message = Harc_V1_GetHostInfoRequestV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()

        let response = try await adapter.getHostInfo(
            request: ServerRequest(metadata: [:], message: message),
            peer: HarcHostRPCPeer(
                remotePeer: "ipv4:192.0.2.10:50000",
                localPeer: "ipv4:192.0.2.20:443"
            )
        ).message
        let captured = try #require(await application.capturedHostInfo())

        #expect(captured.source.bindingSHA256 == sourceBytes)
        #expect(response.displayName == "Studio Harc")
        #expect(try response.libraryID.domainValue() == libraryID)
        #expect(
            try response.hostAuthorityID.domainValue()
                == hostKey.publicKey.hostAuthorityID
        )
        #expect(response.hostAuthorityPublicKeyX963 == hostKey.publicKey.rawBytes)
        #expect(response.offers.count == 1)
        #expect(response.exactSignedTransportSet.framedBytes == transportBytes)
        #expect(response.serverTimeUnixMs == 1_800_000_000_125)
    }

    @Test("NegotiateCapabilities validates input and preserves exact payload/hash")
    func negotiationProjection() async throws {
        let transportBytes = Data("HARCSO1\0transport".utf8)
        let negotiation = try negotiationResponse(transportBytes: transportBytes)
        let hostKey = SoftwareP256SigningKey()
        let application = HostInfoRPCApplicationFake(
            hostInfo: GetHostInfoResponse(
                protocolMajor: 1,
                protocolMinor: 0,
                displayName: "Harc",
                libraryID: .random(),
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                offers: [try projectedOffer()],
                exactSignedTransportSet: transportBytes,
                serverTime: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            negotiation: negotiation
        )
        let sourceBytes = bytes(0x21)
        let adapter = HarcHostInfoGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            sourceBindingProvider: sourceProvider(sourceBytes),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        var message = Harc_V1_NegotiateCapabilitiesRequestV1()
        message.protocol = HarcProtocolVersion.v1.protobufV1()
        message.clientOffer = offer()

        let response = try await adapter.negotiateCapabilities(
            request: ServerRequest(metadata: [:], message: message),
            peer: HarcHostRPCPeer(remotePeer: "remote", localPeer: "local")
        ).message
        let captured = try #require(await application.capturedNegotiation())

        #expect(captured.source.bindingSHA256 == sourceBytes)
        #expect(captured.clientOffer.supportedFeatureIDs == ["transfer.chunk.v1"])
        #expect(
            response.exactNegotiatedCapabilitiesPayload
                == negotiation.exactNegotiatedCapabilities
        )
        #expect(
            response.negotiatedCapabilitiesSha256.value
                == negotiation.negotiatedCapabilitiesSHA256
        )
        #expect(response.exactSignedTransportSet.framedBytes == transportBytes)
    }

    @Test("malformed public requests fail before the application is called")
    func malformedRequest() async throws {
        let hostKey = SoftwareP256SigningKey()
        let application = HostInfoRPCApplicationFake(
            hostInfo: GetHostInfoResponse(
                protocolMajor: 1,
                protocolMinor: 0,
                displayName: "Harc",
                libraryID: .random(),
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                offers: [try projectedOffer()],
                exactSignedTransportSet: bytes(0x31),
                serverTime: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            negotiation: try negotiationResponse(transportBytes: bytes(0x31))
        )
        let adapter = HarcHostInfoGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            sourceBindingProvider: sourceProvider(bytes(0x32)),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )

        do {
            _ = try await adapter.getHostInfo(
                request: ServerRequest(
                    metadata: [:],
                    message: Harc_V1_GetHostInfoRequestV1()
                ),
                peer: HarcHostRPCPeer(remotePeer: "remote", localPeer: "local")
            )
            Issue.record("Expected missing protocol to fail")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
        }
        #expect(await application.capturedHostInfo() == nil)
    }

    @Test("oversized unknown protobuf fields are rejected at the 1 MiB control edge")
    func oversizedUnknownFields() async throws {
        let hostKey = SoftwareP256SigningKey()
        let application = HostInfoRPCApplicationFake(
            hostInfo: GetHostInfoResponse(
                protocolMajor: 1,
                protocolMinor: 0,
                displayName: "Harc",
                libraryID: .random(),
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                offers: [try projectedOffer()],
                exactSignedTransportSet: bytes(0x41),
                serverTime: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            negotiation: try negotiationResponse(transportBytes: bytes(0x41))
        )
        let adapter = HarcHostInfoGRPCServiceAdapterV1(
            application: application,
            capabilityPolicy: try capabilityPolicy(),
            sourceBindingProvider: sourceProvider(bytes(0x42)),
            preauthenticationGate: HarcBootstrapPreauthenticationGate()
        )
        var valid = Harc_V1_GetHostInfoRequestV1()
        valid.protocol = HarcProtocolVersion.v1.protobufV1()
        var encoded = try valid.serializedData()
        encoded.append(0x7a) // Unknown field 15, length-delimited.
        encoded.append(contentsOf: varint(
            UInt64(HarcHostBootstrapGRPCServiceSupport.maximumControlRequestBytes)
        ))
        encoded.append(Data(
            repeating: 0x55,
            count: HarcHostBootstrapGRPCServiceSupport.maximumControlRequestBytes
        ))
        let oversized = try Harc_V1_GetHostInfoRequestV1(
            serializedBytes: encoded
        )
        #expect(
            try oversized.serializedData().count
                > HarcHostBootstrapGRPCServiceSupport.maximumControlRequestBytes
        )

        do {
            _ = try await adapter.getHostInfo(
                request: ServerRequest(metadata: [:], message: oversized),
                peer: HarcHostRPCPeer(
                    remotePeer: "ipv4:192.0.2.10:50000",
                    localPeer: "ipv4:192.0.2.20:443"
                )
            )
            Issue.record("Expected oversized unknown fields to fail")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
            #expect(error.message == "The request is malformed.")
        }
        #expect(await application.capturedHostInfo() == nil)
    }

    @Test("raw control ceiling precedes duplicate-field protobuf canonicalization")
    func rawCeilingPrecedesProtobufCanonicalization() throws {
        var canonical = Harc_V1_GetHostInfoRequestV1()
        canonical.protocol = HarcProtocolVersion.v1.protobufV1()
        let oneEncoding = try canonical.serializedData()
        let limit = HarcHostBootstrapGRPCServiceSupport.maximumControlRequestBytes
        let repetitionCount = limit / oneEncoding.count + 1
        var duplicateKnownFields = Data()
        duplicateKnownFields.reserveCapacity(oneEncoding.count * repetitionCount)
        for _ in 0..<repetitionCount {
            duplicateKnownFields.append(oneEncoding)
        }

        let decoded = try Harc_V1_GetHostInfoRequestV1(
            serializedBytes: duplicateKnownFields
        )

        #expect(duplicateKnownFields.count > limit)
        #expect(try decoded.serializedData().count <= limit)
        #expect(
            HarcGRPCRequestPayloadGate.maximumPayloadBytes(
                for: "/harc.v1.HostInfoService/GetHostInfo"
            ) == limit
        )
        let sourceBindingProvider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0xA2, count: 32)
        )
        #expect(
            HarcGRPCServerRuntime.bootstrapTransportConfiguration(
                sourceBindingProvider: sourceBindingProvider
            ).rpc
                .maxRequestPayloadSize
                == HarcGRPCRequestPayloadGate.maximumAudioPayloadBytes
        )
    }

    private func projectedOffer() throws -> HostInfoCapabilityOffer {
        try HostInfoCapabilityOffer(
            protocolMajor: 1,
            minimumProtocolMinor: 0,
            maximumProtocolMinor: 0,
            requiredFeatureIDs: ["transfer.chunk.v1"],
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            supportedCanonicalFormats: [.harcV1]
        )
    }

    private func offer() -> Harc_V1_CapabilityOfferV1 {
        var value = Harc_V1_CapabilityOfferV1()
        value.protocolMajor = 1
        value.minimumProtocolMinor = 0
        value.maximumProtocolMinor = 0
        value.requirements.requiredFeatures = ["transfer.chunk.v1"]
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

    private func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: ["transfer.chunk.v1"]
            ),
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func negotiationResponse(
        transportBytes: Data
    ) throws -> NegotiateHostCapabilitiesResponse {
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.selectedFeatureIds = ["transfer.chunk.v1"]
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let exact = try value.serializedData()
        return NegotiateHostCapabilitiesResponse(
            protocolMajor: 1,
            protocolMinor: 0,
            exactNegotiatedCapabilities: exact,
            negotiatedCapabilitiesSHA256: Data(SHA256.hash(data: exact)),
            exactSignedTransportSet: transportBytes,
            serverTime: Date(timeIntervalSince1970: 1_800_000_000.5)
        )
    }

    private func sourceProvider(
        _ sourceBytes: Data
    ) -> HarcHostRPCSourceBindingProvider {
        HarcHostRPCSourceBindingProvider { _ in
            try HostPreauthenticationSource(bindingSHA256: sourceBytes)
        }
    }

    private func bytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}

private actor HostInfoRPCApplicationFake: HarcHostInfoRPCApplication {
    private let hostInfo: GetHostInfoResponse
    private let negotiation: NegotiateHostCapabilitiesResponse
    private var hostInfoRequest: GetHostInfoRequest?
    private var negotiationRequest: NegotiateHostCapabilitiesRequest?

    init(
        hostInfo: GetHostInfoResponse,
        negotiation: NegotiateHostCapabilitiesResponse
    ) {
        self.hostInfo = hostInfo
        self.negotiation = negotiation
    }

    func getHostInfo(
        _ request: GetHostInfoRequest
    ) async throws -> GetHostInfoResponse {
        hostInfoRequest = request
        return hostInfo
    }

    func negotiateCapabilities(
        _ request: NegotiateHostCapabilitiesRequest
    ) async throws -> NegotiateHostCapabilitiesResponse {
        negotiationRequest = request
        return negotiation
    }

    func capturedHostInfo() -> GetHostInfoRequest? { hostInfoRequest }

    func capturedNegotiation() -> NegotiateHostCapabilitiesRequest? {
        negotiationRequest
    }
}
