import AVFAudio
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import UIKit

enum SpikeCodec: String, CaseIterable, Codable, Identifiable, Sendable {
    case cafALAC = "caf-alac"
    case flac = "flac"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cafALAC: "CAF + ALAC"
        case .flac: "FLAC"
        }
    }

    var fileExtension: String {
        switch self {
        case .cafALAC: "caf"
        case .flac: "flac"
        }
    }

    var formatID: AudioFormatID {
        switch self {
        case .cafALAC: kAudioFormatAppleLossless
        case .flac: kAudioFormatFLAC
        }
    }
}

enum CodecSpikeMode: String, Codable, Sendable {
    case quickMatrix
    case threeHourRealTime
}

struct CodecSpikeProgress: Sendable {
    let codec: SpikeCodec
    let completedChunks: Int
    let totalChunks: Int
    let message: String
}

struct CodecTrialEvidence: Codable, Sendable {
    let codec: SpikeCodec
    let chunkIndex: Int
    let canonicalFrames: UInt64
    let pcmSHA256: String
    let decodedPCM_SHA256: String
    let encodedSHA256: String
    let encodedBytes: UInt64
    let encodingMilliseconds: Double
    let decodingMilliseconds: Double
    let bitExact: Bool
    let residentBytesBefore: UInt64
    let residentBytesAfter: UInt64
    let peakResidentBytes: UInt64
    let memoryMeasurementAvailable: Bool
    let thermalStateBefore: String
    let thermalStateAfter: String
    let thermalMeasurementAvailable: Bool
    let seriousOrCriticalThermalObserved: Bool
}

struct CodecAggregateEvidence: Codable, Sendable {
    let codec: SpikeCodec
    let completedChunks: Int
    let failedChunks: Int
    let p95EncodingMilliseconds: Double
    let maximumEncodingMilliseconds: Double
    let maximumIncrementalResidentBytes: UInt64
    let maximumQueueDepth: Int
    let memoryMeasurementAvailable: Bool
    let thermalMeasurementAvailable: Bool
    let seriousOrCriticalThermalObserved: Bool
    let totalEncodedBytes: UInt64
    let bitExact: Bool
}

struct CodecSpikeFailure: Codable, Sendable {
    let codec: SpikeCodec
    let chunkIndex: Int
    let message: String
}

struct CodecSpikeReport: Codable, Sendable {
    private static let qualifyingSchemaVersion = 4
    private static let qualifyingCanonicalFormat = "16000-hz-mono-signed-int16-little-endian"
    private static let qualifyingChunkDurationSeconds = 60
    private static let qualifyingChunkCount = 180
    private static let qualifyingCanonicalFramesPerChunk: UInt64 = 960_000
    private static let qualifyingElapsedSeconds = 10_800.0

    let schemaVersion: Int
    let mode: CodecSpikeMode
    let startedAt: Date
    let endedAt: Date
    let elapsedMonotonicSeconds: Double
    let deviceModel: String
    let simulatorBuild: Bool
    let iOSAppOnMac: Bool
    let userInterfaceIdiom: String
    let operatingSystem: String
    let buildSHA: String
    let canonicalFormat: String
    let chunkDurationSeconds: Int
    let scheduledChunkCount: Int
    let trials: [CodecTrialEvidence]
    let aggregates: [CodecAggregateEvidence]
    let failures: [CodecSpikeFailure]

