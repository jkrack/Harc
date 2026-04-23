import Foundation
@preconcurrency import AVFoundation

/// Reads a finished recording's mono audio and produces one embedding per
/// diarized speaker, concatenating up to `maxTotalMs` of that speaker's
/// audio from their segments.
///
/// Kept as a free function rather than methods on `SpeakerEmbedder` so the
/// embedder protocol stays minimal and the I/O stays testable in isolation.
public enum SpeakerExtractor {

    /// Speaker segment as delivered by the diarizer. Mirrors the `speakers`
    /// field of a finished `SessionTranscript` — kept structurally identical
    /// so callers don't need a mapping step.
    public struct Segment: Sendable, Equatable {
        public let speaker: Int
        public let startMs: Int
        public let endMs: Int
        public init(speaker: Int, startMs: Int, endMs: Int) {
            self.speaker = speaker
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public enum ExtractError: Error, LocalizedError {
        case audioOpenFailed(String)
        case resampleNotSupported

        public var errorDescription: String? {
            switch self {
            case .audioOpenFailed(let s): return "Could not open audio for speaker extraction: \(s)."
            case .resampleNotSupported: return "Audio is not 16 kHz mono — speaker extraction expects Harc's recorded format."
            }
        }
    }

    /// Extract embeddings. Segments shorter than `minTotalMs` (summed per
    /// speaker) are skipped — the embedder's output is too noisy to be
    /// useful at that length.
    ///
    /// - Parameter wavURL: path to the final mixed WAV written by
    ///   `RecordingSession`. Must be 16 kHz mono Float32 (the format the
    ///   recorder produces — we don't do resampling here).
    /// - Parameter segments: diarized segments, typically from
    ///   `SessionTranscript.speakers`.
    /// - Parameter embedder: the embedder implementation. Until a real
    ///   ECAPA model is bundled, this is `StubSpeakerEmbedder` — see its
    ///   header for what that means.
    public static func extract(
        from wavURL: URL,
        segments: [Segment],
        embedder: SpeakerEmbedder,
        minTotalMs: Int = 1_000,
        maxTotalMs: Int = 60_000
    ) async throws -> [SpeakerEmbedding] {
        guard !segments.isEmpty else { return [] }

        let samples = try Self.loadMono16kFloat(at: wavURL)

        // Group segments by speaker. Preserve diarizer order.
        var bySpeaker: [Int: [Segment]] = [:]
        for seg in segments {
            bySpeaker[seg.speaker, default: []].append(seg)
        }

        let sampleRate = 16_000
        var out: [SpeakerEmbedding] = []
        out.reserveCapacity(bySpeaker.count)

        for (speakerIndex, segs) in bySpeaker.sorted(by: { $0.key < $1.key }) {
            let totalMs = segs.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            guard totalMs >= minTotalMs else { continue }

            // Concatenate up to `maxTotalMs` worth of audio from this speaker.
            var cat: [Float] = []
            cat.reserveCapacity(maxTotalMs * sampleRate / 1000)
            var gatheredMs = 0
            for seg in segs {
                let remainingMs = maxTotalMs - gatheredMs
                if remainingMs <= 0 { break }
                let wantMs = min(remainingMs, max(0, seg.endMs - seg.startMs))
                guard wantMs > 0 else { continue }
                let startSample = max(0, seg.startMs * sampleRate / 1000)
                let endSample = min(samples.count, (seg.startMs + wantMs) * sampleRate / 1000)
                if endSample > startSample {
                    cat.append(contentsOf: samples[startSample..<endSample])
                    gatheredMs += (endSample - startSample) * 1000 / sampleRate
                }
            }
            guard cat.count >= sampleRate else { continue }   // <1 s after sample alignment

            do {
                let vec = try embedder.embed(samples: cat)
                out.append(SpeakerEmbedding(
                    speakerIndex: speakerIndex,
                    vector: vec,
                    segmentCount: segs.count,
                    totalMs: totalMs
                ))
            } catch SpeakerEmbedderError.tooShort {
                continue
            }
        }
        return out
    }

    // MARK: - Audio I/O

    /// Read all frames of a 16 kHz mono Float32 WAV into a flat Float array.
    /// Throws if the format isn't what Harc writes — we don't resample here;
    /// resampling is the recorder's job.
    static func loadMono16kFloat(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ExtractError.audioOpenFailed(error.localizedDescription)
        }
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw ExtractError.resampleNotSupported
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ExtractError.audioOpenFailed("could not allocate PCM buffer (\(frameCount) frames)")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw ExtractError.audioOpenFailed(error.localizedDescription)
        }
        guard let ptr = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }
}
