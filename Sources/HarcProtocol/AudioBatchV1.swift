import CryptoKit
import Foundation
import HarcProtocolWire
import HarcTransfer

/// The exact, immutable `HARCAB1` body handed to a background transfer task.
///
/// The protobuf header is decoded for validation, but `exactHeaderPayload` and
/// `exactBytes` are retained because re-serializing a decoded protobuf value is
/// never an identity operation in the Harc protocol.
public struct HarcAudioBatchV1: Sendable {
    public static let magic = Data("HARCAB1\0".utf8)
    public static let maximumHeaderBytes = 1 * 1_024 * 1_024
    public static let maximumEntryBytes = 4 * 1_024 * 1_024
    public static let maximumEntries = 64
    public static let maximumExactBytes = 64 * 1_024 * 1_024

    public let exactBytes: Data
    public let exactHeaderPayload: Data
    public let header: Harc_V1_AudioBatchHeaderV1
    public let encodedChunks: [Data]
    public let exactSHA256: Data

    /// Serializes the header exactly once and immediately reparses the complete
    /// frame through the same bounded decoder used for received data.
    public static func create(
        header: Harc_V1_AudioBatchHeaderV1,
        encodedChunks: [Data],
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        try requireEntryCount(
            headerCount: header.entries.count,
            payloadCount: encodedChunks.count
        )
        let exactHeaderPayload = try header.serializedData()
        guard exactHeaderPayload.count <= maximumHeaderBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "AudioBatchHeaderV1",
                limit: UInt64(maximumHeaderBytes),
                actual: UInt64(exactHeaderPayload.count)
            )
        }
        guard let headerLength = UInt32(exactly: exactHeaderPayload.count) else {
            throw HarcProtocolCodecError.numericOverflow(field: "audioBatch.headerLength")
        }

        var exactByteCount = UInt64(magic.count)
        try addToExactByteCount(4, total: &exactByteCount)
        try addToExactByteCount(UInt64(exactHeaderPayload.count), total: &exactByteCount)
        for chunk in encodedChunks {
            guard chunk.count <= maximumEntryBytes,
                  UInt32(exactly: chunk.count) != nil else {
                throw HarcProtocolCodecError.inputTooLarge(
                    field: "audioBatch.encodedChunk",
                    limit: UInt64(maximumEntryBytes),
                    actual: UInt64(chunk.count)
                )
            }
            try addToExactByteCount(4, total: &exactByteCount)
            try addToExactByteCount(UInt64(chunk.count), total: &exactByteCount)
        }

        var writer = HarcBinaryWriter()
        writer.append(magic)
        writer.append(headerLength)
        writer.append(exactHeaderPayload)
        for chunk in encodedChunks {
            let encodedLength = UInt32(chunk.count)
            writer.append(encodedLength)
            writer.append(chunk)
        }

        return try decode(
            writer.data,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
    }

    /// Performs all length checks before slicing or parsing nested protobufs.
    public static func decode(
        _ exactBytes: Data,
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: maximumExactBytes,
            field: "HarcAudioBatchV1"
        )
        try reader.requireMagic(magic, field: "HarcAudioBatchV1")

        let headerLength = UInt64(try reader.readUInt32(field: "audioBatch.headerLength"))
        guard headerLength > 0, headerLength <= UInt64(maximumHeaderBytes) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.headerLength",
                minimum: 1,
                maximum: UInt64(maximumHeaderBytes),
                actual: headerLength
            )
        }
        guard headerLength <= UInt64(reader.remainingCount) else {
            throw HarcProtocolCodecError.truncated(field: "audioBatch.headerPayload")
        }
        let exactHeaderPayload = try reader.readData(
            count: Int(headerLength),
            field: "audioBatch.headerPayload"
        )
        try HarcProtobufWirePreflight.requireRepeatedMessageCount(
            in: exactHeaderPayload,
            fieldNumber: 7,
            maximum: maximumEntries,
            field: "audioBatch.entries"
        )
        let header = try Harc_V1_AudioBatchHeaderV1(serializedBytes: exactHeaderPayload)
        try validateHeader(
            header,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        try validateDeclaredExactByteCount(
            headerLength: headerLength,
            entries: header.entries
        )

        var encodedChunks: [Data] = []
        encodedChunks.reserveCapacity(header.entries.count)
        for (index, descriptor) in header.entries.enumerated() {
            let declaredLength = UInt64(descriptor.encodedLength)
            guard declaredLength > 0, declaredLength <= UInt64(maximumEntryBytes) else {
                throw HarcProtocolCodecError.lengthOutOfRange(
                    field: "audioBatch.entries[\(index)].encodedLength",
                    minimum: 1,
                    maximum: UInt64(maximumEntryBytes),
                    actual: declaredLength
                )
            }
            guard reader.remainingCount >= 4 else {
                throw HarcProtocolCodecError.truncated(field: "audioBatch.entries[\(index)].length")
            }
            let framedLength = UInt64(try reader.readUInt32(
                field: "audioBatch.entries[\(index)].length"
            ))
            guard framedLength == declaredLength else {
                throw HarcProtocolCodecError.lengthMismatch(
                    field: "audioBatch.entries[\(index)].encodedLength",
                    expected: declaredLength,
                    actual: framedLength
                )
            }
            guard framedLength <= UInt64(reader.remainingCount) else {
                throw HarcProtocolCodecError.truncated(field: "audioBatch.entries[\(index)].payload")
            }
            let chunk = try reader.readData(
                count: Int(framedLength),
                field: "audioBatch.entries[\(index)].payload"
            )
            let digest = Data(SHA256.hash(data: chunk))
            guard digest == descriptor.encodedSha256.value else {
                throw HarcProtocolCodecError.payloadHashMismatch
            }
            encodedChunks.append(chunk)
        }
        try reader.requireEnd()

        return Self(
            exactBytes: exactBytes,
            exactHeaderPayload: exactHeaderPayload,
            header: header,
            encodedChunks: encodedChunks,
            exactSHA256: Data(SHA256.hash(data: exactBytes))
        )
    }

    private static func validateHeader(
        _ header: Harc_V1_AudioBatchHeaderV1,
        supportedRequiredFeatures: Set<String>,
        versionPolicy: HarcProtocolVersionPolicy
    ) throws {
        guard header.hasProtocol else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "audioBatch.protocol")
        }
        try harcValidateContainerProtocol(
            header.protocol,
            knownCriticalFields: Set(1 ... 7),
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        try harcRequireWireBytes(header.hasBatchID ? header.batchID.value : Data(), count: 16, field: "audioBatch.batchID")
        try harcRequireWireBytes(header.hasUploadID ? header.uploadID.value : Data(), count: 16, field: "audioBatch.uploadID")
        try harcRequireWireBytes(
            header.hasUploadProfileSha256 ? header.uploadProfileSha256.value : Data(),
            count: 32,
            field: "audioBatch.uploadProfileSHA256"
        )
        guard header.hasOriginRecordingID, header.originRecordingID.hasDeviceID else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "audioBatch.originRecordingID")
        }
        try harcRequireWireBytes(
            header.originRecordingID.deviceID.sha256,
            count: 32,
            field: "audioBatch.originRecordingID.deviceID"
        )
        try harcRequireWireBytes(
            header.originRecordingID.recordingUuid,
            count: 16,
            field: "audioBatch.originRecordingID.recordingUUID"
        )
        try harcRequireWireBytes(
            header.hasDeviceID ? header.deviceID.sha256 : Data(),
            count: 32,
            field: "audioBatch.deviceID"
        )
        guard header.originRecordingID.deviceID.sha256 == header.deviceID.sha256 else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "audioBatch.deviceID")
        }
        guard !header.entries.isEmpty, header.entries.count <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.entries",
                minimum: 1,
                maximum: UInt64(maximumEntries),
                actual: UInt64(header.entries.count)
            )
        }

        var priorIndex: UInt32?
        var chunkIDs = Set<Data>()
        for (index, entry) in header.entries.enumerated() {
            try harcRequireWireBytes(
                entry.hasChunkID ? entry.chunkID.value : Data(),
                count: 16,
                field: "audioBatch.entries[\(index)].chunkID"
            )
            guard chunkIDs.insert(entry.chunkID.value).inserted else {
                throw HarcProtocolCodecError.duplicateValue(field: "audioBatch.entries.chunkID")
            }
            if let priorIndex, entry.chunkIndex <= priorIndex {
                throw HarcProtocolCodecError.nonCanonicalOrder(field: "audioBatch.entries.chunkIndex")
            }
            guard entry.canonicalFrameCount > 0,
                  entry.canonicalFrameCount <= TransferLimits.ordinaryChunkFrames,
                  !entry.canonicalStartFrame.addingReportingOverflow(entry.canonicalFrameCount).overflow else {
                throw HarcProtocolCodecError.invalidTimeRange(
                    field: "audioBatch.entries[\(index)].canonicalFrames"
                )
            }
            try harcRequireWireBytes(
                entry.hasEncodedSha256 ? entry.encodedSha256.value : Data(),
                count: 32,
                field: "audioBatch.entries[\(index)].encodedSHA256"
            )
            try harcRequireWireBytes(
                entry.hasCanonicalDecodedSha256 ? entry.canonicalDecodedSha256.value : Data(),
                count: 32,
                field: "audioBatch.entries[\(index)].canonicalDecodedSHA256"
            )
            guard entry.hasEncoding else {
                throw HarcProtocolCodecError.missingPayloadBinding(
                    field: "audioBatch.entries[\(index)].encoding"
                )
            }
            try harcValidateContainerEncoding(entry.encoding, field: "audioBatch.entries[\(index)].encoding")
            let canonicalBytes = entry.canonicalFrameCount.multipliedReportingOverflow(by: 2)
            guard !canonicalBytes.overflow,
                  entry.canonicalDecodedSha256.value.count == SHA256.Digest.byteCount else {
                throw HarcProtocolCodecError.numericOverflow(
                    field: "audioBatch.entries[\(index)].canonicalDecodedBytes"
                )
            }
            if entry.encoding.codec == .losslessAudioCodecRawCanonicalPcmFixture {
                guard UInt64(entry.encodedLength) == canonicalBytes.partialValue,
                      entry.encodedSha256.value == entry.canonicalDecodedSha256.value else {
                    throw HarcProtocolCodecError.headerPayloadMismatch(
                        field: "audioBatch.entries[\(index)].rawPCMFixture"
                    )
                }
            }
            priorIndex = entry.chunkIndex
        }
    }

    private static func requireEntryCount(headerCount: Int, payloadCount: Int) throws {
        guard headerCount > 0, headerCount <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.entries",
                minimum: 1,
                maximum: UInt64(maximumEntries),
                actual: UInt64(headerCount)
            )
        }
        guard payloadCount <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.encodedChunks",
                minimum: 0,
                maximum: UInt64(maximumEntries),
                actual: UInt64(payloadCount)
            )
        }
        guard headerCount == payloadCount else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "audioBatch.encodedChunks",
                expected: UInt64(headerCount),
                actual: UInt64(payloadCount)
            )
        }
    }

    private static func validateDeclaredExactByteCount(
        headerLength: UInt64,
        entries: [Harc_V1_AudioBatchEntryV1]
    ) throws {
        var total = UInt64(magic.count)
        try addToExactByteCount(4, total: &total)
        try addToExactByteCount(headerLength, total: &total)
        for entry in entries {
            try addToExactByteCount(4, total: &total)
            try addToExactByteCount(UInt64(entry.encodedLength), total: &total)
        }
    }

    private static func addToExactByteCount(_ count: UInt64, total: inout UInt64) throws {
        let result = total.addingReportingOverflow(count)
        guard !result.overflow else {
            throw HarcProtocolCodecError.numericOverflow(field: "audioBatch.exactBytes")
        }
        guard result.partialValue <= UInt64(maximumExactBytes) else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "audioBatch.exactBytes",
                limit: UInt64(maximumExactBytes),
                actual: result.partialValue
            )
        }
        total = result.partialValue
    }

    private init(
        exactBytes: Data,
        exactHeaderPayload: Data,
        header: Harc_V1_AudioBatchHeaderV1,
        encodedChunks: [Data],
        exactSHA256: Data
    ) {
        self.exactBytes = exactBytes
        self.exactHeaderPayload = exactHeaderPayload
        self.header = header
        self.encodedChunks = encodedChunks
        self.exactSHA256 = exactSHA256
    }
}

