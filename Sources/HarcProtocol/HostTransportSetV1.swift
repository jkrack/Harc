import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

public struct HostTransportEntryV1: Equatable, Hashable, Sendable {
    public let tlsSPKISHA256: Data
    public let notBeforeUnixMilliseconds: UInt64
    public let notAfterUnixMilliseconds: UInt64

    public init(
        tlsSPKISHA256: Data,
        notBeforeUnixMilliseconds: UInt64,
        notAfterUnixMilliseconds: UInt64
    ) throws {
        try harcRequireDigest(tlsSPKISHA256, field: "tlsSPKISHA256")
        guard notAfterUnixMilliseconds > notBeforeUnixMilliseconds else {
            throw HarcProtocolCodecError.invalidTimeRange(field: "transportEntry")
        }
        let lifetime = notAfterUnixMilliseconds - notBeforeUnixMilliseconds
        guard lifetime <= HarcProtocolLimits.transportEntryLifetimeMilliseconds else {
            throw HarcProtocolCodecError.invalidTimeRange(field: "transportEntryLifetime")
        }
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.notBeforeUnixMilliseconds = notBeforeUnixMilliseconds
        self.notAfterUnixMilliseconds = notAfterUnixMilliseconds
    }

    public func isValid(
        atUnixMilliseconds time: UInt64,
        clockSkewMilliseconds: UInt64 = HarcProtocolLimits.transportClockSkewMilliseconds
    ) -> Bool {
        let earliest = notBeforeUnixMilliseconds > clockSkewMilliseconds
            ? notBeforeUnixMilliseconds - clockSkewMilliseconds
            : 0
        let latest = notAfterUnixMilliseconds.addingReportingOverflow(clockSkewMilliseconds)
        let latestPermitted = latest.overflow ? UInt64.max : latest.partialValue
        return time >= earliest && time <= latestPermitted
    }
}

/// A transport set whose exact frame, host signature, registered envelope
/// tuple, key derivation, and payload/header mirrors have all been verified.
public struct VerifiedHostTransportSetV1: Equatable, Hashable, Sendable {
    public let transportSet: HostTransportSetV1
    public let signedObject: HarcSignedObjectV1
    public let hostAuthorityPublicKey: P256X963PublicKey

    public var exactSignedBytes: Data { signedObject.exactFramedBytes }

    public static func decode(
        _ exactSignedBytes: Data,
        hostAuthorityPublicKey: P256X963PublicKey,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        let signedObject = try HarcSignedObjectV1.decode(
            exactSignedBytes,
            versionPolicy: versionPolicy
        )
        // Authenticate the admitted frame before interpreting the independent
        // transport payload. This keeps this specialized public acceptance path
        // aligned with the registered protobuf authentication path.
        try signedObject.verifySignature(using: hostAuthorityPublicKey)
        let payload = try HostTransportSetV1.decode(
            signedObject.exactPayloadBytes,
            versionPolicy: versionPolicy
        )
        let bindings = HarcSignedPayloadBindingsV1(
            protocolVersion: payload.protocolVersion,
            libraryID: payload.libraryID,
            hostAuthorityID: payload.hostAuthorityID,
            issuedAtUnixMilliseconds: payload.issuedAtUnixMilliseconds
        )
        try signedObject.verifyRegistered(
            using: hostAuthorityPublicKey,
            payloadBindings: bindings
        )
        return Self(
            transportSet: payload,
            signedObject: signedObject,
            hostAuthorityPublicKey: hostAuthorityPublicKey
        )
    }

    public func validatedEvidence() throws -> ValidatedTransportSetEvidence {
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: transportSet.libraryID,
            hostAuthorityID: transportSet.hostAuthorityID,
            hostAuthorityPublicKey: hostAuthorityPublicKey
        )
        return try ValidatedTransportSetEvidence(
            hostTrust: hostTrust,
            epoch: transportSet.setEpoch,
            exactSignedBytes: exactSignedBytes
        )
    }

    private init(
        transportSet: HostTransportSetV1,
        signedObject: HarcSignedObjectV1,
        hostAuthorityPublicKey: P256X963PublicKey
    ) {
        self.transportSet = transportSet
        self.signedObject = signedObject
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
    }
}

