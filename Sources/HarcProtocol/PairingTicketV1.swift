import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity

public enum PairingEndpointKindV1: UInt8, CaseIterable, Sendable {
    case bonjourInstance = 1
    case dnsHost = 2
    case ipv4 = 3
    case ipv6 = 4
    case remoteRelay = 5
}

/// Compact relay reachability carried inside the same short-lived bearer
/// ticket as direct endpoints. Only an HTTPS hostname and three independent
/// 256-bit opaque values cross this boundary; no Harc identity is used as a
/// relay route.
public struct PairingRelayEndpointV1: Equatable, Hashable, Sendable {
    public static let port: UInt16 = 443
    public static let maximumServiceHostBytes = 120

    public let serviceHost: String
    public let hostRouteID: String
    public let admissionRouteID: String
    public let capability: String

    public init(
        serviceHost: String,
        hostRouteID: String,
        admissionRouteID: String,
        capability: String
    ) throws {
        let serviceBytes = Data(serviceHost.utf8)
        guard !serviceBytes.isEmpty,
              serviceBytes.count <= Self.maximumServiceHostBytes else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "remoteRelay.serviceHost"
            )
        }
        try PairingEndpointV1.validateDNS(serviceBytes)
        for (field, value) in [
            ("hostRouteID", hostRouteID),
            ("admissionRouteID", admissionRouteID),
            ("capability", capability),
        ] {
            let decoded = try harcDecodeCanonicalBase64URL(value)
            guard decoded.count == 32 else {
                throw HarcProtocolCodecError.invalidEndpoint(
                    field: "remoteRelay.\(field)"
                )
            }
        }
        self.serviceHost = serviceHost
        self.hostRouteID = hostRouteID
        self.admissionRouteID = admissionRouteID
        self.capability = capability
    }

    public func pairingEndpoint() throws -> PairingEndpointV1 {
        var writer = HarcBinaryWriter()
        let serviceBytes = Data(serviceHost.utf8)
        writer.append(UInt8(1))
        writer.append(UInt8(serviceBytes.count))
        writer.append(serviceBytes)
        writer.append(try harcDecodeCanonicalBase64URL(hostRouteID))
        writer.append(try harcDecodeCanonicalBase64URL(admissionRouteID))
        writer.append(try harcDecodeCanonicalBase64URL(capability))
        return try PairingEndpointV1(
            kind: .remoteRelay,
            port: Self.port,
            value: writer.data
        )
    }

    public static func decode(_ endpoint: PairingEndpointV1) throws -> Self {
        guard endpoint.kind == .remoteRelay, endpoint.port == port else {
            throw HarcProtocolCodecError.invalidEndpoint(field: "remoteRelay")
        }
        let decoded = try decodeUnchecked(
            port: endpoint.port,
            value: endpoint.value
        )
        guard try decoded.pairingEndpoint() == endpoint else {
            throw HarcProtocolCodecError.headerPayloadMismatch(
                field: "canonicalRemoteRelay"
            )
        }
        return decoded
    }

    fileprivate static func decodeUnchecked(
        port: UInt16,
        value: Data
    ) throws -> Self {
        guard port == Self.port else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "remoteRelay.port"
            )
        }
        var reader = try HarcBinaryReader(
            value,
            maximumBytes: Int(UInt8.max),
            field: "remoteRelay"
        )
        guard try reader.readUInt8(field: "remoteRelay.version") == 1 else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "remoteRelay.version"
            )
        }
        let hostLength = Int(
            try reader.readUInt8(field: "remoteRelay.serviceHostLength")
        )
        guard (1 ... maximumServiceHostBytes).contains(hostLength) else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "remoteRelay.serviceHostLength"
            )
        }
        let serviceBytes = try reader.readData(
            count: hostLength,
            field: "remoteRelay.serviceHost"
        )
        guard let serviceHost = String(data: serviceBytes, encoding: .ascii),
              Data(serviceHost.utf8) == serviceBytes else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "remoteRelay.serviceHost"
            )
        }
        let decoded = try Self(
            serviceHost: serviceHost,
            hostRouteID: harcEncodeBase64URL(
                reader.readData(count: 32, field: "remoteRelay.hostRouteID")
            ),
            admissionRouteID: harcEncodeBase64URL(
                reader.readData(count: 32, field: "remoteRelay.admissionRouteID")
            ),
            capability: harcEncodeBase64URL(
                reader.readData(count: 32, field: "remoteRelay.capability")
            )
        )
        try reader.requireEnd()
        return decoded
    }
}

