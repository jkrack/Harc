import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocolWire
import HarcTransfer
import SwiftProtobuf

/// Fail-closed errors raised before a generated protobuf value reaches a
/// domain module. The field string is diagnostic only and is never returned as
/// protocol authority.
public enum HarcProtobufConversionError: Error, Equatable, Sendable {
    case inputTooLarge(limit: Int, actual: Int)
    case malformedProtobuf
    case missingField(String)
    case invalidLength(field: String, expected: Int, actual: Int)
    case invalidValue(field: String)
    case integerOutOfRange(field: String)
    case unsupportedEnum(field: String, rawValue: Int)
    case nonCanonicalOrder(field: String)
    case duplicateValue(field: String)
    case unsupportedRequiredFeature(String)
    case unknownCriticalField(UInt32)
    case exactPayloadHashMismatch
    case lossyConversion(field: String)
    case inconsistentField(String)
}

extension HarcProtobufConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let limit, let actual):
            return "Protobuf input exceeds \(limit) bytes; received \(actual)."
        case .malformedProtobuf:
            return "The protobuf payload is malformed."
        case .missingField(let field):
            return "Required protobuf field \(field) is absent."
        case .invalidLength(let field, let expected, let actual):
            return "Protobuf field \(field) must contain \(expected) bytes; received \(actual)."
        case .invalidValue(let field):
            return "Protobuf field \(field) has an invalid value."
        case .integerOutOfRange(let field):
            return "Protobuf field \(field) is outside the supported integer range."
        case .unsupportedEnum(let field, let rawValue):
            return "Protobuf field \(field) uses unsupported enum value \(rawValue)."
        case .nonCanonicalOrder(let field):
            return "Protobuf field \(field) is not in canonical order."
        case .duplicateValue(let field):
            return "Protobuf field \(field) contains a duplicate value."
        case .unsupportedRequiredFeature(let feature):
            return "Required protocol feature \(feature) is unsupported."
        case .unknownCriticalField(let fieldNumber):
            return "Critical protobuf field number \(fieldNumber) is unknown."
        case .exactPayloadHashMismatch:
            return "The exact protobuf payload does not match its declared SHA-256."
        case .lossyConversion(let field):
            return "Protobuf field \(field) cannot be converted without changing its value."
        case .inconsistentField(let field):
            return "Protobuf field \(field) is inconsistent with the containing value."
        }
    }
}

/// Canonically validated compatibility requirements. Keeping the original
/// sorted lists (rather than sets) makes locally serialized payloads stable.
public struct HarcValidatedProtocolRequirements: Equatable, Hashable, Sendable {
    public static let none = try! Self(requiredFeatures: [], criticalFieldNumbers: [])

    public let requiredFeatures: [String]
    public let criticalFieldNumbers: [UInt32]

    public init(
        requiredFeatures: [String],
        criticalFieldNumbers: [UInt32]
    ) throws {
        try harcRequireCanonicalCodes(requiredFeatures, field: "protocol.requirements.requiredFeatures")
        guard criticalFieldNumbers == criticalFieldNumbers.sorted() else {
            throw HarcProtobufConversionError.nonCanonicalOrder(
                field: "protocol.requirements.criticalFieldNumbers"
            )
        }
        guard Set(criticalFieldNumbers).count == criticalFieldNumbers.count else {
            throw HarcProtobufConversionError.duplicateValue(
                field: "protocol.requirements.criticalFieldNumbers"
            )
        }
        for number in criticalFieldNumbers {
            guard harcIsValidProtobufFieldNumber(number) else {
                throw HarcProtobufConversionError.invalidValue(
                    field: "protocol.requirements.criticalFieldNumbers"
                )
            }
        }
        self.requiredFeatures = requiredFeatures
        self.criticalFieldNumbers = criticalFieldNumbers
    }

    public var protobufV1: Harc_V1_ProtocolRequirementsV1 {
        var value = Harc_V1_ProtocolRequirementsV1()
        value.requiredFeatures = requiredFeatures
        value.criticalFieldNumbers = criticalFieldNumbers
        return value
    }
}

/// Runtime compatibility policy for one generated-message interpretation.
/// Known field numbers are supplied at the call site because requirements in
/// the nested version apply to the containing message, not globally.
public struct HarcProtobufCompatibilityPolicy: Equatable, Sendable {
    public static let currentV1 = Self(
        versionPolicy: .currentV1,
        supportedRequiredFeatures: []
    )

    public let versionPolicy: HarcProtocolVersionPolicy
    public let supportedRequiredFeatures: Set<String>

    public init(
        versionPolicy: HarcProtocolVersionPolicy,
        supportedRequiredFeatures: Set<String>
    ) {
        self.versionPolicy = versionPolicy
        self.supportedRequiredFeatures = supportedRequiredFeatures
    }

    public func validate(
        _ value: Harc_V1_ProtocolVersionV1,
        knownCriticalFieldNumbers: Set<UInt32>
    ) throws -> (HarcProtocolVersion, HarcValidatedProtocolRequirements) {
        guard let major = UInt16(exactly: value.major) else {
            throw HarcProtobufConversionError.integerOutOfRange(field: "protocol.major")
        }
        guard let minor = UInt16(exactly: value.minor) else {
            throw HarcProtobufConversionError.integerOutOfRange(field: "protocol.minor")
        }
        let version = HarcProtocolVersion(major: major, minor: minor)
        try versionPolicy.validate(version)

        let requirements: HarcValidatedProtocolRequirements
        if value.hasRequirements {
            requirements = try HarcValidatedProtocolRequirements(
                requiredFeatures: value.requirements.requiredFeatures,
                criticalFieldNumbers: value.requirements.criticalFieldNumbers
            )
        } else {
            requirements = .none
        }

        for feature in requirements.requiredFeatures
            where !supportedRequiredFeatures.contains(feature) {
            throw HarcProtobufConversionError.unsupportedRequiredFeature(feature)
        }
        for number in requirements.criticalFieldNumbers
            where !knownCriticalFieldNumbers.contains(number) {
            throw HarcProtobufConversionError.unknownCriticalField(number)
        }
        return (version, requirements)
    }
}

/// Owns the exact received or once-serialized protobuf bytes alongside their
/// decoded view. Forwarders and signature validators use `exactBytes`; they do
/// not decode and reserialize in order to recover signed bytes.
public struct HarcExactProtobufPayload<Message: SwiftProtobuf.Message>: Sendable {
    public let exactBytes: Data
    public let message: Message

    public init(
        decoding exactBytes: Data,
        as _: Message.Type = Message.self,
        maximumBytes: Int = HarcProtocolLimits.decodedControlPayloadBytes
    ) throws {
        guard exactBytes.count <= maximumBytes else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: maximumBytes,
                actual: exactBytes.count
            )
        }
        do {
            self.message = try Message(serializedBytes: exactBytes)
        } catch {
            throw HarcProtobufConversionError.malformedProtobuf
        }
        self.exactBytes = exactBytes
    }

    /// Serializes a new local payload exactly once. All later hashing,
    /// persistence, signing, and transport must use `exactBytes`.
    public init(
        serializingOnce message: Message,
        maximumBytes: Int = HarcProtocolLimits.decodedControlPayloadBytes
    ) throws {
        let bytes: Data
        do {
            bytes = try message.serializedData()
        } catch {
            throw HarcProtobufConversionError.malformedProtobuf
        }
        guard bytes.count <= maximumBytes else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: maximumBytes,
                actual: bytes.count
            )
        }
        self.message = message
        self.exactBytes = bytes
    }
}

