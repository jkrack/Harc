import AVFoundation
import Foundation
import HarcAudioMobile
import HarcDomain
import Observation

@MainActor
@Observable
final class HarcMobileCaptureCoordinator {
    enum State: Equatable {
        case idle
        case requestingPermission
        case starting
        case recording(startedAt: Date)
        case stopping
        case saved(recordingUUID: UUID)
        case storageExhausted(recordingUUID: UUID)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let producingDeviceID: DeviceID
    private let locations: HarcMobileCaptureLocations
    private let storageExhaustionAfterCanonicalBytesForTesting: UInt64?
    private let onFinalized: @MainActor (HarcMobileFinalizedMaster) throws -> Void
    private var engine: AVAudioEngine?
    private var pipeline: HarcMobileCapturePipeline?
    private var captureInput: HarcMobileCaptureInput?
    private var activeRoute: CaptureRouteDescriptor?
    private var isReconfiguring = false
    private var observers: [NSObjectProtocol] = []

    init(
        producingDeviceID: DeviceID,
        locations: HarcMobileCaptureLocations,
        storageExhaustionAfterCanonicalBytesForTesting: UInt64? = nil,
        onFinalized: @escaping @MainActor (
            HarcMobileFinalizedMaster
        ) throws -> Void
    ) {
        self.producingDeviceID = producingDeviceID
        self.locations = locations
        self.storageExhaustionAfterCanonicalBytesForTesting =
            storageExhaustionAfterCanonicalBytesForTesting
        self.onFinalized = onFinalized
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return state == .stopping
    }

    var startedAt: Date? {
        if case .recording(let date) = state { return date }
        return nil
    }

