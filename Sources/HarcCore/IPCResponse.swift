import Foundation

public enum IPCResponse: Codable, Equatable, Sendable {
    case result(TranscribeResult)
    case diarization(DiarizeResult)
    case status(DaemonStatus)
    case error(IPCError)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable { case result, diarization, status, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .result:
            self = .result(try c.decode(TranscribeResult.self, forKey: .payload))
        case .diarization:
            self = .diarization(try c.decode(DiarizeResult.self, forKey: .payload))
        case .status:
            self = .status(try c.decode(DaemonStatus.self, forKey: .payload))
        case .error:
            self = .error(try c.decode(IPCError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let r):
            try c.encode(Kind.result, forKey: .type)
            try c.encode(r, forKey: .payload)
        case .diarization(let d):
            try c.encode(Kind.diarization, forKey: .type)
            try c.encode(d, forKey: .payload)
        case .status(let s):
            try c.encode(Kind.status, forKey: .type)
            try c.encode(s, forKey: .payload)
        case .error(let e):
            try c.encode(Kind.error, forKey: .type)
            try c.encode(e, forKey: .payload)
        }
    }
}

/// Detected concurrent speech, independent of successful speaker identification.
/// Missing overlap arrays mean unassessed legacy output; an empty array means
/// the producing diarizer detected none. Times are relative to the saved audio.
public struct SpeechOverlapRange: Codable, Equatable, Hashable, Sendable {
    public let startMs: Int
    public let endMs: Int

    public init(startMs: Int, endMs: Int) throws {
        guard startMs >= 0, endMs > startMs else { throw CocoaError(.coderInvalidValue) }
        self.startMs = startMs
        self.endMs = endMs
    }

    private enum CodingKeys: String, CodingKey { case startMs, endMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startMs: c.decode(Int.self, forKey: .startMs),
                      endMs: c.decode(Int.self, forKey: .endMs))
    }
}

public struct TranscribeResult: Codable, Equatable, Sendable {
    public var text: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    /// Full-recording speaker centroids when the daemon performed
    /// diarization as part of this request. Older daemons omit this field.
    public var speakerEmbeddings: [SpeakerEmbeddingRow]
    public var overlapRanges: [SpeechOverlapRange]?
    public var processingMs: Int

    public init(
        text: String,
        words: [Word],
        speakers: [SpeakerSegment],
        speakerEmbeddings: [SpeakerEmbeddingRow] = [],
        processingMs: Int
    ) {
        self.text = text
        self.words = words
        self.speakers = speakers
        self.speakerEmbeddings = speakerEmbeddings
        self.overlapRanges = nil
        self.processingMs = processingMs
    }

    private enum CodingKeys: String, CodingKey {
        case text, words, speakers, speakerEmbeddings, processingMs, overlapRanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        words = try container.decode([Word].self, forKey: .words)
        speakers = try container.decode([SpeakerSegment].self, forKey: .speakers)
        speakerEmbeddings = try container.decodeIfPresent(
            [SpeakerEmbeddingRow].self,
            forKey: .speakerEmbeddings
        ) ?? []
        overlapRanges = try container.decodeIfPresent([SpeechOverlapRange].self, forKey: .overlapRanges)
        processingMs = try container.decode(Int.self, forKey: .processingMs)
    }
}

public struct DiarizeResult: Codable, Equatable, Sendable {
    public var segments: [SpeakerSegment]
    public var speakers: [SpeakerEmbeddingRow]
    public var processingMs: Int
    public var overlapRanges: [SpeechOverlapRange]?

    public init(
        segments: [SpeakerSegment],
        speakers: [SpeakerEmbeddingRow],
        processingMs: Int
    ) {
        self.segments = segments
        self.speakers = speakers
        self.processingMs = processingMs
        self.overlapRanges = nil
    }
}

public struct SpeakerEmbeddingRow: Codable, Equatable, Sendable {
    /// Legacy daemon payloads omitted model provenance and were exclusively WeSpeaker.
    public static let legacyModelID = "wespeaker_v2"
    public var speakerIndex: Int
    public var vector: [Float]
    public var totalMs: Int
    public var segmentCount: Int
    public let modelID: String

    public init(speakerIndex: Int, vector: [Float], totalMs: Int, segmentCount: Int) {
        self.init(speakerIndex: speakerIndex, vector: vector, totalMs: totalMs,
                  segmentCount: segmentCount, modelID: Self.legacyModelID)
    }