public struct HostTransportSetV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCTS1\0".utf8)

    public let protocolVersion: HarcProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let setEpoch: UInt64
    public let issuedAtUnixMilliseconds: UInt64
    public let entries: [HostTransportEntryV1]

    public init(
        protocolVersion: HarcProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        setEpoch: UInt64,
        issuedAtUnixMilliseconds: UInt64,
        entries: [HostTransportEntryV1],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        try versionPolicy.validate(protocolVersion)
        guard setEpoch > 0 else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "setEpoch",
                minimum: 1,
                maximum: UInt64.max,
                actual: setEpoch
            )
        }
        guard (1 ... HarcProtocolLimits.transportEntries).contains(entries.count) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "transportEntries",
                minimum: 1,
                maximum: UInt64(HarcProtocolLimits.transportEntries),
                actual: UInt64(entries.count)
            )
        }
        try Self.validateCanonicalEntries(entries)
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.setEpoch = setEpoch
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.entries = entries
    }

    public func encoded() -> Data {
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        writer.append(protocolVersion.major)
        writer.append(protocolVersion.minor)
        writer.append(uuid: libraryID.rawValue)
        writer.append(hostAuthorityID.rawBytes)
        writer.append(setEpoch)
        writer.append(issuedAtUnixMilliseconds)
        writer.append(UInt8(entries.count))
        for entry in entries {
            writer.append(entry.tlsSPKISHA256)
            writer.append(entry.notBeforeUnixMilliseconds)
            writer.append(entry.notAfterUnixMilliseconds)
        }
        return writer.data
    }

    public static func decode(
        _ exactBytes: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        let maximumLength = Self.magic.count + 2 + 2 + 16 + 32 + 8 + 8 + 1
            + HarcProtocolLimits.transportEntries * (32 + 8 + 8)
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: maximumLength,
            field: "HostTransportSetV1"
        )
        try reader.requireMagic(Self.magic, field: "HostTransportSetV1")
        let version = HarcProtocolVersion(
            major: try reader.readUInt16(field: "protocolMajor"),
            minor: try reader.readUInt16(field: "protocolMinor")
        )
        try versionPolicy.validate(version)
        let libraryID = LibraryID(try reader.readUUID(field: "libraryID"))
        let hostAuthorityID = try HostAuthorityID(
            reader.readData(count: HostAuthorityID.byteCount, field: "hostAuthorityID")
        )
        let epoch = try reader.readUInt64(field: "setEpoch")
        let issuedAt = try reader.readUInt64(field: "issuedAtUnixMilliseconds")
        let count = Int(try reader.readUInt8(field: "entryCount"))
        guard (1 ... HarcProtocolLimits.transportEntries).contains(count) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "entryCount",
                minimum: 1,
                maximum: UInt64(HarcProtocolLimits.transportEntries),
                actual: UInt64(count)
            )
        }
        var entries: [HostTransportEntryV1] = []
        entries.reserveCapacity(count)
        for index in 0 ..< count {
            entries.append(try HostTransportEntryV1(
                tlsSPKISHA256: reader.readData(count: 32, field: "entries[\(index)].tlsSPKISHA256"),
                notBeforeUnixMilliseconds: reader.readUInt64(field: "entries[\(index)].notBefore"),
                notAfterUnixMilliseconds: reader.readUInt64(field: "entries[\(index)].notAfter")
            ))
        }
        try reader.requireEnd()
        return try Self(
            protocolVersion: version,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            setEpoch: epoch,
            issuedAtUnixMilliseconds: issuedAt,
            entries: entries,
            versionPolicy: versionPolicy
        )
    }

    public func entry(
        matchingSPKISHA256 digest: Data,
        atUnixMilliseconds time: UInt64,
        clockSkewMilliseconds: UInt64 = HarcProtocolLimits.transportClockSkewMilliseconds
    ) -> HostTransportEntryV1? {
        entries.first {
            $0.tlsSPKISHA256 == digest
                && $0.isValid(atUnixMilliseconds: time, clockSkewMilliseconds: clockSkewMilliseconds)
        }
    }

    private static func validateCanonicalEntries(_ entries: [HostTransportEntryV1]) throws {
        for (prior, current) in zip(entries, entries.dropFirst()) {
            if prior.tlsSPKISHA256 == current.tlsSPKISHA256 {
                throw HarcProtocolCodecError.duplicateValue(field: "transportEntries.tlsSPKISHA256")
            }
            guard prior.tlsSPKISHA256.lexicographicallyPrecedes(current.tlsSPKISHA256) else {
                throw HarcProtocolCodecError.nonCanonicalOrder(field: "transportEntries")
            }
        }
    }
}