// MARK: - Shared scalar conversions

public extension HarcProtocolVersion {
    func protobufV1(
        requirements: HarcValidatedProtocolRequirements = .none
    ) -> Harc_V1_ProtocolVersionV1 {
        var value = Harc_V1_ProtocolVersionV1()
        value.major = UInt32(major)
        value.minor = UInt32(minor)
        value.requirements = requirements.protobufV1
        return value
    }
}

public extension Harc_V1_LibraryIDV1 {
    init(_ value: LibraryID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> LibraryID { LibraryID(try harcUUIDFromWire(value, field: "libraryID")) }
}

public extension Harc_V1_HostStateIDV1 {
    init(_ value: HostStateID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> HostStateID { HostStateID(try harcUUIDFromWire(value, field: "hostStateID")) }
}

public extension Harc_V1_GrantIDV1 {
    init(_ value: GrantID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> GrantID { GrantID(try harcUUIDFromWire(value, field: "grantID")) }
}

public extension Harc_V1_TicketIDV1 {
    init(_ value: UUID) { self.init(); self.value = harcUUIDBytesForWire(value) }
    func validatedUUID() throws -> UUID { try harcUUIDFromWire(value, field: "ticketID") }
}

public extension Harc_V1_ClaimIDV1 {
    init(_ value: UUID) { self.init(); self.value = harcUUIDBytesForWire(value) }
    func validatedUUID() throws -> UUID { try harcUUIDFromWire(value, field: "claimID") }
}

public extension Harc_V1_ChallengeIDV1 {
    init(_ value: UUID) { self.init(); self.value = harcUUIDBytesForWire(value) }
    func validatedUUID() throws -> UUID { try harcUUIDFromWire(value, field: "challengeID") }
}

public extension Harc_V1_CanonicalRecordingIDV1 {
    init(_ value: CanonicalRecordingID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> CanonicalRecordingID {
        CanonicalRecordingID(try harcUUIDFromWire(value, field: "canonicalRecordingID"))
    }
}

public extension Harc_V1_UploadIDV1 {
    init(_ value: UploadID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> UploadID { UploadID(try harcUUIDFromWire(value, field: "uploadID")) }
}

public extension Harc_V1_OperationIDV1 {
    init(_ value: OperationID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> OperationID { OperationID(try harcUUIDFromWire(value, field: "operationID")) }
}

public extension Harc_V1_ChunkIDV1 {
    init(_ value: ChunkID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> ChunkID { ChunkID(try harcUUIDFromWire(value, field: "chunkID")) }
}

public extension Harc_V1_AudioBatchIDV1 {
    init(_ value: AudioBatchID) { self.init(); self.value = harcUUIDBytesForWire(value.rawValue) }
    func domainValue() throws -> AudioBatchID { AudioBatchID(try harcUUIDFromWire(value, field: "audioBatchID")) }
}

public extension Harc_V1_BatchAckIDV1 {
    init(_ value: UUID) { self.init(); self.value = harcUUIDBytesForWire(value) }
    func validatedUUID() throws -> UUID {
        try harcUUIDFromWire(value, field: "batchAcknowledgementID")
    }
}

public extension Harc_V1_HostAuthorityIDV1 {
    init(_ value: HostAuthorityID) { self.init(); sha256 = value.rawBytes }
    func domainValue() throws -> HostAuthorityID {
        try harcRequireLength(sha256, expected: 32, field: "hostAuthorityID")
        return try HostAuthorityID(sha256)
    }
}

public extension Harc_V1_DeviceIDV1 {
    init(_ value: DeviceID) { self.init(); sha256 = value.rawBytes }
    func domainValue() throws -> DeviceID {
        try harcRequireLength(sha256, expected: 32, field: "deviceID")
        return try DeviceID(sha256)
    }
}

public extension Harc_V1_OriginRecordingIDV1 {
    init(_ value: OriginRecordingID) {
        self.init()
        deviceID = Harc_V1_DeviceIDV1(value.deviceID)
        recordingUuid = harcUUIDBytesForWire(value.recordingUUID)
    }

    func domainValue() throws -> OriginRecordingID {
        guard hasDeviceID else {
            throw HarcProtobufConversionError.missingField("originRecordingID.deviceID")
        }
        return OriginRecordingID(
            deviceID: try deviceID.domainValue(),
            recordingUUID: try harcUUIDFromWire(
                recordingUuid,
                field: "originRecordingID.recordingUUID"
            )
        )
    }
}

public extension Harc_V1_SHA256DigestV1 {
    init(exactBytes: Data) throws {
        self.init()
        try harcRequireLength(exactBytes, expected: 32, field: "sha256")
        value = exactBytes
    }

    func validatedBytes(field: String) throws -> Data {
        try harcRequireLength(value, expected: 32, field: field)
        return value
    }
}

public extension Harc_V1_CanonicalPCMFormatV1 {
    init(_ value: CanonicalPCMFormat) {
        self.init()
        sampleRateHz = value.sampleRateHz
        channelCount = UInt32(value.channelCount)
        switch value.encoding {
        case .signedInt16LittleEndian:
            encoding = .canonicalPcmEncodingSignedInt16LittleEndian
        }
    }

    func domainValue() throws -> CanonicalPCMFormat {
        let domainEncoding: CanonicalPCMEncoding
        switch encoding {
        case .canonicalPcmEncodingSignedInt16LittleEndian:
            domainEncoding = .signedInt16LittleEndian
        case .canonicalPcmEncodingUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "canonicalFormat.encoding",
                rawValue: encoding.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "canonicalFormat.encoding",
                rawValue: rawValue
            )
        }
        guard let channelCount = UInt16(exactly: channelCount) else {
            throw HarcProtobufConversionError.integerOutOfRange(
                field: "canonicalFormat.channelCount"
            )
        }
        return try CanonicalPCMFormat(
            sampleRateHz: sampleRateHz,
            channelCount: channelCount,
            encoding: domainEncoding
        )
    }
}

public extension Harc_V1_CanonicalFrameRangeV1 {
    init(_ value: CanonicalFrameRange) {
        self.init()
        startFrame = value.startFrame
        endFrameExclusive = value.endFrameExclusive
    }

    func domainValue() throws -> CanonicalFrameRange {
        try CanonicalFrameRange(startFrame: startFrame, endFrameExclusive: endFrameExclusive)
    }
}

// MARK: - Processing and projection

public extension Harc_V1_ProcessingFailureV1 {
    init(_ value: ProcessingFailure) {
        self.init()
        code = value.code
        if let message = value.message { self.message = message }
    }

