import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

enum HostAuthenticationProtocolV1 {
    static let major: UInt16 = 1
    static let minor: UInt16 = 0
    static let pairingDeviceLabelBytes = 256

    static func validate(major: UInt16, minor: UInt16) throws {
        guard major == Self.major, minor == Self.minor else {
            throw HarcHostError.invalidAuthenticationInput("protocol version")
        }
    }
}

// MARK: - Shared pre-authentication inputs

/// A host-scoped, privacy-preserving binding for the transport source. Network
/// adapters derive this value before entering HarcHost; raw addresses are never
/// persisted in the authentication journal.
public struct HostPreauthenticationSource: Equatable, Hashable, Sendable {
    public let bindingSHA256: Data

    public init(bindingSHA256: Data) throws {
        guard bindingSHA256.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("source binding")
        }
        self.bindingSHA256 = bindingSHA256
    }
}

public protocol HostAuthenticationRandomness: Sendable {
    func randomBytes(count: Int) throws -> Data
    func randomUUID() throws -> UUID
}

public struct SystemHostAuthenticationRandomness: HostAuthenticationRandomness {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        guard count > 0, count <= 4_096 else {
            throw HarcHostError.invalidAuthenticationInput("random byte count")
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    public func randomUUID() throws -> UUID { UUID() }
}

// MARK: - Pairing claims

public struct HostPairingClaimContext: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let hostAuthorityPublicKey: P256X963PublicKey
    public let tlsSPKISHA256: Data

    public init(
        protocolMajor: UInt16 = 1,
        protocolMinor: UInt16 = 0,
        hostAuthorityPublicKey: P256X963PublicKey,
        tlsSPKISHA256: Data
    ) throws {
        try HostAuthenticationProtocolV1.validate(
            major: protocolMajor,
            minor: protocolMinor
        )
        guard tlsSPKISHA256.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("pairing context")
        }
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.tlsSPKISHA256 = tlsSPKISHA256
    }
}

public struct BeginHostPairingClaimRequest: Sendable {
    public let ticketID: UUID
    public let ticketSecret: Data
    public let clientNonce: Data
    public let devicePublicKey: P256X963PublicKey
    public let requestedScopes: [AuthorizationScope]
    public let deviceLabel: String
    public let source: HostPreauthenticationSource
    public let context: HostPairingClaimContext

    public init(
        ticketID: UUID,
        ticketSecret: Data,
        clientNonce: Data,
        devicePublicKey: P256X963PublicKey,
        requestedScopes: [AuthorizationScope],
        deviceLabel: String,
        source: HostPreauthenticationSource,
        context: HostPairingClaimContext
    ) throws {
        guard ticketSecret.count == 24,
              clientNonce.count == SHA256.Digest.byteCount,
              requestedScopes.count <= 8,
              requestedScopes == Array(Set(requestedScopes)).sorted() else {
            throw HarcHostError.invalidAuthenticationInput("pairing claim")
        }
        guard deviceLabel == deviceLabel.precomposedStringWithCanonicalMapping,
              !deviceLabel.isEmpty,
              deviceLabel.utf8.count
                <= HostAuthenticationProtocolV1.pairingDeviceLabelBytes,
              !deviceLabel.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw HarcHostError.invalidAuthenticationInput("device label")
        }
        self.ticketID = ticketID
        self.ticketSecret = ticketSecret
        self.clientNonce = clientNonce
        self.devicePublicKey = devicePublicKey
        self.requestedScopes = requestedScopes
        self.deviceLabel = deviceLabel
        self.source = source
        self.context = context
    }
}

public struct BeginHostPairingClaimResponse: Equatable, Sendable {
    public let claimID: UUID
    public let hostNonce: Data
    /// Returned exactly once. HarcHost persists only its domain-separated hash.
    public let claimantToken: Data
    public let expiresAt: Date

    public init(claimID: UUID, hostNonce: Data, claimantToken: Data, expiresAt: Date) {
        self.claimID = claimID
        self.hostNonce = hostNonce
        self.claimantToken = claimantToken
        self.expiresAt = expiresAt
    }
}

public struct ProveHostPairingClaimRequest: Sendable {
    public let claimID: UUID
    public let claimantToken: Data
    public let clientSignature: P256RawSignature

