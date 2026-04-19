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

    public init(
        startedAt: Date, endedAt: Date, audioPath: String,
        joinedText: String, words: [Word], speakers: [SpeakerSegment],
        chunks: [ChunkResult],
        manualEditAt: Date? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioPath = audioPath
        self.joinedText = joinedText
        self.words = words
        self.speakers = speakers
        self.chunks = chunks
        self.manualEditAt = manualEditAt
    }
}

public struct TranscriptUpdate: Sendable {
    public let chunkIndex: Int
    public let joinedTextSoFar: String
}
