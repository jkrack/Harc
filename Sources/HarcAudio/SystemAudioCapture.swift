import Foundation
import HarcCore
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
@preconcurrency import ScreenCaptureKit

public protocol SystemAudioCaptureSource: Sendable {
    /// Request screen-recording permission. Throws `AudioError.systemAudioPermissionDenied` on refusal.
    /// First call triggers the TCC prompt.
    func requestPermission() async throws

    /// Start capture. Returns a stream of PCM buffers.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>

    func stop() async
    func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async
}

public extension SystemAudioCaptureSource {
    func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async {}
}

/// Real implementation backed by SCStream.
public actor SystemAudioCapture: NSObject, SystemAudioCaptureSource, SCStreamOutput, SCStreamDelegate {
    /// Hands sample buffers from the (nonisolated) SCStream callback to the
    /// consumer stream *synchronously*, so arrival order is delivery order.
    /// The old path spawned one unstructured Task per buffer — tasks reach
    /// an actor in scheduler order, not creation order, so system-audio
    /// samples could land in the WAV out of sequence under load.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: AsyncStream<AVAudioPCMBuffer>.Continuation?
        private var handler: (@Sendable (CaptureIntegrityReport.Reason) -> Void)?
        private var stopping = false
        func setHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) {
            lock.withLock { self.handler = handler }
        }
        func set(_ c: AsyncStream<AVAudioPCMBuffer>.Continuation?) {
            lock.withLock { cont = c; stopping = false }
        }
        func yield(_ b: AVAudioPCMBuffer) {
            let dropped = lock.withLock { () -> Bool in
                if let result = cont?.yield(b), case .dropped = result { return true }
                return false
            }
            if dropped { observe(.bufferOverrun) }
        }
        func observe(_ reason: CaptureIntegrityReport.Reason) {
            let callback = lock.withLock { cont != nil && !stopping ? handler : nil }
            callback?(reason)
        }
        func prepareStop() { lock.withLock { stopping = true } }
        func finish() {
            lock.withLock { cont?.finish(); cont = nil }
        }
    }

    private var stream: SCStream?
    private let continuationBox = ContinuationBox()
    /// Serial: `.global(qos:)` is a concurrent queue, which lets SCStream run
    /// two sample callbacks at once — the second half of the ordering bug.
    private let sampleQueue = DispatchQueue(label: "com.harc.system-audio.samples", qos: .userInteractive)
    private var isRunning = false
    // Cached across requestPermission→start within a single session so the TCC
    // path fires once, not twice. Consumed on start; cleared on stop.
    private var cachedContent: SCShareableContent?

    public func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async {
        continuationBox.setHandler(handler)
    }

    public override init() {
        super.init()
    }

    public func requestPermission() async throws {
        // Invoking SCShareableContent triggers the TCC prompt and surfaces denial via error.
        do {
            cachedContent = try await SCShareableContent.current
        } catch {
            throw AudioError.systemAudioPermissionDenied
        }
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if isRunning {
            return AsyncStream { cont in cont.finish() }
        }

        let content: SCShareableContent
        if let cached = cachedContent {
            content = cached
            cachedContent = nil
        } else {
            do {
                content = try await SCShareableContent.current
            } catch {
                throw AudioError.systemAudioPermissionDenied
            }
        }
        guard let display = content.displays.first else {
            throw AudioError.systemAudioStreamFailed("no display")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // We need a minimal video spec even for audio-only capture.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            throw AudioError.systemAudioStreamFailed("addStreamOutput: \(error.localizedDescription)")
        }

        let (s, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuationBox.set(cont)
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            continuationBox.finish()
            throw AudioError.systemAudioStreamFailed("startCapture: \(error.localizedDescription)")
        }
        isRunning = true
        return s
    }

    public func stop() async {
        cachedContent = nil
        guard isRunning, let stream else { return }
        continuationBox.prepareStop()
        try? await stream.stopCapture()
        self.stream = nil
        continuationBox.finish()
        isRunning = false
    }

    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let buffer = Self.convertToPCM(sampleBuffer) else {
            if CMSampleBufferGetNumSamples(sampleBuffer) > 0 { continuationBox.observe(.conversionFailed) }
            return
        }
        // Synchronous yield on the serial sample queue: ordered by construction.
        continuationBox.yield(buffer)
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuationBox.observe(.sourceStopped)
        continuationBox.finish()
    }

    /// Copy a CMSampleBuffer from SCStream into an owned native-format PCM buffer.
    /// SCStream delivers Int16 or Float32 depending on the system; we route
    /// whatever format the buffer describes and let AudioMixer normalise.
    nonisolated static func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              streamDesc.mFormatID == kAudioFormatLinearPCM,
              let frames = Int32(exactly: CMSampleBufferGetNumSamples(sampleBuffer)), frames > 0
        else { return nil }

        var asbd = streamDesc
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        // CoreMedia validates frame geometry and copies into the populated ABL.
        // Raw CMBlockBuffer memcpy assumed contiguity, planar packing and enough
        // destination storage, none of which is guaranteed by that API.
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: frames, into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }
        return pcm
    }
}

/// The "system audio off" source: declines permission without ever touching
/// TCC, which routes the session down its tested mic-only fallback path.
/// Used when the user turns system audio off in Quick Capture — a choice,
/// not a failure, so the caller suppresses the permission nag.
public struct DisabledSystemAudioCapture: SystemAudioCaptureSource {
    public init() {}

    public func requestPermission() async throws {
        throw AudioError.systemAudioPermissionDenied
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
    }

    public func stop() async {}
}