    var hasRecordedPhysicalIdentity: Bool {
        !simulatorBuild
            && !iOSAppOnMac
            && userInterfaceIdiom == "phone"
            && !deviceModel.hasPrefix("Simulator ")
            && Self.isIPhoneHardwareIdentifier(deviceModel)
            && buildSHA.count == 40
            && buildSHA.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    private static func isIPhoneHardwareIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("iPhone") else { return false }
        let numericSuffix = value.dropFirst("iPhone".count)
        let components = numericSuffix.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        return components.allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy(asciiDigits.contains)
        }
    }

    /// A single report can qualify one candidate on one device. Selecting the
    /// release codec still requires the complete cross-device/candidate matrix.
    var passesCandidateDeviceThresholds: Bool {
        let wallSeconds = endedAt.timeIntervalSince(startedAt)
        guard schemaVersion == Self.qualifyingSchemaVersion,
              mode == .threeHourRealTime,
              hasRecordedPhysicalIdentity,
              canonicalFormat == Self.qualifyingCanonicalFormat,
              chunkDurationSeconds == Self.qualifyingChunkDurationSeconds,
              scheduledChunkCount == Self.qualifyingChunkCount,
              elapsedMonotonicSeconds.isFinite,
              elapsedMonotonicSeconds >= Self.qualifyingElapsedSeconds,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt.timeIntervalSinceReferenceDate.isFinite,
              wallSeconds.isFinite,
              wallSeconds >= Self.qualifyingElapsedSeconds,
              !operatingSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              failures.isEmpty,
              aggregates.count == 1,
              trials.count == Self.qualifyingChunkCount else {
            return false
        }

        let aggregate = aggregates[0]
        let recordedIndexes = trials.map(\.chunkIndex)
        guard recordedIndexes == Array(0..<Self.qualifyingChunkCount),
              trials.allSatisfy({ trial in
                  trial.codec == aggregate.codec
                      && trial.canonicalFrames == Self.qualifyingCanonicalFramesPerChunk
                      && Self.isLowercaseSHA256(trial.pcmSHA256)
                      && Self.isLowercaseSHA256(trial.decodedPCM_SHA256)
                      && Self.isLowercaseSHA256(trial.encodedSHA256)
                      && trial.pcmSHA256 == trial.decodedPCM_SHA256
                      && trial.encodedBytes > 0
                      && trial.encodingMilliseconds.isFinite
                      && trial.encodingMilliseconds >= 0
                      && trial.decodingMilliseconds.isFinite
                      && trial.decodingMilliseconds >= 0
                      && trial.bitExact
                      && trial.memoryMeasurementAvailable
                      && trial.thermalMeasurementAvailable
                      && CodecSpikeRunner.isKnownThermalState(trial.thermalStateBefore)
                      && CodecSpikeRunner.isKnownThermalState(trial.thermalStateAfter)
                      && !trial.seriousOrCriticalThermalObserved
                      && trial.peakResidentBytes >= trial.residentBytesBefore
                      && trial.peakResidentBytes >= trial.residentBytesAfter
              }) else {
            return false
        }

        let sortedEncodingMilliseconds = trials.map(\.encodingMilliseconds).sorted()
        let p95Index = Int(ceil(Double(sortedEncodingMilliseconds.count) * 0.95)) - 1
        let observedP95 = sortedEncodingMilliseconds[p95Index]
        let observedMaximum = sortedEncodingMilliseconds.last ?? .infinity
        var observedEncodedBytes: UInt64 = 0
        for trial in trials {
            let addition = observedEncodedBytes.addingReportingOverflow(trial.encodedBytes)
            guard !addition.overflow else { return false }
            observedEncodedBytes = addition.partialValue
        }

        return aggregate.completedChunks == Self.qualifyingChunkCount
            && aggregate.failedChunks == 0
            && aggregate.bitExact
            && aggregate.p95EncodingMilliseconds.isFinite
            && aggregate.p95EncodingMilliseconds == observedP95
            && aggregate.p95EncodingMilliseconds < 10_000
            && aggregate.maximumEncodingMilliseconds.isFinite
            && aggregate.maximumEncodingMilliseconds == observedMaximum
            && (1...2).contains(aggregate.maximumQueueDepth)
            && aggregate.memoryMeasurementAvailable
            && aggregate.maximumIncrementalResidentBytes < 100 * 1_024 * 1_024
            && aggregate.thermalMeasurementAvailable
            && !aggregate.seriousOrCriticalThermalObserved
            && aggregate.totalEncodedBytes == observedEncodedBytes
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

enum CodecSpikeError: LocalizedError {
    case canonicalFormatUnavailable
    case decodedFrameCount(expected: Int, actual: Int)
    case decodedBytesUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .canonicalFormatUnavailable:
            "AVFoundation could not create Harc's 16 kHz mono Int16 format."
        case .decodedFrameCount(let expected, let actual):
            "Decoded frame count mismatch: expected \(expected), got \(actual)."
        case .decodedBytesUnavailable:
            "AVFoundation returned no decoded PCM buffer."
        case .cancelled:
            "The codec spike was cancelled."
        }
    }
}