/// A bounded protobuf wire walk used to limit repeated message fields before
/// SwiftProtobuf materializes their generated arrays.
struct HarcProtobufWirePreflight {
    private static let maximumFieldNumber: UInt64 = 0x1fff_ffff
    private static let maximumGroupDepth = 64

    let data: Data

    static func requireRepeatedMessageCount(
        in data: Data,
        fieldNumber: UInt32,
        maximum: Int,
        field: String
    ) throws {
        let scanner = Self(data: data)
        var count = 0
        try scanner.scan(field: field) { number, wireType, depth, _ in
            guard depth == 0, number == fieldNumber, wireType == 2 else { return }
            try increment(&count, maximum: maximum, field: field)
        }
    }

    func scan(
        range: Range<Int>? = nil,
        field: String,
        visit: (UInt32, UInt8, Int, Range<Int>?) throws -> Void
    ) throws {
        let bounds = range ?? (0 ..< data.count)
        guard bounds.lowerBound >= 0, bounds.upperBound <= data.count else {
            throw HarcProtocolCodecError.truncated(field: field)
        }

        var offset = bounds.lowerBound
        var groups: [UInt32] = []
        while offset < bounds.upperBound {
            let key = try readVarint(offset: &offset, end: bounds.upperBound, field: field)
            let number = key >> 3
            let wireType = UInt8(key & 0x07)
            guard number > 0, number <= Self.maximumFieldNumber,
                  let fieldNumber = UInt32(exactly: number) else {
                throw HarcProtocolCodecError.invalidText(field: "\(field).wireKey")
            }

            switch wireType {
            case 0:
                try visit(fieldNumber, wireType, groups.count, nil)
                _ = try readVarint(offset: &offset, end: bounds.upperBound, field: field)
            case 1:
                try visit(fieldNumber, wireType, groups.count, nil)
                try advance(&offset, by: 8, end: bounds.upperBound, field: field)
            case 2:
                let depth = groups.count
                let byteCount = try readVarint(offset: &offset, end: bounds.upperBound, field: field)
                guard let length = Int(exactly: byteCount) else {
                    throw HarcProtocolCodecError.numericOverflow(field: "\(field).wireLength")
                }
                let payloadStart = offset
                try advance(&offset, by: length, end: bounds.upperBound, field: field)
                try visit(fieldNumber, wireType, depth, payloadStart ..< offset)
            case 3:
                try visit(fieldNumber, wireType, groups.count, nil)
                guard groups.count < Self.maximumGroupDepth else {
                    throw HarcProtocolCodecError.lengthOutOfRange(
                        field: "\(field).wireGroupDepth",
                        minimum: 0,
                        maximum: UInt64(Self.maximumGroupDepth),
                        actual: UInt64(groups.count + 1)
                    )
                }
                groups.append(fieldNumber)
            case 4:
                guard groups.last == fieldNumber else {
                    throw HarcProtocolCodecError.invalidText(field: "\(field).wireGroup")
                }
                groups.removeLast()
                try visit(fieldNumber, wireType, groups.count, nil)
            case 5:
                try visit(fieldNumber, wireType, groups.count, nil)
                try advance(&offset, by: 4, end: bounds.upperBound, field: field)
            default:
                throw HarcProtocolCodecError.invalidText(field: "\(field).wireType")
            }
        }
        guard groups.isEmpty else {
            throw HarcProtocolCodecError.truncated(field: "\(field).wireGroup")
        }
    }

