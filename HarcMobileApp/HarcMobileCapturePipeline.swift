import Darwin
import Foundation
import HarcAudioMobile
import HarcDomain
@preconcurrency import AVFoundation

enum HarcMobileCapturePipelineError: LocalizedError {
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            "The recording ended before the microphone produced audio."
        }
    }
}

struct HarcMobileTerminalCaptureDiscontinuity: Sendable {
    let reason: CaptureDiscontinuityReason
    let oldRoute: CaptureRouteDescriptor?
    let newRoute: CaptureRouteDescriptor?

    init(
        reason: CaptureDiscontinuityReason,
        oldRoute: CaptureRouteDescriptor? = nil,
        newRoute: CaptureRouteDescriptor? = nil
    ) {
        self.reason = reason
        self.oldRoute = oldRoute
        self.newRoute = newRoute
    }
}

/// Owns the non-real-time half of a single recording.
///
/// The engine tap only calls `offer`. Conversion, hashing, checkpointing, and
/// finalization all happen serially on `writerQueue`.
final class HarcMobileCapturePipeline: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<HarcMobileFinalizedMaster, any Error>
    ) -> Void

    let handoff: HarcMobileAudioHandoff

    private let writerQueue = DispatchQueue(
        label: "com.harc.mobile.capture-writer",
        qos: .userInitiated
    )
    private let writer: HarcMobileDurableMasterWriter
    private let converter: HarcMobileCanonicalPCMConverter
    private let inputSampleRate: Double
    private let completion: Completion
    private let stateLock = NSLock()
    private var finishRequest: (
        HarcMobileCaptureFinalizationReason,
        HarcMobileTerminalCaptureDiscontinuity?
    )?
    private var canonicalFrames: UInt64 = 0
    private var lastInputHostTime: UInt64?
    private var lastInputFrameCount: AVAudioFrameCount = 0

    init(
        locations: HarcMobileCaptureLocations,
        producingDeviceID: DeviceID,
        inputFormat: AVAudioFormat,
        tapFrameCapacity: AVAudioFrameCount,
        captureStartedAt: Date,
        captureStartedMonotonicNanoseconds: UInt64,
        completion: @escaping Completion
    ) throws {
        handoff = try HarcMobileAudioHandoff(
            format: inputFormat,
            frameCapacity: tapFrameCapacity
        )
        writer = try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: producingDeviceID,
            captureStartedAt: captureStartedAt,
            captureStartedMonotonicNanoseconds:
                captureStartedMonotonicNanoseconds
        )
        converter = try HarcMobileCanonicalPCMConverter(
            inputFormat: inputFormat
        )
        inputSampleRate = inputFormat.sampleRate
        self.completion = completion
    }

    func start() {
        writerQueue.async { [self] in run() }
    }

    /// Cleans up an initialized writer when the audio engine never started.
    func abandonBeforeStart() {
        _ = try? writer.abandonIfEmpty()
    }

    @inline(__always)
    func offer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        handoff.offer(buffer, hostTime: hostTime)
    }

    func requestFinish(
        reason: HarcMobileCaptureFinalizationReason,
        discontinuity: HarcMobileTerminalCaptureDiscontinuity? = nil
    ) {
        stateLock.lock()
        if finishRequest == nil { finishRequest = (reason, discontinuity) }
        stateLock.unlock()
        handoff.available.signal()
    }

    private func run() {
        do {
            while true {
                handoff.available.wait()
                while let lease = handoff.take() {
                    defer { handoff.release(lease) }
                    let observedInputGap = inputGapBefore(lease)
                    let bytes = try converter.convert(lease.buffer)
                    lastInputHostTime = lease.hostTime
                    lastInputFrameCount = lease.buffer.frameLength
                    guard !bytes.isEmpty else { continue }
                    let now = Date()
                    let monotonic = DispatchTime.now().uptimeNanoseconds
                    try writer.appendCanonicalPCM(
                        bytes,
                        endedAt: now,
                        endedMonotonicNanoseconds: monotonic
                    )
                    canonicalFrames += UInt64(bytes.count / 2)
                    if observedInputGap {
                        try recordDiscontinuity(
                            .bufferOverrun,
                            at: now,
                            monotonic: monotonic
                        )
                    }
                }
                if let request = requestedFinish(), handoff.isEmpty {
                    try finish(request)
                    return
                }
            }
        } catch {
            let reason = Self.failureFinalizationReason(error)
            do {
                if let recovered = try writer
                    .recoverDurablePrefixAfterFailure(reason: reason) {
                    completion(.success(recovered))
                } else {
                    completion(.failure(error))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func inputGapBefore(
        _ lease: HarcMobileAudioHandoffLease
    ) -> Bool {
        guard lease.droppedInputFramesBeforeThisBuffer == 0 else { return true }
        guard let lastInputHostTime, lastInputFrameCount > 0 else { return false }
        let expectedDelta = AVAudioTime.hostTime(
            forSeconds: Double(lastInputFrameCount) / inputSampleRate
        )
        let tolerance = AVAudioTime.hostTime(forSeconds: 0.002)
        let expected = lastInputHostTime.addingReportingOverflow(expectedDelta)
        guard !expected.overflow else { return true }
        let upperBound = expected.partialValue.addingReportingOverflow(tolerance)
        guard !upperBound.overflow else { return true }
        return lease.hostTime > upperBound.partialValue
    }

    private func finish(
        _ request: (
            HarcMobileCaptureFinalizationReason,
            HarcMobileTerminalCaptureDiscontinuity?
        )
    ) throws {
        let tail = try converter.finish()
        if !tail.isEmpty {
            let now = Date()
            let monotonic = DispatchTime.now().uptimeNanoseconds
            try writer.appendCanonicalPCM(
                tail,
                endedAt: now,
                endedMonotonicNanoseconds: monotonic
            )
            canonicalFrames += UInt64(tail.count / 2)
        }
        if canonicalFrames == 0 {
            _ = try writer.abandonIfEmpty()
            completion(.failure(HarcMobileCapturePipelineError.noAudioCaptured))
            return
        }
        if handoff.takePendingDroppedInputFrames() > 0 {
            try recordDiscontinuity(
                .bufferOverrun,
                at: Date(),
                monotonic: DispatchTime.now().uptimeNanoseconds
            )
        }
        if let discontinuity = request.1 {
            try recordDiscontinuity(
                discontinuity.reason,
                at: Date(),
                monotonic: DispatchTime.now().uptimeNanoseconds,
                oldRoute: discontinuity.oldRoute,
                newRoute: discontinuity.newRoute
            )
        }
        completion(.success(try writer.finalize(reason: request.0)))
    }

    private func requestedFinish() -> (
        HarcMobileCaptureFinalizationReason,
        HarcMobileTerminalCaptureDiscontinuity?
    )? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finishRequest
    }

    private func recordDiscontinuity(
        _ reason: CaptureDiscontinuityReason,
        at wallTime: Date,
        monotonic: UInt64,
        oldRoute: CaptureRouteDescriptor? = nil,
        newRoute: CaptureRouteDescriptor? = nil
    ) throws {
        try writer.recordDiscontinuity(CaptureDiscontinuity(
            recordingID: writer.originRecordingID,
            monotonicTimeNanoseconds: monotonic,
            wallTime: wallTime,
            reason: reason,
            oldRoute: oldRoute,
            newRoute: newRoute,
            affectedFrames: CanonicalFrameRange(
                startFrame: canonicalFrames,
                endFrameExclusive: canonicalFrames
            ),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        ))
    }

    private static func failureFinalizationReason(
        _ error: any Error
    ) -> HarcMobileCaptureFinalizationReason {
        guard case .posix(_, let code) = error as?
            HarcMobileCaptureStorageError else {
            return .writerFailure
        }
        return code == ENOSPC || code == EDQUOT
            ? .storageExhausted
            : .writerFailure
    }
}
