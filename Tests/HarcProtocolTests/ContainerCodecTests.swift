import CryptoKit
import Foundation
@testable import HarcProtocol
import HarcProtocolWire
import Testing

@Suite("Exact audio and processing containers")
struct ContainerCodecTests {
    @Test("HARCAB1 preserves exact header and body while validating descriptors")
    func audioBatchRoundTrip() throws {
        let chunks = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        let header = audioHeader(chunks: chunks)
        let batch = try HarcAudioBatchV1.create(header: header, encodedChunks: chunks)
        let decoded = try HarcAudioBatchV1.decode(batch.exactBytes)
        let expectedHeaderPayload = try header.serializedData()


        #expect(batch.exactBytes.prefix(8) == Data("HARCAB1\0".utf8))
        #expect(decoded.exactHeaderPayload == expectedHeaderPayload)
        #expect(decoded.header == header)
        #expect(decoded.encodedChunks == chunks)
        #expect(decoded.exactSHA256 == Data(SHA256.hash(data: batch.exactBytes)))
    }

    @Test("HARCAB1 rejects body tamper, framing mismatch, truncation, and trailing bytes")
    func audioBatchRejections() throws {
        let chunks = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        let batch = try HarcAudioBatchV1.create(
            header: audioHeader(chunks: chunks),
            encodedChunks: chunks
        )

        var tampered = batch.exactBytes
        tampered[tampered.count - 1] ^= 0xff
        #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            try HarcAudioBatchV1.decode(tampered)
        }

