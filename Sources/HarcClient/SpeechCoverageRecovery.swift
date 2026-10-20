import Foundation
import AVFoundation
import HarcCore

/// Bounded post-diarization retry of detected speech with no lexical word overlap.
/// Detection is conservative evidence of missing text, not proof of ASR accuracy.
enum SpeechCoverageRecovery {
    struct Result {
        let transcript: SessionTranscript
        let failedRanges: [FailedChunkRange]
    }

    static func recover(_ input: SessionTranscript, client: any TranscribingClient,
                        maximumRequests: Int = 8) async -> Result {
        let lexical = input.words.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
        let priorFailures = input.processingCoverage?.failedRanges ?? []
        var spans: [(start: Int, end: Int)] = []
        for segment in input.speakers.sorted(by: { $0.startMs < $1.startMs }) {
            guard segment.startMs >= 0, segment.endMs > segment.startMs,
                  !lexical.contains(where: { $0.startMs < segment.endMs && $0.endMs > segment.startMs }),
                  !priorFailures.contains(where: { $0.startMs < segment.endMs && $0.endMs > segment.startMs }) else { continue }
            if let last = spans.last, segment.startMs <= last.end {
                spans[spans.count - 1].end = max(last.end, segment.endMs)
            } else { spans.append((segment.startMs, segment.endMs)) }
        }
        guard !spans.isEmpty else { return Result(transcript: input, failedRanges: []) }
        let notices = UntranscribedAudioMarker.parse(in: input.joinedText)
        var originalText = input.joinedText
        for notice in notices { originalText = originalText.replacingOccurrences(of: notice.text, with: "") }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func tokenText(_ words: [Word]) -> String {
            words.map(\.text).joined(separator: words.contains { $0.text.first?.isWhitespace == true } ? "" : " ")
        }
        let canMerge = normalized(originalText) == normalized(tokenText(input.words)) && input.manualEditAt == nil
        func normalizedTokens(_ words: [Word]) -> [Word] {
            let pieces = words.contains { $0.text.first?.isWhitespace == true }
            return words.enumerated().map { index, word in
                let prefix = (!pieces || index == 0) && word.text.first?.isWhitespace != true ? " " : ""
                return Word(text: prefix + word.text, startMs: word.startMs, endMs: word.endMs, speakerAttribution: word.speakerAttribution)
            }
        }
        var added: [Word] = []
        var failures: [FailedChunkRange] = []
        var requests = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        for span in spans {
            var cursor = span.start
            while cursor < span.end {
                let end = cursor + min(8_000, span.end - cursor)
                let start = cursor
                cursor = end
                guard canMerge, !Task.isCancelled, requests < maximumRequests,
                      ContinuousClock.now < deadline else {
                    // Keep one marker for the unattempted remainder, not an unbounded plan.
                    failures.append(.init(startMs: start, endMs: span.end, reason: "Detected speech has no timed text; recovery was not completed"))
                    break
                }
                requests += 1
                do {
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: input.audioPath),
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    let rate = file.processingFormat.sampleRate
                    let duration = Double(file.length) * 1000 / rate
                    guard rate.isFinite, rate > 0, duration.isFinite, Double(start) < duration,
                          Double(end) <= duration + 1 else { throw ClientError.chunkerFailed("Speech interval exceeds saved audio") }
                    let lowerMs = max(0, start - 200)
                    let upperMs = min(duration, Double(end) + 200)
                    let first = AVAudioFramePosition(Double(lowerMs) * rate / 1000)
                    let last = min(file.length, AVAudioFramePosition(upperMs * rate / 1000))
                    // Bound both the destination and scratch PCM allocations together.
                    let frames = last - first
                    let channels = Int(file.processingFormat.channelCount)
                    guard frames > 0, frames <= Int64(UInt32.max), channels > 0,
                          Double(frames) * Double(channels) * 8 <= 32 * 1024 * 1024,
                          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                            frameCapacity: AVAudioFrameCount(last - first)) else { throw ClientError.chunkerFailed("Invalid recovery excerpt") }
                    file.framePosition = first
                    // AVAudioFile may return a short read before EOF (including float WAVs).
                    // Accumulate those native frames instead of mistaking one read for EOF.
                    guard let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                            frameCapacity: AVAudioFrameCount(frames)),
                          let destination = buffer.floatChannelData,
                          let source = scratch.floatChannelData else {
                        throw ClientError.chunkerFailed("Invalid recovery PCM format")
                    }
                    var copied: AVAudioFrameCount = 0
                    while copied < AVAudioFrameCount(frames) {
                        try Task.checkCancellation()
                        try file.read(into: scratch, frameCount: AVAudioFrameCount(frames) - copied)
                        guard scratch.frameLength > 0 else { throw ClientError.chunkerFailed("Recovery excerpt underread") }
                        for channel in 0..<channels {
                            destination[channel].advanced(by: Int(copied)).update(from: source[channel], count: Int(scratch.frameLength))
                        }
                        copied += scratch.frameLength
                    }
                    buffer.frameLength = copied
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("harc-speech-retry-\(UUID()).wav")
                    defer { try? FileManager.default.removeItem(at: url) }
                    do {
                        let output = try AVAudioFile(forWriting: url, settings: file.fileFormat.settings)
                        try output.write(from: buffer)
                    }
                    try Task.checkCancellation()
                    // Each production IPC request has its own kernel-enforced deadline.
                    let result = try await client.transcribe(audioPath: url.path, diarize: false, vad: false)
                    try Task.checkCancellation()
                    // Assess complete words, not individual SentencePiece fragments:
                    // a narrow span may contain only a punctuation token even
                    // though its reconstructed lexical word covers that span.
                    let recovered = Word.displayWords(from: result.words).compactMap { word -> Word? in
                        guard word.startMs >= 0, word.endMs > word.startMs,
                              Double(word.endMs) <= upperMs - Double(lowerMs) + 1 else { return nil }
                        let lo = word.startMs + lowerMs, hi = word.endMs + lowerMs
                        // A complete word can straddle a diarization boundary.
                        // Require actual interval support, and never duplicate
                        // neighboring words already present in the transcript.
                        guard lo < end, hi > start,
                              !lexical.contains(where: { $0.startMs < hi && $0.endMs > lo }),
                              !added.contains(where: { $0.startMs < hi && $0.endMs > lo }) else { return nil }
                        return Word(text: word.text, startMs: lo, endMs: hi)
                    }
                    guard recovered.contains(where: { $0.text.contains { $0.isLetter || $0.isNumber } }) else {
                        throw ClientError.chunkerFailed("Detected speech still has no timed text")
                    }
                    added.append(contentsOf: normalizedTokens(recovered))
                } catch {
                    failures.append(.init(startMs: start, endMs: end, reason: "Detected speech could not be recovered"))
                }
            }
        }
        var output = input
        if !added.isEmpty {
            output.words = (normalizedTokens(input.words) + added).sorted { $0.startMs < $1.startMs }
        }
        if canMerge {
            var events = output.words.map { ($0.startMs, $0.text) }
            if added.isEmpty { events = normalizedTokens(input.words).map { ($0.startMs, $0.text) } }
            events += notices.map { ($0.startMs, " " + $0.text + " ") }
            events += failures.map { ($0.startMs, " " + $0.markerText + " ") }
            output.joinedText = events.sorted { $0.0 < $1.0 }.map(\.1).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            output.joinedText += failures.map { "\n\n" + $0.markerText }.joined()
        }
        output.processingCoverage = .init(degradedRanges: input.processingCoverage?.degradedRanges ?? [],
            failedRanges: priorFailures + failures.map {
                .init(startMs: $0.startMs, endMs: $0.endMs, reasonCode: "stt.speech_without_text")
            })
        // Original chunks retain the original decoder passes; final words/text include repairs.
        return Result(transcript: output, failedRanges: failures)
    }
}
