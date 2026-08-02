import Foundation
import Testing
@testable import HarcDomain

@Suite("HarcDomain states and discontinuities")
struct StateAndDiscontinuityTests {
    private func origin() throws -> OriginRecordingID {
        OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: 0xA5, count: 32)),
            recordingUUID: try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        )
    }

    @Test("Processing failures use bounded portable codes")
    func processingFailureValidation() throws {
        let failure = try ProcessingFailure(code: "model_missing", message: " Model unavailable ")
        #expect(failure.code == "model_missing")
        #expect(failure.message == "Model unavailable")

        #expect(throws: DomainValidationError.self) {
            try ProcessingFailure(code: "")
        }
        #expect(throws: DomainValidationError.self) {
            try ProcessingFailure(code: "Not Portable")
        }
    }

    @Test("Failure details cannot attach to successful or active processing")
    func processingDescriptorValidation() throws {
        let failure = try ProcessingFailure(code: "transcription_failed")
        #expect(throws: DomainValidationError.self) {
            try ProcessingDescriptor(state: .ready, failure: failure)
        }
        let degraded = try ProcessingDescriptor(state: .degraded, failure: failure)
        #expect(degraded.failure == failure)
        #expect(ProcessingDescriptor.ready.state == .ready)

        let invalidJSON = Data(#"{"state":"ready","failure":{"code":"failed"}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProcessingDescriptor.self, from: invalidJSON)
        }
    }

    @Test("Projection descriptors distinguish unknown legacy from ready V1")
    func projectionDescriptorValidation() throws {
        let versionOne = try ProjectionVersion(1)
        #expect(ProjectionDescriptor.unknownLegacy.version == nil)
        #expect(ProjectionDescriptor.readyV1.version == versionOne)
        #expect(throws: DomainValidationError.self) {
            try ProjectionDescriptor(state: .ready)
        }
        #expect(throws: DomainValidationError.self) {
            try ProjectionDescriptor(state: .unknownLegacy, version: versionOne)
        }
        #expect(throws: DomainValidationError.self) {
            try ProjectionVersion(0)
        }
    }

    @Test("Canonical audio is unavailable until all verified values exist")
    func canonicalAudioValidation() throws {
        let hash = try CanonicalPCMHash(Data(repeating: 0x55, count: 32))
        #expect(CanonicalAudioDescriptor.unavailablePendingHash.pcmSHA256 == nil)
        #expect(throws: DomainValidationError.self) {
            try CanonicalAudioDescriptor(
                availability: .available,
                pcmSHA256: hash,
                totalFrames: nil,
                format: .harcV1
            )
        }
        let available = try CanonicalAudioDescriptor.available(
            pcmSHA256: hash,
            totalFrames: 16_000
        )
        #expect(available.format == .harcV1)
        #expect(available.totalFrames == 16_000)
        #expect(try JSONDecoder().decode(
            CanonicalAudioDescriptor.self,
            from: JSONEncoder().encode(available)
        ) == available)
    }

    @Test("Frame ranges are half-open and reject reversed bounds")
    func frameRanges() throws {
        let range = try CanonicalFrameRange(startFrame: 10, endFrameExclusive: 25)
        #expect(range.frameCount == 15)
        #expect(try CanonicalFrameRange(startFrame: 10, endFrameExclusive: 10).frameCount == 0)
        #expect(throws: DomainValidationError.self) {
            try CanonicalFrameRange(startFrame: 11, endFrameExclusive: 10)
        }
    }

    @Test("Capture route and discontinuity values validate portable metadata")
    func discontinuityValidation() throws {
        #expect(throws: DomainValidationError.self) {
            try CaptureRouteDescriptor()
        }
        #expect(throws: DomainValidationError.self) {
            try CaptureRouteDescriptor(name: "Mic", sampleRateHz: .infinity)
        }

        let route = try CaptureRouteDescriptor(
            identifier: "built-in-mic",
            name: "Built-in Microphone",
            sampleRateHz: 48_000,
            channelCount: 1
        )
        let value = try CaptureDiscontinuity(
            recordingID: origin(),
            monotonicTimeNanoseconds: 42,
            wallTime: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .routeChanged,
            newRoute: route,
            affectedFrames: CanonicalFrameRange(startFrame: 160, endFrameExclusive: 160),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        #expect(try JSONDecoder().decode(
            CaptureDiscontinuity.self,
            from: JSONEncoder().encode(value)
        ) == value)
    }

    @Test("Library metadata enforces the host tuple")
    func libraryMetadataValidation() throws {
        let libraryID = LibraryID.random()
        let authorityID = try HostAuthorityID(Data(repeating: 0x33, count: 32))
        let stateID = HostStateID.random()

        #expect(throws: DomainValidationError.inconsistentHostIdentity) {
            try LibraryMetadata(
                libraryID: libraryID,
                writerMode: .standalone,
                hostAuthorityID: authorityID,
                hostStateID: nil,
                currentChangeCursor: .zero
            )
        }
        #expect(throws: DomainValidationError.inconsistentHostIdentity) {
            try LibraryMetadata(
                libraryID: libraryID,
                writerMode: .host,
                hostAuthorityID: nil,
                hostStateID: nil,
                currentChangeCursor: .zero
            )
        }

        let dormant = try LibraryMetadata(
            libraryID: libraryID,
            writerMode: .standalone,
            hostAuthorityID: authorityID,
            hostStateID: stateID,
            currentChangeCursor: ChangeCursor(7)
        )
        #expect(try JSONDecoder().decode(
            LibraryMetadata.self,
            from: JSONEncoder().encode(dormant)
        ) == dormant)
    }
}
