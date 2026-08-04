import Darwin
import Foundation
import HarcAudioMobile
import HarcDomain
@preconcurrency import AVFoundation

enum HarcMobileCapturePipelineError: LocalizedError {
    case noAudioCaptured
    case captureFinishing
    case staleInputSegment

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            "The recording ended before the microphone produced audio."
        case .captureFinishing:
            "The recording stopped before the audio route could be rebuilt."
        case .staleInputSegment:
            "The audio route changed again before its converter was ready."
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

/// One immutable hardware-format generation. The tap captures this object, so
/// a route rebuild can publish a new generation without taking a lock or
/// changing an object underneath the real-time callback.
final class HarcMobileCaptureInput: @unchecked Sendable {
    fileprivate let handoff: HarcMobileAudioHandoff
    fileprivate let converter: HarcMobileCanonicalPCMConverter
    fileprivate let inputSampleRate: Double
    fileprivate var lastInputHostTime: UInt64?
    fileprivate var lastInputFrameCount: AVAudioFrameCount = 0

    fileprivate init(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        availabilitySignal: DispatchSemaphore
    ) throws {
        handoff = try HarcMobileAudioHandoff(
            format: format,
            frameCapacity: frameCapacity,
            availabilitySignal: availabilitySignal
        )
        converter = try HarcMobileCanonicalPCMConverter(inputFormat: format)
        inputSampleRate = format.sampleRate
    }

    @inline(__always)
    func offer(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        handoff.offer(buffer, hostTime: hostTime)
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

    let initialInput: HarcMobileCaptureInput

    private let writerQueue = DispatchQueue(
        label: "com.harc.mobile.capture-writer",
        qos: .userInitiated
    )
    private let available: DispatchSemaphore
    private let writer: HarcMobileDurableMasterWriter
    private let completion: Completion
    private let stateLock = NSLock()
    private var finishRequest: (
        HarcMobileCaptureFinalizationReason,
        HarcMobileTerminalCaptureDiscontinuity?
    )?
    private var terminalError: (any Error)?
    private var reconfigurationRequests: [ReconfigurationRequest] = []
    private var canonicalFrames: UInt64 = 0

    private struct ReconfigurationRequest: @unchecked Sendable {
        let replacing: HarcMobileCaptureInput
        let replacement: HarcMobileCaptureInput
        let discontinuity: HarcMobileTerminalCaptureDiscontinuity
        let continuation: CheckedContinuation<
            HarcMobileCaptureInput,
            any Error
        >
    }

    init(
        locations: HarcMobileCaptureLocations,
        producingDeviceID: DeviceID,
        inputFormat: AVAudioFormat,
        tapFrameCapacity: AVAudioFrameCount,
        captureStartedAt: Date,
        captureStartedMonotonicNanoseconds: UInt64,
        storageAttributes: any HarcMobileCaptureStorageAttributeApplying =
            FoundationHarcMobileCaptureStorageAttributes(),
        completion: @escaping Completion
    ) throws {
        let available = DispatchSemaphore(value: 0)
        self.available = available
        initialInput = try HarcMobileCaptureInput(
            format: inputFormat,
            frameCapacity: tapFrameCapacity,
            availabilitySignal: available
        )
        writer = try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: producingDeviceID,
            captureStartedAt: captureStartedAt,
            captureStartedMonotonicNanoseconds:
                captureStartedMonotonicNanoseconds,
            attributes: storageAttributes
        )
        self.completion = completion
    }

    func start() {
        writerQueue.async { [self] in run() }
    }

    /// Cleans up an initialized writer when the audio engine never started.
    func abandonBeforeStart() {
        _ = try? writer.abandonIfEmpty()
    }

    func prepareReplacementInput(
        replacing: HarcMobileCaptureInput,
        inputFormat: AVAudioFormat,
        tapFrameCapacity: AVAudioFrameCount,
        discontinuity: HarcMobileTerminalCaptureDiscontinuity
    ) async throws -> HarcMobileCaptureInput {
        let replacement = try HarcMobileCaptureInput(
            format: inputFormat,
            frameCapacity: tapFrameCapacity,
            availabilitySignal: available
        )
        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            if let terminalError {
                stateLock.unlock()
                continuation.resume(throwing: terminalError)
                return
            }
            guard finishRequest == nil else {
                stateLock.unlock()
                continuation.resume(
                    throwing: HarcMobileCapturePipelineError.captureFinishing
                )
                return
            }
            reconfigurationRequests.append(ReconfigurationRequest(
                replacing: replacing,
                replacement: replacement,
                discontinuity: discontinuity,
                continuation: continuation
            ))
            stateLock.unlock()
            available.signal()
        }
    }

