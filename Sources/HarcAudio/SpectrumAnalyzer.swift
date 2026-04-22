import Foundation
import Accelerate

/// 5-band FFT analyzer sized for the menu-bar icon.
///
/// Consumes a mono Float32 time-domain signal at `AudioMixer.targetSampleRate`
/// (16 kHz) and returns 5 normalized band magnitudes in `[0, 1]` covering
/// logarithmic speech-ish bands from ~60 Hz to 8 kHz — bass, low-mid, mid,
/// high-mid, and sibilance.
///
/// Not Sendable; construct one per pipeline and touch it from a single thread.
public final class SpectrumAnalyzer {
    /// Power-of-two FFT length. 256 samples at 16 kHz = 16 ms — matches the
    /// ~60 Hz redraw budget the menu bar works with.
    public static let fftSize: Int = 256

    /// Band boundaries in FFT bin indices. `fftSize/2` = 128 bins span 0..8 kHz;
    /// each bin is `sampleRate / fftSize` = 62.5 Hz wide. Skipping bin 0 (DC).
    ///
    /// - `[1, 4)`   → 62.5 – 250 Hz   (low voice / bass)
    /// - `[4, 8)`   → 250 – 500 Hz    (chest voice)
    /// - `[8, 24)`  → 500 – 1.5 kHz   (mid)
    /// - `[24, 64)` → 1.5 – 4 kHz     (presence / consonants)
    /// - `[64, 128)`→ 4 – 8 kHz       (sibilance / highs)
    private static let bandEdges: [Int] = [1, 4, 8, 24, 64, 128]
    public static let bandCount: Int = bandEdges.count - 1

    private let fftSetup: FFTSetup
    private let log2N: vDSP_Length
    private var window: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    public init() {
        let log2N = vDSP_Length(log2(Float(Self.fftSize)))
        self.log2N = log2N
        guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            fatalError("SpectrumAnalyzer: vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup

        var win = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&win, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = win

        self.realp = [Float](repeating: 0, count: Self.fftSize / 2)
        self.imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Analyze `count` time-domain samples and return 5 band levels in `[0, 1]`.
    /// Fewer than `fftSize` samples → zero-padded; more → only the trailing
    /// `fftSize` samples are analyzed.
    public func analyze(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        let n = Self.fftSize
        var padded = [Float](repeating: 0, count: n)
        let srcStart = max(0, count - n)
        let copyCount = count - srcStart
        if copyCount > 0 {
            padded.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress!, samples.advanced(by: srcStart),
                           copyCount * MemoryLayout<Float>.size)
            }
        }

        // Apply Hanning window in place.
        vDSP_vmul(padded, 1, window, 1, &padded, 1, vDSP_Length(n))

        // Pack N real samples into N/2 split-complex pairs, then run in-place
        // real FFT. After `vDSP_fft_zrip`, entry 0 contains DC in realp[0] and
        // the Nyquist component in imagp[0] (packed); entries 1..N/2-1 are the
        // positive-frequency bins.
        padded.withUnsafeBufferPointer { paddedPtr in
            paddedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexIn in
                realp.withUnsafeMutableBufferPointer { rpBuf in
                    imagp.withUnsafeMutableBufferPointer { ipBuf in
                        var split = DSPSplitComplex(realp: rpBuf.baseAddress!, imagp: ipBuf.baseAddress!)
                        vDSP_ctoz(complexIn, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2N,
                                      FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        // FFT scaling: `vDSP_fft_zrip` leaves amplitude at `N/2` × original.
        // After `zvmags`, the squared magnitudes are `(N/2)²` × original power,
        // and windowing attenuates the signal further (Hanning coherent gain
        // ~0.5). A full-scale sinusoid at a bin centre yields squared magnitude
        // ≈ `N² / 16`. Divide by that to land a loud tone near 1.0 before log.
        let reference = Float(Self.fftSize * Self.fftSize) / 16.0

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let startBin = Self.bandEdges[b]
            let endBin = Self.bandEdges[b + 1]
            // Max within the band reads sharper than average on voice transients.
            var maxMag: Float = 0
            for k in startBin..<endBin {
                if magnitudes[k] > maxMag { maxMag = magnitudes[k] }
            }
            let scaled = maxMag / reference
            let db = scaled > 1e-6 ? 10 * log10f(scaled) : -60
            let normalized = max(0, min(1, (db + 60) / 60))
            bands[b] = normalized
        }
        return bands
    }
}
