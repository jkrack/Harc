import Foundation
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
}

/// Real implementation backed by SCStream.
public actor SystemAudioCapture: NSObject, SystemAudioCaptureSource, SCStreamOutput {
    /// Hands sample buffers from the (nonisolated) SCStream callback to the
    /// consumer stream *synchronously*, so arrival order is delivery order.
    /// The old path spawned one unstructured Task per buffer — tasks reach
    /// an actor in scheduler order, not creation order, so system-audio
    /// samples could land in the WAV out of sequence under load.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: AsyncStream<AVAudioPCMBuffer>.Continuation?
        func set(_ c: AsyncStream<AVAudioPCMBuffer>.Continuation?) {
            lock.lock(); cont = c; lock.unlock()
        }
        func yield(_ b: AVAudioPCMBuffer) {
            lock.lock(); cont?.yield(b); lock.unlock()
        }
        func finish() {
            lock.lock(); cont?.finish(); cont = nil; lock.unlock()
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

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            throw AudioError.systemAudioStreamFailed("addStreamOutput: \(error.localizedDescription)")
        }

        let (s, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
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
        guard let buffer = Self.convertToPCM(sampleBuffer) else { return }
        // Synchronous yield on the serial sample queue: ordered by construction.
        continuationBox.yield(buffer)
    }

    /// Convert a CMSampleBuffer from SCStream into a Float32 AVAudioPCMBuffer.
    /// SCStream delivers Int16 or Float32 depending on the system; we route
    /// whatever format the buffer describes and let AudioMixer normalise.
    nonisolated private static func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return nil }

        var asbd = streamDesc
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLen = 0
        var ptr: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen,
            dataPointerOut: &ptr
        )
        guard status == kCMBlockBufferNoErr, let src = ptr else { return nil }

        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
           let dst = pcm.floatChannelData {
            // Non-interleaved Float32 — copy per channel. Derive the per-channel
            // stride from the declared frame geometry rather than splitting the
            // observed buffer length, which would be wrong for formats where
            // channel planes aren't equal-sized.
            let perChannelBytes = Int(format.streamDescription.pointee.mBytesPerFrame) * Int(frames)
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src.advanced(by: ch * perChannelBytes), perChannelBytes)
            }
        } else {
            // Interleaved or Int16 — memcpy as a single blob into the raw storage.
            let mutableABL = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            if let raw = mutableABL[0].mData {
                memcpy(raw, src, totalLen)
                mutableABL[0].mDataByteSize = UInt32(totalLen)
            }
        }
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
