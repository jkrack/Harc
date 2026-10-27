import AVFAudio
import HarcDomain
import XCTest
import SwiftUI
import UIKit
@testable import HarcMobile

@MainActor
final class HarcMobileCaptureExperienceTests: XCTestCase {
    func testSetupMacIconInkStaysInsideItsTileAtEveryTextSize() throws {
        for size in DynamicTypeSize.allCases {
            let renderer = ImageRenderer(content:
                HarcMobileMacIcon()
                    .foregroundStyle(.black)
                    .environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 160, height: 160)
                    .background(.white)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Setup-Mac-symbol-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            var bytes = [UInt8](repeating: 0, count: 160 * 160 * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: 160, height: 160, bitsPerComponent: 8,
                bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 160))
            var ink = 0
            var escapedInk = 0
            for y in 0..<160 {
                for x in 0..<160 {
                    let i = (y * 160 + x) * 4
                    if bytes[i] < 64 && bytes[i + 1] < 64 && bytes[i + 2] < 64 && bytes[i + 3] > 240 {
                        ink += 1
                        if x < 58 || x >= 102 || y < 58 || y >= 102 { escapedInk += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(ink, 20, "The symbol must actually render at \(size)")
            XCTAssertEqual(escapedInk, 0, "Symbol ink escaped the 44-point tile at \(size)")
        }
    }

    func testTextActionContrastOnLibrarySurfaces() {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let foreground = luminance(UIColor(HarcMobilePalette.actionText).resolvedColor(with: traits))
            for surface in [UIColor.systemBackground, .secondarySystemGroupedBackground] {
                let background = luminance(surface.resolvedColor(with: traits))
                let ratio = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Text action contrast in \(style)")
            }
        }
    }

    func testLongHostNameIsPreservedInAccessiblePresentation() {
        let name = "Fixture Mac mini — Design and Accessibility Review Workstation"
        let presentation = HarcMobileHostPillPresentation.make(
            status: .connected(lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
            hostName: name
        )
        XCTAssertEqual(presentation.title, name)
        XCTAssertEqual(presentation.accessibilityValue, "\(name), connected")
    }

    func testLongHostNameAtNormalAndLargestText() {
        let name = "Fixture Mac mini — Design and Accessibility Review Workstation"
        let presentation = HarcMobileHostPillPresentation.make(
            status: .connected(lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
            hostName: name
        )
        for size: DynamicTypeSize in [.large, .accessibility5] {
            let host = UIHostingController(rootView:
                HarcMobileHostPill(presentation: presentation, action: {})
                    .environment(\.dynamicTypeSize, size)
                    .padding(16)
            )
            host.safeAreaRegions = []
            let fit = host.sizeThatFits(in: CGSize(width: 390, height: 844))
            XCTAssertLessThanOrEqual(fit.width, 390)
            XCTAssertLessThan(fit.height, 844)
            XCTAssertGreaterThanOrEqual(fit.height, 76)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: fit.height))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Long-Mac-name-component-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

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

        XCTAssertEqual(presentation.title, "Your Mac unavailable")
        XCTAssertEqual(presentation.relativeMoment, .checked(attemptedAt))
    }

    func testPendingTransferCopySaysRecordingIsSafeHere() {
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .idle,
            pendingCount: 2,
            localRecordings: [],
            hostName: "Studio Mac"
        )

        XCTAssertEqual(
            presentation.title,
            "2 recordings safe on this iPhone"
        )
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertEqual(
            presentation.detail,
            "Transfers paused · they move to Studio Mac when ready"
        )
    }

    func testUploadedTransferRequiresVerifiedReceiptLanguage() {
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .uploaded(recordingUUID: UUID()),
            pendingCount: 0,
            localRecordings: []
        )

        XCTAssertEqual(presentation.title, "All recordings verified on Mac")
        XCTAssertEqual(
            presentation.detail,
            "Verified durable receipt received"
        )
        XCTAssertEqual(presentation.tone, .healthy)
    }

    func testCodecGateKeepsExplanationInsideSetupAndSync() {
        let id = UUID()
        let recording = HarcMobileLocalRecording(
            id: id,
            originID: OriginRecordingID(
                deviceID: try! DeviceID(Data(repeating: 0x42, count: 32)),
                recordingUUID: id
            ),
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

        XCTAssertEqual(
            presentation.title,
            "1 recording safe on this iPhone"
        )
        XCTAssertEqual(
            presentation.detail,
            "Open Setup & Sync to review sending status."
        )
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertFalse(presentation.detail.contains("codec"))
    }

    func testHostPillMapsHealthWithoutDashboardCopy() {
        let connected = HarcMobileHostPillPresentation.make(
            status: .connected(
                lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 50)
            ),
            hostName: "Studio Mac"
        )
        XCTAssertEqual(connected.title, "Studio Mac")
        XCTAssertEqual(connected.tone, .connected)
        XCTAssertEqual(
            connected.accessibilityValue,
            "Studio Mac, connected"
        )

        let unpaired = HarcMobileHostPillPresentation.make(
            status: .unpaired,
            hostName: nil
        )
        XCTAssertEqual(unpaired.title, "Pair a Mac")
        XCTAssertEqual(unpaired.accessibilityValue, "No Mac paired")
        XCTAssertEqual(unpaired.tone, .neutral)
    }

    func testMacPillFallbackKeepsConnectionAndRepairMeaning() {
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 200)
        let unavailable = HarcMobileHostPillPresentation.make(
            status: .unavailable(lastAttemptedAt: attemptedAt), hostName: "  "
        )
        XCTAssertEqual(unavailable.title, "Your Mac")
        XCTAssertEqual(unavailable.accessibilityValue, "Your Mac, unavailable")
        XCTAssertEqual(unavailable.tone, .unavailable)
        let repair = HarcMobileHostPillPresentation.make(
            status: .pairingRepairRequired(lastAttemptedAt: attemptedAt),
            hostName: "Studio Mac"
        )
        XCTAssertEqual(repair.title, "Repair pairing")
        XCTAssertEqual(
            repair.accessibilityValue,
            "Pairing with Studio Mac needs repair; recordings remain safe"
        )
    }

    func testSecurityBlockedIsTheOnlyCriticalTransferSummary() {
        let presentation = HarcMobileCaptureStatusPresentation.transfer(
            state: .securityBlocked(
                recordingUUID: UUID(),
                message: "Receipt signature mismatch"
            ),
            pendingCount: 1,
            localRecordings: []
        )

        XCTAssertEqual(
            presentation.title,
            "Transfer paused — security review required"
        )
        XCTAssertEqual(presentation.tone, .critical)
        XCTAssertEqual(
            presentation.detail,
            "1 recording safe on this iPhone"
        )
    }

    func testCancelledLibraryIsTerminalAndDoesNotClaimSyncSuccess() {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 300)
        for count in [0, 2] {
            let presentation = HarcMobileCaptureStatusPresentation.library(
                state: .cancelled, recordingCount: count, lastUpdatedAt: updatedAt
            )
            XCTAssertEqual(presentation.title, "Library refresh cancelled")
            XCTAssertEqual(presentation.tone, .neutral)
            XCTAssertTrue(presentation.detail.contains("Refresh Library to try again"))
            XCTAssertEqual(presentation.relativeMoment, .updated(updatedAt))
        }
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
