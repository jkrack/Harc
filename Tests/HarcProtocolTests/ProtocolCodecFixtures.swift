import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol

enum ProtocolCodecFixtures {
    static let issuedAt: UInt64 = 2_000_000_000_000

    static func bytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }

    static func uuid(_ value: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012u", value))!
    }

    static func key(_ byte: UInt8) -> SoftwareP256SigningKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = byte == 0 ? 1 : byte
        return try! SoftwareP256SigningKey(rawRepresentation: scalar)
    }

    static func currentGrantBinding(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        deviceKey: SoftwareP256SigningKey,
        grantID: UUID,
        grantEpoch: UInt64,
        scopes: Set<AuthorizationScope> = [.libraryMetadataWrite, .processingSubmitOwn],
        issuedAtUnixMilliseconds: UInt64 = issuedAt - 1_000,
        expiresAtUnixMilliseconds: UInt64? = issuedAt + 120_000
    ) throws -> HarcCurrentGrantBindingV1 {
        let grant = try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            grantID: GrantID(grantID),
            devicePublicKey: deviceKey.publicKey,
            scopes: scopes,
            grantEpoch: GrantEpoch(grantEpoch),
            issuedAt: Date(
                timeIntervalSince1970: Double(issuedAtUnixMilliseconds) / 1_000
            ),
            expiresAt: expiresAtUnixMilliseconds.map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            },
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        return try HarcCurrentGrantBindingV1(
            registryEntry: DeviceRegistryEntry(activeGrant: grant)
        )
    }

    static func verifiedTransportSet(
        hostKey: SoftwareP256SigningKey,
        libraryID: LibraryID,
        epoch: UInt64 = 7
    ) throws -> VerifiedHostTransportSetV1 {
        let payload = try HostTransportSetV1(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            setEpoch: epoch,
            issuedAtUnixMilliseconds: issuedAt,
            entries: [
                try HostTransportEntryV1(
                    tlsSPKISHA256: bytes(0x21),
                    notBeforeUnixMilliseconds: issuedAt - 1_000,
                    notAfterUnixMilliseconds: issuedAt + 60_000
                ),
                try HostTransportEntryV1(
                    tlsSPKISHA256: bytes(0x22),
                    notBeforeUnixMilliseconds: issuedAt - 1_000,
                    notAfterUnixMilliseconds: issuedAt + 60_000
                ),
            ]
        )
        let payloadBytes = payload.encoded()
        let header = try HarcSignedEnvelopeV1(
            messageType: .hostTransportSet,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: nil,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .hostTransportSet,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payloadBytes)
        )
        let object = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: payloadBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: payload.protocolVersion,
                libraryID: payload.libraryID,
                hostAuthorityID: payload.hostAuthorityID,
                issuedAtUnixMilliseconds: payload.issuedAtUnixMilliseconds
            ),
            using: hostKey
        )
        return try VerifiedHostTransportSetV1.decode(
            object.exactFramedBytes,
            hostAuthorityPublicKey: hostKey.publicKey
        )
    }
}

extension Data {
    init(protocolHex: String) throws {
        let compact = protocolHex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else { throw ProtocolHexError.invalid }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index ..< end], radix: 16) else {
                throw ProtocolHexError.invalid
            }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }
}

private enum ProtocolHexError: Error { case invalid }