    static func increment(_ count: inout Int, maximum: Int, field: String) throws {
        let result = count.addingReportingOverflow(1)
        guard !result.overflow else {
            throw HarcProtocolCodecError.numericOverflow(field: field)
        }
        guard result.partialValue <= maximum else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: field,
                minimum: 0,
                maximum: UInt64(maximum),
                actual: UInt64(result.partialValue)
            )
        }
        count = result.partialValue
    }

    static func add(_ count: Int, to total: inout Int, maximum: Int, field: String) throws {
        let result = total.addingReportingOverflow(count)
        guard !result.overflow else {
            throw HarcProtocolCodecError.numericOverflow(field: field)
        }
        guard result.partialValue <= maximum else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: field,
                minimum: 0,
                maximum: UInt64(maximum),
                actual: UInt64(result.partialValue)
            )
        }
        total = result.partialValue
    }

    private func readVarint(offset: inout Int, end: Int, field: String) throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0 ..< 10 {
            guard offset < end else {
                throw HarcProtocolCodecError.truncated(field: "\(field).wireVarint")
            }
            let byte = data[data.index(data.startIndex, offsetBy: offset)]
            offset += 1
            if byteIndex == 9, byte > 1 {
                throw HarcProtocolCodecError.numericOverflow(field: "\(field).wireVarint")
            }
            value |= UInt64(byte & 0x7f) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw HarcProtocolCodecError.numericOverflow(field: "\(field).wireVarint")
    }

    private func advance(_ offset: inout Int, by count: Int, end: Int, field: String) throws {
        let result = offset.addingReportingOverflow(count)
        guard !result.overflow, result.partialValue <= end else {
            throw HarcProtocolCodecError.truncated(field: "\(field).wirePayload")
        }
        offset = result.partialValue
    }
}