struct CodecSpikeRunner: Sendable {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerChannel = 16
    static let ordinaryChunkSeconds = 60

    typealias ProgressHandler = @Sendable (CodecSpikeProgress) async -> Void

    func runQuickMatrix(
        chunksPerCodec: Int = 5,
        progress: @escaping ProgressHandler
    ) async throws -> CodecSpikeReport {
        try await run(
            mode: .quickMatrix,
            codecs: SpikeCodec.allCases,
            chunksPerCodec: chunksPerCodec,
            paceInRealTime: false,
            progress: progress
        )
    }

    func runThreeHour(
        codec: SpikeCodec,
        progress: @escaping ProgressHandler
    ) async throws -> CodecSpikeReport {
        try await run(
            mode: .threeHourRealTime,
            codecs: [codec],
            chunksPerCodec: 3 * 60,
            paceInRealTime: true,
            progress: progress
        )
    }

    private func run(
        mode: CodecSpikeMode,
        codecs: [SpikeCodec],
        chunksPerCodec: Int,
        paceInRealTime: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> CodecSpikeReport {
        let startedInstant = ContinuousClock.now
        let startedAt = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-codec-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var trials: [CodecTrialEvidence] = []
        var failures: [CodecSpikeFailure] = []
        var aggregateQueueDepth: [SpikeCodec: Int] = [:]
        let resourceObserver = CodecResourceObserver()
        resourceObserver.start()
        defer { resourceObserver.cancel() }

        for codec in codecs {
            var nextDeadline = ContinuousClock.now
            for chunkIndex in 0..<chunksPerCodec {
                guard !Task.isCancelled else { throw CodecSpikeError.cancelled }

                if paceInRealTime {
                    nextDeadline += .seconds(Self.ordinaryChunkSeconds)
                    try await ContinuousClock().sleep(until: nextDeadline)
                }

                // One chunk becomes ready at each capture boundary. Encoding is
                // deliberately serial; if work ever exceeds a minute this
                // counter exposes the accumulated queue instead of hiding it.
                let now = ContinuousClock.now
                let overdue = paceInRealTime && now > nextDeadline
                    ? Int((now - nextDeadline) / .seconds(Self.ordinaryChunkSeconds))
                    : 0
                aggregateQueueDepth[codec] = max(aggregateQueueDepth[codec, default: 0], overdue + 1)

                await progress(CodecSpikeProgress(
                    codec: codec,
                    completedChunks: chunkIndex,
                    totalChunks: chunksPerCodec,
                    message: "Encoding chunk \(chunkIndex + 1) of \(chunksPerCodec)"
                ))

                do {
                    let pcm = Self.canonicalPCM(chunkIndex: chunkIndex)
                    let output = root.appendingPathComponent(
                        "\(codec.rawValue)-\(chunkIndex).\(codec.fileExtension)"
                    )
                    let trial = try Self.measure(
                        codec: codec,
                        chunkIndex: chunkIndex,
                        pcm: pcm,
                        outputURL: output
                    )
                    trials.append(trial)
                    try? FileManager.default.removeItem(at: output)
                } catch {
                    failures.append(CodecSpikeFailure(
                        codec: codec,
                        chunkIndex: chunkIndex,
                        message: error.localizedDescription
                    ))
                }

                await progress(CodecSpikeProgress(
                    codec: codec,
                    completedChunks: chunkIndex + 1,
                    totalChunks: chunksPerCodec,
                    message: failures.last.map {
                        $0.codec == codec && $0.chunkIndex == chunkIndex
                    } == true
                        ? "Chunk \(chunkIndex + 1) failed"
                        : "Chunk \(chunkIndex + 1) verified"
                ))
            }
        }

        let resourceObservation = resourceObserver.stop()
        let aggregates = codecs.map { codec in
            Self.aggregate(
                codec: codec,
                trials: trials.filter { $0.codec == codec },
                failures: failures.filter { $0.codec == codec },
                maximumQueueDepth: aggregateQueueDepth[codec, default: 0],
                resourceObservation: resourceObservation
            )
        }

        let endedInstant = ContinuousClock.now
        let userInterfaceIdiom = await MainActor.run { Self.userInterfaceIdiom }
        return CodecSpikeReport(
            schemaVersion: 4,
            mode: mode,
            startedAt: startedAt,
            endedAt: Date(),
            elapsedMonotonicSeconds: startedInstant.duration(to: endedInstant).seconds,
            deviceModel: Self.deviceModel,
            simulatorBuild: Self.isSimulatorBuild,
            iOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            userInterfaceIdiom: userInterfaceIdiom,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            buildSHA: Bundle.main.object(forInfoDictionaryKey: "HarcBuildSHA") as? String ?? "unrecorded",
            canonicalFormat: "16000-hz-mono-signed-int16-little-endian",
            chunkDurationSeconds: Self.ordinaryChunkSeconds,
            scheduledChunkCount: chunksPerCodec,
            trials: trials,
            aggregates: aggregates,
            failures: failures
        )
    }

    private static func canonicalPCM(chunkIndex: Int) -> Data {
        let frameCount = sampleRate * ordinaryChunkSeconds
        var samples = [Int16](repeating: 0, count: frameCount)
        var noiseState = UInt64(truncatingIfNeeded: 0x9e37_79b9_7f4a_7c15 ^ UInt64(chunkIndex))

        for frame in 0..<frameCount {
            // Deterministic speech-like fixture without allocating or loading a
            // copyrighted recording. A triangle component exercises prediction;
            // low-level seeded noise prevents an unrealistically tiny file.
            let phase = (frame + chunkIndex * 97) % 320
            let triangle = phase < 160 ? phase : 320 - phase
            noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Int16(truncatingIfNeeded: noiseState >> 52)
            let value = (triangle - 80) * 280 + Int(noise) * 3
            samples[frame] = Int16(clamping: value)
        }

        return samples.withUnsafeBytes { Data($0) }
    }

    private static func measure(
        codec: SpikeCodec,
        chunkIndex: Int,
        pcm: Data,
        outputURL: URL
    ) throws -> CodecTrialEvidence {
        let pcmHash = sha256Hex(pcm)
        let memoryBefore = memorySnapshot
        let thermalBefore = thermalStateName(ProcessInfo.processInfo.thermalState)

        let encodeStart = ContinuousClock.now
        try encode(pcm: pcm, codec: codec, outputURL: outputURL)
        let encodeElapsed = encodeStart.duration(to: .now)
        let encoded = try Data(contentsOf: outputURL, options: [.mappedIfSafe])

        let decodeStart = ContinuousClock.now
        let decoded = try decode(url: outputURL, expectedFrames: pcm.count / MemoryLayout<Int16>.size)
        let decodeElapsed = decodeStart.duration(to: .now)

        let memoryAfter = memorySnapshot
        let thermalAfter = thermalStateName(ProcessInfo.processInfo.thermalState)
        let decodedHash = sha256Hex(decoded)
        return CodecTrialEvidence(
            codec: codec,
            chunkIndex: chunkIndex,
            canonicalFrames: UInt64(pcm.count / MemoryLayout<Int16>.size),
            pcmSHA256: pcmHash,
            decodedPCM_SHA256: decodedHash,
            encodedSHA256: sha256Hex(encoded),
            encodedBytes: UInt64(encoded.count),
            encodingMilliseconds: encodeElapsed.milliseconds,
            decodingMilliseconds: decodeElapsed.milliseconds,
            bitExact: decoded == pcm,
            residentBytesBefore: memoryBefore.current,
            residentBytesAfter: memoryAfter.current,
            peakResidentBytes: max(memoryBefore.peak, memoryAfter.peak),
            memoryMeasurementAvailable: memoryBefore.available && memoryAfter.available,
            thermalStateBefore: thermalBefore,
            thermalStateAfter: thermalAfter,
            thermalMeasurementAvailable: Self.isKnownThermalState(thermalBefore)
                && Self.isKnownThermalState(thermalAfter),
            seriousOrCriticalThermalObserved: Self.isSeriousOrCritical(thermalBefore)
                || Self.isSeriousOrCritical(thermalAfter)
        )
    }

    private static func encode(pcm: Data, codec: SpikeCodec, outputURL: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw CodecSpikeError.canonicalFormatUnavailable
        }
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CodecSpikeError.canonicalFormatUnavailable
        }
        buffer.frameLength = frames
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw CodecSpikeError.decodedBytesUnavailable
        }
        pcm.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: pcm.count)

        let settings: [String: Any] = [
            AVFormatIDKey: codec.formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: bitsPerChannel,
        ]
        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.synchronize()
        try handle.close()
    }

    private static func decode(url: URL, expectedFrames: Int) throws -> Data {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw CodecSpikeError.decodedBytesUnavailable
        }
        try file.read(into: buffer)
        let actualFrames = Int(buffer.frameLength)
        guard actualFrames == expectedFrames else {
            throw CodecSpikeError.decodedFrameCount(expected: expectedFrames, actual: actualFrames)
        }
        guard let bytes = buffer.audioBufferList.pointee.mBuffers.mData else {
            throw CodecSpikeError.decodedBytesUnavailable
        }
        return Data(bytes: bytes, count: actualFrames * MemoryLayout<Int16>.size)
    }

    private static func aggregate(
        codec: SpikeCodec,
        trials: [CodecTrialEvidence],
        failures: [CodecSpikeFailure],
        maximumQueueDepth: Int,
        resourceObservation: CodecResourceObservation
    ) -> CodecAggregateEvidence {
        let sorted = trials.map(\.encodingMilliseconds).sorted()
        let p95Index = sorted.isEmpty ? 0 : min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95 = sorted.isEmpty ? .infinity : sorted[p95Index]
        let maximumIncremental = resourceObservation.peakResidentBytes
            > resourceObservation.baselineResidentBytes
            ? resourceObservation.peakResidentBytes - resourceObservation.baselineResidentBytes
            : 0
        let thermalFailure = trials.contains {
            $0.seriousOrCriticalThermalObserved
        } || resourceObservation.seriousOrCriticalThermalObserved
        let memoryMeasurementAvailable = resourceObservation.memoryMeasurementAvailable
            && trials.allSatisfy(\.memoryMeasurementAvailable)
        let thermalMeasurementAvailable = resourceObservation.thermalMeasurementAvailable
            && trials.allSatisfy(\.thermalMeasurementAvailable)

        return CodecAggregateEvidence(
            codec: codec,
            completedChunks: trials.count,
            failedChunks: failures.count,
            p95EncodingMilliseconds: p95,
            maximumEncodingMilliseconds: sorted.last ?? .infinity,
            maximumIncrementalResidentBytes: maximumIncremental,
            maximumQueueDepth: maximumQueueDepth,
            memoryMeasurementAvailable: memoryMeasurementAvailable,
            thermalMeasurementAvailable: thermalMeasurementAvailable,
            seriousOrCriticalThermalObserved: thermalFailure,
            totalEncodedBytes: trials.reduce(0) { $0 + $1.encodedBytes },
            bitExact: !trials.isEmpty && trials.allSatisfy(\.bitExact)
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static var memorySnapshot: (current: UInt64, peak: UInt64, available: Bool) {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, false) }
        return (UInt64(info.resident_size), UInt64(info.resident_size_max), true)
    }

    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulator \(simulated)"
        }
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static var isSimulatorBuild: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    @MainActor private static var userInterfaceIdiom: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "phone"
        case .pad: "pad"
        case .tv: "tv"
        case .carPlay: "carPlay"
        case .mac: "mac"
        case .vision: "vision"
        case .unspecified: "unspecified"
        @unknown default: "unknown"
        }
    }

    fileprivate static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    fileprivate static func isSeriousOrCritical(_ state: String) -> Bool {
        state == "serious" || state == "critical"
    }

    fileprivate static func isKnownThermalState(_ state: String) -> Bool {
        state == "nominal" || state == "fair" || isSeriousOrCritical(state)
    }
}

