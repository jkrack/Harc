import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import Testing

@Suite("Host transport set and pairing ticket codec")
struct PairingTicketCodecTests {
    @Test("transport payload and signed frame round-trip without byte rewriting")
    func transportRoundTrip() throws {
        let hostKey = ProtocolCodecFixtures.key(10)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(100))
        let verified = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )
        let payloadBytes = verified.transportSet.encoded()


        #expect(payloadBytes.prefix(8) == Data("HARCTS1\0".utf8))
        #expect(payloadBytes.count == 8 + 4 + 16 + 32 + 8 + 8 + 1 + 2 * 48)
        #expect(try HostTransportSetV1.decode(payloadBytes) == verified.transportSet)
        #expect(verified.signedObject.exactPayloadBytes == payloadBytes)
        #expect(try verified.validatedEvidence().exactSignedBytes == verified.exactSignedBytes)
    }

    @Test("transport frame signature is verified before malformed payload interpretation")
    func transportSignaturePrecedesPayloadDecode() throws {
        let hostKey = ProtocolCodecFixtures.key(14)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(140))
        let malformedPayload = Data([0xff])
        let header = try HarcSignedEnvelopeV1(
            messageType: .hostTransportSet,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: nil,
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .hostTransportSet,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(malformedPayload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: malformedPayload,
            using: hostKey
        )
        var tampered = object.exactFramedBytes
        tampered[tampered.count - 1] ^= 1

        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try VerifiedHostTransportSetV1.decode(
                tampered,
                hostAuthorityPublicKey: hostKey.publicKey
            )
        }
    }

    @Test("transport entries enforce canonical order, uniqueness, lifetime, and skew")
    func transportEntryRules() throws {
        let hostKey = ProtocolCodecFixtures.key(11)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(110))
        let earlier = try HostTransportEntryV1(
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(1),
            notBeforeUnixMilliseconds: 1_000,
            notAfterUnixMilliseconds: 2_000
        )
        let later = try HostTransportEntryV1(
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(2),
            notBeforeUnixMilliseconds: 1_000,
            notAfterUnixMilliseconds: 2_000
        )
        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(field: "transportEntries")) {
            try HostTransportSetV1(
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                setEpoch: 1,
                issuedAtUnixMilliseconds: 1_000,
                entries: [later, earlier]
            )
        }
        #expect(throws: HarcProtocolCodecError.duplicateValue(
            field: "transportEntries.tlsSPKISHA256"
        )) {
            try HostTransportSetV1(
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                setEpoch: 1,
                issuedAtUnixMilliseconds: 1_000,
                entries: [earlier, earlier]
            )
        }
        #expect(earlier.isValid(atUnixMilliseconds: 700))
        #expect(earlier.isValid(atUnixMilliseconds: 302_000))
        #expect(!earlier.isValid(atUnixMilliseconds: 302_001))
        #expect(throws: HarcProtocolCodecError.invalidTimeRange(field: "transportEntryLifetime")) {
            try HostTransportEntryV1(
                tlsSPKISHA256: ProtocolCodecFixtures.bytes(3),
                notBeforeUnixMilliseconds: 1,
                notAfterUnixMilliseconds: 1
                    + HarcProtocolLimits.transportEntryLifetimeMilliseconds + 1
            )
        }
    }

    @Test("ticket binary and URI preserve the authority-authenticated transport object")
    func ticketAndURIRoundTrip() throws {
        let hostKey = ProtocolCodecFixtures.key(12)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(120))
        let verified = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )
        let endpoints = [
            try PairingEndpointV1.bonjourInstance("Jordan’s Mac Mini"),
            try PairingEndpointV1.dnsHost("harc-host.local", port: 443),
            try PairingEndpointV1.ipv4(Data([192, 168, 1, 4]), port: 443),
            try PairingEndpointV1.ipv6(Data(repeating: 0x11, count: 16), port: 443),
        ]
        let ticket = try PairingTicketV1(
            ticketID: ProtocolCodecFixtures.uuid(121),
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            verifiedTransportSet: verified,
            ticketSecret: ProtocolCodecFixtures.bytes(0x31, count: 24),
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 120_000,
            endpoints: endpoints
        )
        let binary = try ticket.encoded()
        let uri = try ticket.encodedURI()
        let decoded = try PairingTicketV1.decode(
            binary,
            atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
        )
        let uriDecoded = try PairingTicketV1.decodeURI(
            uri,
            atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
        )

        #expect(binary.prefix(9) == Data("HARCTKT1\0".utf8))
        #expect(binary.count <= 1_024)
        #expect(uri.hasPrefix("harc-pair://v1/"))
        #expect(uri.utf8.count <= 1_400)
        #expect(!uri.contains("="))
        #expect(decoded == ticket)
        #expect(uriDecoded == ticket)
        #expect(decoded.exactTransportObjectBytes == verified.exactSignedBytes)
        #expect(decoded.pairingAdmissionSecret == decoded.ticketSecret)
        let expectedSecretBinding = try PairingTicketV1.ticketSecretBindingSHA256(
            ticketID: ticket.ticketID,
            secret: ticket.pairingAdmissionSecret
        )
        #expect(decoded.ticketSecretBindingSHA256 == expectedSecretBinding)
    }

    @Test("remote relay endpoint round-trips opaque binary routing only")
    func remoteRelayEndpointRoundTrip() throws {
        let route = harcEncodeBase64URL(Data(repeating: 0x11, count: 32))
        let admission = harcEncodeBase64URL(Data(repeating: 0x22, count: 32))
        let capability = harcEncodeBase64URL(Data(repeating: 0x33, count: 32))
        let relay = try PairingRelayEndpointV1(
            serviceHost: "relay.harc.example",
            hostRouteID: route,
            admissionRouteID: admission,
            capability: capability
        )
        let endpoint = try relay.pairingEndpoint()

        #expect(endpoint.kind == .remoteRelay)
        #expect(endpoint.port == 443)
        #expect(endpoint.textValue == nil)
        #expect(try PairingRelayEndpointV1.decode(endpoint) == relay)

        #expect(throws: HarcProtocolCodecError.self) {
            try PairingRelayEndpointV1(
                serviceHost: "https://relay.harc.example",
                hostRouteID: route,
                admissionRouteID: admission,
                capability: capability
            )
        }
    }

    @Test("remote relay endpoint bytes are bound into pairing admission")
    func remoteRelayEndpointAdmissionBinding() throws {
        let hostKey = ProtocolCodecFixtures.key(15)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(150))
        let verified = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )
        let route = harcEncodeBase64URL(Data(repeating: 0x11, count: 32))
        let capability = harcEncodeBase64URL(Data(repeating: 0x33, count: 32))
        let makeTicket: (UInt8) throws -> PairingTicketV1 = { admissionByte in
            let endpoint = try PairingRelayEndpointV1(
                serviceHost: "relay.harc.example",
                hostRouteID: route,
                admissionRouteID: harcEncodeBase64URL(
                    Data(repeating: admissionByte, count: 32)
                ),
                capability: capability
            ).pairingEndpoint()
            return try PairingTicketV1(
                ticketID: ProtocolCodecFixtures.uuid(151),
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                verifiedTransportSet: verified,
                ticketSecret: ProtocolCodecFixtures.bytes(0x41, count: 24),
                issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
                expiresAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 120_000,
                endpoints: [endpoint]
            )
        }
        let issued = try makeTicket(0x22)
        let redirected = try makeTicket(0x23)

        #expect(issued.pairingAdmissionSecret.count == 24)
        #expect(issued.pairingAdmissionSecret != issued.ticketSecret)
        #expect(
            issued.pairingAdmissionSecret
                != redirected.pairingAdmissionSecret
        )
        #expect(
            issued.ticketSecretBindingSHA256
                != redirected.ticketSecretBindingSHA256
        )
    }

    @Test("ticket rejects expiry, lengths, URI variants, authority tamper, and transport tamper")
    func ticketRejections() throws {
        let hostKey = ProtocolCodecFixtures.key(13)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(130))
        let verified = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )
        let endpoint = try PairingEndpointV1.dnsHost("host.local", port: 8443)
        let ticket = try PairingTicketV1(
            ticketID: ProtocolCodecFixtures.uuid(131),
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            verifiedTransportSet: verified,
            ticketSecret: ProtocolCodecFixtures.bytes(0x32, count: 24),
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 10_000,
            endpoints: [endpoint]
        )
        let binary = try ticket.encoded()
        let uri = try ticket.encodedURI()

        #expect(throws: HarcProtocolCodecError.expired(field: "PairingTicketV1")) {
            try PairingTicketV1.decode(
                binary,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 10_000
            )
        }
        #expect(throws: HarcProtocolCodecError.invalidPairingURI) {
            try PairingTicketV1.decodeURI(
                uri + "=",
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }
        #expect(throws: HarcProtocolCodecError.invalidPairingURI) {
            try PairingTicketV1.decodeURI(
                " " + uri,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }

        var wrongLength = binary
        wrongLength[10] ^= 1
        #expect(throws: HarcProtocolCodecError.self) {
            try PairingTicketV1.decode(
                wrongLength,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }

        var authorityTamper = binary
        authorityTamper[47] ^= 1
        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")) {
            try PairingTicketV1.decode(
                authorityTamper,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }

        var transportTamper = binary
        let transportOffset = 9 + 2 + 2 + 2 + 16 + 16 + 32 + 65 + 2
        transportTamper[transportOffset + verified.exactSignedBytes.count - 1] ^= 1
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try PairingTicketV1.decode(
                transportTamper,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }

        var unknownEndpoint = binary
        let endpointOffset = binary.count - endpoint.value.count - 4
        unknownEndpoint[endpointOffset] = 0
        #expect(throws: HarcProtocolCodecError.invalidEndpoint(field: "endpoints[0].kind")) {
            try PairingTicketV1.decode(
                unknownEndpoint,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            )
        }
    }

    @Test("endpoint canonicalization and total ticket limits fail closed")
    func endpointAndSizeRules() throws {
        #expect(throws: HarcProtocolCodecError.invalidEndpoint(field: "dns.value")) {
            try PairingEndpointV1.dnsHost("Host.Local", port: 443)
        }
        #expect(throws: HarcProtocolCodecError.invalidEndpoint(field: "bonjour.port")) {
            try PairingEndpointV1(
                kind: .bonjourInstance,
                port: 443,
                value: Data("host".utf8)
            )
        }

        let a = try PairingEndpointV1.bonjourInstance("a")
        let b = try PairingEndpointV1.bonjourInstance("b")
        let hostKey = ProtocolCodecFixtures.key(14)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(140))
        let verified = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )
        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(field: "endpoints")) {
            try PairingTicketV1(
                ticketID: ProtocolCodecFixtures.uuid(141),
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                verifiedTransportSet: verified,
                ticketSecret: ProtocolCodecFixtures.bytes(1, count: 24),
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: 2,
                endpoints: [b, a]
            )
        }

        let hugeEndpoints = [
            try PairingEndpointV1.bonjourInstance(String(repeating: "a", count: 255)),
            try PairingEndpointV1.bonjourInstance(String(repeating: "b", count: 255)),
            try PairingEndpointV1.dnsHost(
                [String](repeating: String(repeating: "c", count: 62), count: 4)
                    .joined(separator: "."),
                port: 443
            ),
        ]
        #expect(throws: HarcProtocolCodecError.self) {
            try PairingTicketV1(
                ticketID: ProtocolCodecFixtures.uuid(142),
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                verifiedTransportSet: verified,
                ticketSecret: ProtocolCodecFixtures.bytes(1, count: 24),
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: 2,
                endpoints: hugeEndpoints
            )
        }
    }
}
