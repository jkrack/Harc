import Foundation
import AVFoundation

/// Decodes a 16 kHz mono Int16 WAV (Harc's recording format) into a
/// fixed-length array of normalized peak amplitudes for visualization.
///
/// Streams the file in chunks so multi-hour recordings don't load the
/// entire WAV into memory. Results are cached by `(absolute path, sample
/// count)`; the cache is a small LRU.
public enum AmplitudeEnvelopeLoader {

    /// Loads `url` and returns `samples`-length `[Float]` of normalized
    /// peak amplitudes. Each output value is `max(|s|)` over roughly
    /// `totalFrames / samples` consecutive frames of the WAV, normalized
    /// by the global max so quiet recordings still render visibly.
    public static func load(url: URL, samples: Int = 1024) async throws -> [Float] {
        let key = CacheKey(path: url.standardizedFileURL.path, samples: samples)
        if let cached = await cache.get(key) {
            return cached
        }
        let env = try await Task.detached(priority: .userInitiated) {
            try decodeEnvelope(url: url, samples: samples)
        }.value
        await cache.put(key, env)
        return env
    }

    // MARK: - Private

    internal struct CacheKey: Hashable, Sendable {
        let path: String
        let samples: Int
    }

    private static let cache = EnvelopeCache(capacity: 16)

    private static func decodeEnvelope(url: URL, samples outSamples: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, outSamples > 0 else { return [] }

        let framesPerBin = max(1, Int(totalFrames) / outSamples)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBin)) else {
            throw NSError(domain: "AmplitudeEnvelopeLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to allocate decode buffer."
            ])
        }

        var envelope = [Float](repeating: 0, count: outSamples)
        var globalMax: Float = 0

        for i in 0..<outSamples {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerBin))
            let read = Int(buffer.frameLength)
            if read == 0 { break }
            let peak = peakAmplitude(in: buffer, frameCount: read)
            envelope[i] = peak
            globalMax = max(globalMax, peak)
        }

        if globalMax > 0 {
            for i in envelope.indices { envelope[i] /= globalMax }
        }
        return envelope
    }

    private static func peakAmplitude(in buffer: AVAudioPCMBuffer, frameCount: Int) -> Float {
        if let floats = buffer.floatChannelData {
            let chan = floats[0]
            var peak: Float = 0
            for i in 0..<frameCount {
                let v = abs(chan[i])
                if v > peak { peak = v }
            }
            return peak
        }
        if let int16s = buffer.int16ChannelData {
            let chan = int16s[0]
            var peak: Int32 = 0
            for i in 0..<frameCount {
                let v = Int32(chan[i].magnitude)
                if v > peak { peak = v }
            }
            return Float(peak) / Float(Int16.max)
        }
        return 0
    }
}

// MARK: - LRU cache

private actor EnvelopeCache {
    private let capacity: Int
    private var entries: [AmplitudeEnvelopeLoader.CacheKey: [Float]] = [:]
    private var order: [AmplitudeEnvelopeLoader.CacheKey] = []

    init(capacity: Int) { self.capacity = capacity }

    func get(_ key: AmplitudeEnvelopeLoader.CacheKey) -> [Float]? {
        guard let value = entries[key] else { return nil }
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
            order.append(key)
        }
        return value
    }

    func put(_ key: AmplitudeEnvelopeLoader.CacheKey, _ value: [Float]) {
        if entries[key] != nil {
            entries[key] = value
            if let i = order.firstIndex(of: key) {
                order.remove(at: i)
                order.append(key)
            }
            return
        }
        entries[key] = value
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}