private struct CodecResourceObservation: Sendable {
    let baselineResidentBytes: UInt64
    let peakResidentBytes: UInt64
    let memoryMeasurementAvailable: Bool
    let thermalMeasurementAvailable: Bool
    let seriousOrCriticalThermalObserved: Bool
}

/// Observes the complete real-time run, including the 60-second intervals
/// between encoder work. Mach's resident high-water mark catches short-lived
/// allocation peaks; polling plus the thermal-change notification prevents a
/// serious state between chunk endpoints from being lost.
private final class CodecResourceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let baselineResidentBytes: UInt64
    private var peakResidentBytes: UInt64
    private var memoryMeasurementAvailable: Bool
    private var thermalMeasurementAvailable: Bool
    private var seriousOrCriticalThermalObserved: Bool
    private var timer: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    private var stopped = false

    init() {
        let memory = CodecSpikeRunner.memorySnapshot
        baselineResidentBytes = memory.current
        peakResidentBytes = max(memory.current, memory.peak)
        memoryMeasurementAvailable = memory.available
        let thermal = CodecSpikeRunner.thermalStateName(ProcessInfo.processInfo.thermalState)
        thermalMeasurementAvailable = CodecSpikeRunner.isKnownThermalState(thermal)
        seriousOrCriticalThermalObserved = CodecSpikeRunner.isSeriousOrCritical(
            thermal
        )
    }

    func start() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.sample()
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.harc.codec-spike-resource-observer", qos: .utility)
        )
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> CodecResourceObservation {
        sample()

        lock.lock()
        if !stopped {
            stopped = true
            timer?.cancel()
            timer = nil
            if let thermalObserver {
                NotificationCenter.default.removeObserver(thermalObserver)
                self.thermalObserver = nil
            }
        }
        let observation = CodecResourceObservation(
            baselineResidentBytes: baselineResidentBytes,
            peakResidentBytes: peakResidentBytes,
            memoryMeasurementAvailable: memoryMeasurementAvailable,
            thermalMeasurementAvailable: thermalMeasurementAvailable,
            seriousOrCriticalThermalObserved: seriousOrCriticalThermalObserved
        )
        lock.unlock()
        return observation
    }

    func cancel() {
        _ = stop()
    }

    private func sample() {
        let memory = CodecSpikeRunner.memorySnapshot
        let thermal = CodecSpikeRunner.thermalStateName(ProcessInfo.processInfo.thermalState)

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        peakResidentBytes = max(peakResidentBytes, max(memory.current, memory.peak))
        memoryMeasurementAvailable = memoryMeasurementAvailable && memory.available
        thermalMeasurementAvailable = thermalMeasurementAvailable
            && CodecSpikeRunner.isKnownThermalState(thermal)
        seriousOrCriticalThermalObserved = seriousOrCriticalThermalObserved
            || CodecSpikeRunner.isSeriousOrCritical(thermal)
        lock.unlock()
    }
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
