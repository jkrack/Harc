import CryptoKit
import Foundation
import HarcProtocolWire

public enum HarcProcessingBundleEntryV1: Sendable {
    case transcript(exactPayload: Data, value: Harc_V1_TranscriptArtifactV1)
    case diarization(exactPayload: Data, value: Harc_V1_DiarizationArtifactV1)
    case summary(exactPayload: Data, value: Harc_V1_SummaryArtifactV1)
    case coverage(exactPayload: Data, value: Harc_V1_CoverageArtifactV1)

    public var exactPayload: Data {
        switch self {
        case .transcript(let bytes, _), .diarization(let bytes, _),
             .summary(let bytes, _), .coverage(let bytes, _):
            bytes
        }
    }
}

/// An exact `HARCPB1` edge-processing artifact body.
///
/// Entry hashes are checked before their protobuf payloads are parsed. The
/// exact header, each exact entry, and the complete frame remain available for
/// persistence and signature/hash binding.
public struct HarcProcessingBundleV1: Sendable {
    public static let magic = Data("HARCPB1\0".utf8)
    public static let maximumHeaderBytes = 1 * 1_024 * 1_024
    public static let maximumEntryBytes = 16 * 1_024 * 1_024
    public static let maximumExactBytes = 32 * 1_024 * 1_024
    public static let maximumEntries = 8
    public static let maximumDecodedTextBytes = 8 * 1_024 * 1_024
    public static let maximumTranscriptUtterances = 16_384
    public static let maximumTranscriptWordsPerUtterance = 4_096
    public static let maximumTranscriptWords = 262_144
    public static let maximumDiarizationTurns = 65_536
    public static let maximumCoverageRanges = 65_536
    public static let maximumSummaryModelRevisions = 1_024

    public let exactBytes: Data
    public let exactHeaderPayload: Data
    public let header: Harc_V1_ProcessingBundleHeaderV1
    public let entries: [HarcProcessingBundleEntryV1]
    public let exactSHA256: Data