    func domainValue() throws -> ProcessingFailure {
        let value = try ProcessingFailure(code: code, message: hasMessage ? message : nil)
        guard value.code == code, value.message == (hasMessage ? message : nil) else {
            throw HarcProtobufConversionError.lossyConversion(field: "processingFailure")
        }
        return value
    }
}

public extension Harc_V1_ProcessingDescriptorV1 {
    init(_ value: ProcessingDescriptor) {
        self.init()
        switch value.state {
        case .pending: state = .recordingProcessingStatePending
        case .transcribing: state = .recordingProcessingStateTranscribing
        case .projecting: state = .recordingProcessingStateProjecting
        case .ready: state = .recordingProcessingStateReady
        case .degraded: state = .recordingProcessingStateDegraded
        case .failedRecoverable: state = .recordingProcessingStateFailedRecoverable
        }
        if let failure = value.failure { self.failure = Harc_V1_ProcessingFailureV1(failure) }
    }

    func domainValue() throws -> ProcessingDescriptor {
        let domainState: RecordingProcessingState
        switch state {
        case .recordingProcessingStatePending: domainState = .pending
        case .recordingProcessingStateTranscribing: domainState = .transcribing
        case .recordingProcessingStateProjecting: domainState = .projecting
        case .recordingProcessingStateReady: domainState = .ready
        case .recordingProcessingStateDegraded: domainState = .degraded
        case .recordingProcessingStateFailedRecoverable: domainState = .failedRecoverable
        case .recordingProcessingStateUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "processing.state",
                rawValue: state.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "processing.state",
                rawValue: rawValue
            )
        }
        return try ProcessingDescriptor(
            state: domainState,
            failure: hasFailure ? try failure.domainValue() : nil
        )
    }
}

public extension Harc_V1_ProjectionDescriptorV1 {
    init(_ value: ProjectionDescriptor) {
        self.init()
        switch value.state {
        case .unknownLegacy: state = .recordingProjectionStateUnknownLegacy
        case .pending: state = .recordingProjectionStatePending
        case .projecting: state = .recordingProjectionStateProjecting
        case .ready: state = .recordingProjectionStateReady
        case .degraded: state = .recordingProjectionStateDegraded
        case .failedRecoverable: state = .recordingProjectionStateFailedRecoverable
        }
        if let version = value.version { self.version = version.rawValue }
        if let failure = value.failure { self.failure = Harc_V1_ProcessingFailureV1(failure) }
    }

    func domainValue() throws -> ProjectionDescriptor {
        let domainState: RecordingProjectionState
        switch state {
        case .recordingProjectionStateUnknownLegacy: domainState = .unknownLegacy
        case .recordingProjectionStatePending: domainState = .pending
        case .recordingProjectionStateProjecting: domainState = .projecting
        case .recordingProjectionStateReady: domainState = .ready
        case .recordingProjectionStateDegraded: domainState = .degraded
        case .recordingProjectionStateFailedRecoverable: domainState = .failedRecoverable
        case .recordingProjectionStateUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "projection.state",
                rawValue: state.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "projection.state",
                rawValue: rawValue
            )
        }
        return try ProjectionDescriptor(
            state: domainState,
            version: hasVersion ? try ProjectionVersion(version) : nil,
            failure: hasFailure ? try failure.domainValue() : nil
        )
    }
}

// MARK: - Lossless encoding

public extension Harc_V1_LosslessEncodingConfigurationV1 {
    init(_ value: LosslessEncodingConfiguration) {
        self.init()
        switch value.codec {
        case .appleLossless: codec = .losslessAudioCodecAppleLossless
        case .flac: codec = .losslessAudioCodecFlac
        case .rawCanonicalPCMFixture: codec = .losslessAudioCodecRawCanonicalPcmFixture
        }
        switch value.container {
        case .coreAudioFormat: container = .losslessAudioContainerCoreAudioFormat
        case .flac: container = .losslessAudioContainerFlac
        case .rawCanonicalPCMFixture: container = .losslessAudioContainerRawCanonicalPcmFixture
        }
        if let level = value.flacCompressionLevel { flacCompressionLevel = UInt32(level) }
    }

    func domainValue() throws -> LosslessEncodingConfiguration {
        let domainCodec: LosslessAudioCodec
        switch codec {
        case .losslessAudioCodecAppleLossless: domainCodec = .appleLossless
        case .losslessAudioCodecFlac: domainCodec = .flac
        case .losslessAudioCodecRawCanonicalPcmFixture: domainCodec = .rawCanonicalPCMFixture
        case .losslessAudioCodecUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(field: "encoding.codec", rawValue: codec.rawValue)
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(field: "encoding.codec", rawValue: rawValue)
        }
        let domainContainer: LosslessAudioContainer
        switch container {
        case .losslessAudioContainerCoreAudioFormat: domainContainer = .coreAudioFormat
        case .losslessAudioContainerFlac: domainContainer = .flac
        case .losslessAudioContainerRawCanonicalPcmFixture: domainContainer = .rawCanonicalPCMFixture
        case .losslessAudioContainerUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "encoding.container",
                rawValue: container.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "encoding.container",
                rawValue: rawValue
            )
        }
        let level: UInt8?
        if hasFlacCompressionLevel {
            guard let exact = UInt8(exactly: flacCompressionLevel) else {
                throw HarcProtobufConversionError.integerOutOfRange(
                    field: "encoding.flacCompressionLevel"
                )
            }
            level = exact
        } else {
            level = nil
        }
        return try LosslessEncodingConfiguration(
            codec: domainCodec,
            container: domainContainer,
            flacCompressionLevel: level
        )
    }
}

// MARK: - Identity claims

public extension Harc_V1_AuthorizationScopeV1 {
    init(_ value: AuthorizationScope) {
        switch value {
        case .libraryAudioRead: self = .authorizationScopeLibraryAudioRead
        case .libraryMetadataRead: self = .authorizationScopeLibraryMetadataRead
        case .libraryMetadataWrite: self = .authorizationScopeLibraryMetadataWrite
        case .libraryTranscriptRead: self = .authorizationScopeLibraryTranscriptRead
        case .processingSubmitOwn: self = .authorizationScopeProcessingSubmitOwn
        case .recordingReadOwn: self = .authorizationScopeRecordingReadOwn
        case .recordingUploadOwn: self = .authorizationScopeRecordingUploadOwn
        }
    }

