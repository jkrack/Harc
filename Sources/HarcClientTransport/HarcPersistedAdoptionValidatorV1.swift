import Foundation
import HarcClientStore
import HarcIdentity
import HarcProtocol
import HarcTransfer

public enum HarcPersistedAdoptionValidationError:
    Error, Equatable, Sendable
{
    case tupleMismatch
    case transportEpochMismatch
    case grantBindingMismatch(field: String)
    case grantInactive
    case grantNotYetValid
    case grantExpired
}

/// Reauthenticates the exact signed objects loaded from the client store before
/// they are used to open a new application session. A database row is only a
/// cache of prior validation; reconnect never treats it as cryptographic proof.
public enum HarcPersistedAdoptionValidatorV1 {
    public static func validate(
        _ snapshot: ActiveAdoptionSnapshot,
        devicePublicKey: P256X963PublicKey,
        at date: Date = Date(),
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws -> ValidatedClientAdoptionEvidence {
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: snapshot.tuple.libraryID,
            hostAuthorityID: snapshot.tuple.hostAuthorityID,
            hostAuthorityPublicKeyX963: snapshot.authorityPublicKeyX963
        )
        let transport = try VerifiedHostTransportSetV1.decode(
            snapshot.transportSet.exactSignedBytes,
            hostAuthorityPublicKey: hostTrust.hostAuthorityPublicKey
        )
        guard snapshot.transportSet.tuple == snapshot.tuple,
              snapshot.grant.tuple == snapshot.tuple,
              transport.transportSet.libraryID == hostTrust.libraryID,
              transport.transportSet.hostAuthorityID
                == hostTrust.hostAuthorityID else {
            throw HarcPersistedAdoptionValidationError.tupleMismatch
        }
        guard transport.transportSet.setEpoch == snapshot.transportSet.epoch else {
            throw HarcPersistedAdoptionValidationError.transportEpochMismatch
        }

        let authenticated = try HarcAuthenticatedSignedObjectV1
            .decodeAndAuthenticate(
                snapshot.grant.exactSignedBytes,
                using: hostTrust.hostAuthorityPublicKey,
                compatibility: compatibility,
                purpose: .historicalEvidence
            )
        guard case .deviceGrant(_, let claims) = authenticated.payload else {
            throw HarcPersistedAdoptionValidationError
                .grantBindingMismatch(field: "type")
        }
        guard claims.libraryID == hostTrust.libraryID,
              claims.hostAuthorityID == hostTrust.hostAuthorityID else {
            throw HarcPersistedAdoptionValidationError
                .grantBindingMismatch(field: "hostTrust")
        }
        guard claims.devicePublicKey == devicePublicKey,
              claims.deviceID == devicePublicKey.deviceID,
              claims.deviceID == snapshot.grant.deviceID else {
            throw HarcPersistedAdoptionValidationError
                .grantBindingMismatch(field: "device")
        }
        guard claims.grantID == snapshot.grant.grantID,
              claims.grantEpoch.rawValue == snapshot.grant.registryEpoch,
              claims.protocolVersion.major == snapshot.grant.protocolVersion.major,
              claims.protocolVersion.minor == snapshot.grant.protocolVersion.minor,
              claims.devicePublicKey.rawBytes
                == snapshot.grant.devicePublicKeyX963,
              claims.scopes.map(\.rawValue)
                == snapshot.grant.scopes.map(\.rawValue),
              claims.issuedAt == snapshot.grant.issuedAt,
              claims.expiresAt == snapshot.grant.expiresAt,
              claims.minimumCompatibleProtocolMinor
                == snapshot.grant.minimumCompatibleProtocolMinor,
              claims.maximumCompatibleProtocolMinor
                == snapshot.grant.maximumCompatibleProtocolMinor else {
            throw HarcPersistedAdoptionValidationError
                .grantBindingMismatch(field: "claims")
        }
        guard snapshot.grant.status == .active else {
            throw HarcPersistedAdoptionValidationError.grantInactive
        }
        guard claims.issuedAt <= date else {
            throw HarcPersistedAdoptionValidationError.grantNotYetValid
        }
        guard claims.expiresAt.map({ date < $0 }) ?? true else {
            throw HarcPersistedAdoptionValidationError.grantExpired
        }

        let grant = try ValidatedDeviceGrantEvidence(
            hostTrust: hostTrust,
            claims: claims,
            status: .active,
            exactSignedBytes: snapshot.grant.exactSignedBytes
        )
        return try ValidatedClientAdoptionEvidence(
            hostTrust: hostTrust,
            transportSet: transport.validatedEvidence(),
            grant: grant,
            adoptedAt: snapshot.adoptedAt
        )
    }
}
