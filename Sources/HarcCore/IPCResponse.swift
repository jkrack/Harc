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

public struct TranscribeResult: Codable, Equatable, Sendable {
    public var text: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    /// Full-recording speaker centroids when the daemon performed
    /// diarization as part of this request. Older daemons omit this field.
    public var speakerEmbeddings: [SpeakerEmbeddingRow]
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
        self.processingMs = processingMs
    }

    private enum CodingKeys: String, CodingKey {
        case text, words, speakers, speakerEmbeddings, processingMs
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
        processingMs = try container.decode(Int.self, forKey: .processingMs)
    }
}

public struct DiarizeResult: Codable, Equatable, Sendable {
    public var segments: [SpeakerSegment]
    public var speakers: [SpeakerEmbeddingRow]
    public var processingMs: Int

    public init(
        segments: [SpeakerSegment],
        speakers: [SpeakerEmbeddingRow],
        processingMs: Int
    ) {
        self.segments = segments
        self.speakers = speakers
        self.processingMs = processingMs
    }
}

public struct SpeakerEmbeddingRow: Codable, Equatable, Sendable {
    public var speakerIndex: Int
    public var vector: [Float]
    public var totalMs: Int
    public var segmentCount: Int

    public init(
        speakerIndex: Int,
        vector: [Float],
        totalMs: Int,
        segmentCount: Int
    ) {
        self.speakerIndex = speakerIndex
        self.vector = vector
        self.totalMs = totalMs
        self.segmentCount = segmentCount
    }
}

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
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