public struct PairingEndpointV1: Equatable, Hashable, Sendable {
    public let kind: PairingEndpointKindV1
    public let port: UInt16
    public let value: Data

    public init(kind: PairingEndpointKindV1, port: UInt16, value: Data) throws {
        guard !value.isEmpty, value.count <= UInt8.max else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "endpoint.value",
                minimum: 1,
                maximum: UInt64(UInt8.max),
                actual: UInt64(value.count)
            )
        }
        switch kind {
        case .bonjourInstance:
            guard port == 0 else {
                throw HarcProtocolCodecError.invalidEndpoint(field: "bonjour.port")
            }
            _ = try harcValidateCanonicalText(value, field: "bonjour.value")
        case .dnsHost:
            guard port != 0 else {
                throw HarcProtocolCodecError.invalidEndpoint(field: "dns.port")
            }
            try Self.validateDNS(value)
        case .ipv4:
            guard port != 0, value.count == 4 else {
                throw HarcProtocolCodecError.invalidEndpoint(field: "ipv4")
            }
        case .ipv6:
            guard port != 0, value.count == 16 else {
                throw HarcProtocolCodecError.invalidEndpoint(field: "ipv6")
            }
        case .remoteRelay:
            guard port == PairingRelayEndpointV1.port else {
                throw HarcProtocolCodecError.invalidEndpoint(
                    field: "remoteRelay.port"
                )
            }
            _ = try PairingRelayEndpointV1.decodeUnchecked(
                port: port,
                value: value
            )
        }
        self.kind = kind
        self.port = port
        self.value = value
    }

    public static func bonjourInstance(_ value: String) throws -> Self {
        try Self(kind: .bonjourInstance, port: 0, value: Data(value.utf8))
    }

    public static func dnsHost(_ value: String, port: UInt16) throws -> Self {
        try Self(kind: .dnsHost, port: port, value: Data(value.utf8))
    }

    public static func ipv4(_ addressBytes: Data, port: UInt16) throws -> Self {
        try Self(kind: .ipv4, port: port, value: addressBytes)
    }

    public static func ipv6(_ addressBytes: Data, port: UInt16) throws -> Self {
        try Self(kind: .ipv6, port: port, value: addressBytes)
    }

    public var textValue: String? {
        switch kind {
        case .bonjourInstance, .dnsHost: String(data: value, encoding: .utf8)
        case .ipv4, .ipv6, .remoteRelay: nil
        }
    }

    fileprivate static func compare(_ lhs: Self, _ rhs: Self) -> ComparisonResult {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue ? .orderedAscending : .orderedDescending
        }
        if lhs.value != rhs.value {
            return lhs.value.lexicographicallyPrecedes(rhs.value) ? .orderedAscending : .orderedDescending
        }
        if lhs.port == rhs.port { return .orderedSame }
        return lhs.port < rhs.port ? .orderedAscending : .orderedDescending
    }

    fileprivate static func validateDNS(_ bytes: Data) throws {
        guard let value = String(data: bytes, encoding: .ascii),
              Data(value.utf8) == bytes,
              value == value.lowercased(),
              !value.hasSuffix("."),
              value.utf8.count <= 253 else {
            throw HarcProtocolCodecError.invalidEndpoint(field: "dns.value")
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard (1 ... 63).contains(label.utf8.count),
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  Self.isDNSAlphanumeric(first),
                  Self.isDNSAlphanumeric(last) else { return false }
            return label.utf8.allSatisfy {
                Self.isDNSAlphanumeric($0) || $0 == 0x2d
            }
        }) else {
            throw HarcProtocolCodecError.invalidEndpoint(field: "dns.value")
        }
    }

    private static func isDNSAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39)
    }
}