    public init(claimID: UUID, claimantToken: Data, clientSignature: P256RawSignature) throws {
        guard claimantToken.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("claimant token")
        }
        self.claimID = claimID
        self.claimantToken = claimantToken
        self.clientSignature = clientSignature
    }
}

public struct HostPairingProofResult: Equatable, Sendable {
    public let sasDigest: Data
    public let sasWordIndexes: [UInt16]
    public let sasWords: [String]

    public init(
        sasDigest: Data,
        sasWordIndexes: [UInt16],
        sasWords: [String]
    ) throws {
        guard sasDigest.count == SHA256.Digest.byteCount,
              sasWordIndexes.count == 4,
              sasWordIndexes.allSatisfy({ $0 < 2_048 }),
              sasWords.count == 4,
              sasWords.allSatisfy({ word in
                  !word.isEmpty && word.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7a }
              }) else {
            throw HarcHostError.invalidAuthenticationInput("pairing SAS")
        }
        self.sasDigest = sasDigest
        self.sasWordIndexes = sasWordIndexes
        self.sasWords = sasWords
    }
}

/// Result of durably moving a ticket-bound claim into local approval.
/// Transcript/SAS validation stays in the injected protocol boundary, while
/// HarcHost attaches the authoritative expiry loaded from its durable claim.
public struct HostPairingClaimProofResponse: Equatable, Sendable {
    public let proof: HostPairingProofResult
    public let expiresAt: Date

    public init(proof: HostPairingProofResult, expiresAt: Date) throws {
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.invalidAuthenticationInput("pairing expiry")
        }
        self.proof = proof
        self.expiresAt = expiresAt
    }

    public var sasDigest: Data { proof.sasDigest }
    public var sasWordIndexes: [UInt16] { proof.sasWordIndexes }
    public var sasWords: [String] { proof.sasWords }
}

public enum HostPairingClaimStatus: Equatable, Sendable {
    case pending
    case approved(exactGrantBytes: Data)
    case denied
    case expired
    case cancelled
}

public struct HostPendingPairingClaim: Equatable, Sendable {
    public let claimID: UUID
    public let ticketID: UUID
    public let clientKind: AdoptedClientKind
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let deviceLabel: String
    public let requestedScopes: [AuthorizationScope]
    /// The resident approval UI must present this as transport-trust repair,
    /// not as an ordinary same-key re-adoption.
    public let requiresTransportTrustRepair: Bool
    public let sasDigest: Data
    public let sasWordIndexes: [UInt16]
    public let sasWords: [String]
    public let expiresAt: Date
}

public struct HostPairingGrantIssuanceRequest: Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let clientKind: AdoptedClientKind
    public let devicePublicKey: P256X963PublicKey
    /// Exact canonical subset the resident user approved locally. This is not
    /// necessarily every scope the remote claimant requested.
    public let approvedScopes: [AuthorizationScope]
    public let existingEntry: DeviceRegistryEntry?
    public let approvedAt: Date
}

public struct HostPairingIssuedGrant: Sendable {
    public let claims: DeviceGrantClaims
    public let exactSignedGrantBytes: Data

    public init(claims: DeviceGrantClaims, exactSignedGrantBytes: Data) throws {
        guard !exactSignedGrantBytes.isEmpty else {
            throw HarcHostError.invalidAuthenticationInput("exact grant bytes")
        }
        self.claims = claims
        self.exactSignedGrantBytes = exactSignedGrantBytes
    }
}

/// Host-authority signing remains outside the network-facing claim service.
/// Only the resident local approval controller receives this boundary.
public protocol HostPairingGrantIssuingBoundary: Sendable {
    func issueGrant(
        for request: HostPairingGrantIssuanceRequest
    ) async throws -> HostPairingIssuedGrant
}

// MARK: - Sessions

public struct HostNegotiatedSessionCapabilities: Equatable, Sendable {
    public static let maximumExactByteCount = 65_536

    public let exactBytes: Data
    public let sha256: Data
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let selectedCodec: String
    public let selectedContainer: String

