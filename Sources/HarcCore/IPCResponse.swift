import Foundation

public enum IPCResponse: Codable, Equatable {
    case result(TranscribeResult)
    case status(DaemonStatus)
    case error(IPCError)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable { case result, status, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .result:
            self = .result(try c.decode(TranscribeResult.self, forKey: .payload))
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
    public var processingMs: Int

    public init(text: String, words: [Word], speakers: [SpeakerSegment], processingMs: Int) {
        self.text = text
        self.words = words
        self.speakers = speakers
        self.processingMs = processingMs
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
    public var version: String
    public var modelLoaded: Bool
    public var uptimeSeconds: Int
    public init(version: String, modelLoaded: Bool, uptimeSeconds: Int) {
        self.version = version
        self.modelLoaded = modelLoaded
        self.uptimeSeconds = uptimeSeconds
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
