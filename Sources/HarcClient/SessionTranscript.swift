import Foundation
import HarcCore

public struct ChunkResult: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    public var processingMs: Int

    public init(
        startMs: Int, endMs: Int,
        text: String, words: [Word], speakers: [SpeakerSegment],
        processingMs: Int
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
        self.speakers = speakers
        self.processingMs = processingMs
    }
}

/// One interval whose derived transcript quality is not equivalent to a
/// successful transcription of the saved master audio.
///
/// Times are relative to the beginning of `SessionTranscript.audioPath`.
/// `reasonCode` is a stable, privacy-safe protocol identifier; detailed daemon
/// errors stay in local diagnostics and never become signed cross-device data.
public struct TranscriptCoverageIssue: Codable, Equatable, Hashable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let reasonCode: String

    public init(startMs: Int, endMs: Int, reasonCode: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.reasonCode = reasonCode
    }
}

/// Explicit evidence about the completeness of a locally produced transcript.
///
/// `nil` on `SessionTranscript` means unknown legacy provenance and must never
/// be interpreted as complete. An explicit value with both arrays empty proves
/// that the producing pipeline observed no degraded or failed audio intervals.
public struct TranscriptProcessingCoverage: Codable, Equatable, Hashable, Sendable {
    public let degradedRanges: [TranscriptCoverageIssue]
    public let failedRanges: [TranscriptCoverageIssue]

    public init(
        degradedRanges: [TranscriptCoverageIssue] = [],
        failedRanges: [TranscriptCoverageIssue] = []
    ) {
        self.degradedRanges = degradedRanges
        self.failedRanges = failedRanges
    }

    public static let complete = TranscriptProcessingCoverage()
}

public struct SessionTranscript: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var audioPath: String
    public var joinedText: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    public var chunks: [ChunkResult]
    /// Set when the user has manually edited `joinedText` in the editor.
    /// Signals downstream tools that word timings are approximate.
    public var manualEditAt: Date?
    /// Explicit processing coverage for signed Client artifacts. Missing on
    /// legacy JSON and therefore intentionally not treated as complete.
    public var processingCoverage: TranscriptProcessingCoverage?

    public init(
        startedAt: Date, endedAt: Date, audioPath: String,
        joinedText: String, words: [Word], speakers: [SpeakerSegment],
        chunks: [ChunkResult],
        manualEditAt: Date? = nil
    ) {
        self.init(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioPath,
            joinedText: joinedText,
            words: words,
            speakers: speakers,
            chunks: chunks,
            manualEditAt: manualEditAt,
            processingCoverage: nil
        )
    }

    /// Creates a transcript with explicit processing-completeness evidence.
    ///
    /// The original initializer remains source and binary compatible and leaves
    /// provenance unknown. Producers that can prove completeness use this form;
    /// legacy JSON also decodes the property as `nil`.
    public init(
        startedAt: Date, endedAt: Date, audioPath: String,
        joinedText: String, words: [Word], speakers: [SpeakerSegment],
        chunks: [ChunkResult],
        manualEditAt: Date? = nil,
        processingCoverage: TranscriptProcessingCoverage?
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioPath = audioPath
        self.joinedText = joinedText
        self.words = words
        self.speakers = speakers
        self.chunks = chunks
        self.manualEditAt = manualEditAt
        self.processingCoverage = processingCoverage
    }
}

public struct TranscriptUpdate: Sendable {
    public let chunkIndex: Int
    public let joinedTextSoFar: String
}
