import AVFoundation
import Foundation
import HarcAudioMobile
import HarcDomain
import XCTest
@testable import HarcMobile

final class HarcMobileCapturePipelineTests: XCTestCase {
    func testReconfigurationAfterWriterFailureFailsInsteadOfWaiting()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: root
        )
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let (results, resultContinuation) = AsyncStream<
            Result<HarcMobileFinalizedMaster, any Error>
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pipeline = try HarcMobileCapturePipeline(
            locations: locations,
            producingDeviceID: DeviceID(Data(repeating: 0x58, count: 32)),
            inputFormat: format,
            tapFrameCapacity: 4_096,
            captureStartedAt: Date().addingTimeInterval(60),
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            storageAttributes: NoopStorageAttributes()
        ) { result in
            resultContinuation.yield(result)
            resultContinuation.finish()
        }

        pipeline.start()
        pipeline.initialInput.offer(
            try makeBuffer(
                format: format,
                frameCount: 2_400,
                value: 0.15
            ),
            hostTime: 10_000
        )

        var iterator = results.makeAsyncIterator()
        let maybeCompletedResult = await iterator.next()
        let completedResult = try XCTUnwrap(maybeCompletedResult)
        if case .success = completedResult {
            XCTFail("Invalid writer chronology unexpectedly succeeded")
        }

        do {
            _ = try await pipeline.prepareReplacementInput(
                replacing: pipeline.initialInput,
                inputFormat: format,
                tapFrameCapacity: 4_096,
                discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                    reason: .routeChanged
                )
            )
            XCTFail("A terminated pipeline accepted a reconfiguration")
        } catch {
            XCTAssertEqual(
                error as? HarcMobileCaptureStorageError,
                .invalidCanonicalBytes
            )
        }
    }

    func testFormatChangingRouteRebuildsConverterWithoutSplittingMaster()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: root
        )
        let deviceID = try DeviceID(Data(repeating: 0x57, count: 32))
        let initialFormat = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let replacementFormat = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ))
        let oldRoute = try CaptureRouteDescriptor(
            identifier: "built-in-mic",
            name: "Built-in Microphone",
            sampleRateHz: initialFormat.sampleRate,
            channelCount: UInt32(initialFormat.channelCount)
        )
        let newRoute = try CaptureRouteDescriptor(
            identifier: "usb-mic",
            name: "USB Microphone",
            sampleRateHz: replacementFormat.sampleRate,
            channelCount: UInt32(replacementFormat.channelCount)
        )
        let (results, resultContinuation) = AsyncStream<
            Result<HarcMobileFinalizedMaster, any Error>
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pipeline = try HarcMobileCapturePipeline(
            locations: locations,
            producingDeviceID: deviceID,
            inputFormat: initialFormat,
            tapFrameCapacity: 4_096,
            captureStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            storageAttributes: NoopStorageAttributes()
        ) { result in
            resultContinuation.yield(result)
            resultContinuation.finish()
        }

        pipeline.start()
        pipeline.initialInput.offer(
            try makeBuffer(
                format: initialFormat,
                frameCount: 2_400,
                value: 0.15
            ),
            hostTime: 10_000
        )
        let replacement = try await pipeline.prepareReplacementInput(
            replacing: pipeline.initialInput,
            inputFormat: replacementFormat,
            tapFrameCapacity: 4_096,
            discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                reason: .routeChanged,
                oldRoute: oldRoute,
                newRoute: newRoute
            )
        )
        replacement.offer(
            try makeBuffer(
                format: replacementFormat,
                frameCount: 2_205,
                value: 0.25
            ),
            hostTime: 20_000
        )
        pipeline.requestFinish(reason: .userStopped)

        var iterator = results.makeAsyncIterator()
        let completedResult = await iterator.next()
        let result = try XCTUnwrap(completedResult)
        let master: HarcMobileFinalizedMaster
        switch result {
        case .success(let finalized):
            master = finalized
        case .failure(let error):
            XCTFail("Capture pipeline failed: \(error)")
            return
        }

        XCTAssertEqual(master.producingDeviceID, deviceID)
        XCTAssertEqual(master.finalizationReason, .userStopped)
        XCTAssertEqual(master.totalCanonicalFrames, 1_600)
        XCTAssertEqual(master.discontinuities.count, 1)
        XCTAssertEqual(master.discontinuities.first?.reason, .routeChanged)
        XCTAssertEqual(master.discontinuities.first?.oldRoute, oldRoute)
        XCTAssertEqual(master.discontinuities.first?.newRoute, newRoute)
        XCTAssertEqual(
            try Data(contentsOf: master.masterFileURL).count,
            44 + 1_600 * 2
        )
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        value: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< Int(frameCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }
}

private struct NoopStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying
{
    func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws {}
}
