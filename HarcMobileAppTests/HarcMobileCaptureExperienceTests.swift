import AVFAudio
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileCaptureExperienceTests: XCTestCase {
    func testAudioMeterReportsActivityAndResetsWithoutTouchingCaptureState() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 512
        )!
        buffer.frameLength = 512
        let samples = buffer.floatChannelData![0]
        for frame in 0 ..< Int(buffer.frameLength) {
            samples[frame] = frame.isMultiple(of: 2) ? 0.28 : -0.28
        }

        let meter = HarcMobileAudioLevelMeter()
        meter.observe(buffer)

        XCTAssertGreaterThan(meter.level, 0.35)
        XCTAssertLessThanOrEqual(meter.level, 1)
        meter.reset()
        XCTAssertEqual(meter.level, 0)
    }

    func testUnavailableHostUsesActualLastVerifiedTime() {
        let verifiedAt = Date(timeIntervalSinceReferenceDate: 100)
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 200)

        let presentation = HarcMobileCaptureStatusPresentation.host(
            status: .unavailable(lastAttemptedAt: attemptedAt),
            hostName: "Studio Mac",
            lastVerifiedAt: verifiedAt
        )

        XCTAssertEqual(presentation.title, "Studio Mac unavailable")
        XCTAssertEqual(presentation.tone, .caution)
        XCTAssertEqual(presentation.relativeMoment, .seen(verifiedAt))
        XCTAssertTrue(presentation.detail.contains("Local recording"))
    }

    func testUnavailableHostWithoutPriorSuccessReportsLastCheck() {
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 200)

        let presentation = HarcMobileCaptureStatusPresentation.host(
            status: .unavailable(lastAttemptedAt: attemptedAt),
            hostName: nil,
            lastVerifiedAt: nil
        )

        XCTAssertEqual(presentation.title, "Harc Host unavailable")
        XCTAssertEqual(presentation.relativeMoment, .checked(attemptedAt))
    }

    func testPendingTransferCopySaysRecordingIsSafeHere() {
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .idle,
            pendingCount: 2,
            localRecordings: []
        )

        XCTAssertEqual(presentation.title, "2 recordings safe here")
        XCTAssertEqual(presentation.tone, .caution)
        XCTAssertTrue(presentation.detail.contains("verified Host receipt"))
    }

    func testUploadedTransferRequiresVerifiedReceiptLanguage() {
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .uploaded(recordingUUID: UUID()),
            pendingCount: 0,
            localRecordings: []
        )

        XCTAssertEqual(presentation.title, "Saved on Host")
        XCTAssertEqual(
            presentation.detail,
            "Verified durable receipt received"
        )
        XCTAssertEqual(presentation.tone, .healthy)
    }

    func testCodecGateUsesCalmUserFacingLanguageAndLocalCount() {
        let recording = HarcMobileLocalRecording(
            id: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            duration: 30,
            masterFileURL: URL(fileURLWithPath: "/tmp/capture.caf"),
            transferState: .localOnly,
            discontinuities: []
        )
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .codecQualificationRequired(recordingUUID: recording.id),
            pendingCount: 1,
            localRecordings: [recording]
        )

        XCTAssertEqual(presentation.title, "Transfers paused")
        XCTAssertEqual(
            presentation.detail,
            "1 recording safe on this iPhone"
        )
        XCTAssertFalse(presentation.detail.contains("codec"))
        XCTAssertFalse(presentation.detail.contains("build"))
    }

    func testLibraryPresentationNamesCachedCanonicalRecordingCount() {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 300)
        let presentation = HarcMobileCaptureStatusPresentation.library(
            state: .ready(lastUpdated: updatedAt),
            recordingCount: 42,
            lastUpdatedAt: updatedAt
        )

        XCTAssertEqual(presentation.title, "Library")
        XCTAssertEqual(presentation.detail, "42 recordings")
        XCTAssertEqual(presentation.relativeMoment, .updated(updatedAt))
    }
}
