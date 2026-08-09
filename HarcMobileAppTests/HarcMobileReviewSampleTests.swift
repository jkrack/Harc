import Foundation
import XCTest
@testable import HarcMobile

final class HarcMobileReviewSampleTests: XCTestCase {
    func testReviewSampleIsOfflineReadOnlyAndContainsNoUserData() {
        XCTAssertFalse(HarcMobileReviewSample.requiresHost)
        XCTAssertFalse(HarcMobileReviewSample.containsUserData)
        XCTAssertFalse(HarcMobileReviewSample.writesClientState)
        XCTAssertFalse(HarcMobileReviewSample.title.isEmpty)
        XCTAssertFalse(HarcMobileReviewSample.transcript.isEmpty)
        XCTAssertFalse(HarcMobileReviewSample.summary.isEmpty)
        XCTAssertFalse(HarcMobileReviewSample.tags.isEmpty)
    }

    func testSyntheticReviewAudioIsCanonicalMonoPCM16WAV() throws {
        let audio = HarcMobileReviewSampleAudio.makeWAV()
        let expectedPayload = Int(HarcMobileReviewSampleAudio.sampleRate)
            * HarcMobileReviewSample.durationSeconds
            * MemoryLayout<Int16>.size

        XCTAssertEqual(audio.count, 44 + expectedPayload)
        XCTAssertEqual(String(data: audio[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: audio[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: audio[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(try uint16(audio, offset: 20), 1)
        XCTAssertEqual(
            try uint16(audio, offset: 22),
            HarcMobileReviewSampleAudio.channels
        )
        XCTAssertEqual(
            try uint32(audio, offset: 24),
            HarcMobileReviewSampleAudio.sampleRate
        )
        XCTAssertEqual(
            try uint16(audio, offset: 34),
            HarcMobileReviewSampleAudio.bitsPerSample
        )
        XCTAssertEqual(try uint32(audio, offset: 40), UInt32(expectedPayload))
        XCTAssertTrue(audio[44...].contains { $0 != 0 })
    }

    func testCriticalAccessibilityIdentifiersAreUnique() {
        let identifiers = [
            HarcMobileAccessibilityID.root,
            HarcMobileAccessibilityID.startRecording,
            HarcMobileAccessibilityID.stopRecording,
            HarcMobileAccessibilityID.recordingBanner,
            HarcMobileAccessibilityID.recordingBannerStop,
            HarcMobileAccessibilityID.openReviewSample,
            HarcMobileAccessibilityID.openReviewSampleToolbar,
            HarcMobileAccessibilityID.reviewSampleRoot,
            HarcMobileAccessibilityID.reviewSampleAudio,
            HarcMobileAccessibilityID.scanPairingCode,
            HarcMobileAccessibilityID.pairingWordsMatch,
            HarcMobileAccessibilityID.pairingWordsMismatch,
            HarcMobileAccessibilityID.exportDisclosure,
            HarcMobileAccessibilityID.exportShare,
            HarcMobileAccessibilityID.privacy,
        ]
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("harc.mobile.") })
    }

    func testPrivacyCopyMatchesTheNoTrackingAndNoContentAccessArchitecture() {
        XCTAssertEqual(
            HarcMobilePrivacyCopy.dataCollectionAnswer,
            "No tracking, advertising, app-use analytics, or developer access "
                + "to recording content."
        )
        XCTAssertTrue(HarcMobilePrivacyCopy.summary.contains("no cloud account"))
        XCTAssertTrue(HarcMobilePrivacyCopy.summary.contains("does not retain Workers logs or traces"))
        XCTAssertTrue(HarcMobilePrivacyCopy.recording.contains("verified durable receipt"))
        XCTAssertTrue(HarcMobilePrivacyCopy.permissions.contains("Local Network"))
        XCTAssertTrue(HarcMobilePrivacyCopy.permissions.contains("while servicing the connection"))
        XCTAssertTrue(HarcMobilePrivacyCopy.export.contains("system share sheet"))
    }

    private func uint16(_ data: Data, offset: Int) throws -> UInt16 {
        let range = offset..<(offset + MemoryLayout<UInt16>.size)
        let bytes = try XCTUnwrap(data.subdata(in: range).withUnsafeBytes {
            $0.loadUnaligned(as: UInt16.self)
        })
        return UInt16(littleEndian: bytes)
    }

    private func uint32(_ data: Data, offset: Int) throws -> UInt32 {
        let range = offset..<(offset + MemoryLayout<UInt32>.size)
        let bytes = try XCTUnwrap(data.subdata(in: range).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        })
        return UInt32(littleEndian: bytes)
    }
}
