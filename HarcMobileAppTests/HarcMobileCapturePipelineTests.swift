import AVFoundation
import Foundation
import HarcAudioMobile
import HarcDomain
import XCTest
@testable import HarcMobile

final class HarcMobileCapturePipelineTests: XCTestCase {
    @MainActor
    func testDequeuedReconfigurationCheckpointFailureReleasesEveryCaller()
        async throws
    {
        try await assertCheckpointFailureReleasesEveryCaller(cancelAtCheckpoint: false)
    }

    @MainActor
    func testCancelledReconfigurationCheckpointFailureReleasesEveryCaller()
        async throws
    {
        try await assertCheckpointFailureReleasesEveryCaller(cancelAtCheckpoint: true)
    }

    @MainActor
    private func assertCheckpointFailureReleasesEveryCaller(
        cancelAtCheckpoint: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = try HarcMobileCaptureLocations(applicationSupportRoot: root)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let attributes = FailSecondCheckpointAttributes()
        let enqueued = expectation(description: "all route requests queued before writer starts")
        enqueued.expectedFulfillmentCount = 3
        enqueued.assertForOverFulfill = true
        let completed = expectation(description: "pipeline completed once")
        completed.assertForOverFulfill = true
        let rebuilt = expectation(description: "all route rebuild awaits returned")
        rebuilt.expectedFulfillmentCount = 3
        rebuilt.assertForOverFulfill = true
        let pipeline = try HarcMobileCapturePipeline(
            locations: locations,
            producingDeviceID: DeviceID(Data(repeating: 0x59, count: 32)),
            inputFormat: format,
            tapFrameCapacity: 4_096,
            captureStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            storageAttributes: attributes,
            reconfigurationEnqueuedForTesting: { enqueued.fulfill() }
        ) { result in
            switch result {
            case .success:
                XCTFail("An empty failed capture unexpectedly produced a master")
            case .failure(let error):
                XCTAssertEqual(error as? CheckpointFault, .injected)
            }
            completed.fulfill()
        }

        // No microphone or audio buffers: initialization writes checkpoint #1;
        // the first dequeued route request forces checkpoint #2 and throws.
        // Observe admission before starting the writer: its first request is
        // in-flight at the fault while exactly two more remain queued.
        let callers = (0 ..< 3).map { _ in
            Task { @MainActor in
                do {
                    _ = try await pipeline.prepareReplacementInput(
                        replacing: pipeline.initialInput,
                        inputFormat: format,
                        tapFrameCapacity: 4_096,
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .routeChanged
                        )
                    )
                    XCTFail("A failed checkpoint accepted a replacement input")
                } catch {
                    XCTAssertEqual(error as? CheckpointFault, .injected)
                }
                rebuilt.fulfill()
            }
        }
        // Do not await task values or use a task group: the pre-fix continuation
        // leak must fail a bounded expectation instead of hanging test teardown.
        defer { callers.forEach { $0.cancel() } }
        if cancelAtCheckpoint {
            // The fault is reached only after dequeue. Cancel on the writer
            // thread just before it throws, without racing a timer or sleeping.
            attributes.beforeFailure { callers.forEach { $0.cancel() } }
        }
        let admissionResult = await XCTWaiter.fulfillment(of: [enqueued], timeout: 5)
        XCTAssertEqual(admissionResult, .completed)
        pipeline.start()
        let result = await XCTWaiter.fulfillment(
            of: [completed, rebuilt], timeout: 5
        )
        XCTAssertEqual(result, .completed, "Every rebuild await must terminate")
        XCTAssertEqual(attributes.checkpointApplications, 2)

        let late = expectation(description: "post-failure route request returned")
        late.assertForOverFulfill = true
        let lateCaller = Task { @MainActor in
            do {
                _ = try await pipeline.prepareReplacementInput(
                    replacing: pipeline.initialInput,
                    inputFormat: format,
                    tapFrameCapacity: 4_096,
                    discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                        reason: .routeChanged
                    )
                )
                XCTFail("A terminated pipeline accepted a replacement input")
            } catch {
                XCTAssertEqual(error as? CheckpointFault, .injected)
            }
            late.fulfill()
        }
        defer { lateCaller.cancel() }
        let lateResult = await XCTWaiter.fulfillment(of: [late], timeout: 5)
        XCTAssertEqual(lateResult, .completed)
    }

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
        let repeated = expectation(description: "stale repeated request returned")
        repeated.assertForOverFulfill = true
        let repeatedCaller = Task {
            do {
                let format = try XCTUnwrap(AVAudioFormat(
                    standardFormatWithSampleRate: 44_100,
                    channels: 1
                ))
                _ = try await pipeline.prepareReplacementInput(
                    replacing: pipeline.initialInput,
                    inputFormat: format,
                    tapFrameCapacity: 4_096,
                    discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                        reason: .routeChanged
                    )
                )
                XCTFail("A repeated request replaced a stale input generation")
            } catch {
                if let pipelineError = error as? HarcMobileCapturePipelineError,
                   case .staleInputSegment = pipelineError {
                    // The original replacement remains the writer's active input.
                } else {
                    XCTFail("Unexpected repeated-request error: \(error)")
                }
            }
            repeated.fulfill()
        }
        defer { repeatedCaller.cancel() }
        let repeatedResult = await XCTWaiter.fulfillment(of: [repeated], timeout: 5)
        XCTAssertEqual(repeatedResult, .completed)
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

private enum CheckpointFault: Error, Equatable {
    case injected
}

private final class FailSecondCheckpointAttributes:
    HarcMobileCaptureStorageAttributeApplying, @unchecked Sendable
{
    private let lock = NSLock()
    private var applications = 0
    private var failureAction: (@Sendable () -> Void)?

    func beforeFailure(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        failureAction = action
        lock.unlock()
    }

    var checkpointApplications: Int {
        lock.lock()
        defer { lock.unlock() }
        return applications
    }

    func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws {
        guard url.lastPathComponent.hasSuffix(".capture.json") else { return }
        lock.lock()
        applications += 1
        let shouldFail = applications == 2
        let action = shouldFail ? failureAction : nil
        if shouldFail { failureAction = nil }
        lock.unlock()
        if shouldFail {
            action?()
            throw CheckpointFault.injected
        }
    }
}