    func domainValue() throws -> AuthorizationScope {
        switch self {
        case .authorizationScopeLibraryAudioRead: return .libraryAudioRead
        case .authorizationScopeLibraryMetadataRead: return .libraryMetadataRead
        case .authorizationScopeLibraryMetadataWrite: return .libraryMetadataWrite
        case .authorizationScopeLibraryTranscriptRead: return .libraryTranscriptRead
        case .authorizationScopeProcessingSubmitOwn: return .processingSubmitOwn
        case .authorizationScopeRecordingReadOwn: return .recordingReadOwn
        case .authorizationScopeRecordingUploadOwn: return .recordingUploadOwn
        case .authorizationScopeUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "authorizationScope",
                rawValue: rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "authorizationScope",
                rawValue: rawValue
            )
        }
    }
}

public extension Harc_V1_DeviceGrantV1 {
    init(
        _ value: DeviceGrantClaims,
        requirements: HarcValidatedProtocolRequirements = .none
    ) throws {
        self.init()
        `protocol` = HarcProtocolVersion(
            major: value.protocolVersion.major,
            minor: value.protocolVersion.minor
        ).protobufV1(requirements: requirements)
        libraryID = Harc_V1_LibraryIDV1(value.libraryID)
        hostAuthorityID = Harc_V1_HostAuthorityIDV1(value.hostAuthorityID)
        grantID = Harc_V1_GrantIDV1(value.grantID)
        deviceID = Harc_V1_DeviceIDV1(value.deviceID)
        devicePublicKeyX963 = value.devicePublicKey.rawBytes
        scopes = value.scopes.map(Harc_V1_AuthorizationScopeV1.init)
        grantEpoch = value.grantEpoch.rawValue
        issuedAtUnixMs = try harcWireUnixMilliseconds(value.issuedAt, field: "deviceGrant.issuedAt")
        if let expiresAt = value.expiresAt {
            expiresAtUnixMs = try harcWireUnixMilliseconds(expiresAt, field: "deviceGrant.expiresAt")
        }
        minimumCompatibleProtocolMinor = UInt32(value.minimumCompatibleProtocolMinor)
        maximumCompatibleProtocolMinor = UInt32(value.maximumCompatibleProtocolMinor)
    }

    func domainValue(
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws -> DeviceGrantClaims {
        guard hasProtocol else { throw HarcProtobufConversionError.missingField("deviceGrant.protocol") }
        guard hasLibraryID else { throw HarcProtobufConversionError.missingField("deviceGrant.libraryID") }
        guard hasHostAuthorityID else {
            throw HarcProtobufConversionError.missingField("deviceGrant.hostAuthorityID")
        }
        guard hasGrantID else { throw HarcProtobufConversionError.missingField("deviceGrant.grantID") }
        guard hasDeviceID else { throw HarcProtobufConversionError.missingField("deviceGrant.deviceID") }

        let validatedVersion = try compatibility.validate(
            `protocol`,
            knownCriticalFieldNumbers: Set(1 ... 12)
        ).0
        let publicKey = try P256X963PublicKey(devicePublicKeyX963)
        let decodedScopes = try scopes.map { try $0.domainValue() }
        guard let minimumMinor = UInt16(exactly: minimumCompatibleProtocolMinor),
              let maximumMinor = UInt16(exactly: maximumCompatibleProtocolMinor) else {
            throw HarcProtobufConversionError.integerOutOfRange(
                field: "deviceGrant.compatibleProtocolMinor"
            )
        }
        return try DeviceGrantClaims(
            protocolVersion: IdentityProtocolVersion(
                major: validatedVersion.major,
                minor: validatedVersion.minor
            ),
            libraryID: try libraryID.domainValue(),
            hostAuthorityID: try hostAuthorityID.domainValue(),
            grantID: try grantID.domainValue(),
            deviceID: try deviceID.domainValue(),
            devicePublicKey: publicKey,
            scopes: decodedScopes,
            grantEpoch: try GrantEpoch(grantEpoch),
            issuedAt: try harcWireDateFromUnixMilliseconds(issuedAtUnixMs, field: "deviceGrant.issuedAt"),
            expiresAt: hasExpiresAtUnixMs
                ? try harcWireDateFromUnixMilliseconds(expiresAtUnixMs, field: "deviceGrant.expiresAt")
                : nil,
            minimumCompatibleProtocolMinor: minimumMinor,
            maximumCompatibleProtocolMinor: maximumMinor
        )
    }
}

public extension Harc_V1_DeviceRevocationV1 {
    init(
        _ value: DeviceRevocationClaims,
        requirements: HarcValidatedProtocolRequirements = .none
    ) throws {
        self.init()
        `protocol` = HarcProtocolVersion(
            major: value.protocolVersion.major,
            minor: value.protocolVersion.minor
        ).protobufV1(requirements: requirements)
        libraryID = Harc_V1_LibraryIDV1(value.libraryID)
        hostAuthorityID = Harc_V1_HostAuthorityIDV1(value.hostAuthorityID)
        deviceID = Harc_V1_DeviceIDV1(value.deviceID)
        grantID = Harc_V1_GrantIDV1(value.grantID)
        priorGrantEpoch = value.priorGrantEpoch.rawValue
        newGrantEpoch = value.newGrantEpoch.rawValue
        var wireRevocationID = Harc_V1_RevocationIDV1()
        wireRevocationID.value = harcUUIDBytesForWire(value.revocationID)
        revocationID = wireRevocationID
        reasonCode = value.reasonCode
        issuedAtUnixMs = try harcWireUnixMilliseconds(value.issuedAt, field: "deviceRevocation.issuedAt")
    }

    func domainValue(
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws -> DeviceRevocationClaims {
        guard hasProtocol else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.protocol")
        }
        guard hasLibraryID else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.libraryID")
        }
        guard hasHostAuthorityID else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.hostAuthorityID")
        }
        guard hasDeviceID else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.deviceID")
        }
        guard hasGrantID else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.grantID")
        }
        guard hasRevocationID else {
            throw HarcProtobufConversionError.missingField("deviceRevocation.revocationID")
        }
        let validatedVersion = try compatibility.validate(
            `protocol`,
            knownCriticalFieldNumbers: Set(1 ... 10)
        ).0
        return try DeviceRevocationClaims(
            protocolVersion: IdentityProtocolVersion(
                major: validatedVersion.major,
                minor: validatedVersion.minor
            ),
            libraryID: try libraryID.domainValue(),
            hostAuthorityID: try hostAuthorityID.domainValue(),
            deviceID: try deviceID.domainValue(),
            grantID: try grantID.domainValue(),
            priorGrantEpoch: try GrantEpoch(priorGrantEpoch),
            newGrantEpoch: try GrantEpoch(newGrantEpoch),
            revocationID: try harcUUIDFromWire(
                revocationID.value,
                field: "deviceRevocation.revocationID"
            ),
            reasonCode: reasonCode,
            issuedAt: try harcWireDateFromUnixMilliseconds(
                issuedAtUnixMs,
                field: "deviceRevocation.issuedAt"
            )
        )
    }
}

// MARK: - Capture and transfer values

public extension Harc_V1_CaptureRouteDescriptorV1 {
    init(_ value: CaptureRouteDescriptor) {
        self.init()
        if let identifier = value.identifier { self.identifier = identifier }
        if let name = value.name { self.name = name }
        if let sampleRateHz = value.sampleRateHz { self.sampleRateHz = sampleRateHz }
        if let channelCount = value.channelCount { self.channelCount = channelCount }
    }

    func domainValue() throws -> CaptureRouteDescriptor {
        let originalIdentifier = hasIdentifier ? identifier : nil
        let originalName = hasName ? name : nil
        let originalRate = hasSampleRateHz ? sampleRateHz : nil
        let originalChannels = hasChannelCount ? channelCount : nil
        let value = try CaptureRouteDescriptor(
            identifier: originalIdentifier,
            name: originalName,
            sampleRateHz: originalRate,
            channelCount: originalChannels
        )
        guard value.identifier == originalIdentifier, value.name == originalName else {
            throw HarcProtobufConversionError.lossyConversion(field: "captureRoute")
        }
        return value
    }
}

