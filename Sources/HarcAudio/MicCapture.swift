import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import HarcAudioObjC

/// Minimal protocol so RecordingSession can be tested against fakes.
public protocol MicCaptureSource: Sendable {
    /// Prompt for permission if not yet granted. Throws `AudioError.micPermissionDenied` on refusal.
    func requestPermission() async throws

    /// Start capture. Returns a stream of PCM buffers at the hardware-native format.
    /// The stream finishes after `stop()`.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>

    func stop() async
}

/// Real implementation backed by AVAudioEngine.
public actor MicCapture: MicCaptureSource {
    private let engine = AVAudioEngine()
    private let selection: MicrophoneSelection
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false

    public init(selection: MicrophoneSelection = .systemDefault) {
        self.selection = selection
    }

    public func requestPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioError.micPermissionDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw AudioError.micPermissionDenied }
        @unknown default:
            throw AudioError.micPermissionDenied
        }
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if isRunning {
            return AsyncStream { cont in cont.finish() }
        }

        let input = engine.inputNode
        guard let selectedDevice = AudioInputDeviceCatalog.resolvedDevice(for: selection) else {
            let name = selection.lastKnownName ?? "the selected microphone"
            throw AudioError.audioEngineFailed(
                selection.usesSystemDefault
                    ? "No system-default microphone is available. Choose an input device in Harc."
                    : "\(name) is not connected. Choose another microphone in Harc."
            )
        }
        do {
            try input.auAudioUnit.setDeviceID(selectedDevice.deviceID)
        } catch {
            throw AudioError.audioEngineFailed(
                "\(selectedDevice.name) could not be selected: \(error.localizedDescription)"
            )
        }
        let outputFormat = input.outputFormat(forBus: 0)
        let inputFormat = input.inputFormat(forBus: 0)
        guard Self.isValidInputFormat(outputFormat) || Self.isValidInputFormat(inputFormat) else {
            throw AudioError.audioEngineFailed(
                "Microphone input format is unavailable. Check the selected input device in System Settings."
            )
        }

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont

        let tapBlock: AVAudioNodeTapBlock = { [cont] buffer, _ in
            // Copy the buffer — AVAudioEngine reuses the underlying storage.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                return
            }
            copy.frameLength = buffer.frameLength
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let total = Int(buffer.frameLength) * bytesPerFrame
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], total)
                }
            }
            cont.yield(copy)
        }

        var tapError: NSError?
        let tapInstalled = Self.installInputTap(
            on: input,
            bufferSize: 4096,
            preferredFormats: Self.tapFormatCandidates(outputFormat: outputFormat, inputFormat: inputFormat),
            block: tapBlock,
            error: &tapError
        )

        guard tapInstalled else {
            cont.finish()
            continuation = nil
            let reason = tapError?.localizedDescription ?? "Microphone tap could not be installed."
            throw AudioError.audioEngineFailed(reason)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            // An input node reporting 0 ch / 0 Hz while the output side looks
            // fine is what a process without effective microphone access sees
            // — the engine then fails deep in AUGraphParser with
            // kAudioUnitErr_FormatNotSupported (-10868). Passing that string
            // through told the user "com.apple.coreaudio.avfaudio error
            // -10868", which names neither the cause nor the fix. The guard
            // above deliberately accepts either format, so this is the point
            // where the distinction can still be drawn.
            guard Self.isValidInputFormat(inputFormat) else {
                throw AudioError.audioEngineFailed(
                    "No microphone input is available. Check Harc's Microphone permission in System Settings → Privacy & Security, and that an input device is selected."
                )
            }
            throw AudioError.audioEngineFailed(error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    static func isValidInputFormat(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate.isFinite && format.sampleRate > 0
    }

    static func tapFormatCandidates(outputFormat: AVAudioFormat, inputFormat: AVAudioFormat) -> [AVAudioFormat?] {
        var candidates: [AVAudioFormat?] = [nil]
        if isValidInputFormat(outputFormat) {
            candidates.append(outputFormat)
        }
        if isValidInputFormat(inputFormat), inputFormat != outputFormat {
            candidates.append(inputFormat)
        }
        return candidates
    }

    private static func installInputTap(
        on input: AVAudioInputNode,
        bufferSize: AVAudioFrameCount,
        preferredFormats: [AVAudioFormat?],
        block: @escaping AVAudioNodeTapBlock,
        error: inout NSError?
    ) -> Bool {
        for format in preferredFormats {
            var candidateError: NSError?
            if HarcInstallTapOnAudioNode(input, 0, bufferSize, format, block, &candidateError) {
                return true
            }
            input.removeTap(onBus: 0)
            error = candidateError
        }
        return false
    }

    public func stop() async {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRunning = false
    }
}
