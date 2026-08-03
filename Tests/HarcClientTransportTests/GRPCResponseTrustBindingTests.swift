#if canImport(Network)
import Foundation
import GRPCCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import Testing
@testable import HarcClientTransport

@Suite("gRPC response-to-TLS trust binding")
struct GRPCResponseTrustBindingTests {
    @Test("stream initialization rejects a channel without a physical parent")
    func missingParentConnection() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        #expect(throws: HarcGRPCResponseTrustBindingError
            .missingParentConnectionChannel) {
            try HarcGRPCResponseTrustBridge.initializeStream(
                channel: channel,
                codec: HarcGRPCResponseTrustCodec()
            ).wait()
        }
    }

    @Test("a response keeps its parent connection trust after another handshake")
    func exactConnectionBinding() throws {
        let fixture = try BootstrapClientFixture()
        let trustA = fixture.acceptedTrust
        let tlsKeyB = try TransportTrustFixtures.tlsKey(0x42)
        let transportB = try TransportTrustFixtures.transportSet(
            authorityKey: fixture.authorityKey,
            tlsKeys: [tlsKeyB],
            epoch: trustA.transportSetEpoch + 1
        )
        let leafB = try HarcTLSLeafDERParser.parse(
            TransportTrustFixtures.leafCertificate(
                tlsKey: tlsKeyB,
                exactTransportSet: transportB.exactSignedBytes
            )
        )
        let trustB = HarcAcceptedServerTrust(
            hostTrust: trustA.hostTrust,
            transportSetEpoch: transportB.transportSet.setEpoch,
            exactTransportSet: transportB.exactSignedBytes,
            leaf: leafB
        )
        let codec = HarcGRPCResponseTrustCodec()

        let sealedA = try codec.seal(trustA)
        let sealedB = try codec.seal(trustB)

        #expect(sealedA != sealedB)
        #expect(
            try codec.trust(from: responseTrustMetadata(sealedA)) == trustA
        )
        #expect(
            try codec.trust(from: responseTrustMetadata(sealedB)) == trustB
        )
    }

    @Test("response binding metadata is locally authenticated and fail-closed")
    func bindingValidation() throws {
        let fixture = try BootstrapClientFixture()
        let codec = HarcGRPCResponseTrustCodec()

        #expect(throws: HarcGRPCResponseTrustBindingError
            .missingResponseBinding) {
            try codec.trust(from: Metadata())
        }

        var malformed = Metadata()
        malformed.addBinary(
            [0x01],
            forKey: HarcGRPCResponseTrustCodec.metadataKey
        )
        #expect(throws: HarcGRPCResponseTrustBindingError
            .malformedResponseBinding) {
            try codec.trust(from: malformed)
        }

        var forgedString = Metadata()
        forgedString.addString(
            Data(repeating: 0xF1, count: 32).base64EncodedString(),
            forKey: HarcGRPCResponseTrustCodec.metadataKey
        )
        #expect(throws: HarcGRPCResponseTrustBindingError
            .malformedResponseBinding) {
            try codec.trust(from: forgedString)
        }

        let sealed = try codec.seal(fixture.acceptedTrust)
        var duplicate = Metadata()
        duplicate.addBinary(
            Array(sealed),
            forKey: HarcGRPCResponseTrustCodec.metadataKey
        )
        duplicate.addBinary(
            Array(sealed),
            forKey: HarcGRPCResponseTrustCodec.metadataKey
        )
        #expect(throws: HarcGRPCResponseTrustBindingError
            .duplicateResponseBinding(count: 2)) {
            try codec.trust(from: duplicate)
        }

        let valid = responseTrustMetadata(sealed)
        #expect(try codec.trust(from: valid) == fixture.acceptedTrust)
        // Stateless envelopes intentionally carry no replay/cleanup state.
        #expect(try codec.trust(from: valid) == fixture.acceptedTrust)

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        #expect(throws: HarcGRPCResponseTrustBindingError
            .invalidResponseBindingAuthentication) {
            try codec.trust(from: responseTrustMetadata(tampered))
        }

        let otherOwnerCodec = HarcGRPCResponseTrustCodec()
        #expect(throws: HarcGRPCResponseTrustBindingError
            .invalidResponseBindingAuthentication) {
            try otherOwnerCodec.trust(from: valid)
        }

        let inconsistentTrust = HarcAcceptedServerTrust(
            hostTrust: fixture.acceptedTrust.hostTrust,
            transportSetEpoch: fixture.acceptedTrust.transportSetEpoch,
            exactTransportSet: Data([0xB2]),
            leaf: fixture.acceptedTrust.leaf
        )
        #expect(throws: HarcGRPCResponseTrustBindingError
            .responseTrustBindingMismatch) {
            try codec.seal(inconsistentTrust)
        }
    }

    @Test("peer values are replaced on initial headers and scrubbed from trailers")
    func responseHeaderReplacement() throws {
        let fixture = try BootstrapClientFixture()
        let codec = HarcGRPCResponseTrustCodec()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HarcGRPCResponseTrustMetadataHandler(
                trust: fixture.acceptedTrust,
                codec: codec
            )
        )
        defer { _ = try? channel.finish() }

        var initial = HPACKHeaders()
        initial.add(name: ":status", value: "200")
        initial.add(
            name: HarcGRPCResponseTrustCodec.metadataKey,
            value: Data(repeating: 0xA1, count: 32).base64EncodedString()
        )
        initial.add(
            name: HarcGRPCResponseTrustCodec.metadataKey,
            value: Data(repeating: 0xA2, count: 32).base64EncodedString()
        )
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(.init(headers: initial))
        )

        let readInitial: HTTP2Frame.FramePayload? = try channel.readInbound(
            as: HTTP2Frame.FramePayload.self
        )
        let forwardedInitial = try #require(readInitial)
        guard case .headers(let initialHeaders) = forwardedInitial else {
            Issue.record("Expected initial response headers")
            return
        }
        let injected = initialHeaders.headers[
            HarcGRPCResponseTrustCodec.metadataKey
        ]
        #expect(injected.count == 1)
        let encodedEnvelope = try #require(injected.first)
        let envelope = try #require(Data(base64Encoded: encodedEnvelope))
        #expect(
            try codec.trust(from: responseTrustMetadata(envelope))
                == fixture.acceptedTrust
        )

        var trailers = HPACKHeaders()
        trailers.add(
            name: HarcGRPCResponseTrustCodec.metadataKey,
            value: "peer-controlled"
        )
        trailers.add(name: "grpc-status", value: "0")
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(
                .init(headers: trailers, endStream: true)
            )
        )

        let readTrailers: HTTP2Frame.FramePayload? = try channel.readInbound(
            as: HTTP2Frame.FramePayload.self
        )
        let forwardedTrailers = try #require(readTrailers)
        guard case .headers(let trailerHeaders) = forwardedTrailers else {
            Issue.record("Expected response trailers")
            return
        }
        #expect(
            trailerHeaders.headers[
                HarcGRPCResponseTrustCodec.metadataKey
            ].isEmpty
        )
        #expect(trailerHeaders.headers["grpc-status"] == ["0"])
    }

    @Test("one physical connection accepts exactly one authenticated handshake")
    func immutableConnectionTrust() throws {
        let fixture = try BootstrapClientFixture()
        let binding = HarcGRPCConnectionTrustBinding()

        #expect(throws: HarcGRPCResponseTrustBindingError
            .noAuthenticatedHandshake) {
            try binding.authenticatedTrust()
        }
        try binding.record(fixture.acceptedTrust)
        #expect(try binding.authenticatedTrust() == fixture.acceptedTrust)
        #expect(throws: HarcGRPCResponseTrustBindingError
            .duplicateAuthenticatedHandshake) {
            try binding.record(fixture.acceptedTrust)
        }
    }

    @Test("abandoned response envelopes cannot exhaust mutable capacity")
    func abandonedResponsesHaveNoCapacityState() throws {
        let fixture = try BootstrapClientFixture()
        let codec = HarcGRPCResponseTrustCodec()
        var first: Data?
        var last: Data?

        for index in 0 ..< 1_100 {
            let sealed = try codec.seal(fixture.acceptedTrust)
            if index == 0 {
                first = sealed
            }
            last = sealed
        }

        #expect(
            try codec.trust(from: responseTrustMetadata(try #require(first)))
                == fixture.acceptedTrust
        )
        #expect(
            try codec.trust(from: responseTrustMetadata(try #require(last)))
                == fixture.acceptedTrust
        )
    }

    @Test("trailers-only failures never receive a local trust binding")
    func trailersOnlyResponse() throws {
        let fixture = try BootstrapClientFixture()
        let codec = HarcGRPCResponseTrustCodec()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HarcGRPCResponseTrustMetadataHandler(
                trust: fixture.acceptedTrust,
                codec: codec
            )
        )
        defer { _ = try? channel.finish() }

        var trailers = HPACKHeaders()
        trailers.add(
            name: HarcGRPCResponseTrustCodec.metadataKey,
            value: Data(repeating: 0xC1, count: 32).base64EncodedString()
        )
        trailers.add(name: "grpc-status", value: "7")
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(
                .init(headers: trailers, endStream: true)
            )
        )

        let read: HTTP2Frame.FramePayload? = try channel.readInbound(
            as: HTTP2Frame.FramePayload.self
        )
        let forwarded = try #require(read)
        guard case .headers(let headers) = forwarded else {
            Issue.record("Expected trailers-only response")
            return
        }
        #expect(
            headers.headers[
                HarcGRPCResponseTrustCodec.metadataKey
            ].isEmpty
        )
        let subsequent = try codec.seal(fixture.acceptedTrust)
        #expect(
            try codec.trust(from: responseTrustMetadata(subsequent))
                == fixture.acceptedTrust
        )
    }
}

private func responseTrustMetadata(_ sealed: Data) -> Metadata {
    var metadata = Metadata()
    metadata.addBinary(
        Array(sealed),
        forKey: HarcGRPCResponseTrustCodec.metadataKey
    )
    return metadata
}
#endif