public extension Harc_V1_CaptureDiscontinuityV1 {
    init(_ value: CaptureDiscontinuity) throws {
        self.init()
        originRecordingID = Harc_V1_OriginRecordingIDV1(value.recordingID)
        monotonicTimeNanoseconds = value.monotonicTimeNanoseconds
        wallTimeUnixMs = try harcWireUnixMilliseconds(
            value.wallTime,
            field: "captureDiscontinuity.wallTime"
        )
        switch value.reason {
        case .interruptionBegan: reason = .captureDiscontinuityReasonInterruptionBegan
        case .interruptionEnded: reason = .captureDiscontinuityReasonInterruptionEnded
        case .routeChanged: reason = .captureDiscontinuityReasonRouteChanged
        case .engineConfigurationChanged: reason = .captureDiscontinuityReasonEngineConfigurationChanged
        case .mediaServicesLost: reason = .captureDiscontinuityReasonMediaServicesLost
        case .mediaServicesReset: reason = .captureDiscontinuityReasonMediaServicesReset
        case .writerFailure: reason = .captureDiscontinuityReasonWriterFailure
        case .bufferOverrun: reason = .captureDiscontinuityReasonBufferOverrun
        case .recovery: reason = .captureDiscontinuityReasonRecovery
        }
        if let oldRoute = value.oldRoute { self.oldRoute = Harc_V1_CaptureRouteDescriptorV1(oldRoute) }
        if let newRoute = value.newRoute { self.newRoute = Harc_V1_CaptureRouteDescriptorV1(newRoute) }
        affectedFrames = Harc_V1_CanonicalFrameRangeV1(value.affectedFrames)
        switch value.canonicalizationPolicy {
        case .preserveCapturedPCM:
            canonicalizationPolicy = .captureCanonicalizationPolicyPreserveCapturedPcm
        case .annotateGapWithoutInsertedSilence:
            canonicalizationPolicy = .captureCanonicalizationPolicyAnnotateGapWithoutInsertedSilence
        }
    }

    func domainValue() throws -> CaptureDiscontinuity {
        guard hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField("captureDiscontinuity.originRecordingID")
        }
        guard hasAffectedFrames else {
            throw HarcProtobufConversionError.missingField("captureDiscontinuity.affectedFrames")
        }
        let domainReason: CaptureDiscontinuityReason
        switch reason {
        case .captureDiscontinuityReasonInterruptionBegan: domainReason = .interruptionBegan
        case .captureDiscontinuityReasonInterruptionEnded: domainReason = .interruptionEnded
        case .captureDiscontinuityReasonRouteChanged: domainReason = .routeChanged
        case .captureDiscontinuityReasonEngineConfigurationChanged: domainReason = .engineConfigurationChanged
        case .captureDiscontinuityReasonMediaServicesLost: domainReason = .mediaServicesLost
        case .captureDiscontinuityReasonMediaServicesReset: domainReason = .mediaServicesReset
        case .captureDiscontinuityReasonWriterFailure: domainReason = .writerFailure
        case .captureDiscontinuityReasonBufferOverrun: domainReason = .bufferOverrun
        case .captureDiscontinuityReasonRecovery: domainReason = .recovery
        case .captureDiscontinuityReasonUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "captureDiscontinuity.reason",
                rawValue: reason.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "captureDiscontinuity.reason",
                rawValue: rawValue
            )
        }
        let domainPolicy: CaptureCanonicalizationPolicy
        switch canonicalizationPolicy {
        case .captureCanonicalizationPolicyPreserveCapturedPcm:
            domainPolicy = .preserveCapturedPCM
        case .captureCanonicalizationPolicyAnnotateGapWithoutInsertedSilence:
            domainPolicy = .annotateGapWithoutInsertedSilence
        case .captureCanonicalizationPolicyUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "captureDiscontinuity.canonicalizationPolicy",
                rawValue: canonicalizationPolicy.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "captureDiscontinuity.canonicalizationPolicy",
                rawValue: rawValue
            )
        }
        return try CaptureDiscontinuity(
            recordingID: try originRecordingID.domainValue(),
            monotonicTimeNanoseconds: monotonicTimeNanoseconds,
            wallTime: try harcWireDateFromUnixMilliseconds(
                wallTimeUnixMs,
                field: "captureDiscontinuity.wallTime"
            ),
            reason: domainReason,
            oldRoute: hasOldRoute ? try oldRoute.domainValue() : nil,
            newRoute: hasNewRoute ? try newRoute.domainValue() : nil,
            affectedFrames: try affectedFrames.domainValue(),
            canonicalizationPolicy: domainPolicy
        )
    }
}

public extension Harc_V1_ChunkDescriptorV1 {
    init(_ value: LogicalChunkDescriptor) throws {
        self.init()
        originRecordingID = Harc_V1_OriginRecordingIDV1(value.originRecordingID)
        chunkID = Harc_V1_ChunkIDV1(value.chunkID)
        chunkIndex = value.chunkIndex
        canonicalStartFrame = value.canonicalStartFrame
        canonicalFrameCount = value.canonicalFrameCount
        canonicalFormat = Harc_V1_CanonicalPCMFormatV1(value.canonicalFormat)
        encoding = Harc_V1_LosslessEncodingConfigurationV1(value.encoding)
        encodedByteLength = value.encodedByteLength
        encodedSha256 = try Harc_V1_SHA256DigestV1(exactBytes: value.encodedSHA256.rawBytes)
        canonicalDecodedByteLength = value.canonicalDecodedByteLength
        canonicalDecodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: value.canonicalDecodedSHA256.rawBytes
        )
    }

    func domainValue() throws -> LogicalChunkDescriptor {
        guard hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField("chunk.originRecordingID")
        }
        guard hasChunkID else { throw HarcProtobufConversionError.missingField("chunk.chunkID") }
        guard hasCanonicalFormat else {
            throw HarcProtobufConversionError.missingField("chunk.canonicalFormat")
        }
        guard hasEncoding else { throw HarcProtobufConversionError.missingField("chunk.encoding") }
        guard hasEncodedSha256 else {
            throw HarcProtobufConversionError.missingField("chunk.encodedSHA256")
        }
        guard hasCanonicalDecodedSha256 else {
            throw HarcProtobufConversionError.missingField("chunk.canonicalDecodedSHA256")
        }
        return try LogicalChunkDescriptor(
            originRecordingID: try originRecordingID.domainValue(),
            chunkID: try chunkID.domainValue(),
            chunkIndex: chunkIndex,
            canonicalStartFrame: canonicalStartFrame,
            canonicalFrameCount: canonicalFrameCount,
            canonicalFormat: try canonicalFormat.domainValue(),
            encoding: try encoding.domainValue(),
            encodedByteLength: encodedByteLength,
            encodedSHA256: try EncodedChunkSHA256(
                encodedSha256.validatedBytes(field: "chunk.encodedSHA256")
            ),
            canonicalDecodedByteLength: canonicalDecodedByteLength,
            canonicalDecodedSHA256: try CanonicalPCMHash(
                canonicalDecodedSha256.validatedBytes(field: "chunk.canonicalDecodedSHA256")
            )
        )
    }
}

