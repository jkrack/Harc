import Foundation
import HarcCore
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
    func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async
}

public extension MicCaptureSource {
    func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async {}
}

/// Real implementation backed by AVAudioEngine.
public actor MicCapture: MicCaptureSource {
    private let engine = AVAudioEngine()
    private let selection: MicrophoneSelection
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var integrityHandler: (@Sendable (CaptureIntegrityReport.Reason) -> Void)?
    private var livenessTask: Task<Void, Never>?
    private var tapBlock: AVAudioNodeTapBlock?
    private var tapActivity: MicrophoneTapActivity?

    public func setIntegrityHandler(_ handler: @escaping @Sendable (CaptureIntegrityReport.Reason) -> Void) async { integrityHandler = handler }

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
        if !selection.usesSystemDefault {
            do {
                try input.auAudioUnit.setDeviceID(selectedDevice.deviceID)
            } catch {
                throw AudioError.audioEngineFailed(
                    "\(selectedDevice.name) could not be selected: \(error.localizedDescription)"
                )
            }
        }
        guard input.auAudioUnit.canPerformInput else {
            throw AudioError.audioEngineFailed("\(selectedDevice.name) cannot capture microphone audio.")
        }
        // AUAudioUnit's input is disabled by default. Device selection may
        // rebuild its I/O configuration, so enable input after routing and
        // before asking AVAudioEngine for the hardware format.
        input.auAudioUnit.isInputEnabled = true
        let outputFormat = input.outputFormat(forBus: 0)
        let inputFormat = input.inputFormat(forBus: 0)
        // The input-side format describes whether hardware capture is actually
        // enabled. A valid output bus alone can still belong to a dead input.
        guard Self.isValidInputFormat(inputFormat) else {
            throw AudioError.audioEngineFailed(
                "Microphone input format is unavailable. Check the selected input device in System Settings."
            )
        }

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.continuation = cont

        let handler = integrityHandler
        let activity = MicrophoneTapActivity()
        let tapBlock: AVAudioNodeTapBlock = { [cont, handler, activity] buffer, _ in
            // Copy the buffer — AVAudioEngine reuses the underlying storage.
            guard let copy = try? PCMBufferCopy.copy(buffer) else { handler?(.conversionFailed); return }
            switch cont.yield(copy) {
            case .enqueued:
                activity.noteFrames()
            case .dropped:
                handler?(.bufferOverrun)
                activity.noteFrames()
            case .terminated:
                break
            @unknown default:
                break
            }
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
        self.tapBlock = tapBlock
        self.tapActivity = activity

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            continuation = nil
            self.tapBlock = nil
            self.tapActivity = nil
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
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.configurationChanged() }
        }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self else { return }
                await self.checkTapLiveness(activity)
            }
        }
        return stream
    }

    static func isValidInputFormat(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate.isFinite && format.sampleRate > 0
    }

    static func tapFormatCandidates(outputFormat: AVAudioFormat, inputFormat: AVAudioFormat) -> [AVAudioFormat?] {
        var candidates: [AVAudioFormat?] = []
        if isValidInputFormat(outputFormat) {
            candidates.append(outputFormat)
        }
        if isValidInputFormat(inputFormat), inputFormat != outputFormat {
            candidates.append(inputFormat)
        }
        // A nil format is the last fallback. An explicit output-bus format is
        // the documented AVAudioEngine input-tap configuration and avoids a
        // successful install with an unusable device-negotiated format.
        candidates.append(nil)
        return candidates
    }

    private func checkTapLiveness(_ activity: MicrophoneTapActivity) async {
        guard isRunning, activity.secondsSinceLastFrame >= 5 else { return }
        FileHandle.standardError.write(Data(
            "harc-audio: microphone engine is running but its tap delivered no frames for five seconds\n".utf8
        ))
        integrityHandler?(.sourceStopped)
        await stop()
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

    private func configurationChanged() async {
        guard isRunning, !engine.isRunning else { return }
        let input = engine.inputNode
        do {
            guard let device = AudioInputDeviceCatalog.resolvedDevice(for: selection) else {
                throw AudioError.audioEngineFailed("The selected microphone disconnected.")
            }
            input.removeTap(onBus: 0)
            if !selection.usesSystemDefault {
                try input.auAudioUnit.setDeviceID(device.deviceID)
            }
            guard input.auAudioUnit.canPerformInput else {
                throw AudioError.audioEngineFailed("\(device.name) cannot capture microphone audio.")
            }
            input.auAudioUnit.isInputEnabled = true
            let outputFormat = input.outputFormat(forBus: 0)
            let inputFormat = input.inputFormat(forBus: 0)
            guard Self.isValidInputFormat(inputFormat), let tapBlock else {
                throw AudioError.audioEngineFailed("Microphone input format is unavailable after a device change.")
            }
            var tapError: NSError?
            guard Self.installInputTap(
                on: input,
                bufferSize: 4096,
                preferredFormats: Self.tapFormatCandidates(
                    outputFormat: outputFormat, inputFormat: inputFormat
                ),
                block: tapBlock,
                error: &tapError
            ) else {
                throw AudioError.audioEngineFailed(
                    tapError?.localizedDescription ?? "Microphone tap could not be restarted."
                )
            }
            engine.prepare()
            try engine.start()
            tapActivity?.noteFrames()
            integrityHandler?(.sourceInterrupted)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: microphone restart failed: \(error.localizedDescription)\n".utf8
            ))
            integrityHandler?(.sourceStopped)
            await stop()
        }
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        livenessTask?.cancel()
        livenessTask = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapBlock = nil
        tapActivity = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
    }
}

/// The audio callback only updates a clock; the actor's timer does the slow
/// work. A running AVAudioEngine with no tap frames must not appear healthy.
private final class MicrophoneTapActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFrameAt = ProcessInfo.processInfo.systemUptime

    func noteFrames() {
        lock.withLock { lastFrameAt = ProcessInfo.processInfo.systemUptime }
    }

    var secondsSinceLastFrame: TimeInterval {
        lock.withLock { ProcessInfo.processInfo.systemUptime - lastFrameAt }
    }
}
