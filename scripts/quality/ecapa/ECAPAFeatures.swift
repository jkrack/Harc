import Foundation
import Accelerate

/// Diagnostic SpeechBrain ECAPA filterbank. 16 kHz mono; 2–30 s bounded input.
struct ECAPAFeatures {
    enum Failure: Error { case invalidAudio }
    private let window: [Float]
    private let realBasis: [Float]
    private let imaginaryBasis: [Float]
    private let filters: [Float]
    init() {
        window = (0..<400).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / 400) }
        var real = [Float](), imaginary = [Float]()
        for bin in 0..<201 {
            for sample in 0..<400 {
                let phase = 2 * Double.pi * Double(bin * sample) / 400
                real.append(Float(cos(phase))); imaginary.append(Float(-sin(phase)))
            }
        }
        realBasis = real; imaginaryBasis = imaginary
        let maximumMel = Float(2595 * log10(1 + 8000.0 / 700))
        let hz: [Float] = (0..<82).map { i in
            let mel = Float(i) * (maximumMel / 81)
            return 700 * (pow(10, mel / 2595) - 1)
        }
        var weights = [Float]()
        for mel in 0..<80 {
            let center = hz[mel + 1], bandwidth = hz[mel + 1] - hz[mel]
            for bin in 0..<201 {
                let slope = (Float(bin * 40) - center) / bandwidth
                weights.append(max(0, min(slope + 1, 1 - slope)))
            }
        }
        filters = weights
    }
    func extract(_ samples: [Float]) throws -> [Float] {
        guard (32000...480000).contains(samples.count), samples.allSatisfy(\.isFinite) else { throw Failure.invalidAudio }
        let frames = samples.count / 160 + 1
        var output = [Float](); output.reserveCapacity(frames * 80)
        var frame = [Float](repeating: 0, count: 400)
        var real = [Float](repeating: 0, count: 201), imaginary = real, power = real
        var mel = [Float](repeating: 0, count: 80)
        for index in 0..<frames {
            if index % 32 == 0 { try Task.checkCancellation() }
            let lower = index * 160 - 200
            for n in 0..<400 {
                let i = lower + n
                frame[n] = (i >= 0 && i < samples.count ? samples[i] : 0) * window[n]
            }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, 201, 400, 1, realBasis, 400, frame, 1, 0, &real, 1)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, 201, 400, 1, imaginaryBasis, 400, frame, 1, 0, &imaginary, 1)
            for bin in 0..<201 { power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, 80, 201, 1, filters, 201, power, 1, 0, &mel, 1)
            output.append(contentsOf: mel.map { 10 * log10(max($0, 1e-10)) })
        }
        let floor = (output.max() ?? -100) - 80
        return output.map { max($0, floor) }
    }
}