    func start() async {
        guard state == .idle || isTerminalState else { return }
        state = .requestingPermission
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else {
            state = .failed("Microphone access is required to record.")
            return
        }

        state = .starting
        var candidatePipeline: HarcMobileCapturePipeline?
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.allowBluetoothHFP]
            )
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw HarcMobileAudioConversionError.unsupportedInputFormat
            }
            let startedAt = Date()
            let startedMonotonic = DispatchTime.now().uptimeNanoseconds
            let pipeline = try HarcMobileCapturePipeline(
                locations: locations,
                producingDeviceID: producingDeviceID,
                inputFormat: format,
                tapFrameCapacity: 4_096,
                captureStartedAt: startedAt,
                captureStartedMonotonicNanoseconds: startedMonotonic,
                storageExhaustionAfterCanonicalBytesForTesting:
                    storageExhaustionAfterCanonicalBytesForTesting
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.pipelineCompleted(result)
                }
            }
            let captureInput = pipeline.initialInput
            candidatePipeline = pipeline
            input.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: format
            ) { [captureInput] buffer, time in
                captureInput.offer(buffer, hostTime: time.hostTime)
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.pipeline = pipeline
            self.captureInput = captureInput
            activeRoute = Self.routeDescriptor(
                session.currentRoute,
                sampleRate: format.sampleRate,
                channelCount: UInt32(format.channelCount)
            )
            pipeline.start()
            installObservers()
            state = .recording(startedAt: startedAt)
        } catch {
            teardownEngine()
            captureInput = nil
            candidatePipeline?.abandonBeforeStart()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        finishCapture(reason: .userStopped, discontinuity: nil)
    }

    func resetTerminalState() {
        guard isTerminalState else { return }
        state = .idle
    }

    private var isTerminalState: Bool {
        switch state {
        case .saved, .storageExhausted, .failed: true
        default: false
        }
    }

    private func finishCapture(
        reason: HarcMobileCaptureFinalizationReason,
        discontinuity: HarcMobileTerminalCaptureDiscontinuity?
    ) {
        guard case .recording = state, let pipeline else { return }
        state = .stopping
        teardownEngine()
        activeRoute = nil
        captureInput = nil
        isReconfiguring = false
        pipeline.requestFinish(reason: reason, discontinuity: discontinuity)
    }

    private func pipelineCompleted(
        _ result: Result<HarcMobileFinalizedMaster, any Error>
    ) async {
        pipeline = nil
        captureInput = nil
        isReconfiguring = false
        removeObservers()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            switch result {
            case .success(let master):
                try onFinalized(master)
                state = Self.terminalState(
                    recordingUUID: master.originRecordingID.recordingUUID,
                    finalizationReason: master.finalizationReason
                )
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    static func terminalState(
        recordingUUID: UUID,
        finalizationReason: HarcMobileCaptureFinalizationReason
    ) -> State {
        finalizationReason == .storageExhausted
            ? .storageExhausted(recordingUUID: recordingUUID)
            : .saved(recordingUUID: recordingUUID)
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let typeValue = notification.userInfo?[
                    AVAudioSessionInterruptionTypeKey
                ] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: typeValue)
                        == .began else { return }
                Task { @MainActor [weak self] in
                    self?.finishCapture(
                        reason: .systemEnded,
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .interruptionBegan,
                            oldRoute: self?.activeRoute
                        )
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let previousRoute = (
                    notification.userInfo?[
                        AVAudioSessionRouteChangePreviousRouteKey
                    ] as? AVAudioSessionRouteDescription
                ).flatMap { Self.routeDescriptor($0) }
                Task { @MainActor [weak self] in
                    let current = AVAudioSession.sharedInstance()
                    await self?.rebuildCapturePath(
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .routeChanged,
                            oldRoute: previousRoute ?? self?.activeRoute,
                            newRoute: Self.routeDescriptor(
                                current.currentRoute,
                                sampleRate: current.sampleRate,
                                channelCount: UInt32(
                                    current.inputNumberOfChannels
                                )
                            )
                        )
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishCapture(
                        reason: .systemEnded,
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .mediaServicesLost,
                            oldRoute: self?.activeRoute
                        )
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let session = AVAudioSession.sharedInstance()
                    self?.finishCapture(
                        reason: .systemEnded,
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .mediaServicesReset,
                            oldRoute: self?.activeRoute,
                            newRoute: Self.routeDescriptor(
                                session.currentRoute,
                                sampleRate: session.sampleRate,
                                channelCount: UInt32(
                                    session.inputNumberOfChannels
                                )
                            )
                        )
                    )
                }
            },
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let session = AVAudioSession.sharedInstance()
                    await self?.rebuildCapturePath(
                        discontinuity: HarcMobileTerminalCaptureDiscontinuity(
                            reason: .engineConfigurationChanged,
                            oldRoute: self?.activeRoute,
                            newRoute: Self.routeDescriptor(
                                session.currentRoute,
                                sampleRate: session.sampleRate,
                                channelCount: UInt32(
                                    session.inputNumberOfChannels
                                )
                            )
                        )
                    )
                }
            },
        ]
    }

    /// Rebuilds the hardware engine and converter while the same durable
    /// master remains open. The old tap is removed before the writer drains
    /// its generation; the replacement tap cannot offer frames until the
    /// writer has finalized the old converter and recorded the discontinuity.
    private func rebuildCapturePath(
        discontinuity: HarcMobileTerminalCaptureDiscontinuity
    ) async {
        guard case .recording = state,
              !isReconfiguring,
              let pipeline,
              let captureInput else { return }
        isReconfiguring = true
        removeObservers()
        teardownEngine()
        var replacementPrepared = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            let replacementEngine = AVAudioEngine()
            let node = replacementEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw HarcMobileAudioConversionError.unsupportedInputFormat
            }
            let replacement = try await pipeline.prepareReplacementInput(
                replacing: captureInput,
                inputFormat: format,
                tapFrameCapacity: 4_096,
                discontinuity: discontinuity
            )
            replacementPrepared = true
            guard case .recording = state else {
                isReconfiguring = false
                return
            }
            self.engine = replacementEngine
            self.captureInput = replacement
            node.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: format
            ) { [replacement] buffer, time in
                replacement.offer(buffer, hostTime: time.hostTime)
            }
            replacementEngine.prepare()
            try replacementEngine.start()
            activeRoute = Self.routeDescriptor(
                session.currentRoute,
                sampleRate: format.sampleRate,
                channelCount: UInt32(format.channelCount)
            )
            isReconfiguring = false
            installObservers()
        } catch {
            isReconfiguring = false
            guard case .recording = state else { return }
            finishCapture(
                reason: .systemEnded,
                discontinuity: replacementPrepared ? nil : discontinuity
            )
        }
    }

    nonisolated private static func routeDescriptor(
        _ route: AVAudioSessionRouteDescription,
        sampleRate: Double? = nil,
        channelCount: UInt32? = nil
    ) -> CaptureRouteDescriptor? {
        let input = route.inputs.first
        return try? CaptureRouteDescriptor(
            identifier: input?.uid,
            name: input?.portName,
            sampleRateHz: sampleRate.flatMap { $0 > 0 ? $0 : nil },
            channelCount: channelCount.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