    public static func create(
        header: Harc_V1_ProcessingBundleHeaderV1,
        exactEntryPayloads: [Data],
        totalCanonicalFrames: UInt64? = nil,
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        try requireEntryCount(
            headerCount: header.entries.count,
            payloadCount: exactEntryPayloads.count
        )
        let exactHeaderPayload = try header.serializedData()
        guard exactHeaderPayload.count <= maximumHeaderBytes,
              let headerLength = UInt32(exactly: exactHeaderPayload.count) else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "ProcessingBundleHeaderV1",
                limit: UInt64(maximumHeaderBytes),
                actual: UInt64(exactHeaderPayload.count)
            )
        }

        var exactByteCount = UInt64(magic.count)
        try addToExactByteCount(4, total: &exactByteCount)
        try addToExactByteCount(UInt64(exactHeaderPayload.count), total: &exactByteCount)
        for (index, payload) in exactEntryPayloads.enumerated() {
            guard payload.count <= maximumEntryBytes else {
                throw HarcProtocolCodecError.inputTooLarge(
                    field: "processingBundle.entry",
                    limit: UInt64(maximumEntryBytes),
                    actual: UInt64(payload.count)
                )
            }
            try addToExactByteCount(8, total: &exactByteCount)
            try addToExactByteCount(UInt64(payload.count), total: &exactByteCount)
            try preflightEntryPayload(
                header.entries[index].entryType,
                exactPayload: payload
            )
        }

        var writer = HarcBinaryWriter()
        writer.append(magic)
        writer.append(headerLength)
        writer.append(exactHeaderPayload)
        for payload in exactEntryPayloads {
            writer.append(UInt64(payload.count))
            writer.append(payload)
        }

        return try decode(
            writer.data,
            totalCanonicalFrames: totalCanonicalFrames,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
    }

    public static func decode(
        _ exactBytes: Data,
        totalCanonicalFrames: UInt64? = nil,
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: maximumExactBytes,
            field: "HarcProcessingBundleV1"
        )
        try reader.requireMagic(magic, field: "HarcProcessingBundleV1")
        let headerLength = UInt64(try reader.readUInt32(field: "processingBundle.headerLength"))
        guard headerLength > 0, headerLength <= UInt64(maximumHeaderBytes) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "processingBundle.headerLength",
                minimum: 1,
                maximum: UInt64(maximumHeaderBytes),
                actual: headerLength
            )
        }
        guard headerLength <= UInt64(reader.remainingCount) else {
            throw HarcProtocolCodecError.truncated(field: "processingBundle.headerPayload")
        }
        let exactHeaderPayload = try reader.readData(
            count: Int(headerLength),
            field: "processingBundle.headerPayload"
        )
        try HarcProtobufWirePreflight.requireRepeatedMessageCount(
            in: exactHeaderPayload,
            fieldNumber: 5,
            maximum: maximumEntries,
            field: "processingBundle.entries"
        )
        let header = try Harc_V1_ProcessingBundleHeaderV1(serializedBytes: exactHeaderPayload)
        try validateHeader(
            header,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        try validateDeclaredExactByteCount(
            headerLength: headerLength,
            entries: header.entries
        )

        var entries: [HarcProcessingBundleEntryV1] = []
        entries.reserveCapacity(header.entries.count)
        var decodedTextBytes = 0
        for (index, descriptor) in header.entries.enumerated() {
            let declaredLength = descriptor.payloadByteLength
            guard declaredLength > 0, declaredLength <= UInt64(maximumEntryBytes) else {
                throw HarcProtocolCodecError.lengthOutOfRange(
                    field: "processingBundle.entries[\(index)].payloadByteLength",
                    minimum: 1,
                    maximum: UInt64(maximumEntryBytes),
                    actual: declaredLength
                )
            }
            guard reader.remainingCount >= 8 else {
                throw HarcProtocolCodecError.truncated(field: "processingBundle.entries[\(index)].length")
            }
            let framedLength = try reader.readUInt64(field: "processingBundle.entries[\(index)].length")
            guard framedLength == declaredLength else {
                throw HarcProtocolCodecError.lengthMismatch(
                    field: "processingBundle.entries[\(index)].payloadByteLength",
                    expected: declaredLength,
                    actual: framedLength
                )
            }
            guard framedLength <= UInt64(reader.remainingCount) else {
                throw HarcProtocolCodecError.truncated(field: "processingBundle.entries[\(index)].payload")
            }
            let exactPayload = try reader.readData(
                count: Int(framedLength),
                field: "processingBundle.entries[\(index)].payload"
            )
            guard Data(SHA256.hash(data: exactPayload)) == descriptor.payloadSha256.value else {
                throw HarcProtocolCodecError.payloadHashMismatch
            }
            try preflightEntryPayload(descriptor.entryType, exactPayload: exactPayload)
            entries.append(try decodeEntry(
                descriptor,
                exactPayload: exactPayload,
                totalCanonicalFrames: totalCanonicalFrames,
                supportedRequiredFeatures: supportedRequiredFeatures,
                versionPolicy: versionPolicy,
                decodedTextBytes: &decodedTextBytes
            ))
        }
        try reader.requireEnd()

        return Self(
            exactBytes: exactBytes,
            exactHeaderPayload: exactHeaderPayload,
            header: header,
            entries: entries,
            exactSHA256: Data(SHA256.hash(data: exactBytes))
        )
    }

    /// Rechecks all frame-range invariants once the canonical recording length
    /// is known, without reserializing any protobuf value.
    public func validateAgainstRecording(totalCanonicalFrames: UInt64) throws {
        for entry in entries {
            switch entry {
            case .transcript(_, let value):
                try Self.validateTranscript(value, totalCanonicalFrames: totalCanonicalFrames)
            case .diarization(_, let value):
                try Self.validateDiarization(value, totalCanonicalFrames: totalCanonicalFrames)
            case .coverage(_, let value):
                try Self.validateCoverage(value, totalCanonicalFrames: totalCanonicalFrames)
            case .summary:
                break
            }
        }
    }

    private static func validateHeader(
        _ header: Harc_V1_ProcessingBundleHeaderV1,
        supportedRequiredFeatures: Set<String>,
        versionPolicy: HarcProtocolVersionPolicy
    ) throws {
        guard header.hasProtocol else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "processingBundle.protocol")
        }
        try harcValidateContainerProtocol(
            header.protocol,
            knownCriticalFields: Set(1 ... 5),
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        try harcRequireWireBytes(
            header.hasArtifactID ? header.artifactID.value : Data(),
            count: 16,
            field: "processingBundle.artifactID"
        )
        guard header.hasOriginRecordingID, header.originRecordingID.hasDeviceID else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "processingBundle.originRecordingID")
        }
        try harcRequireWireBytes(
            header.originRecordingID.deviceID.sha256,
            count: 32,
            field: "processingBundle.originRecordingID.deviceID"
        )
        try harcRequireWireBytes(
            header.originRecordingID.recordingUuid,
            count: 16,
            field: "processingBundle.originRecordingID.recordingUUID"
        )
        try harcRequireWireBytes(
            header.hasCanonicalAudioSha256 ? header.canonicalAudioSha256.value : Data(),
            count: 32,
            field: "processingBundle.canonicalAudioSHA256"
        )
        guard !header.entries.isEmpty, header.entries.count <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "processingBundle.entries",
                minimum: 1,
                maximum: UInt64(maximumEntries),
                actual: UInt64(header.entries.count)
            )
        }

        var priorType = 0
        var observed = Set<Int>()
        for (index, descriptor) in header.entries.enumerated() {
            let rawType = descriptor.entryType.rawValue
            guard (1 ... 4).contains(rawType) else {
                throw HarcProtocolCodecError.invalidText(
                    field: "processingBundle.entries[\(index)].entryType"
                )
            }
            guard rawType > priorType else {
                throw HarcProtocolCodecError.nonCanonicalOrder(field: "processingBundle.entries.entryType")
            }
            guard observed.insert(rawType).inserted else {
                throw HarcProtocolCodecError.duplicateValue(field: "processingBundle.entries.entryType")
            }
            guard descriptor.schemaVersion == 1 else {
                throw HarcProtocolCodecError.unsupportedProtocolMinor(
                    UInt16(clamping: descriptor.schemaVersion)
                )
            }
            try harcRequireWireBytes(
                descriptor.hasPayloadSha256 ? descriptor.payloadSha256.value : Data(),
                count: 32,
                field: "processingBundle.entries[\(index)].payloadSHA256"
            )
            priorType = rawType
        }
        guard observed.contains(1), observed.contains(2), observed.contains(4) else {
            throw HarcProtocolCodecError.missingPayloadBinding(
                field: "processingBundle.requiredEntries"
            )
        }
    }

    private static func requireEntryCount(headerCount: Int, payloadCount: Int) throws {
        guard headerCount > 0, headerCount <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "processingBundle.entries",
                minimum: 1,
                maximum: UInt64(maximumEntries),
                actual: UInt64(headerCount)
            )
        }
        guard payloadCount <= maximumEntries else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "processingBundle.entryPayloads",
                minimum: 0,
                maximum: UInt64(maximumEntries),
                actual: UInt64(payloadCount)
            )
        }
        guard headerCount == payloadCount else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "processingBundle.entryPayloads",
                expected: UInt64(headerCount),
                actual: UInt64(payloadCount)
            )
        }
    }

    private static func validateDeclaredExactByteCount(
        headerLength: UInt64,
        entries: [Harc_V1_ProcessingBundleEntryDescriptorV1]
    ) throws {
        var total = UInt64(magic.count)
        try addToExactByteCount(4, total: &total)
        try addToExactByteCount(headerLength, total: &total)
        for entry in entries {
            try addToExactByteCount(8, total: &total)
            try addToExactByteCount(entry.payloadByteLength, total: &total)
        }
    }

    private static func addToExactByteCount(_ count: UInt64, total: inout UInt64) throws {
        let result = total.addingReportingOverflow(count)
        guard !result.overflow else {
            throw HarcProtocolCodecError.numericOverflow(field: "processingBundle.exactBytes")
        }
        guard result.partialValue <= UInt64(maximumExactBytes) else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "processingBundle.exactBytes",
                limit: UInt64(maximumExactBytes),
                actual: result.partialValue
            )
        }
        total = result.partialValue
    }

    private static func preflightEntryPayload(
        _ entryType: Harc_V1_ProcessingBundleEntryTypeV1,
        exactPayload: Data
    ) throws {
        let scanner = HarcProtobufWirePreflight(data: exactPayload)
        switch entryType {
        case .processingBundleEntryTypeTranscript:
            var utteranceCount = 0
            var totalWordCount = 0
            try scanner.scan(field: "transcript") { number, wireType, depth, payloadRange in
                guard depth == 0, number == 3, wireType == 2,
                      let utteranceRange = payloadRange else { return }
                try HarcProtobufWirePreflight.increment(
                    &utteranceCount,
                    maximum: maximumTranscriptUtterances,
                    field: "transcript.utterances"
                )
                var utteranceWordCount = 0
                try scanner.scan(range: utteranceRange, field: "transcript.utterance") {
                    nestedNumber, nestedWireType, nestedDepth, _ in
                    guard nestedDepth == 0, nestedNumber == 6, nestedWireType == 2 else { return }
                    try HarcProtobufWirePreflight.increment(
                        &utteranceWordCount,
                        maximum: maximumTranscriptWordsPerUtterance,
                        field: "transcript.utterance.words"
                    )
                }
                try HarcProtobufWirePreflight.add(
                    utteranceWordCount,
                    to: &totalWordCount,
                    maximum: maximumTranscriptWords,
                    field: "transcript.words"
                )
            }
        case .processingBundleEntryTypeDiarization:
            try HarcProtobufWirePreflight.requireRepeatedMessageCount(
                in: exactPayload,
                fieldNumber: 2,
                maximum: maximumDiarizationTurns,
                field: "diarization.turns"
            )
        case .processingBundleEntryTypeSummary:
            try HarcProtobufWirePreflight.requireRepeatedMessageCount(
                in: exactPayload,
                fieldNumber: 6,
                maximum: maximumSummaryModelRevisions,
                field: "summary.modelRevisions"
            )
        case .processingBundleEntryTypeCoverage:
            var rangeCount = 0
            try scanner.scan(field: "coverage") { number, wireType, depth, payloadRange in
                guard depth == 0, number == 2, wireType == 2,
                      let coverageRange = payloadRange else { return }
                try scanner.scan(range: coverageRange, field: "coverage.coverage") {
                    nestedNumber, nestedWireType, nestedDepth, _ in
                    guard nestedDepth == 0, (1 ... 3).contains(nestedNumber),
                          nestedWireType == 2 else { return }
                    try HarcProtobufWirePreflight.increment(
                        &rangeCount,
                        maximum: maximumCoverageRanges,
                        field: "coverage.ranges"
                    )
                }
            }
        case .processingBundleEntryTypeUnspecified, .UNRECOGNIZED:
            break
        }
    }

    private static func decodeEntry(
        _ descriptor: Harc_V1_ProcessingBundleEntryDescriptorV1,
        exactPayload: Data,
        totalCanonicalFrames: UInt64?,
        supportedRequiredFeatures: Set<String>,
        versionPolicy: HarcProtocolVersionPolicy,
        decodedTextBytes: inout Int
    ) throws -> HarcProcessingBundleEntryV1 {
        switch descriptor.entryType {
        case .processingBundleEntryTypeTranscript:
            let value = try Harc_V1_TranscriptArtifactV1(serializedBytes: exactPayload)
            try validateEntryProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownCriticalFields: Set(1 ... 3),
                supportedRequiredFeatures: supportedRequiredFeatures,
                versionPolicy: versionPolicy
            )
            try validateTranscript(value, totalCanonicalFrames: totalCanonicalFrames)
            try addTextBytes(transcriptTextBytes(value), to: &decodedTextBytes)
            return .transcript(exactPayload: exactPayload, value: value)
        case .processingBundleEntryTypeDiarization:
            let value = try Harc_V1_DiarizationArtifactV1(serializedBytes: exactPayload)
            try validateEntryProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownCriticalFields: Set(1 ... 2),
                supportedRequiredFeatures: supportedRequiredFeatures,
                versionPolicy: versionPolicy
            )
            try validateDiarization(value, totalCanonicalFrames: totalCanonicalFrames)
            try addTextBytes(diarizationTextBytes(value), to: &decodedTextBytes)
            return .diarization(exactPayload: exactPayload, value: value)
        case .processingBundleEntryTypeSummary:
            let value = try Harc_V1_SummaryArtifactV1(serializedBytes: exactPayload)
            try validateEntryProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownCriticalFields: Set(1 ... 6),
                supportedRequiredFeatures: supportedRequiredFeatures,
                versionPolicy: versionPolicy
            )
            try validateSummary(value)
            try addTextBytes(summaryTextBytes(value), to: &decodedTextBytes)
            return .summary(exactPayload: exactPayload, value: value)
        case .processingBundleEntryTypeCoverage:
            let value = try Harc_V1_CoverageArtifactV1(serializedBytes: exactPayload)
            try validateEntryProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownCriticalFields: Set(1 ... 2),
                supportedRequiredFeatures: supportedRequiredFeatures,
                versionPolicy: versionPolicy
            )
            guard value.hasCoverage else {
                throw HarcProtocolCodecError.missingPayloadBinding(field: "coverage.coverage")
            }
            try validateCoverage(value, totalCanonicalFrames: totalCanonicalFrames)
            try addTextBytes(coverageTextBytes(value), to: &decodedTextBytes)
            return .coverage(exactPayload: exactPayload, value: value)
        case .processingBundleEntryTypeUnspecified, .UNRECOGNIZED:
            throw HarcProtocolCodecError.invalidText(field: "processingBundle.entryType")
        }
    }

    private static func validateEntryProtocol(
        present: Bool,
        value: Harc_V1_ProtocolVersionV1,
        knownCriticalFields: Set<UInt32>,
        supportedRequiredFeatures: Set<String>,
        versionPolicy: HarcProtocolVersionPolicy
    ) throws {
        guard present else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "processingBundle.entry.protocol")
        }
        try harcValidateContainerProtocol(
            value,
            knownCriticalFields: knownCriticalFields,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
    }

    private static func validateTranscript(
        _ value: Harc_V1_TranscriptArtifactV1,
        totalCanonicalFrames: UInt64?
    ) throws {
        try harcRequireCanonicalASCII(value.locale, field: "transcript.locale", maximumBytes: 128)
        var priorUtteranceEnd: UInt64 = 0
        for (utteranceIndex, utterance) in value.utterances.enumerated() {
            try harcRequireFrameRange(
                start: utterance.startFrame,
                end: utterance.endFrameExclusive,
                priorEnd: priorUtteranceEnd,
                maximum: totalCanonicalFrames,
                field: "transcript.utterances[\(utteranceIndex)]"
            )
            try harcRequireConfidence(utterance.hasConfidence ? utterance.confidence : nil)
            if utterance.hasLocalSpeakerID {
                try harcRequireCanonicalASCII(
                    utterance.localSpeakerID,
                    field: "transcript.utterances[\(utteranceIndex)].localSpeakerID",
                    maximumBytes: 128
                )
            }
            var priorWordEnd = utterance.startFrame
            for (wordIndex, word) in utterance.words.enumerated() {
                try harcRequireFrameRange(
                    start: word.startFrame,
                    end: word.endFrameExclusive,
                    priorEnd: priorWordEnd,
                    maximum: utterance.endFrameExclusive,
                    field: "transcript.utterances[\(utteranceIndex)].words[\(wordIndex)]"
                )
                guard word.startFrame >= utterance.startFrame else {
                    throw HarcProtocolCodecError.invalidTimeRange(field: "transcript.wordBounds")
                }
                try harcRequireConfidence(word.hasConfidence ? word.confidence : nil)
                if word.hasLocalSpeakerID {
                    try harcRequireCanonicalASCII(
                        word.localSpeakerID,
                        field: "transcript.word.localSpeakerID",
                        maximumBytes: 128
                    )
                }
                priorWordEnd = word.endFrameExclusive
            }
            priorUtteranceEnd = utterance.endFrameExclusive
        }
    }

    private static func validateDiarization(
        _ value: Harc_V1_DiarizationArtifactV1,
        totalCanonicalFrames: UInt64?
    ) throws {
        var priorEnd: UInt64 = 0
        for (index, turn) in value.turns.enumerated() {
            try harcRequireFrameRange(
                start: turn.startFrame,
                end: turn.endFrameExclusive,
                priorEnd: priorEnd,
                maximum: totalCanonicalFrames,
                field: "diarization.turns[\(index)]"
            )
            try harcRequireCanonicalASCII(
                turn.localClusterID,
                field: "diarization.turns[\(index)].localClusterID",
                maximumBytes: 128
            )
            try harcRequireConfidence(turn.hasConfidence ? turn.confidence : nil)
            priorEnd = turn.endFrameExclusive
        }
    }

    private static func validateSummary(_ value: Harc_V1_SummaryArtifactV1) throws {
        guard value.hasSummaryMarkdown || value.hasActionItemsMarkdown else {
            throw HarcProtocolCodecError.missingPayloadBinding(field: "summary.content")
        }
        try harcRequireCanonicalASCII(value.promptID, field: "summary.promptID", maximumBytes: 256)
        try harcRequireCanonicalASCII(value.promptRevision, field: "summary.promptRevision", maximumBytes: 256)
        let keys = value.modelRevisions.map(\.componentID)
        guard keys == keys.sorted() else {
            throw HarcProtocolCodecError.nonCanonicalOrder(field: "summary.modelRevisions")
        }
        guard Set(keys).count == keys.count else {
            throw HarcProtocolCodecError.duplicateValue(field: "summary.modelRevisions")
        }
        for revision in value.modelRevisions {
            try harcRequireCanonicalASCII(revision.componentID, field: "summary.modelRevision.componentID", maximumBytes: 256)
            try harcRequireCanonicalASCII(revision.revision, field: "summary.modelRevision.revision", maximumBytes: 256)
        }
    }

    private static func validateCoverage(
        _ value: Harc_V1_CoverageArtifactV1,
        totalCanonicalFrames: UInt64?
    ) throws {
        let coverage = value.coverage
        var categorized: [(start: UInt64, end: UInt64)] = []
        for (index, range) in coverage.coveredRanges.enumerated() {
            try harcRequireFrameRange(
                start: range.startFrame,
                end: range.endFrameExclusive,
                priorEnd: index == 0 ? 0 : coverage.coveredRanges[index - 1].endFrameExclusive,
                maximum: totalCanonicalFrames,
                field: "coverage.coveredRanges[\(index)]"
            )
            categorized.append((range.startFrame, range.endFrameExclusive))
        }
        for (category, ranges) in [
            ("degradedRanges", coverage.degradedRanges),
            ("failedRanges", coverage.failedRanges),
        ] {
            var priorEnd: UInt64 = 0
            for (index, explained) in ranges.enumerated() {
                guard explained.hasFrames else {
                    throw HarcProtocolCodecError.missingPayloadBinding(field: "coverage.\(category)[\(index)].frames")
                }
                try harcRequireFrameRange(
                    start: explained.frames.startFrame,
                    end: explained.frames.endFrameExclusive,
                    priorEnd: priorEnd,
                    maximum: totalCanonicalFrames,
                    field: "coverage.\(category)[\(index)]"
                )
                try harcRequireProtocolIdentifierASCII(
                    explained.reasonCode,
                    field: "coverage.\(category)[\(index)].reasonCode",
                    maximumBytes: 256
                )
                categorized.append((explained.frames.startFrame, explained.frames.endFrameExclusive))
                priorEnd = explained.frames.endFrameExclusive
            }
        }
        categorized.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        var expectedStart: UInt64 = 0
        for range in categorized {
            guard range.start == expectedStart else {
                throw HarcProtocolCodecError.invalidTimeRange(field: "coverage.completePartition")
            }
            expectedStart = range.end
        }
        if let totalCanonicalFrames, expectedStart != totalCanonicalFrames {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "coverage.totalCanonicalFrames",
                expected: totalCanonicalFrames,
                actual: expectedStart
            )
        }
    }

    private static func transcriptTextBytes(_ value: Harc_V1_TranscriptArtifactV1) -> Int {
        value.locale.utf8.count + value.utterances.reduce(into: 0) { total, utterance in
            total += utterance.text.utf8.count
            if utterance.hasLocalSpeakerID { total += utterance.localSpeakerID.utf8.count }
            for word in utterance.words {
                total += word.text.utf8.count
                if word.hasLocalSpeakerID { total += word.localSpeakerID.utf8.count }
            }
        }
    }

    private static func summaryTextBytes(_ value: Harc_V1_SummaryArtifactV1) -> Int {
        var total = value.promptID.utf8.count + value.promptRevision.utf8.count
        if value.hasSummaryMarkdown { total += value.summaryMarkdown.utf8.count }
        if value.hasActionItemsMarkdown { total += value.actionItemsMarkdown.utf8.count }
        for revision in value.modelRevisions {
            total += revision.componentID.utf8.count + revision.revision.utf8.count
        }
        return total
    }

    private static func diarizationTextBytes(_ value: Harc_V1_DiarizationArtifactV1) -> Int {
        value.turns.reduce(0) { $0 + $1.localClusterID.utf8.count }
    }

    private static func coverageTextBytes(_ value: Harc_V1_CoverageArtifactV1) -> Int {
        value.coverage.degradedRanges.reduce(0) { $0 + $1.reasonCode.utf8.count }
            + value.coverage.failedRanges.reduce(0) { $0 + $1.reasonCode.utf8.count }
    }

    private static func addTextBytes(_ count: Int, to total: inout Int) throws {
        let result = total.addingReportingOverflow(count)
        guard !result.overflow, result.partialValue <= maximumDecodedTextBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "processingBundle.decodedText",
                limit: UInt64(maximumDecodedTextBytes),
                actual: UInt64(clamping: result.partialValue)
            )
        }
        total = result.partialValue
    }

    private init(
        exactBytes: Data,
        exactHeaderPayload: Data,
        header: Harc_V1_ProcessingBundleHeaderV1,
        entries: [HarcProcessingBundleEntryV1],
        exactSHA256: Data
    ) {
        self.exactBytes = exactBytes
        self.exactHeaderPayload = exactHeaderPayload
        self.header = header
        self.entries = entries
        self.exactSHA256 = exactSHA256
    }
}

private func harcRequireCanonicalASCII(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.isEmpty,
          value.utf8.count <= maximumBytes,
          value.precomposedStringWithCanonicalMapping == value,
          value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else {
        throw HarcProtocolCodecError.invalidText(field: field)
    }
}

private func harcRequireProtocolIdentifierASCII(
    _ value: String,
    field: String,
    maximumBytes: Int
) throws {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard !value.isEmpty,
          value.utf8.count <= maximumBytes,
          value.unicodeScalars.allSatisfy(allowed.contains) else {
        throw HarcProtocolCodecError.invalidText(field: field)
    }
}

private func harcRequireConfidence(_ value: Float?) throws {
    guard let value else { return }
    guard value.isFinite, (0 ... 1).contains(value) else {
        throw HarcProtocolCodecError.invalidText(field: "confidence")
    }
}

private func harcRequireFrameRange(
    start: UInt64,
    end: UInt64,
    priorEnd: UInt64,
    maximum: UInt64?,
    field: String
) throws {
    guard end > start, start >= priorEnd else {
        throw HarcProtocolCodecError.invalidTimeRange(field: field)
    }
    if let maximum, end > maximum {
        throw HarcProtocolCodecError.invalidTimeRange(field: field)
    }
}