    func requestFinish(
        reason: HarcMobileCaptureFinalizationReason,
        discontinuity: HarcMobileTerminalCaptureDiscontinuity? = nil
    ) {
        stateLock.lock()
        if finishRequest == nil { finishRequest = (reason, discontinuity) }
        stateLock.unlock()
        available.signal()
    }

    private func run() {
        var activeInput = initialInput
        do {
            while true {
                available.wait()
                try drain(activeInput)
                if let request = requestedFinish(),
                   activeInput.handoff.isEmpty {
                    failPendingReconfigurations(
                        with: HarcMobileCapturePipelineError.captureFinishing
                    )
                    try finishInput(activeInput)
                    try finishCapture(request)
                    return
                }
                if let request = takeReconfigurationRequest() {
                    guard request.replacing === activeInput else {
                        request.continuation.resume(
                            throwing:
                                HarcMobileCapturePipelineError.staleInputSegment
                        )
                        continue
                    }
                    try finishInput(activeInput)
                    try recordDiscontinuity(
                        request.discontinuity.reason,
                        at: Date(),
                        monotonic: DispatchTime.now().uptimeNanoseconds,
                        oldRoute: request.discontinuity.oldRoute,
                        newRoute: request.discontinuity.newRoute
                    )
                    activeInput = request.replacement
                    request.continuation.resume(returning: activeInput)
                }
            }
        } catch {
            markTerminatedAndFailPendingReconfigurations(with: error)
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
        _ lease: HarcMobileAudioHandoffLease,
        input: HarcMobileCaptureInput
    ) -> Bool {
        guard lease.droppedInputFramesBeforeThisBuffer == 0 else { return true }
        guard let lastInputHostTime = input.lastInputHostTime,
              input.lastInputFrameCount > 0 else { return false }
        let expectedDelta = AVAudioTime.hostTime(
            forSeconds: Double(input.lastInputFrameCount)
                / input.inputSampleRate
        )
        let tolerance = AVAudioTime.hostTime(forSeconds: 0.002)
        let expected = lastInputHostTime.addingReportingOverflow(expectedDelta)
        guard !expected.overflow else { return true }
        let upperBound = expected.partialValue.addingReportingOverflow(tolerance)
        guard !upperBound.overflow else { return true }
        return lease.hostTime > upperBound.partialValue
    }

    private func drain(_ input: HarcMobileCaptureInput) throws {
        while let lease = input.handoff.take() {
            defer { input.handoff.release(lease) }
            let observedInputGap = inputGapBefore(lease, input: input)
            let bytes = try input.converter.convert(lease.buffer)
            input.lastInputHostTime = lease.hostTime
            input.lastInputFrameCount = lease.buffer.frameLength
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
    }

    private func finishInput(_ input: HarcMobileCaptureInput) throws {
        let tail = try input.converter.finish()
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
        if input.handoff.takePendingDroppedInputFrames() > 0 {
            try recordDiscontinuity(
                .bufferOverrun,
                at: Date(),
                monotonic: DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    private func finishCapture(
        _ request: (
            HarcMobileCaptureFinalizationReason,
            HarcMobileTerminalCaptureDiscontinuity?
        )
    ) throws {
        if canonicalFrames == 0 {
            _ = try writer.abandonIfEmpty()
            completion(.failure(HarcMobileCapturePipelineError.noAudioCaptured))
            return
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

    private func takeReconfigurationRequest() -> ReconfigurationRequest? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !reconfigurationRequests.isEmpty else { return nil }
        return reconfigurationRequests.removeFirst()
    }

    private func failPendingReconfigurations(with error: any Error) {
        stateLock.lock()
        let pending = reconfigurationRequests
        reconfigurationRequests.removeAll()
        stateLock.unlock()
        for request in pending {
            request.continuation.resume(throwing: error)
        }
    }

    private func markTerminatedAndFailPendingReconfigurations(
        with error: any Error
    ) {
        stateLock.lock()
        terminalError = error
        let pending = reconfigurationRequests
        reconfigurationRequests.removeAll()
        stateLock.unlock()
        for request in pending {
            request.continuation.resume(throwing: error)
        }
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
