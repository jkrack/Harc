import Foundation
import Accelerate

/// Placeholder speaker embedder — **NOT a real voice-fingerprint model.**
///
/// This exists because the intended production embedder (a bundled ECAPA-TDNN
/// Core ML model, ~20 MB) isn't yet included in the repo. Until that model
/// lands, the re-ID pipeline wires up against this stub so the storage,
/// service, and UI layers can be tested end-to-end.
///
/// What this stub does:
///
/// - Splits the input audio into non-overlapping 25 ms frames (400 samples
///   at 16 kHz).
/// - Computes 32 log-magnitude band energies per frame via a mel-ish filter
///   bank over a 512-pt FFT.
/// - Returns the mean + stddev of each band across frames (64 floats), tiled
///   to `embeddingDim`, then L2-normalized.
///
/// What that produces: a vector that clusters audio with **similar spectral
/// texture** — not reliably correlated with speaker identity. Two different
/// voices can map to very similar vectors; the same voice in two recordings
/// can map to very different vectors if the room / mic changed. **Do not
/// draw user-facing conclusions from this embedder's output.**
///
/// The re-ID feature's preference (`speakerReIDEnabled`) defaults to
/// `false` while this stub is the only implementation. When the real ECAPA
/// model lands, swap `SpeakerEmbedder` instances at the call site and flip
/// the default.
public final class StubSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {

    public let embeddingDim: Int

    /// 16 kHz Float32 input.
    public static let expectedSampleRate: Double = 16_000
    private static let frameSize: Int = 400          // 25 ms
    private static let frameStep: Int = 400          // non-overlapping
    private static let fftSize: Int = 512            // next power of two ≥ frameSize
    private static let log2FFTSize: vDSP_Length = 9  // log2(512)
    private static let bandCount: Int = 32
    private static let minSamples: Int = 1 * 16_000 // 1 s

    private let fftSetup: FFTSetup
    private let window: [Float]
    /// Mel-ish filterbank: each row is the weights for one band, summed
    /// across the FFT magnitude spectrum. Pre-computed in init.
    private let filterbank: [[Float]]

    public init(embeddingDim: Int = 192) {
        self.embeddingDim = embeddingDim
        guard let setup = vDSP_create_fftsetup(Self.log2FFTSize, FFTRadix(kFFTRadix2)) else {
            fatalError("StubSpeakerEmbedder: vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup

        var win = [Float](repeating: 0, count: Self.frameSize)
        vDSP_hann_window(&win, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
        self.window = win

        self.filterbank = StubSpeakerEmbedder.buildMelFilterbank(
            bands: Self.bandCount,
            fftBins: Self.fftSize / 2,
            sampleRate: Float(Self.expectedSampleRate)
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public API

    public func embed(samples: [Float]) throws -> [Float] {
        guard samples.count >= Self.minSamples else {
            throw SpeakerEmbedderError.tooShort(minSamples: Self.minSamples, got: samples.count)
        }

        let frames = Self.frameCount(forSamples: samples.count)
        if frames < 1 {
            throw SpeakerEmbedderError.tooShort(minSamples: Self.frameSize, got: samples.count)
        }

        // For each frame: windowed FFT → log band energies (32 floats).
        var bandMatrix = [[Float]](repeating: [Float](repeating: 0, count: Self.bandCount),
                                   count: frames)
        var framePadded = [Float](repeating: 0, count: Self.fftSize)
        var realp = [Float](repeating: 0, count: Self.fftSize / 2)
        var imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)

        for f in 0..<frames {
            let start = f * Self.frameStep
            let take = min(Self.frameSize, samples.count - start)
            for i in 0..<take {
                framePadded[i] = samples[start + i] * window[i]
            }
            for i in take..<Self.fftSize {
                framePadded[i] = 0
            }

            framePadded.withUnsafeBufferPointer { paddedPtr in
                paddedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                        capacity: Self.fftSize / 2) { complexIn in
                    realp.withUnsafeMutableBufferPointer { rp in
                        imagp.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(
                                realp: rp.baseAddress!,
                                imagp: ip.baseAddress!
                            )
                            vDSP_ctoz(complexIn, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                            vDSP_fft_zrip(fftSetup, &split, 1, Self.log2FFTSize,
                                          FFTDirection(kFFTDirection_Forward))
                            vDSP_zvmags(&split, 1, &magnitudes, 1,
                                        vDSP_Length(Self.fftSize / 2))
                        }
                    }
                }
            }

            // Apply filterbank and log.
            for b in 0..<Self.bandCount {
                var acc: Float = 0
                let weights = filterbank[b]
                for k in 0..<magnitudes.count {
                    acc += weights[k] * magnitudes[k]
                }
                bandMatrix[f][b] = log10f(acc + 1e-6)   // log-mel-ish
            }
        }

        // mean + stddev per band → 64 floats
        var mean = [Float](repeating: 0, count: Self.bandCount)
        var stddev = [Float](repeating: 0, count: Self.bandCount)
        let fCount = Float(frames)
        for b in 0..<Self.bandCount {
            var s: Float = 0
            for f in 0..<frames { s += bandMatrix[f][b] }
            mean[b] = s / fCount
        }
        for b in 0..<Self.bandCount {
            var s2: Float = 0
            for f in 0..<frames {
                let d = bandMatrix[f][b] - mean[b]
                s2 += d * d
            }
            stddev[b] = sqrtf(s2 / fCount)
        }

        // Tile mean+std up to embeddingDim, then L2-normalize.
        var vec = [Float](repeating: 0, count: embeddingDim)
        let source = mean + stddev   // 64 floats
        for i in 0..<embeddingDim {
            vec[i] = source[i % source.count]
        }
        l2Normalize(&vec)
        return vec
    }

    // MARK: - Static helpers

    public static func frameCount(forSamples count: Int) -> Int {
        guard count >= frameSize else { return 0 }
        return 1 + (count - frameSize) / frameStep
    }

    private static func buildMelFilterbank(bands: Int, fftBins: Int, sampleRate: Float) -> [[Float]] {
        // Mel-ish triangular filterbank over [0, Nyquist]. Hand-rolled
        // because Accelerate doesn't expose a mel helper and pulling in
        // more dependencies for a stub isn't worth it.
        func hzToMel(_ f: Float) -> Float { 2595 * log10f(1 + f / 700) }
        func melToHz(_ m: Float) -> Float { 700 * (powf(10, m / 2595) - 1) }

        let nyquist = sampleRate / 2
        let melMin = hzToMel(0)
        let melMax = hzToMel(nyquist)
        var points = [Float](repeating: 0, count: bands + 2)
        for i in 0...(bands + 1) {
            let m = melMin + (melMax - melMin) * Float(i) / Float(bands + 1)
            points[i] = melToHz(m)
        }
        let hzPerBin = nyquist / Float(fftBins)

        var fb = [[Float]](repeating: [Float](repeating: 0, count: fftBins), count: bands)
        for b in 0..<bands {
            let lo = points[b]
            let mid = points[b + 1]
            let hi = points[b + 2]
            for k in 0..<fftBins {
                let freq = Float(k) * hzPerBin
                if freq >= lo && freq < mid {
                    fb[b][k] = (freq - lo) / (mid - lo)
                } else if freq >= mid && freq <= hi {
                    fb[b][k] = (hi - freq) / (hi - mid)
                }
            }
        }
        return fb
    }
}