    public init(speakerIndex: Int, vector: [Float], totalMs: Int, segmentCount: Int, modelID: String) {
        self.speakerIndex = speakerIndex
        self.vector = vector
        self.totalMs = totalMs
        self.segmentCount = segmentCount
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case speakerIndex, vector, totalMs, segmentCount, modelID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speakerIndex = try values.decode(Int.self, forKey: .speakerIndex)
        vector = try values.decode([Float].self, forKey: .vector)
        totalMs = try values.decode(Int.self, forKey: .totalMs)
        segmentCount = try values.decode(Int.self, forKey: .segmentCount)
        // Explicit null/malformed provenance is not an old message.
        modelID = values.contains(.modelID)
            ? try values.decode(String.self, forKey: .modelID) : Self.legacyModelID
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .modelID, in: values,
                debugDescription: "Speaker model identity must not be empty")
        }
    }
}

/// An explicit word assignment in the selected local transcript projection.
/// An empty value means unresolved; an absent Word property means legacy timing attribution.
public struct WordSpeakerAttribution: Codable, Equatable, Sendable {
    public let speakerIndex: Int?
    public init() { speakerIndex = nil }
    public init(speakerIndex: Int) throws {
        guard speakerIndex >= 0 else { throw AttributionError.negativeSpeakerIndex }
        self.speakerIndex = speakerIndex
    }
    public enum AttributionError: Error { case negativeSpeakerIndex }
    private enum CodingKeys: String, CodingKey { case speakerIndex }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let index = try values.decodeIfPresent(Int.self, forKey: .speakerIndex) {
            try self.init(speakerIndex: index)
        } else { self.init() }
    }
}

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var speakerAttribution: WordSpeakerAttribution?
    public init(text: String, startMs: Int, endMs: Int, speakerAttribution: WordSpeakerAttribution? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speakerAttribution = speakerAttribution
    }
}

public extension Word {
    func resolvedSpeakerIndex(in segments: [SpeakerSegment]) -> Int? {
        if let speakerAttribution { return speakerAttribution.speakerIndex }
        let midpoint = (startMs + endMs) / 2
        return segments.first { midpoint >= $0.startMs && midpoint < $0.endMs }?.speaker
    }

    /// Rejoin SentencePiece continuations before assigning speaker identities.
    /// A label boundary must never split a lexical word into separate text.
    static func displayWords(from words: [Word]) -> [Word] {
        let pieces = words.contains { $0.text.first?.isWhitespace == true }
        var result: [Word] = []
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if !pieces || word.text.first?.isWhitespace == true || result.isEmpty {
                result.append(Word(text: text, startMs: word.startMs, endMs: word.endMs, speakerAttribution: word.speakerAttribution))
            } else {
                if result[result.count - 1].speakerAttribution != word.speakerAttribution {
                    result[result.count - 1].speakerAttribution = WordSpeakerAttribution()
                }
                result[result.count - 1].text += text
                result[result.count - 1].endMs = word.endMs
            }
        }
        return result
    }
}

public struct SpeakerSegment: Codable, Equatable, Sendable {
    public var speaker: Int
    public var startMs: Int
    public var endMs: Int
    public init(speaker: Int, startMs: Int, endMs: Int) {
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    /// Coarse ASR model lifecycle, so the app can tell the user the truth
    /// about first-run downloads instead of hardcoding "ready".
    public enum ModelState: String, Codable, Sendable {
        case loading
        case downloading
        case ready
        case failed
    }

    public var version: String
    public var modelLoaded: Bool
    public var uptimeSeconds: Int
    /// Optional for wire compatibility with pre-0.5 daemons; `nil` means
    /// the daemon predates model-state reporting (treat as unknown).
    public var modelState: ModelState?
    /// Fraction complete in [0, 1] while `modelState == .downloading`.
    public var downloadProgress: Double?
    /// Human-readable load failure while `modelState == .failed`.
    public var errorMessage: String?

    public init(
        version: String,
        modelLoaded: Bool,
        uptimeSeconds: Int,
        modelState: ModelState? = nil,
        downloadProgress: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.version = version
        self.modelLoaded = modelLoaded
        self.uptimeSeconds = uptimeSeconds
        self.modelState = modelState
        self.downloadProgress = downloadProgress
        self.errorMessage = errorMessage
    }
}

public struct IPCError: Codable, Equatable, Error, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
