import Foundation
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol

/// Production authority-backed issuer for grants approved by the resident
/// local pairing controller. The protected authority key remains behind
/// `HostCryptographicStateStore`; this value receives only its narrow signer
/// capability for the duration of one issuance.
package struct HarcHostPairingGrantIssuerV1:
    HostPairingGrantIssuingBoundary, Sendable
{
    private static let maximumExactlyRepresentableUnixMilliseconds: Double =
        9_007_199_254_740_991

    private let cryptographicStateStore: any HostCryptographicStateStore
    private let expectedTuple: HostCryptographicStateTuple

    package init(
        cryptographicStateStore: any HostCryptographicStateStore,
        expectedTuple: HostCryptographicStateTuple
    ) {
        self.cryptographicStateStore = cryptographicStateStore
        self.expectedTuple = expectedTuple
    }

    package func issueGrant(
        for request: HostPairingGrantIssuanceRequest
    ) async throws -> HostPairingIssuedGrant {
        guard request.libraryID == expectedTuple.libraryID,
              request.hostAuthorityID == expectedTuple.hostAuthorityID else {
            throw HarcHostError.pairingGrantMismatch
        }
        if let existing = request.existingEntry {
            guard existing.libraryID == request.libraryID,
                  existing.hostAuthorityID == request.hostAuthorityID,
                  existing.deviceID == request.devicePublicKey.deviceID,
                  existing.devicePublicKey == request.devicePublicKey else {
                throw HarcHostError.pairingGrantMismatch
            }
        }

        let state = try await cryptographicStateStore.load(
            requiredTuple: expectedTuple
        )
        guard state.tuple == expectedTuple,
              state.authorityIdentity.hostAuthorityID
                == expectedTuple.hostAuthorityID else {
            throw HarcProtocolCodecError.invalidKeyBinding(
                field: "hostAuthorityID"
            )
        }

        let issuedAt = try Self.canonicalWireDate(request.approvedAt)
        let grantID: GrantID
        let grantEpoch: GrantEpoch
        let protocolVersion: IdentityProtocolVersion
        let minimumCompatibleProtocolMinor: UInt16
        let maximumCompatibleProtocolMinor: UInt16
        if let existing = request.existingEntry {
            grantEpoch = try existing.currentGrantEpoch.next()
            grantID = existing.status == .active
                ? existing.currentGrantID
                : Self.freshGrantID(excluding: existing.currentGrantID)
            protocolVersion = existing.protocolVersion
            minimumCompatibleProtocolMinor =
                existing.minimumCompatibleProtocolMinor
            maximumCompatibleProtocolMinor =
                existing.maximumCompatibleProtocolMinor
        } else {
            grantID = Self.freshGrantID()
            grantEpoch = .initial
            protocolVersion = .v1
            minimumCompatibleProtocolMinor = 0
            maximumCompatibleProtocolMinor = 0
        }

        let claims = try DeviceGrantClaims(
            protocolVersion: protocolVersion,
            libraryID: request.libraryID,
            hostAuthorityID: request.hostAuthorityID,
            grantID: grantID,
            devicePublicKey: request.devicePublicKey,
            scopes: Set(request.approvedScopes),
            grantEpoch: grantEpoch,
            issuedAt: issuedAt.date,
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
        )
        let wireGrant = try Harc_V1_DeviceGrantV1(claims)
        let exactPayload = try HarcExactProtobufPayload(
            serializingOnce: wireGrant
        )
        let wireProtocolVersion = HarcProtocolVersion(
            major: claims.protocolVersion.major,
            minor: claims.protocolVersion.minor
        )
        let expiresAt = wireGrant.hasExpiresAtUnixMs
            ? wireGrant.expiresAtUnixMs
            : nil
        let header = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            protocolVersion: wireProtocolVersion,
            libraryID: claims.libraryID,
            hostAuthorityID: claims.hostAuthorityID,
            signerDeviceID: nil,
            grantID: claims.grantID.rawValue,
            grantEpoch: claims.grantEpoch.rawValue,
            operationID: nil,
            issuedAtUnixMilliseconds: issuedAt.unixMilliseconds,
            expiresAtUnixMilliseconds: expiresAt,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(
                exactPayload.exactBytes
            )
        )
        let signed = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: wireProtocolVersion,
                libraryID: claims.libraryID,
                hostAuthorityID: claims.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAt.unixMilliseconds,
                grantID: claims.grantID.rawValue,
                grantEpoch: claims.grantEpoch.rawValue,
                expiresAtUnixMilliseconds: expiresAt
            ),
            using: state.authorityIdentity
        )

        // Return only bytes admitted through the same public authentication
        // path used by clients, never an unchecked producer-side assembly.
        let authenticated = try HarcAuthenticatedSignedObjectV1
            .decodeAndAuthenticate(
                signed.exactFramedBytes,
                using: state.authorityIdentity.publicKey,
                purpose: .historicalEvidence
            )
        guard case let .deviceGrant(
            authenticatedPayload,
            authenticatedClaims
        ) = authenticated.payload,
              authenticatedClaims == claims,
              authenticatedPayload.exactBytes == exactPayload.exactBytes,
              authenticated.signedObject.exactFramedBytes
                == signed.exactFramedBytes else {
            throw HarcProtocolCodecError.headerPayloadMismatch(
                field: "exactDeviceGrantObject"
            )
        }

        return try HostPairingIssuedGrant(
            claims: authenticatedClaims,
            exactSignedGrantBytes: authenticated.signedObject.exactFramedBytes
        )
    }

    private static func freshGrantID(
        excluding excluded: GrantID? = nil
    ) -> GrantID {
        while true {
            let candidate = GrantID.random()
            if candidate.rawValue != HarcSignedEnvelopeV1.zeroUUID,
               candidate != excluded {
                return candidate
            }
        }
    }

    private static func canonicalWireDate(
        _ value: Date
    ) throws -> (date: Date, unixMilliseconds: UInt64) {
        let milliseconds = value.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 0 else {
            throw HarcProtobufConversionError.invalidValue(
                field: "deviceGrant.issuedAt"
            )
        }
        guard milliseconds <= maximumExactlyRepresentableUnixMilliseconds else {
            throw HarcProtobufConversionError.integerOutOfRange(
                field: "deviceGrant.issuedAt"
            )
        }
        let exactMilliseconds = milliseconds.rounded(.down)
        guard let unixMilliseconds = UInt64(exactly: exactMilliseconds) else {
            throw HarcProtobufConversionError.lossyConversion(
                field: "deviceGrant.issuedAt"
            )
        }
        let date = Date(
            timeIntervalSince1970: Double(unixMilliseconds) / 1_000
        )
        return (date, unixMilliseconds)
    }
}