public struct PairingTicketV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCTKT1\0".utf8)
    public static let uriPrefix = "harc-pair://v1/"
    private static let secretBindingDomain = "HARC-PAIRING-TICKET-SECRET-V1\0"
    private static let remoteAdmissionDomain =
        "HARC-PAIRING-REMOTE-ADMISSION-V1\0"

    public let protocolVersion: HarcProtocolVersion
    public let ticketID: UUID
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostAuthorityPublicKey: P256X963PublicKey
    public let verifiedTransportSet: VerifiedHostTransportSetV1
    public let ticketSecret: Data
    public let issuedAtUnixMilliseconds: UInt64
    public let expiresAtUnixMilliseconds: UInt64
    public let endpoints: [PairingEndpointV1]

    public var exactTransportObjectBytes: Data { verifiedTransportSet.exactSignedBytes }

    public init(
        protocolVersion: HarcProtocolVersion = .v1,
        ticketID: UUID,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostAuthorityPublicKey: P256X963PublicKey,
        verifiedTransportSet: VerifiedHostTransportSetV1,
        ticketSecret: Data,
        issuedAtUnixMilliseconds: UInt64,
        expiresAtUnixMilliseconds: UInt64,
        endpoints: [PairingEndpointV1],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        try versionPolicy.validate(protocolVersion)
        guard hostAuthorityPublicKey.hostAuthorityID == hostAuthorityID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")
        }
        guard ticketSecret.count == 24 else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "ticketSecret",
                expected: 24,
                actual: UInt64(ticketSecret.count)
            )
        }
        guard expiresAtUnixMilliseconds > issuedAtUnixMilliseconds else {
            throw HarcProtocolCodecError.invalidTimeRange(field: "pairingTicket")
        }
        let maximumExpiry = try harcAdding(
            issuedAtUnixMilliseconds,
            HarcProtocolLimits.pairingTicketLifetimeMilliseconds,
            field: "pairingTicketLifetime"
        )
        guard expiresAtUnixMilliseconds <= maximumExpiry else {
            throw HarcProtocolCodecError.invalidTimeRange(field: "pairingTicketLifetime")
        }
        guard endpoints.count <= HarcProtocolLimits.pairingEndpoints else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "endpoints",
                minimum: 0,
                maximum: UInt64(HarcProtocolLimits.pairingEndpoints),
                actual: UInt64(endpoints.count)
            )
        }
        try Self.validateCanonicalEndpoints(endpoints)
        let transport = verifiedTransportSet.transportSet
        guard transport.protocolVersion == protocolVersion else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "transport.protocolVersion")
        }
        guard transport.libraryID == libraryID else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "transport.libraryID")
        }
        guard transport.hostAuthorityID == hostAuthorityID else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "transport.hostAuthorityID")
        }
        guard verifiedTransportSet.hostAuthorityPublicKey == hostAuthorityPublicKey else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "transport.hostAuthorityPublicKey")
        }
        let transportLength = verifiedTransportSet.exactSignedBytes.count
        guard (1 ... HarcProtocolLimits.pairingTransportObjectBytes).contains(transportLength) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "transportObject",
                minimum: 1,
                maximum: UInt64(HarcProtocolLimits.pairingTransportObjectBytes),
                actual: UInt64(transportLength)
            )
        }

        self.protocolVersion = protocolVersion
        self.ticketID = ticketID
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.verifiedTransportSet = verifiedTransportSet
        self.ticketSecret = ticketSecret
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.endpoints = endpoints

        _ = try encoded()
    }

    /// The 24-byte bearer presented to `BeginPairingClaim`.
    ///
    /// Direct-only V1 tickets retain their frozen raw-secret behavior. A ticket
    /// containing a remote relay endpoint instead derives the bearer from the
    /// complete canonical ticket, so changing, adding, or removing any relay
    /// reachability byte produces a value the Host's original reservation will
    /// reject. The resulting binding is also included in the signed pairing
    /// transcript and SAS.
    public var pairingAdmissionSecret: Data {
        guard endpoints.contains(where: { $0.kind == .remoteRelay }) else {
            return ticketSecret
        }
        let digest = harcDomainSeparatedSHA256(
            Self.remoteAdmissionDomain,
            try! encoded()
        )
        return Data(digest.prefix(ticketSecret.count))
    }

    public var ticketSecretBindingSHA256: Data {
        try! Self.ticketSecretBindingSHA256(
            ticketID: ticketID,
            secret: pairingAdmissionSecret
        )
    }

    public static func ticketSecretBindingSHA256(ticketID: UUID, secret: Data) throws -> Data {
        guard secret.count == 24 else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "ticketSecret",
                expected: 24,
                actual: UInt64(secret.count)
            )
        }
        return harcDomainSeparatedSHA256(secretBindingDomain, harcUUIDBytes(ticketID), secret)
    }

    public func encoded() throws -> Data {
        var suffix = HarcBinaryWriter()
        suffix.append(protocolVersion.major)
        suffix.append(protocolVersion.minor)
        suffix.append(uuid: ticketID)
        suffix.append(uuid: libraryID.rawValue)
        suffix.append(hostAuthorityID.rawBytes)
        suffix.append(hostAuthorityPublicKey.rawBytes)
        suffix.append(UInt16(exactTransportObjectBytes.count))
        suffix.append(exactTransportObjectBytes)
        suffix.append(ticketSecret)
        suffix.append(issuedAtUnixMilliseconds)
        suffix.append(expiresAtUnixMilliseconds)
        suffix.append(UInt8(endpoints.count))
        for endpoint in endpoints {
            suffix.append(endpoint.kind.rawValue)
            suffix.append(endpoint.port)
            suffix.append(UInt8(endpoint.value.count))
            suffix.append(endpoint.value)
        }

        let totalCount = Self.magic.count + 2 + suffix.data.count
        guard totalCount <= HarcProtocolLimits.pairingTicketBytes,
              let totalLength = UInt16(exactly: totalCount) else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "PairingTicketV1",
                limit: UInt64(HarcProtocolLimits.pairingTicketBytes),
                actual: UInt64(totalCount)
            )
        }
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        writer.append(totalLength)
        writer.append(suffix.data)
        return writer.data
    }

    public func encodedURI() throws -> String {
        let value = Self.uriPrefix + harcEncodeBase64URL(try encoded())
        guard value.utf8.count <= HarcProtocolLimits.pairingURIBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "pairingURI",
                limit: UInt64(HarcProtocolLimits.pairingURIBytes),
                actual: UInt64(value.utf8.count)
            )
        }
        return value
    }

    public static func decode(
        _ exactBytes: Data,
        atUnixMilliseconds now: UInt64,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: HarcProtocolLimits.pairingTicketBytes,
            field: "PairingTicketV1"
        )
        try reader.requireMagic(Self.magic, field: "PairingTicketV1")
        let declaredLength = try reader.readUInt16(field: "totalLength")
        guard Int(declaredLength) == exactBytes.count else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "totalLength",
                expected: UInt64(exactBytes.count),
                actual: UInt64(declaredLength)
            )
        }
        let version = HarcProtocolVersion(
            major: try reader.readUInt16(field: "protocolMajor"),
            minor: try reader.readUInt16(field: "protocolMinor")
        )
        try versionPolicy.validate(version)
        let ticketID = try reader.readUUID(field: "ticketID")
        let libraryID = LibraryID(try reader.readUUID(field: "libraryID"))
        let hostAuthorityID = try HostAuthorityID(
            reader.readData(count: HostAuthorityID.byteCount, field: "hostAuthorityID")
        )
        let publicKey = try P256X963PublicKey(
            reader.readData(count: P256X963PublicKey.byteCount, field: "hostPublicKeyX963")
        )
        let transportLength = Int(try reader.readUInt16(field: "transportObjectLength"))
        guard (1 ... HarcProtocolLimits.pairingTransportObjectBytes).contains(transportLength) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "transportObjectLength",
                minimum: 1,
                maximum: UInt64(HarcProtocolLimits.pairingTransportObjectBytes),
                actual: UInt64(transportLength)
            )
        }
        let transportBytes = try reader.readData(count: transportLength, field: "transportObject")
        let secret = try reader.readData(count: 24, field: "ticketSecret")
        let issuedAt = try reader.readUInt64(field: "issuedAtUnixMilliseconds")
        let expiresAt = try reader.readUInt64(field: "expiresAtUnixMilliseconds")
        let endpointCount = Int(try reader.readUInt8(field: "endpointCount"))
        guard endpointCount <= HarcProtocolLimits.pairingEndpoints else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "endpointCount",
                minimum: 0,
                maximum: UInt64(HarcProtocolLimits.pairingEndpoints),
                actual: UInt64(endpointCount)
            )
        }
        var endpoints: [PairingEndpointV1] = []
        endpoints.reserveCapacity(endpointCount)
        for index in 0 ..< endpointCount {
            let rawKind = try reader.readUInt8(field: "endpoints[\(index)].kind")
            guard let kind = PairingEndpointKindV1(rawValue: rawKind) else {
                throw HarcProtocolCodecError.invalidEndpoint(field: "endpoints[\(index)].kind")
            }
            let port = try reader.readUInt16(field: "endpoints[\(index)].port")
            let valueLength = Int(try reader.readUInt8(field: "endpoints[\(index)].valueLength"))
            guard valueLength > 0 else {
                throw HarcProtocolCodecError.lengthOutOfRange(
                    field: "endpoints[\(index)].valueLength",
                    minimum: 1,
                    maximum: UInt64(UInt8.max),
                    actual: 0
                )
            }
            endpoints.append(try PairingEndpointV1(
                kind: kind,
                port: port,
                value: reader.readData(count: valueLength, field: "endpoints[\(index)].value")
            ))
        }
        try reader.requireEnd()
        guard publicKey.hostAuthorityID == hostAuthorityID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")
        }
        let verifiedTransportSet = try VerifiedHostTransportSetV1.decode(
            transportBytes,
            hostAuthorityPublicKey: publicKey,
            versionPolicy: versionPolicy
        )
        let decoded = try Self(
            protocolVersion: version,
            ticketID: ticketID,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            hostAuthorityPublicKey: publicKey,
            verifiedTransportSet: verifiedTransportSet,
            ticketSecret: secret,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiresAt,
            endpoints: endpoints,
            versionPolicy: versionPolicy
        )
        guard now < expiresAt else {
            throw HarcProtocolCodecError.expired(field: "PairingTicketV1")
        }
        guard try decoded.encoded() == exactBytes else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "canonicalPairingTicket")
        }
        return decoded
    }

    public static func decodeURI(
        _ uri: String,
        atUnixMilliseconds now: UInt64,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        let uriBytes = Data(uri.utf8)
        guard uriBytes.count <= HarcProtocolLimits.pairingURIBytes,
              String(data: uriBytes, encoding: .ascii) == uri,
              uri.hasPrefix(uriPrefix) else {
            throw HarcProtocolCodecError.invalidPairingURI
        }
        let encoded = String(uri.dropFirst(uriPrefix.count))
        let bytes: Data
        do {
            bytes = try harcDecodeCanonicalBase64URL(encoded)
        } catch {
            throw HarcProtocolCodecError.invalidPairingURI
        }
        let ticket = try decode(
            bytes,
            atUnixMilliseconds: now,
            versionPolicy: versionPolicy
        )
        guard try ticket.encodedURI() == uri else {
            throw HarcProtocolCodecError.invalidPairingURI
        }
        return ticket
    }

    private static func validateCanonicalEndpoints(_ endpoints: [PairingEndpointV1]) throws {
        for (prior, current) in zip(endpoints, endpoints.dropFirst()) {
            switch PairingEndpointV1.compare(prior, current) {
            case .orderedAscending: break
            case .orderedSame:
                throw HarcProtocolCodecError.duplicateValue(field: "endpoints")
            case .orderedDescending:
                throw HarcProtocolCodecError.nonCanonicalOrder(field: "endpoints")
            }
        }
    }
}