public extension Harc_V1_DurableChunkV1 {
    init(_ value: DurableChunkStatus) throws {
        self.init()
        chunkIndex = value.chunkIndex
        chunkID = Harc_V1_ChunkIDV1(value.chunkID)
        encodedSha256 = try Harc_V1_SHA256DigestV1(exactBytes: value.encodedSHA256.rawBytes)
    }

    func domainValue() throws -> DurableChunkStatus {
        guard hasChunkID else {
            throw HarcProtobufConversionError.missingField("durableChunk.chunkID")
        }
        guard hasEncodedSha256 else {
            throw HarcProtobufConversionError.missingField("durableChunk.encodedSHA256")
        }
        return DurableChunkStatus(
            chunkIndex: chunkIndex,
            chunkID: try chunkID.domainValue(),
            encodedSHA256: try EncodedChunkSHA256(
                encodedSha256.validatedBytes(field: "durableChunk.encodedSHA256")
            )
        )
    }
}

public extension Harc_V1_RejectedChunkV1 {
    init(_ value: RejectedChunkStatus) {
        self.init()
        chunkIndex = value.chunkIndex
        chunkID = Harc_V1_ChunkIDV1(value.chunkID)
        switch value.reason {
        case .missingBytes: reason = .rejectedChunkReasonMissingBytes
        case .lengthMismatch: reason = .rejectedChunkReasonLengthMismatch
        case .encodedHashMismatch: reason = .rejectedChunkReasonEncodedHashMismatch
        case .decodedHashMismatch: reason = .rejectedChunkReasonDecodedHashMismatch
        case .corruptContainer: reason = .rejectedChunkReasonCorruptContainer
        case .unsupportedEncoding: reason = .rejectedChunkReasonUnsupportedEncoding
        case .quotaExhausted: reason = .rejectedChunkReasonQuotaExhausted
        }
    }

    func domainValue() throws -> RejectedChunkStatus {
        guard hasChunkID else {
            throw HarcProtobufConversionError.missingField("rejectedChunk.chunkID")
        }
        let domainReason: RejectedChunkReason
        switch reason {
        case .rejectedChunkReasonMissingBytes: domainReason = .missingBytes
        case .rejectedChunkReasonLengthMismatch: domainReason = .lengthMismatch
        case .rejectedChunkReasonEncodedHashMismatch: domainReason = .encodedHashMismatch
        case .rejectedChunkReasonDecodedHashMismatch: domainReason = .decodedHashMismatch
        case .rejectedChunkReasonCorruptContainer: domainReason = .corruptContainer
        case .rejectedChunkReasonUnsupportedEncoding: domainReason = .unsupportedEncoding
        case .rejectedChunkReasonQuotaExhausted: domainReason = .quotaExhausted
        case .rejectedChunkReasonUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "rejectedChunk.reason",
                rawValue: reason.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "rejectedChunk.reason",
                rawValue: rawValue
            )
        }
        return RejectedChunkStatus(
            chunkIndex: chunkIndex,
            chunkID: try chunkID.domainValue(),
            reason: domainReason
        )
    }
}

/// A frozen upload profile decoded from—and still bound to—the exact bytes
/// whose SHA-256 is stored in the domain value.
public struct HarcValidatedUploadProfilePayload: Sendable {
    public let exactPayload: HarcExactProtobufPayload<Harc_V1_UploadProfileV1>
    public let domainValue: FrozenUploadProfile

    public init(
        decoding exactBytes: Data,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let exactPayload = try HarcExactProtobufPayload(
            decoding: exactBytes,
            as: Harc_V1_UploadProfileV1.self
        )
        self.domainValue = try exactPayload.message.domainValue(
            exactPayloadBytes: exactBytes,
            compatibility: compatibility
        )
        self.exactPayload = exactPayload
    }

    public init(
        serializing domainValue: FrozenUploadProfile,
        requirements: HarcValidatedProtocolRequirements = .none
    ) throws {
        let message = try Harc_V1_UploadProfileV1(
            domainValue,
            requirements: requirements
        )
        let exactPayload = try HarcExactProtobufPayload(serializingOnce: message)
        let digest = HarcSignedEnvelopeV1.payloadDigest(exactPayload.exactBytes)
        guard digest == domainValue.profileSHA256.rawBytes else {
            throw HarcProtobufConversionError.exactPayloadHashMismatch
        }
        self.domainValue = domainValue
        self.exactPayload = exactPayload
    }
}

public extension Harc_V1_UploadProfileV1 {
    init(
        _ value: FrozenUploadProfile,
        requirements: HarcValidatedProtocolRequirements = .none
    ) throws {
        self.init()
        `protocol` = HarcProtocolVersion(
            major: value.protocolVersion.major,
            minor: value.protocolVersion.minor
        ).protobufV1(requirements: requirements)
        descriptorSchemaID = value.descriptorSchema.rawValue
        encoding = Harc_V1_LosslessEncodingConfigurationV1(value.encoding)
        canonicalFormat = Harc_V1_CanonicalPCMFormatV1(value.canonicalFormat)
        requiredCapabilityIds = value.requiredCapabilities.map(\.rawValue)
        negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: value.negotiatedCapabilitiesSHA256.rawBytes
        )
        switch value.purpose {
        case .production: purpose = .uploadProfilePurposeProduction
        case .physicalDeviceCodecEvaluation:
            purpose = .uploadProfilePurposePhysicalDeviceCodecEvaluation
        case .fixtureLoopback: purpose = .uploadProfilePurposeFixtureLoopback
        }
    }

    package func domainValue(
        exactPayloadBytes: Data,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws -> FrozenUploadProfile {
        let rebound = try HarcExactProtobufPayload(
            decoding: exactPayloadBytes,
            as: Harc_V1_UploadProfileV1.self
        )
        guard rebound.message == self else {
            throw HarcProtobufConversionError.inconsistentField(
                "uploadProfile.exactPayloadBytes"
            )
        }
        guard hasProtocol else { throw HarcProtobufConversionError.missingField("uploadProfile.protocol") }
        guard hasEncoding else { throw HarcProtobufConversionError.missingField("uploadProfile.encoding") }
        guard hasCanonicalFormat else {
            throw HarcProtobufConversionError.missingField("uploadProfile.canonicalFormat")
        }
        guard hasNegotiatedCapabilitiesSha256 else {
            throw HarcProtobufConversionError.missingField(
                "uploadProfile.negotiatedCapabilitiesSHA256"
            )
        }
        let validatedVersion = try compatibility.validate(
            `protocol`,
            knownCriticalFieldNumbers: Set(1 ... 7)
        ).0
        guard let schema = ChunkDescriptorSchema(rawValue: descriptorSchemaID) else {
            throw HarcProtobufConversionError.invalidValue(field: "uploadProfile.descriptorSchemaID")
        }
        let capabilities = try requiredCapabilityIds.map { raw -> TransferCapabilityID in
            let value = try TransferCapabilityID(raw)
            guard value.rawValue == raw else {
                throw HarcProtobufConversionError.lossyConversion(
                    field: "uploadProfile.requiredCapabilityIDs"
                )
            }
            return value
        }
        let domainPurpose: UploadProfilePurpose
        switch purpose {
        case .uploadProfilePurposeProduction: domainPurpose = .production
        case .uploadProfilePurposePhysicalDeviceCodecEvaluation:
            domainPurpose = .physicalDeviceCodecEvaluation
        case .uploadProfilePurposeFixtureLoopback: domainPurpose = .fixtureLoopback
        case .uploadProfilePurposeUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "uploadProfile.purpose",
                rawValue: purpose.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "uploadProfile.purpose",
                rawValue: rawValue
            )
        }
        return try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(
                major: validatedVersion.major,
                minor: validatedVersion.minor
            ),
            descriptorSchema: schema,
            encoding: try encoding.domainValue(),
            canonicalFormat: try canonicalFormat.domainValue(),
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: try NegotiatedCapabilitiesSHA256(
                negotiatedCapabilitiesSha256.validatedBytes(
                    field: "uploadProfile.negotiatedCapabilitiesSHA256"
                )
            ),
            profileSHA256: try UploadProfileSHA256(
                HarcSignedEnvelopeV1.payloadDigest(exactPayloadBytes)
            ),
            purpose: domainPurpose
        )
    }
}