private func harcValidateContainerEncoding(
    _ value: Harc_V1_LosslessEncodingConfigurationV1,
    field: String
) throws {
    switch (value.codec, value.container) {
    case (.losslessAudioCodecAppleLossless, .losslessAudioContainerCoreAudioFormat),
         (.losslessAudioCodecRawCanonicalPcmFixture, .losslessAudioContainerRawCanonicalPcmFixture):
        guard !value.hasFlacCompressionLevel else {
            throw HarcProtocolCodecError.invalidText(field: field)
        }
    case (.losslessAudioCodecFlac, .losslessAudioContainerFlac):
        guard value.hasFlacCompressionLevel, value.flacCompressionLevel <= 12 else {
            throw HarcProtocolCodecError.invalidText(field: field)
        }
    default:
        throw HarcProtocolCodecError.invalidText(field: field)
    }
}

func harcRequireWireBytes(_ data: Data, count: Int, field: String) throws {
    guard data.count == count else {
        throw HarcProtocolCodecError.lengthMismatch(
            field: field,
            expected: UInt64(count),
            actual: UInt64(data.count)
        )
    }
}

func harcValidateContainerProtocol(
    _ value: Harc_V1_ProtocolVersionV1,
    knownCriticalFields: Set<UInt32>,
    supportedRequiredFeatures: Set<String>,
    versionPolicy: HarcProtocolVersionPolicy
) throws {
    guard let major = UInt16(exactly: value.major) else {
        throw HarcProtocolCodecError.numericOverflow(field: "protocol.major")
    }
    guard let minor = UInt16(exactly: value.minor) else {
        throw HarcProtocolCodecError.numericOverflow(field: "protocol.minor")
    }
    try versionPolicy.validate(HarcProtocolVersion(major: major, minor: minor))

    let features = value.hasRequirements ? value.requirements.requiredFeatures : []
    guard features == features.sorted() else {
        throw HarcProtocolCodecError.nonCanonicalOrder(field: "protocol.requiredFeatures")
    }
    guard Set(features).count == features.count else {
        throw HarcProtocolCodecError.duplicateValue(field: "protocol.requiredFeatures")
    }
    for feature in features {
        guard !feature.isEmpty,
              feature.count <= 128,
              feature.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw HarcProtocolCodecError.invalidText(field: "protocol.requiredFeatures")
        }
        guard supportedRequiredFeatures.contains(feature) else {
            throw HarcProtocolCodecError.invalidText(field: "protocol.unsupportedRequiredFeature")
        }
    }

    let criticalFields = value.hasRequirements ? value.requirements.criticalFieldNumbers : []
    guard criticalFields == criticalFields.sorted() else {
        throw HarcProtocolCodecError.nonCanonicalOrder(field: "protocol.criticalFieldNumbers")
    }
    guard Set(criticalFields).count == criticalFields.count else {
        throw HarcProtocolCodecError.duplicateValue(field: "protocol.criticalFieldNumbers")
    }
    guard criticalFields.allSatisfy(knownCriticalFields.contains) else {
        throw HarcProtocolCodecError.invalidText(field: "protocol.unknownCriticalField")
    }
}