        var wrongLength = batch.exactBytes
        let firstBodyLengthOffset = 8 + 4 + batch.exactHeaderPayload.count
        wrongLength[firstBodyLengthOffset + 3] = 3
        #expect(throws: HarcProtocolCodecError.lengthMismatch(
            field: "audioBatch.entries[0].encodedLength",
            expected: 4,
            actual: 3
        )) {
            try HarcAudioBatchV1.decode(wrongLength)
        }

        #expect(throws: HarcProtocolCodecError.self) {
            try HarcAudioBatchV1.decode(batch.exactBytes.dropLast())
        }
        #expect(throws: HarcProtocolCodecError.trailingBytes(count: 1)) {
            try HarcAudioBatchV1.decode(batch.exactBytes + Data([0]))
        }
    }

    @Test("audio header requirements and canonical entry order fail closed")
    func audioHeaderCompatibilityRules() throws {
        let chunks = [Data([1, 2, 0, 0]), Data([3, 4, 0, 0])]
        var unsupported = audioHeader(chunks: chunks)
        unsupported.protocol.requirements.requiredFeatures = ["harc.future.required"]
        #expect(throws: HarcProtocolCodecError.invalidText(
            field: "protocol.unsupportedRequiredFeature"
        )) {
            try HarcAudioBatchV1.create(header: unsupported, encodedChunks: chunks)
        }

        var unknownCritical = audioHeader(chunks: chunks)
        unknownCritical.protocol.requirements.criticalFieldNumbers = [8]
        #expect(throws: HarcProtocolCodecError.invalidText(
            field: "protocol.unknownCriticalField"
        )) {
            try HarcAudioBatchV1.create(header: unknownCritical, encodedChunks: chunks)
        }

        var reversed = audioHeader(chunks: chunks)
        reversed.entries.swapAt(0, 1)
        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(
            field: "audioBatch.entries.chunkIndex"
        )) {
            try HarcAudioBatchV1.create(header: reversed, encodedChunks: Array(chunks.reversed()))
        }
    }

    @Test("container entry counts are bounded from raw protobuf before generated parsing")
    func rawHeaderEntryPreflight() throws {
        let chunk = Data([1, 2, 3, 4])
        var audioHeaderPayload = try audioHeader(chunks: [chunk]).serializedData()
        appendEmptyMessages(
            to: &audioHeaderPayload,
            fieldNumber: 7,
            count: HarcAudioBatchV1.maximumEntries
        )
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "audioBatch.entries",
            minimum: 0,
            maximum: UInt64(HarcAudioBatchV1.maximumEntries),
            actual: UInt64(HarcAudioBatchV1.maximumEntries + 1)
        )) {
            try HarcAudioBatchV1.decode(
                headerOnlyContainer(magic: HarcAudioBatchV1.magic, header: audioHeaderPayload)
            )
        }

        let fixture = try processingFixture()
        var processingHeaderPayload = try fixture.header.serializedData()
        appendEmptyMessages(
            to: &processingHeaderPayload,
            fieldNumber: 5,
            count: HarcProcessingBundleV1.maximumEntries - fixture.header.entries.count + 1
        )
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "processingBundle.entries",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumEntries),
            actual: UInt64(HarcProcessingBundleV1.maximumEntries + 1)
        )) {
            try HarcProcessingBundleV1.decode(
                headerOnlyContainer(
                    magic: HarcProcessingBundleV1.magic,
                    header: processingHeaderPayload
                )
            )
        }
    }

    @Test("create rejects mismatched or excessive payload cardinality before framing")
    func createEntryCountPreflight() throws {
        let chunk = Data([1, 2, 3, 4])
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "audioBatch.encodedChunks",
            minimum: 0,
            maximum: UInt64(HarcAudioBatchV1.maximumEntries),
            actual: UInt64(HarcAudioBatchV1.maximumEntries + 1)
        )) {
            try HarcAudioBatchV1.create(
                header: audioHeader(chunks: [chunk]),
                encodedChunks: Array(
                    repeating: Data(),
                    count: HarcAudioBatchV1.maximumEntries + 1
                )
            )
        }

        let fixture = try processingFixture()
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "processingBundle.entryPayloads",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumEntries),
            actual: UInt64(HarcProcessingBundleV1.maximumEntries + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: fixture.header,
                exactEntryPayloads: Array(
                    repeating: Data(),
                    count: HarcProcessingBundleV1.maximumEntries + 1
                )
            )
        }

        #expect(throws: HarcProtocolCodecError.lengthMismatch(
            field: "processingBundle.entryPayloads",
            expected: UInt64(fixture.payloads.count),
            actual: UInt64(fixture.payloads.count - 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: fixture.header,
                exactEntryPayloads: Array(fixture.payloads.dropLast())
            )
        }
    }

    @Test("aggregate declared container sizes are bounded before body allocation")
    func aggregateDeclaredSizePreflight() throws {
        let chunks = Array(repeating: Data([1, 2, 3, 4]), count: 16)
        var audioHeader = audioHeader(chunks: chunks)
        for index in audioHeader.entries.indices {
            audioHeader.entries[index].encodedLength = UInt32(HarcAudioBatchV1.maximumEntryBytes)
            audioHeader.entries[index].encoding.codec = .losslessAudioCodecAppleLossless
            audioHeader.entries[index].encoding.container = .losslessAudioContainerCoreAudioFormat
        }
        let audioHeaderPayload = try audioHeader.serializedData()
        let audioActual = UInt64(
            HarcAudioBatchV1.magic.count + 4 + audioHeaderPayload.count
                + audioHeader.entries.count * 4
        ) + UInt64(audioHeader.entries.count * HarcAudioBatchV1.maximumEntryBytes)
        #expect(throws: HarcProtocolCodecError.inputTooLarge(
            field: "audioBatch.exactBytes",
            limit: UInt64(HarcAudioBatchV1.maximumExactBytes),
            actual: audioActual
        )) {
            try HarcAudioBatchV1.decode(
                headerOnlyContainer(magic: HarcAudioBatchV1.magic, header: audioHeaderPayload)
            )
        }

        var fixture = try processingFixture()
        for index in fixture.header.entries.indices {
            fixture.header.entries[index].payloadByteLength = UInt64(
                HarcProcessingBundleV1.maximumEntryBytes
            )
        }
        let processingHeaderPayload = try fixture.header.serializedData()
        let processingActual = UInt64(
            HarcProcessingBundleV1.magic.count + 4 + processingHeaderPayload.count + 2 * 8
        ) + UInt64(2 * HarcProcessingBundleV1.maximumEntryBytes)
        #expect(throws: HarcProtocolCodecError.inputTooLarge(
            field: "processingBundle.exactBytes",
            limit: UInt64(HarcProcessingBundleV1.maximumExactBytes),
            actual: processingActual
        )) {
            try HarcProcessingBundleV1.decode(
                headerOnlyContainer(
                    magic: HarcProcessingBundleV1.magic,
                    header: processingHeaderPayload
                )
            )
        }
    }

    @Test("HARCPB1 parses registered entries only after exact length and hash checks")
    func processingBundleRoundTrip() throws {
        let fixture = try processingFixture()
        let bundle = try HarcProcessingBundleV1.create(
            header: fixture.header,
            exactEntryPayloads: fixture.payloads,
            totalCanonicalFrames: 4
        )
        let decoded = try HarcProcessingBundleV1.decode(
            bundle.exactBytes,
            totalCanonicalFrames: 4
        )
        let expectedHeaderPayload = try fixture.header.serializedData()


        #expect(bundle.exactBytes.prefix(8) == Data("HARCPB1\0".utf8))
        #expect(decoded.exactHeaderPayload == expectedHeaderPayload)
        #expect(decoded.entries.count == 4)
        #expect(decoded.entries.map(\.exactPayload) == fixture.payloads)
        #expect(decoded.exactSHA256 == Data(SHA256.hash(data: bundle.exactBytes)))
        try decoded.validateAgainstRecording(totalCanonicalFrames: 4)
    }

    @Test("HARCPB1 rejects tamper, missing required entries, bad coverage, and trailing bytes")
    func processingBundleRejections() throws {
        let fixture = try processingFixture()
        let bundle = try HarcProcessingBundleV1.create(
            header: fixture.header,
            exactEntryPayloads: fixture.payloads,
            totalCanonicalFrames: 4
        )

        var tampered = bundle.exactBytes
        tampered[tampered.count - 1] ^= 0xff
        #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            try HarcProcessingBundleV1.decode(tampered, totalCanonicalFrames: 4)
        }
        #expect(throws: HarcProtocolCodecError.trailingBytes(count: 1)) {
            try HarcProcessingBundleV1.decode(bundle.exactBytes + Data([0]), totalCanonicalFrames: 4)
        }

        var missingCoverage = fixture.header
        missingCoverage.entries.removeLast()
        #expect(throws: HarcProtocolCodecError.missingPayloadBinding(
            field: "processingBundle.requiredEntries"
        )) {
            try HarcProcessingBundleV1.create(
                header: missingCoverage,
                exactEntryPayloads: Array(fixture.payloads.dropLast()),
                totalCanonicalFrames: 4
            )
        }

        var coverage = Harc_V1_CoverageArtifactV1()
        coverage.protocol = protocolVersion()
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 1
        range.endFrameExclusive = 4
        coverage.coverage.coveredRanges = [range]
        let badCoverage = try coverage.serializedData()
        var badHeader = fixture.header
        badHeader.entries[3].payloadByteLength = UInt64(badCoverage.count)
        badHeader.entries[3].payloadSha256.value = Data(SHA256.hash(data: badCoverage))
        var badPayloads = fixture.payloads
        badPayloads[3] = badCoverage
        #expect(throws: HarcProtocolCodecError.invalidTimeRange(
            field: "coverage.completePartition"
        )) {
            try HarcProcessingBundleV1.create(
                header: badHeader,
                exactEntryPayloads: badPayloads,
                totalCanonicalFrames: 4
            )
        }
    }

    @Test("processing repeated structures are bounded before generated parsing")
    func processingNestedRepeatedPreflight() throws {
        let original = try processingFixture()

        var tooManyUtterances = original.payloads[0]
        appendEmptyMessages(
            to: &tooManyUtterances,
            fieldNumber: 3,
            count: HarcProcessingBundleV1.maximumTranscriptUtterances
        )
        let utteranceFixture = replacingPayload(original, at: 0, with: tooManyUtterances)
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "transcript.utterances",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumTranscriptUtterances),
            actual: UInt64(HarcProcessingBundleV1.maximumTranscriptUtterances + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: utteranceFixture.header,
                exactEntryPayloads: utteranceFixture.payloads,
                totalCanonicalFrames: 4
            )
        }

        var tooManyWordsInOneUtterance = Data()
        appendEmptyMessages(
            to: &tooManyWordsInOneUtterance,
            fieldNumber: 6,
            count: HarcProcessingBundleV1.maximumTranscriptWordsPerUtterance + 1
        )
        var transcriptWithWideUtterance = original.payloads[0]
        appendLengthDelimited(
            to: &transcriptWithWideUtterance,
            fieldNumber: 3,
            payload: tooManyWordsInOneUtterance
        )
        let wideFixture = replacingPayload(original, at: 0, with: transcriptWithWideUtterance)
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "transcript.utterance.words",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumTranscriptWordsPerUtterance),
            actual: UInt64(HarcProcessingBundleV1.maximumTranscriptWordsPerUtterance + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: wideFixture.header,
                exactEntryPayloads: wideFixture.payloads,
                totalCanonicalFrames: 4
            )
        }

        var fullUtterance = Data()
        appendEmptyMessages(
            to: &fullUtterance,
            fieldNumber: 6,
            count: HarcProcessingBundleV1.maximumTranscriptWordsPerUtterance
        )
        var transcriptWithTooManyWords = original.payloads[0]
        let extraUtterances = HarcProcessingBundleV1.maximumTranscriptWords
            / HarcProcessingBundleV1.maximumTranscriptWordsPerUtterance + 1
        for _ in 0 ..< extraUtterances {
            appendLengthDelimited(
                to: &transcriptWithTooManyWords,
                fieldNumber: 3,
                payload: fullUtterance
            )
        }
        let totalWordsFixture = replacingPayload(
            original,
            at: 0,
            with: transcriptWithTooManyWords
        )
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "transcript.words",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumTranscriptWords),
            actual: UInt64(HarcProcessingBundleV1.maximumTranscriptWords + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: totalWordsFixture.header,
                exactEntryPayloads: totalWordsFixture.payloads,
                totalCanonicalFrames: 4
            )
        }

        var tooManyTurns = original.payloads[1]
        appendEmptyMessages(
            to: &tooManyTurns,
            fieldNumber: 2,
            count: HarcProcessingBundleV1.maximumDiarizationTurns
        )
        let turnFixture = replacingPayload(original, at: 1, with: tooManyTurns)
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "diarization.turns",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumDiarizationTurns),
            actual: UInt64(HarcProcessingBundleV1.maximumDiarizationTurns + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: turnFixture.header,
                exactEntryPayloads: turnFixture.payloads,
                totalCanonicalFrames: 4
            )
        }

        var tooManyRevisions = original.payloads[2]
        appendEmptyMessages(
            to: &tooManyRevisions,
            fieldNumber: 6,
            count: HarcProcessingBundleV1.maximumSummaryModelRevisions + 1
        )
        let revisionFixture = replacingPayload(original, at: 2, with: tooManyRevisions)
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "summary.modelRevisions",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumSummaryModelRevisions),
            actual: UInt64(HarcProcessingBundleV1.maximumSummaryModelRevisions + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: revisionFixture.header,
                exactEntryPayloads: revisionFixture.payloads,
                totalCanonicalFrames: 4
            )
        }

        var additionalRanges = Data()
        appendEmptyMessages(
            to: &additionalRanges,
            fieldNumber: 1,
            count: HarcProcessingBundleV1.maximumCoverageRanges
        )
        var tooManyRanges = original.payloads[3]
        appendLengthDelimited(
            to: &tooManyRanges,
            fieldNumber: 2,
            payload: additionalRanges
        )
        let rangeFixture = replacingPayload(original, at: 3, with: tooManyRanges)
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "coverage.ranges",
            minimum: 0,
            maximum: UInt64(HarcProcessingBundleV1.maximumCoverageRanges),
            actual: UInt64(HarcProcessingBundleV1.maximumCoverageRanges + 1)
        )) {
            try HarcProcessingBundleV1.create(
                header: rangeFixture.header,
                exactEntryPayloads: rangeFixture.payloads,
                totalCanonicalFrames: 4
            )
        }
    }

    private func audioHeader(chunks: [Data]) -> Harc_V1_AudioBatchHeaderV1 {
        var header = Harc_V1_AudioBatchHeaderV1()
        header.protocol = protocolVersion()
        header.batchID.value = uuidBytes(1)
        header.uploadID.value = uuidBytes(2)
        header.uploadProfileSha256.value = Data(repeating: 3, count: 32)
        header.originRecordingID.deviceID.sha256 = Data(repeating: 4, count: 32)
        header.originRecordingID.recordingUuid = uuidBytes(5)
        header.deviceID.sha256 = Data(repeating: 4, count: 32)
        header.entries = chunks.enumerated().map { index, chunk in
            var entry = Harc_V1_AudioBatchEntryV1()
            entry.chunkID.value = uuidBytes(UInt32(10 + index))
            entry.chunkIndex = UInt32(index)
            entry.encodedLength = UInt32(chunk.count)
            entry.encodedSha256.value = Data(SHA256.hash(data: chunk))
            entry.canonicalStartFrame = UInt64(index * 2)
            entry.canonicalFrameCount = 2
            entry.canonicalDecodedSha256.value = Data(SHA256.hash(data: chunk))
            entry.encoding.codec = .losslessAudioCodecRawCanonicalPcmFixture
            entry.encoding.container = .losslessAudioContainerRawCanonicalPcmFixture
            return entry
        }
        return header
    }

    private func processingFixture() throws -> (
        header: Harc_V1_ProcessingBundleHeaderV1,
        payloads: [Data]
    ) {
        var transcript = Harc_V1_TranscriptArtifactV1()
        transcript.protocol = protocolVersion()
        transcript.locale = "en-US"
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "test"
        utterance.startFrame = 0
        utterance.endFrameExclusive = 4
        var word = Harc_V1_TranscriptWordV1()
        word.text = "test"
        word.startFrame = 0
        word.endFrameExclusive = 4
        utterance.words = [word]
        transcript.utterances = [utterance]

        var diarization = Harc_V1_DiarizationArtifactV1()
        diarization.protocol = protocolVersion()
        var turn = Harc_V1_SpeakerTurnV1()
        turn.startFrame = 0
        turn.endFrameExclusive = 4
        turn.localClusterID = "speaker-1"
        diarization.turns = [turn]

        var summary = Harc_V1_SummaryArtifactV1()
        summary.protocol = protocolVersion()
        summary.summaryMarkdown = "A test."
        summary.promptID = "harc.summary"
        summary.promptRevision = "v1"

        var coverage = Harc_V1_CoverageArtifactV1()
        coverage.protocol = protocolVersion()
        var covered = Harc_V1_CanonicalFrameRangeV1()
        covered.startFrame = 0
        covered.endFrameExclusive = 4
        coverage.coverage.coveredRanges = [covered]

        let payloads = try [
            transcript.serializedData(),
            diarization.serializedData(),
            summary.serializedData(),
            coverage.serializedData(),
        ]
        let types: [Harc_V1_ProcessingBundleEntryTypeV1] = [
            .processingBundleEntryTypeTranscript,
            .processingBundleEntryTypeDiarization,
            .processingBundleEntryTypeSummary,
            .processingBundleEntryTypeCoverage,
        ]

        var header = Harc_V1_ProcessingBundleHeaderV1()
        header.protocol = protocolVersion()
        header.artifactID.value = uuidBytes(20)
        header.originRecordingID.deviceID.sha256 = Data(repeating: 21, count: 32)
        header.originRecordingID.recordingUuid = uuidBytes(22)
        header.canonicalAudioSha256.value = Data(repeating: 23, count: 32)
        header.entries = zip(types, payloads).map { type, payload in
            var descriptor = Harc_V1_ProcessingBundleEntryDescriptorV1()
            descriptor.entryType = type
            descriptor.schemaVersion = 1
            descriptor.payloadByteLength = UInt64(payload.count)
            descriptor.payloadSha256.value = Data(SHA256.hash(data: payload))
            return descriptor
        }
        return (header, payloads)
    }

    private func protocolVersion() -> Harc_V1_ProtocolVersionV1 {
        var value = Harc_V1_ProtocolVersionV1()
        value.major = 1
        value.minor = 0
        return value
    }

    private func replacingPayload(
        _ fixture: (header: Harc_V1_ProcessingBundleHeaderV1, payloads: [Data]),
        at index: Int,
        with payload: Data
    ) -> (header: Harc_V1_ProcessingBundleHeaderV1, payloads: [Data]) {
        var header = fixture.header
        var payloads = fixture.payloads
        payloads[index] = payload
        header.entries[index].payloadByteLength = UInt64(payload.count)
        header.entries[index].payloadSha256.value = Data(SHA256.hash(data: payload))
        return (header, payloads)
    }

    private func headerOnlyContainer(magic: Data, header: Data) -> Data {
        var result = magic
        let length = UInt32(header.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            result.append(UInt8((length >> UInt32(shift)) & 0xff))
        }
        result.append(header)
        return result
    }

    private func appendEmptyMessages(
        to data: inout Data,
        fieldNumber: UInt32,
        count: Int
    ) {
        for _ in 0 ..< count {
            appendLengthDelimited(to: &data, fieldNumber: fieldNumber, payload: Data())
        }
    }

    private func appendLengthDelimited(
        to data: inout Data,
        fieldNumber: UInt32,
        payload: Data
    ) {
        appendVarint(UInt64(fieldNumber) << 3 | 2, to: &data)
        appendVarint(UInt64(payload.count), to: &data)
        data.append(payload)
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private func uuidBytes(_ value: UInt32) -> Data {
        var bytes = Data(repeating: 0, count: 16)
        bytes[12] = UInt8((value >> 24) & 0xff)
        bytes[13] = UInt8((value >> 16) & 0xff)
        bytes[14] = UInt8((value >> 8) & 0xff)
        bytes[15] = UInt8(value & 0xff)
        return bytes
    }
}