// MARK: - Path-free library values

public extension Harc_V1_CanonicalAudioDescriptorV1 {
    init(_ value: CanonicalAudioDescriptor) throws {
        self.init()
        switch value.availability {
        case .unavailablePendingHash:
            availability = .canonicalAudioAvailabilityUnavailablePendingHash
        case .available:
            availability = .canonicalAudioAvailabilityAvailable
            if let digest = value.pcmSHA256 {
                canonicalPcmSha256 = try Harc_V1_SHA256DigestV1(exactBytes: digest.rawBytes)
            }
            if let frames = value.totalFrames { totalFrames = frames }
            if let format = value.format { canonicalFormat = Harc_V1_CanonicalPCMFormatV1(format) }
        }
    }

    func domainValue() throws -> CanonicalAudioDescriptor {
        switch availability {
        case .canonicalAudioAvailabilityUnavailablePendingHash:
            guard !hasCanonicalPcmSha256, !hasTotalFrames, !hasCanonicalFormat else {
                throw HarcProtobufConversionError.inconsistentField("canonicalAudio.availability")
            }
            return .unavailablePendingHash
        case .canonicalAudioAvailabilityAvailable:
            guard hasCanonicalPcmSha256 else {
                throw HarcProtobufConversionError.missingField("canonicalAudio.canonicalPCMSHA256")
            }
            guard hasTotalFrames else {
                throw HarcProtobufConversionError.missingField("canonicalAudio.totalFrames")
            }
            guard hasCanonicalFormat else {
                throw HarcProtobufConversionError.missingField("canonicalAudio.canonicalFormat")
            }
            return try .available(
                pcmSHA256: CanonicalPCMHash(
                    canonicalPcmSha256.validatedBytes(
                        field: "canonicalAudio.canonicalPCMSHA256"
                    )
                ),
                totalFrames: totalFrames,
                format: canonicalFormat.domainValue()
            )
        case .canonicalAudioAvailabilityUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "canonicalAudio.availability",
                rawValue: availability.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "canonicalAudio.availability",
                rawValue: rawValue
            )
        }
    }
}

public extension Harc_V1_LibraryRecordingSummaryV1 {
    init(_ value: LibraryRecordingSummary) throws {
        self.init()
        canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(value.canonicalID)
        if let originID = value.originID {
            originRecordingID = Harc_V1_OriginRecordingIDV1(originID)
        }
        revision = value.revision.rawValue
        startedAtUnixMs = try harcWireUnixMilliseconds(value.startedAt, field: "recordingSummary.startedAt")
        if let endedAt = value.endedAt {
            endedAtUnixMs = try harcWireUnixMilliseconds(endedAt, field: "recordingSummary.endedAt")
        }
        if let title = value.title { self.title = title }
        if let suggestedTitle = value.suggestedTitle { self.suggestedTitle = suggestedTitle }
        tags = value.tags
        pinned = value.pinned
        canonicalAudio = try Harc_V1_CanonicalAudioDescriptorV1(value.canonicalAudio)
        processing = Harc_V1_ProcessingDescriptorV1(value.processing)
        projection = Harc_V1_ProjectionDescriptorV1(value.projection)
    }

    func domainValue() throws -> LibraryRecordingSummary {
        guard hasCanonicalRecordingID else {
            throw HarcProtobufConversionError.missingField("recordingSummary.canonicalRecordingID")
        }
        guard hasCanonicalAudio else {
            throw HarcProtobufConversionError.missingField("recordingSummary.canonicalAudio")
        }
        guard hasProcessing else {
            throw HarcProtobufConversionError.missingField("recordingSummary.processing")
        }
        guard hasProjection else {
            throw HarcProtobufConversionError.missingField("recordingSummary.projection")
        }
        return try LibraryRecordingSummary(
            canonicalID: canonicalRecordingID.domainValue(),
            originID: hasOriginRecordingID ? try originRecordingID.domainValue() : nil,
            revision: EntityRevision(revision),
            startedAt: harcWireDateFromUnixMilliseconds(
                startedAtUnixMs,
                field: "recordingSummary.startedAt"
            ),
            endedAt: hasEndedAtUnixMs
                ? try harcWireDateFromUnixMilliseconds(
                    endedAtUnixMs,
                    field: "recordingSummary.endedAt"
                )
                : nil,
            title: hasTitle ? title : nil,
            suggestedTitle: hasSuggestedTitle ? suggestedTitle : nil,
            tags: tags,
            pinned: pinned,
            canonicalAudio: canonicalAudio.domainValue(),
            processing: processing.domainValue(),
            projection: projection.domainValue()
        )
    }
}

public extension Harc_V1_SpeakerLabelV1 {
    init(_ value: SpeakerLabel) {
        self.init()
        speakerIndex = value.speakerIndex
        displayName = value.displayName
    }

    func domainValue() throws -> SpeakerLabel {
        let result = try SpeakerLabel(speakerIndex: speakerIndex, displayName: displayName)
        guard result.displayName == displayName else {
            throw HarcProtobufConversionError.lossyConversion(field: "speakerLabel.displayName")
        }
        return result
    }
}

public extension Harc_V1_LibraryRecordingDetailV1 {
    init(_ value: LibraryRecordingDetail) throws {
        self.init()
        summary = try Harc_V1_LibraryRecordingSummaryV1(value.summary)
        if let transcriptText = value.transcriptText { self.transcriptText = transcriptText }
        speakerLabels = value.speakerLabels.map(Harc_V1_SpeakerLabelV1.init)
        if let summaryMarkdown = value.summaryMarkdown { self.summaryMarkdown = summaryMarkdown }
        if let actionItemsMarkdown = value.actionItemsMarkdown {
            self.actionItemsMarkdown = actionItemsMarkdown
        }
        if let notesMarkdown = value.notesMarkdown { self.notesMarkdown = notesMarkdown }
        discontinuities = try value.discontinuities.map(Harc_V1_CaptureDiscontinuityV1.init)
    }