    /// Protocol-neutral semantic projection. Production callers receive this
    /// only from `HostNegotiatedCapabilitiesValidatingBoundary`; the public
    /// initializer also supports explicit HarcHost test seams.
    public init(
        exactBytes: Data,
        sha256: Data? = nil,
        protocolMajor: UInt16 = 1,
        protocolMinor: UInt16,
        selectedCodec: String,
        selectedContainer: String
    ) throws {
        let digest = Data(SHA256.hash(data: exactBytes))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        try HostAuthenticationProtocolV1.validate(
            major: protocolMajor,
            minor: protocolMinor
        )
        guard !exactBytes.isEmpty,
              exactBytes.count <= Self.maximumExactByteCount,
              selectedCodec.count <= 64,
              !selectedCodec.isEmpty,
              selectedCodec.unicodeScalars.allSatisfy(allowed.contains),
              selectedContainer.count <= 64,
              !selectedContainer.isEmpty,
              selectedContainer.unicodeScalars.allSatisfy(allowed.contains),
              sha256 == nil || sha256 == digest else {
            throw HarcHostError.invalidAuthenticationInput("negotiated capabilities")
        }
        self.exactBytes = exactBytes
        self.sha256 = digest
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.selectedCodec = selectedCodec
        self.selectedContainer = selectedContainer
    }
}

public struct BeginHostSessionRequest: Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let claimedDeviceID: DeviceID
    public let grantID: GrantID
    public let source: HostPreauthenticationSource
    public let tlsSPKISHA256: Data

    public init(
        protocolMajor: UInt16 = 1,
        protocolMinor: UInt16 = 0,
        claimedDeviceID: DeviceID,
        grantID: GrantID,
        source: HostPreauthenticationSource,
        tlsSPKISHA256: Data
    ) throws {
        guard tlsSPKISHA256.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("TLS SPKI digest")
        }
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.claimedDeviceID = claimedDeviceID
        self.grantID = grantID
        self.source = source
        self.tlsSPKISHA256 = tlsSPKISHA256
    }
}

/// Valid and invalid lookup hints receive this same structural response. A
/// dummy grant blob is never accepted by `openSession`.
///
/// Frozen V1 has no padding/cover field. Matching the response structure,
/// entropy path, and pre-proof work therefore cannot make a real host-signed
/// grant cryptographically indistinguishable from random dummy bytes. The
/// normative security clarification accepts only that high-entropy targeted
/// validity signal; this core does not invent synthetic signed grants,
/// non-schema bytes, or a stronger indistinguishability claim.
public struct BeginHostSessionResponse: Equatable, Sendable {
    public let challengeID: UUID
    public let serverNonce: Data
    public let expiresAt: Date
    public let exactSignedGrantBytes: Data
    public let serverTime: Date
}

public struct OpenHostSessionRequest: Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let challengeID: UUID
    public let clientNonce: Data
    public let exactCapabilitiesBytes: Data
    public let capabilitiesSHA256: Data
    public let clientSignature: P256RawSignature
    public let tlsSPKISHA256: Data

    public init(
        protocolMajor: UInt16 = 1,
        protocolMinor: UInt16 = 0,
        challengeID: UUID,
        clientNonce: Data,
        exactCapabilitiesBytes: Data,
        capabilitiesSHA256: Data,
        clientSignature: P256RawSignature,
        tlsSPKISHA256: Data
    ) throws {
        guard clientNonce.count == SHA256.Digest.byteCount,
              capabilitiesSHA256.count == SHA256.Digest.byteCount,
              tlsSPKISHA256.count == SHA256.Digest.byteCount,
              !exactCapabilitiesBytes.isEmpty,
              exactCapabilitiesBytes.count
                <= HostNegotiatedSessionCapabilities.maximumExactByteCount else {
            throw HarcHostError.invalidAuthenticationInput("open session")
        }
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.challengeID = challengeID
        self.clientNonce = clientNonce
        self.exactCapabilitiesBytes = exactCapabilitiesBytes
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.clientSignature = clientSignature
        self.tlsSPKISHA256 = tlsSPKISHA256
    }
}

public struct HostOpenedSession: Equatable, Sendable {
    /// Exact `token_id || token_secret`; returned once and never persisted.
    public let credential: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public let capabilitiesSHA256: Data
}

public struct HostAuthenticatedSession: Equatable, Sendable {
    public let context: AuthenticatedDeviceContext
    public let scopes: [AuthorizationScope]
    public let exactCapabilitiesBytes: Data
    public let capabilitiesSHA256: Data
    public let protocolMinor: UInt16
    public let selectedCodec: String
    public let selectedContainer: String
    public let expiresAt: Date
}
