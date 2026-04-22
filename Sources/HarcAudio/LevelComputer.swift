import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Per-session display-level pipeline.
///
/// Single-threaded — only called from `RecordingSession.processPair`. Holds:
///
/// - a rolling 256-sample window of the **weighted** time-domain signal
///   (mic 0.7 + system 0.3) for FFT analysis
/// - an envelope follower on the weighted RMS in dBFS (20 ms attack,
///   200 ms release), clamped to [-60, 0]
/// - a `SpectrumAnalyzer` that produces 5 normalized band magnitudes
///
/// The smoothed dB value is the same signal the silence-detection trigger
/// consumes, so the bars the user sees and the countdown the system runs are
/// driven from one source of truth.
final class LevelComputer {
    /// Mic weight in the display mix. Mic ~0.7 means quiet mic plus loud system
    /// audio still registers, but the user's voice dominates the bars.
    static let micWeight: Float = 0.7
    static let systemWeight: Float = 0.3

    /// Standard VU-meter envelope — spikes rise in ~20 ms, silence decays
    /// in ~200 ms so the bars don't snap to zero on a single quiet buffer.
    static let attackTau: Double = 0.020
    static let releaseTau: Double = 0.200

    /// Envelope operates on dB values clamped to this range.
    static let dbFloor: Float = -60
    static let dbCeiling: Float = 0

    private let analyzer = SpectrumAnalyzer()
    private var rollingWindow: [Float] = []
    private var envelopeDb: Float = LevelComputer.dbFloor
    private var lastTickAt: Date?

    func compute(
        micMono: AVAudioPCMBuffer,
        systemMono: AVAudioPCMBuffer?,
        micDb: Float,
        systemDb: Float
    ) -> AudioLevels {
        // ─── 1 · build weighted time-domain signal ─────────────────────────
        let micFrames = Int(micMono.frameLength)
        let sysFrames = systemMono.map { Int($0.frameLength) } ?? 0
        let n = max(micFrames, sysFrames)

        guard n > 0, let micData = micMono.floatChannelData?[0] else {
            return AudioLevels(
                micDb: micDb,
                systemDb: systemDb,
                smoothedDb: envelopeDb,
                fftBins: [0, 0, 0, 0, 0]
            )
        }
        let sysData = systemMono?.floatChannelData?[0]

        var weighted = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let m = i < micFrames ? micData[i] : 0
            let s = (i < sysFrames ? (sysData?[i] ?? 0) : 0)
            weighted[i] = Self.micWeight * m + Self.systemWeight * s
        }

        // ─── 2 · RMS → dB of the weighted signal ───────────────────────────
        var sumSq: Float = 0
        for x in weighted { sumSq += x * x }
        let rms = sqrtf(sumSq / Float(n))
        let rawDb = rms > 0 ? 20 * log10f(rms) : Self.dbFloor
        let clampedDb = max(Self.dbFloor, min(Self.dbCeiling, rawDb))

        // ─── 3 · attack/release envelope smoothing on the dB value ─────────
        let now = Date()
        let dt: Double
        if let last = lastTickAt {
            dt = max(0.001, now.timeIntervalSince(last))
        } else {
            dt = 0.020
        }
        lastTickAt = now
        let tau = clampedDb > envelopeDb ? Self.attackTau : Self.releaseTau
        let alpha = Float(1 - exp(-dt / tau))
        envelopeDb += alpha * (clampedDb - envelopeDb)

        // ─── 4 · roll & FFT ────────────────────────────────────────────────
        rollingWindow.append(contentsOf: weighted)
        let fftSize = SpectrumAnalyzer.fftSize
        if rollingWindow.count > fftSize {
            rollingWindow.removeFirst(rollingWindow.count - fftSize)
        }
        let fftBins: [Float]
        if rollingWindow.count >= fftSize {
            fftBins = rollingWindow.withUnsafeBufferPointer { buf in
                analyzer.analyze(buf.baseAddress!, count: buf.count)
            }
        } else {
            fftBins = [0, 0, 0, 0, 0]
        }

        return AudioLevels(
            micDb: micDb,
            systemDb: systemDb,
            smoothedDb: envelopeDb,
            fftBins: fftBins
        )
    }
}
