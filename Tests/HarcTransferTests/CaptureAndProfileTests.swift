import Foundation
import HarcDomain
import Testing
@testable import HarcTransfer

@Suite("HarcTransfer finalized capture and frozen profile")
struct CaptureAndProfileTests {
    @Test("Finalized capture enforces Harc V1 identity, clocks, bytes, and discontinuities")
    func finalizedCaptureInvariants() throws {
        let origin = TransferFixtures.origin()
        let discontinuity = try CaptureDiscontinuity(
            recordingID: origin,
            monotonicTimeNanoseconds: 5_000,
            wallTime: TransferFixtures.baseDate.addingTimeInterval(1),
            reason: .routeChanged,
            affectedFrames: CanonicalFrameRange(startFrame: 16_000, endFrameExclusive: 16_000),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        let capture = TransferFixtures.capture(origin: origin, discontinuities: [discontinuity])
        #expect(capture.totalCanonicalBytes == capture.totalCanonicalFrames * 2)

        #expect(throws: TransferValidationError.self) {
            try FinalizedCapture(
                producingDeviceID: TransferFixtures.device(9),
                originRecordingID: origin,
                captureStartedAt: TransferFixtures.baseDate,
                captureEndedAt: TransferFixtures.baseDate.addingTimeInterval(1),
                captureStartedMonotonicNanoseconds: 1,
                captureEndedMonotonicNanoseconds: 2,
                finalizationReason: .userStopped,
                totalCanonicalFrames: 1,
                totalCanonicalBytes: 2,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(1)),
                discontinuities: []
            )
        }
        #expect(throws: TransferValidationError.self) {
            try FinalizedCapture(
                producingDeviceID: origin.deviceID,
                originRecordingID: origin,
                captureStartedAt: TransferFixtures.baseDate,
                captureEndedAt: TransferFixtures.baseDate.addingTimeInterval(-1),
                captureStartedMonotonicNanoseconds: 2,
                captureEndedMonotonicNanoseconds: 1,
                finalizationReason: .userStopped,
                totalCanonicalFrames: 1,
                totalCanonicalBytes: 2,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(1)),
                discontinuities: []
            )
        }
        #expect(throws: TransferValidationError.self) {
            try FinalizedCapture(
                producingDeviceID: origin.deviceID,
                originRecordingID: origin,
                captureStartedAt: TransferFixtures.baseDate,
                captureEndedAt: TransferFixtures.baseDate.addingTimeInterval(1),
                captureStartedMonotonicNanoseconds: 1,
                captureEndedMonotonicNanoseconds: 2,
                finalizationReason: .userStopped,
                totalCanonicalFrames: 10,
                totalCanonicalBytes: 19,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(1)),
                discontinuities: []
            )
        }
    }

    @Test("Discontinuities must be ordered, bounded, and name the same recording")
    func discontinuityInvariants() throws {
        let origin = TransferFixtures.origin()
        let other = TransferFixtures.origin(deviceByte: 2)
        let wrongOrigin = try CaptureDiscontinuity(
            recordingID: other,
            monotonicTimeNanoseconds: 2_000,
            wallTime: TransferFixtures.baseDate,
            reason: .recovery,
            affectedFrames: CanonicalFrameRange(startFrame: 0, endFrameExclusive: 0),
            canonicalizationPolicy: .preserveCapturedPCM
        )
        #expect(throws: TransferValidationError.self) {
            try FinalizedCapture(
                producingDeviceID: origin.deviceID,
                originRecordingID: origin,
                captureStartedAt: TransferFixtures.baseDate,
                captureEndedAt: TransferFixtures.baseDate.addingTimeInterval(2),
                captureStartedMonotonicNanoseconds: 1_000,
                captureEndedMonotonicNanoseconds: 3_000,
                finalizationReason: .recoveredDurablePrefix,
                totalCanonicalFrames: 10,
                totalCanonicalBytes: 20,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(1)),
                discontinuities: [wrongOrigin]
            )
        }

        let outsideFrames = try CaptureDiscontinuity(
            recordingID: origin,
            monotonicTimeNanoseconds: 2_000,
            wallTime: TransferFixtures.baseDate.addingTimeInterval(1),
            reason: .bufferOverrun,
            affectedFrames: CanonicalFrameRange(startFrame: 9, endFrameExclusive: 11),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        #expect(throws: TransferValidationError.self) {
            try FinalizedCapture(
                producingDeviceID: origin.deviceID,
                originRecordingID: origin,
                captureStartedAt: TransferFixtures.baseDate,
                captureEndedAt: TransferFixtures.baseDate.addingTimeInterval(2),
                captureStartedMonotonicNanoseconds: 1_000,
                captureEndedMonotonicNanoseconds: 3_000,
                finalizationReason: .writerFailure,
                totalCanonicalFrames: 10,
                totalCanonicalBytes: 20,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(1)),
                discontinuities: [outsideFrames]
            )
        }
    }

    @Test("Finalized capture is path-free and validating Codable cannot be bypassed")
    func finalizedCaptureCodable() throws {
        let capture = TransferFixtures.capture()
        let data = try JSONEncoder().encode(capture)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.localizedCaseInsensitiveContains("path"))
        #expect(!text.localizedCaseInsensitiveContains("url"))
        #expect(!text.localizedCaseInsensitiveContains("libraryID"))
        #expect(!text.localizedCaseInsensitiveContains("hostAuthority"))
        #expect(try JSONDecoder().decode(FinalizedCapture.self, from: data) == capture)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["totalCanonicalBytes"] = 1
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FinalizedCapture.self, from: malformed)
        }
    }

    @Test("Codec/container pairs and fixture-only raw PCM are closed and validated")
    func codecAndProfileValidation() throws {
        #expect(throws: TransferValidationError.self) {
            try LosslessEncodingConfiguration(
                codec: .appleLossless,
                container: .flac
            )
        }
        #expect(throws: TransferValidationError.self) {
            try LosslessEncodingConfiguration(
                codec: .flac,
                container: .flac,
                flacCompressionLevel: 13
            )
        }
        let flac = try LosslessEncodingConfiguration.flac(compressionLevel: 5)
        #expect(flac.codec == .flac)
        #expect(flac.container == .flac)
        #expect(flac.isProductionEligible)

        #expect(throws: TransferValidationError.self) {
            try FrozenUploadProfile(
                protocolVersion: TransferProtocolVersion(minor: 0),
                encoding: .rawPCMFixture,
                requiredCapabilities: [],
                negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(TransferFixtures.bytes(1)),
                profileSHA256: UploadProfileSHA256(TransferFixtures.bytes(2)),
                purpose: .production
            )
        }
        let fixture = TransferFixtures.profile(
            encoding: .rawPCMFixture,
            purpose: .fixtureLoopback
        )
        #expect(fixture.purpose == .fixtureLoopback)
    }

    @Test("Frozen profile rejects capability mutation, reordering, and malformed hashes")
    func frozenProfileInvariants() throws {
        let a = try TransferCapabilityID("a.feature")
        let b = try TransferCapabilityID("b.feature")
        #expect(throws: TransferValidationError.self) {
            try FrozenUploadProfile(
                protocolVersion: TransferProtocolVersion(minor: 2),
                encoding: .cafALAC,
                requiredCapabilities: [b, a],
                negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(TransferFixtures.bytes(1)),
                profileSHA256: UploadProfileSHA256(TransferFixtures.bytes(2)),
                purpose: .production
            )
        }
        #expect(throws: TransferValidationError.self) {
            try FrozenUploadProfile(
                protocolVersion: TransferProtocolVersion(minor: 2),
                encoding: .cafALAC,
                requiredCapabilities: [a, a],
                negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(TransferFixtures.bytes(1)),
                profileSHA256: UploadProfileSHA256(TransferFixtures.bytes(2)),
                purpose: .production
            )
        }
        #expect(throws: TransferValidationError.self) {
            try UploadProfileSHA256(Data(repeating: 0, count: 31))
        }

        let profile = TransferFixtures.profile()
        let roundTrip = try JSONDecoder().decode(
            FrozenUploadProfile.self,
            from: JSONEncoder().encode(profile)
        )
        #expect(roundTrip == profile)
    }
}
