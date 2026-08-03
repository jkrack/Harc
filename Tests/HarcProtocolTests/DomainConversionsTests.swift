import Foundation
import HarcDomain
@testable import HarcIdentity
import HarcProtocolWire
import HarcTransfer
import Testing
@testable import HarcProtocol

@Suite("Protobuf domain conversions")
struct DomainConversionsTests {
    private let baseDate = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("requirements are canonical and fail closed for unsupported semantics")
    func requirementsFailClosed() throws {
        #expect(throws: HarcProtobufConversionError.nonCanonicalOrder(
            field: "protocol.requirements.requiredFeatures"
        )) {
            try HarcValidatedProtocolRequirements(
                requiredFeatures: ["z.feature", "a.feature"],
                criticalFieldNumbers: []
            )
        }
        #expect(throws: HarcProtobufConversionError.duplicateValue(
            field: "protocol.requirements.criticalFieldNumbers"
        )) {
            try HarcValidatedProtocolRequirements(
                requiredFeatures: [],
                criticalFieldNumbers: [2, 2]
            )
        }
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "protocol.requirements.criticalFieldNumbers"
        )) {
            try HarcValidatedProtocolRequirements(
                requiredFeatures: [],
                criticalFieldNumbers: [19_000]
            )
        }

        let requirements = try HarcValidatedProtocolRequirements(
            requiredFeatures: ["transfer.chunk.v1"],
            criticalFieldNumbers: [2, 7]
        )
        let version = HarcProtocolVersion.v1.protobufV1(requirements: requirements)

        #expect(throws: HarcProtobufConversionError.unsupportedRequiredFeature(
            "transfer.chunk.v1"
        )) {
            try HarcProtobufCompatibilityPolicy.currentV1.validate(
                version,
                knownCriticalFieldNumbers: [2, 7]
            )
        }
        let featureAware = HarcProtobufCompatibilityPolicy(
            versionPolicy: .currentV1,
            supportedRequiredFeatures: ["transfer.chunk.v1"]
        )
        #expect(throws: HarcProtobufConversionError.unknownCriticalField(7)) {
            try featureAware.validate(version, knownCriticalFieldNumbers: [2])
        }
        let accepted = try featureAware.validate(
            version,
            knownCriticalFieldNumbers: [2, 7]
        )
        #expect(accepted.0 == .v1)
        #expect(accepted.1 == requirements)
    }

    @Test("unsupported major and overflowing minor are rejected before domain entry")
    func versionBounds() {
        var wrongMajor = Harc_V1_ProtocolVersionV1()
        wrongMajor.major = 2
        wrongMajor.minor = 0
        #expect(throws: HarcProtocolCodecError.unsupportedProtocolMajor(2)) {
            try HarcProtobufCompatibilityPolicy.currentV1.validate(
                wrongMajor,
                knownCriticalFieldNumbers: []
            )
        }

        var overflowing = Harc_V1_ProtocolVersionV1()
        overflowing.major = 1
        overflowing.minor = UInt32.max
        #expect(throws: HarcProtobufConversionError.integerOutOfRange(field: "protocol.minor")) {
            try HarcProtobufCompatibilityPolicy.currentV1.validate(
                overflowing,
                knownCriticalFieldNumbers: []
            )
        }
    }

    @Test("exact wrapper preserves additive unknown bytes without reserialization")
    func exactUnknownFieldPreservation() throws {
        let known = try HarcExactProtobufPayload(
            serializingOnce: HarcProtocolVersion.v1.protobufV1()
        ).exactBytes
        // Unknown field 100, varint value 1, deliberately placed before the
        // known fields so forwarding cannot accidentally depend on re-encode.
        let exact = Data([0xA0, 0x06, 0x01]) + known
        let wrapped = try HarcExactProtobufPayload(
            decoding: exact,
            as: Harc_V1_ProtocolVersionV1.self
        )
        #expect(wrapped.exactBytes == exact)
        #expect(wrapped.message.major == 1)
        #expect(wrapped.message.minor == 0)

        #expect(throws: HarcProtobufConversionError.inputTooLarge(limit: 2, actual: exact.count)) {
            try HarcExactProtobufPayload(
                decoding: exact,
                as: Harc_V1_ProtocolVersionV1.self,
                maximumBytes: 2
            )
        }
    }

    @Test("UUID and digest wrappers round trip and reject wrong lengths")
    func identifierConversions() throws {
        let uuid = try #require(UUID(uuidString: "12345678-1234-4abc-8def-1234567890ab"))
        #expect(try Harc_V1_LibraryIDV1(LibraryID(uuid)).domainValue() == LibraryID(uuid))
        #expect(try Harc_V1_GrantIDV1(GrantID(uuid)).domainValue() == GrantID(uuid))
        #expect(try Harc_V1_UploadIDV1(UploadID(uuid)).domainValue() == UploadID(uuid))
        #expect(try Harc_V1_ChunkIDV1(ChunkID(uuid)).domainValue() == ChunkID(uuid))

        var badUUID = Harc_V1_LibraryIDV1()
        badUUID.value = Data(repeating: 1, count: 15)
        #expect(throws: HarcProtobufConversionError.invalidLength(
            field: "libraryID",
            expected: 16,
            actual: 15
        )) {
            try badUUID.domainValue()
        }

        var badDigest = Harc_V1_DeviceIDV1()
        badDigest.sha256 = Data(repeating: 1, count: 31)
        #expect(throws: HarcProtobufConversionError.invalidLength(
            field: "deviceID",
            expected: 32,
            actual: 31
        )) {
            try badDigest.domainValue()
        }
    }

    @Test("closed enums reject unspecified and future raw values")
    func closedEnumValidation() throws {
        var format = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        #expect(try format.domainValue() == .harcV1)

        format.encoding = .canonicalPcmEncodingUnspecified
        #expect(throws: HarcProtobufConversionError.unsupportedEnum(
            field: "canonicalFormat.encoding",
            rawValue: 0
        )) {
            try format.domainValue()
        }

        format.encoding = .UNRECOGNIZED(99)
        #expect(throws: HarcProtobufConversionError.unsupportedEnum(
            field: "canonicalFormat.encoding",
            rawValue: 99
        )) {
            try format.domainValue()
        }
    }

    @Test("processing and projection descriptors round trip with invariants")
    func stateDescriptorConversions() throws {
        let failure = try ProcessingFailure(code: "model_missing", message: "Unavailable")
        let processing = try ProcessingDescriptor(state: .degraded, failure: failure)
        #expect(try Harc_V1_ProcessingDescriptorV1(processing).domainValue() == processing)

        let projection = try ProjectionDescriptor(
            state: .failedRecoverable,
            version: ProjectionVersion(2),
            failure: failure
        )
        #expect(try Harc_V1_ProjectionDescriptorV1(projection).domainValue() == projection)

        var trimming = Harc_V1_ProcessingFailureV1()
        trimming.code = " model_missing "
        #expect(throws: HarcProtobufConversionError.lossyConversion(field: "processingFailure")) {
            try trimming.domainValue()
        }
    }

    @Test("device grant preserves identity, scopes, times, and compatibility range")
    func deviceGrantRoundTrip() throws {
        let key = try signingKey(1)
        let claims = try DeviceGrantClaims(
            libraryID: LibraryID(uuid(1)),
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0xA1, count: 32)),
            grantID: GrantID(uuid(2)),
            devicePublicKey: key.publicKey,
            scopes: Set([.recordingReadOwn, .recordingUploadOwn]),
            grantEpoch: .initial,
            issuedAt: baseDate,
            expiresAt: baseDate.addingTimeInterval(3_600),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        let wire = try Harc_V1_DeviceGrantV1(claims)
        #expect(try wire.domainValue() == claims)

        var absent = wire
        absent.clearDeviceID()
        #expect(throws: HarcProtobufConversionError.missingField("deviceGrant.deviceID")) {
            try absent.domainValue()
        }

        var futureScope = wire
        futureScope.scopes = [.UNRECOGNIZED(99)]
        #expect(throws: HarcProtobufConversionError.unsupportedEnum(
            field: "authorizationScope",
            rawValue: 99
        )) {
            try futureScope.domainValue()
        }
    }

    @Test("revocation conversion preserves the strict next-epoch relation")
    func revocationRoundTrip() throws {
        let claims = try DeviceRevocationClaims(
            libraryID: LibraryID(uuid(10)),
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x11, count: 32)),
            deviceID: try DeviceID(Data(repeating: 0x22, count: 32)),
            grantID: GrantID(uuid(11)),
            priorGrantEpoch: .initial,
            newGrantEpoch: GrantEpoch(2),
            revocationID: uuid(12),
            reasonCode: "user_revoked",
            issuedAt: baseDate
        )
        let wire = try Harc_V1_DeviceRevocationV1(claims)
        #expect(try wire.domainValue() == claims)

        var skippedEpoch = wire
        skippedEpoch.newGrantEpoch = 3
        #expect(throws: AuthorizationModelError.self) {
            try skippedEpoch.domainValue()
        }
    }

    @Test("exact upload profile bytes bind the domain hash")
    func uploadProfileExactBinding() throws {
        let wire = try uploadProfileWire()
        let exact = try HarcExactProtobufPayload(serializingOnce: wire).exactBytes
        let validated = try HarcValidatedUploadProfilePayload(decoding: exact)
        #expect(validated.exactPayload.exactBytes == exact)
        #expect(validated.domainValue.profileSHA256.rawBytes
            == HarcSignedEnvelopeV1.payloadDigest(exact))
        #expect(try HarcValidatedUploadProfilePayload(
            serializing: validated.domainValue
        ).exactPayload.exactBytes == exact)

        let withUnknown = Data([0x80, 0x06, 0x01]) + exact // unknown field 96
        let unknownValidated = try HarcValidatedUploadProfilePayload(decoding: withUnknown)
        #expect(unknownValidated.exactPayload.exactBytes == withUnknown)
        #expect(throws: HarcProtobufConversionError.exactPayloadHashMismatch) {
            try HarcValidatedUploadProfilePayload(serializing: unknownValidated.domainValue)
        }
    }

    @Test("chunk and discontinuity conversions retain all domain facts")
    func chunkAndDiscontinuityRoundTrip() throws {
        let origin = OriginRecordingID(
            deviceID: try signingKey(2).publicKey.deviceID,
            recordingUUID: uuid(20)
        )
        let route = try CaptureRouteDescriptor(
            identifier: "built-in-mic",
            name: "Built-in Microphone",
            sampleRateHz: 48_000,
            channelCount: 1
        )
        let discontinuity = try CaptureDiscontinuity(
            recordingID: origin,
            monotonicTimeNanoseconds: 10,
            wallTime: baseDate,
            reason: .routeChanged,
            newRoute: route,
            affectedFrames: CanonicalFrameRange(startFrame: 100, endFrameExclusive: 100),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        #expect(try Harc_V1_CaptureDiscontinuityV1(discontinuity).domainValue() == discontinuity)

        let chunk = try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(uuid(21)),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 100,
            encoding: .cafALAC,
            encodedByteLength: 100,
            encodedSHA256: EncodedChunkSHA256(Data(repeating: 0x33, count: 32)),
            canonicalDecodedByteLength: 200,
            canonicalDecodedSHA256: CanonicalPCMHash(Data(repeating: 0x44, count: 32))
        )
        #expect(try Harc_V1_ChunkDescriptorV1(chunk).domainValue() == chunk)

        let durable = DurableChunkStatus(
            chunkIndex: chunk.chunkIndex,
            chunkID: chunk.chunkID,
            encodedSHA256: chunk.encodedSHA256
        )
        #expect(try Harc_V1_DurableChunkV1(durable).domainValue() == durable)
        let rejected = RejectedChunkStatus(
            chunkIndex: chunk.chunkIndex,
            chunkID: chunk.chunkID,
            reason: .decodedHashMismatch
        )
        #expect(try Harc_V1_RejectedChunkV1(rejected).domainValue() == rejected)
    }

    @Test("path-free library views and typed changes round trip")
    func libraryViewRoundTrip() throws {
        let origin = OriginRecordingID(
            deviceID: try signingKey(3).publicKey.deviceID,
            recordingUUID: uuid(30)
        )
        let summary = try LibraryRecordingSummary(
            canonicalID: CanonicalRecordingID(uuid(31)),
            originID: origin,
            revision: EntityRevision(4),
            startedAt: baseDate,
            endedAt: baseDate.addingTimeInterval(60),
            title: "Planning",
            suggestedTitle: "Roadmap",
            tags: ["work"],
            pinned: true,
            canonicalAudio: .available(
                pcmSHA256: CanonicalPCMHash(Data(repeating: 0x51, count: 32)),
                totalFrames: 960_000
            ),
            processing: .ready,
            projection: .readyV1
        )
        let detail = try LibraryRecordingDetail(
            summary: summary,
            transcriptText: "Hello",
            speakerLabels: [SpeakerLabel(speakerIndex: 0, displayName: "Alex")],
            notesMarkdown: "A note"
        )
        #expect(try Harc_V1_LibraryRecordingDetailV1(detail).domainValue() == detail)

        let descriptor = try LibraryChangeDescriptor(
            cursor: ChangeCursor(9),
            canonicalID: summary.canonicalID,
            revision: summary.revision,
            operation: .upsert,
            changedAt: baseDate.addingTimeInterval(61)
        )
        let change = try HarcValidatedLibraryChangeV1(
            descriptor: descriptor,
            value: .upsert(summary)
        )
        #expect(try change.protobufV1.domainValue() == change)

        var mismatched = try change.protobufV1
        mismatched.operation = .libraryChangeOperationTombstone
        #expect(throws: HarcProtobufConversionError.inconsistentField("libraryChange.value")) {
            try mismatched.domainValue()
        }
    }

    @Test("domain dates with sub-millisecond precision cannot silently truncate")
    func datePrecision() throws {
        let summary = try LibraryRecordingSummary(
            canonicalID: CanonicalRecordingID(uuid(40)),
            revision: .initial,
            startedAt: Date(timeIntervalSince1970: 2_000_000_000.0005)
        )
        #expect(throws: HarcProtobufConversionError.lossyConversion(
            field: "recordingSummary.startedAt"
        )) {
            try Harc_V1_LibraryRecordingSummaryV1(summary)
        }
    }

    private func signingKey(_ value: UInt8) throws -> SoftwareP256SigningKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = value
        return try SoftwareP256SigningKey(rawRepresentation: scalar)
    }

    private func uuid(_ value: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012u", value))!
    }

    private func uploadProfileWire() throws -> Harc_V1_UploadProfileV1 {
        var wire = Harc_V1_UploadProfileV1()
        wire.protocol = HarcProtocolVersion.v1.protobufV1()
        wire.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        wire.encoding = Harc_V1_LosslessEncodingConfigurationV1(.cafALAC)
        wire.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        wire.requiredCapabilityIds = ["transfer.chunk.v1"]
        wire.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x71, count: 32)
        )
        wire.purpose = .uploadProfilePurposeProduction
        return wire
    }
}
