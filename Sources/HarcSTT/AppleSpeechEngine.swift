import AVFoundation
import CoreMedia
import Foundation
import HarcCore
import Speech

/// No SFSpeechRecognizer/server route, HTTP client, or automatic alternative
/// backend. AssetInventory may download Apple's model assets, never audio.
/// Each request owns fresh analysis state and consumes final results only.
enum AppleSpeechEngine {
    static let locale = Locale(identifier: "en-US")

    static func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func assetsInstalled() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await AssetInventory.status(forModules: [makeModule()]) == .installed
    }

    static func prepare(progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw DaemonError.transcriptionFailed("Apple on-device speech is unavailable on this Mac")
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw DaemonError.transcriptionFailed("Apple on-device English speech is not supported")
        }
        let module = makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            await progress(0)
            let reporter = Task {
                while !Task.isCancelled {
                    await progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw DaemonError.transcriptionFailed("Apple speech assets are not installed; reconnect to download the on-device model")
        }
    }

    static func transcribe(audioPath: String) async throws -> TranscribeResult {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath)) }
        catch { throw DaemonError.audioLoadFailed("Could not open audio for Apple speech") }
        guard file.processingFormat.sampleRate > 0 else {
            throw DaemonError.audioLoadFailed("Invalid audio sample rate")
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard file.length > 0 else {
            return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
        }
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            let results = Task {
                var transcript = AttributedString()
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    appendFinal(result.text, to: &transcript)
                }
                return (String(transcript.characters), try timedWords(from: transcript, durationSeconds: duration))
            }
            do {
                // The file API converts to a compatible format while retaining
                // the original file timeline. It owns bounded streaming reads.
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                try Task.checkCancellation()
                let (text, words) = try await results.value
                try Task.checkCancellation()
                let elapsed = start.duration(to: .now).components
                return TranscribeResult(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    words: words, speakers: [],
                    processingMs: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
                )
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                _ = await results.result
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let error = error as? DaemonError { throw error }
                // Framework error descriptions can include the input path.
                throw DaemonError.transcriptionFailed("Apple on-device speech failed; audio is retained for retry")
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Final results are independent text segments. Preserve existing spacing,
    /// including untimed trailing whitespace, across segments. If a new lexical
    /// segment omits a separator, insert only textual whitespace (never audio).
    static func appendFinal(_ part: AttributedString, to text: inout AttributedString) {
        if let previous = text.characters.last, let next = part.characters.first,
           !previous.isWhitespace, !next.isWhitespace,
           next.isLetter || next.isNumber {
            text += AttributedString(" ")
        }
        text += part
    }

    /// Preserve audio-time attributes, including subword continuations, for
    /// Harc's existing Word.displayWords and speaker-midpoint alignment.
    /// Missing/invalid lexical timings fail the chunk, not silently lose words.
    static func timedWords(from text: AttributedString, durationSeconds: Double) throws -> [Word] {
        var words: [Word] = []
        var whitespace = ""
        for run in text.runs {
            let fragment = String(text[run.range].characters)
            if fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                whitespace += fragment
                continue
            }
            let token = whitespace + fragment
            whitespace = ""
            guard let range = run.audioTimeRange else {
                throw DaemonError.transcriptionFailed("Apple speech returned text without audio timing")
            }
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, durationSeconds.isFinite,
                  start >= 0, start <= durationSeconds, end >= start, end <= durationSeconds + 0.1 else {
                throw DaemonError.transcriptionFailed("Apple speech returned invalid audio timing")
            }
            words.append(Word(text: token, startMs: Int((start * 1000).rounded()), endMs: Int((min(end, durationSeconds) * 1000).rounded())))
        }
        return words
    }
}
