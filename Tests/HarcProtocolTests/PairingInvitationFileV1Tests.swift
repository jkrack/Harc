import Foundation
import HarcDomain
@testable import HarcProtocol
import Testing

@Suite("Pairing invitation file")
struct PairingInvitationFileV1Tests {
    @Test("exact canonical URI bytes round-trip without rewriting")
    func exactRoundTrip() throws {
        let ticket = try makeTicket()
        let uri = try ticket.encodedURI()
        let exactBytes = try PairingInvitationFileV1.encode(
            pairingURI: uri,
            atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
        )

        #expect(exactBytes == Data(uri.utf8))
        #expect(
            try PairingInvitationFileV1.decodeURI(
                exactBytes,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
            ) == uri
        )
        #expect(PairingInvitationFileV1.filenameExtension == "harcpair")
        #expect(
            PairingInvitationFileV1.contentTypeIdentifier
                == "com.harc.pairing-invitation"
        )
    }

    @Test("whitespace, non-ASCII, oversize, and expired files fail closed")
    func rejectionRules() throws {
        let ticket = try makeTicket()
        let uri = try ticket.encodedURI()
        let now = ProtocolCodecFixtures.issuedAt + 1

        #expect(throws: HarcProtocolCodecError.invalidPairingURI) {
            try PairingInvitationFileV1.decodeURI(
                Data((uri + "\n").utf8),
                atUnixMilliseconds: now
            )
        }
        #expect(throws: HarcProtocolCodecError.invalidPairingURI) {
            try PairingInvitationFileV1.decodeURI(
                Data("harc-pair://v1/café".utf8),
                atUnixMilliseconds: now
            )
        }
        #expect(throws: HarcProtocolCodecError.invalidPairingURI) {
            try PairingInvitationFileV1.decodeURI(
                Data(
                    repeating: 0x41,
                    count: PairingInvitationFileV1.maximumByteCount + 1
                ),
                atUnixMilliseconds: now
            )
        }
        #expect(
            throws: HarcProtocolCodecError.expired(
                field: "PairingTicketV1"
            )
        ) {
            try PairingInvitationFileV1.decodeURI(
                Data(uri.utf8),
                atUnixMilliseconds:
                    ProtocolCodecFixtures.issuedAt + 120_000
            )
        }
    }

    private func makeTicket() throws -> PairingTicketV1 {
        let hostKey = ProtocolCodecFixtures.key(42)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(420))
        return try PairingTicketV1(
            ticketID: ProtocolCodecFixtures.uuid(421),
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            verifiedTransportSet:
                ProtocolCodecFixtures.verifiedTransportSet(
                    hostKey: hostKey,
                    libraryID: libraryID
                ),
            ticketSecret:
                ProtocolCodecFixtures.bytes(0x42, count: 24),
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds:
                ProtocolCodecFixtures.issuedAt + 120_000,
            endpoints: [
                try PairingEndpointV1.dnsHost(
                    "harc-host.local",
                    port: 65215
                ),
            ]
        )
    }
}