    func domainValue() throws -> LibraryRecordingDetail {
        guard hasSummary else {
            throw HarcProtobufConversionError.missingField("recordingDetail.summary")
        }
        return try LibraryRecordingDetail(
            summary: summary.domainValue(),
            transcriptText: hasTranscriptText ? transcriptText : nil,
            speakerLabels: speakerLabels.map { try $0.domainValue() },
            summaryMarkdown: hasSummaryMarkdown ? summaryMarkdown : nil,
            actionItemsMarkdown: hasActionItemsMarkdown ? actionItemsMarkdown : nil,
            notesMarkdown: hasNotesMarkdown ? notesMarkdown : nil,
            discontinuities: discontinuities.map { try $0.domainValue() }
        )
    }
}

public extension Harc_V1_RecordingTombstoneV1 {
    init(_ value: RecordingTombstone) throws {
        self.init()
        canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(value.canonicalID)
        revision = value.revision.rawValue
        deletedAtUnixMs = try harcWireUnixMilliseconds(value.deletedAt, field: "recordingTombstone.deletedAt")
    }

    func domainValue() throws -> RecordingTombstone {
        guard hasCanonicalRecordingID else {
            throw HarcProtobufConversionError.missingField("recordingTombstone.canonicalRecordingID")
        }
        return try RecordingTombstone(
            canonicalID: canonicalRecordingID.domainValue(),
            revision: EntityRevision(revision),
            deletedAt: harcWireDateFromUnixMilliseconds(
                deletedAtUnixMs,
                field: "recordingTombstone.deletedAt"
            )
        )
    }
}

public enum HarcLibraryChangeValueV1: Equatable, Hashable, Sendable {
    case upsert(LibraryRecordingSummary)
    case tombstone(RecordingTombstone)
}

public struct HarcValidatedLibraryChangeV1: Equatable, Hashable, Sendable {
    public let descriptor: LibraryChangeDescriptor
    public let value: HarcLibraryChangeValueV1

    public init(descriptor: LibraryChangeDescriptor, value: HarcLibraryChangeValueV1) throws {
        switch value {
        case .upsert(let summary):
            guard descriptor.operation == .upsert,
                  summary.canonicalID == descriptor.canonicalID,
                  summary.revision == descriptor.revision else {
                throw HarcProtobufConversionError.inconsistentField("libraryChange.upsert")
            }
        case .tombstone(let tombstone):
            guard descriptor.operation == .tombstone,
                  tombstone.canonicalID == descriptor.canonicalID,
                  tombstone.revision == descriptor.revision else {
                throw HarcProtobufConversionError.inconsistentField("libraryChange.tombstone")
            }
        }
        self.descriptor = descriptor
        self.value = value
    }

    public var protobufV1: Harc_V1_LibraryChangeV1 {
        get throws {
            var wire = Harc_V1_LibraryChangeV1()
            wire.cursor = descriptor.cursor.rawValue
            wire.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(descriptor.canonicalID)
            wire.revision = descriptor.revision.rawValue
            wire.changedAtUnixMs = try harcWireUnixMilliseconds(
                descriptor.changedAt,
                field: "libraryChange.changedAt"
            )
            switch value {
            case .upsert(let summary):
                wire.operation = .libraryChangeOperationUpsert
                wire.value = .upsert(try Harc_V1_LibraryRecordingSummaryV1(summary))
            case .tombstone(let tombstone):
                wire.operation = .libraryChangeOperationTombstone
                wire.value = .tombstone(try Harc_V1_RecordingTombstoneV1(tombstone))
            }
            return wire
        }
    }
}

public extension Harc_V1_LibraryChangeV1 {
    func domainValue() throws -> HarcValidatedLibraryChangeV1 {
        guard hasCanonicalRecordingID else {
            throw HarcProtobufConversionError.missingField("libraryChange.canonicalRecordingID")
        }
        let domainOperation: LibraryChangeOperation
        let domainValue: HarcLibraryChangeValueV1
        switch (operation, value) {
        case (.libraryChangeOperationUpsert, .upsert(let summary)?):
            domainOperation = .upsert
            domainValue = .upsert(try summary.domainValue())
        case (.libraryChangeOperationTombstone, .tombstone(let tombstone)?):
            domainOperation = .tombstone
            domainValue = .tombstone(try tombstone.domainValue())
        case (.libraryChangeOperationUnspecified, _):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "libraryChange.operation",
                rawValue: operation.rawValue
            )
        case (.UNRECOGNIZED(let rawValue), _):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "libraryChange.operation",
                rawValue: rawValue
            )
        default:
            throw HarcProtobufConversionError.inconsistentField("libraryChange.value")
        }
        return try HarcValidatedLibraryChangeV1(
            descriptor: LibraryChangeDescriptor(
                cursor: ChangeCursor(cursor),
                canonicalID: canonicalRecordingID.domainValue(),
                revision: EntityRevision(revision),
                operation: domainOperation,
                changedAt: harcWireDateFromUnixMilliseconds(
                    changedAtUnixMs,
                    field: "libraryChange.changedAt"
                )
            ),
            value: domainValue
        )
    }
}

// MARK: - Private conversion primitives

private func harcRequireLength(_ value: Data, expected: Int, field: String) throws {
    guard value.count == expected else {
        throw HarcProtobufConversionError.invalidLength(
            field: field,
            expected: expected,
            actual: value.count
        )
    }
}

private func harcUUIDBytesForWire(_ value: UUID) -> Data {
    withUnsafeBytes(of: value.uuid) { Data($0) }
}

private func harcUUIDFromWire(_ value: Data, field: String) throws -> UUID {
    try harcRequireLength(value, expected: 16, field: field)
    let bytes = [UInt8](value)
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private func harcRequireCanonicalCodes(_ values: [String], field: String) throws {
    guard values == values.sorted() else {
        throw HarcProtobufConversionError.nonCanonicalOrder(field: field)
    }
    guard Set(values).count == values.count else {
        throw HarcProtobufConversionError.duplicateValue(field: field)
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    for value in values {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw HarcProtobufConversionError.invalidValue(field: field)
        }
    }
}

private func harcIsValidProtobufFieldNumber(_ value: UInt32) -> Bool {
    value >= 1 && value <= 536_870_911 && !(19_000 ... 19_999).contains(value)
}

private let harcMaximumExactlyRepresentableUnixMilliseconds: UInt64 = 9_007_199_254_740_991

private func harcWireUnixMilliseconds(_ value: Date, field: String) throws -> UInt64 {
    let seconds = value.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0 else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
    let scaled = seconds * 1_000
    guard scaled.isFinite, scaled <= Double(harcMaximumExactlyRepresentableUnixMilliseconds) else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let rounded = scaled.rounded()
    guard let result = UInt64(exactly: rounded),
          Date(timeIntervalSince1970: Double(result) / 1_000) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return result
}

private func harcWireDateFromUnixMilliseconds(_ value: UInt64, field: String) throws -> Date {
    guard value <= harcMaximumExactlyRepresentableUnixMilliseconds else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let date = Date(timeIntervalSince1970: Double(value) / 1_000)
    guard try harcWireUnixMilliseconds(date, field: field) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return date
}
