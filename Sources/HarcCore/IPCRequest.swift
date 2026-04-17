import Foundation

public enum IPCRequest: Codable, Equatable, Sendable {
    case transcribe(TranscribeRequest)
    case status
    case shutdown

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable { case transcribe, status, shutdown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .transcribe:
            self = .transcribe(try c.decode(TranscribeRequest.self, forKey: .payload))
        case .status:
            self = .status
        case .shutdown:
            self = .shutdown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transcribe(let r):
            try c.encode(Kind.transcribe, forKey: .type)
            try c.encode(r, forKey: .payload)
        case .status:
            try c.encode(Kind.status, forKey: .type)
        case .shutdown:
            try c.encode(Kind.shutdown, forKey: .type)
        }
    }
}

public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var language: String
    public var wantTimestamps: Bool
    public var diarize: Bool

    public init(
        audioPath: String,
        language: String = "en",
        wantTimestamps: Bool = true,
        diarize: Bool = true
    ) {
        self.audioPath = audioPath
        self.language = language
        self.wantTimestamps = wantTimestamps
        self.diarize = diarize
    }

    private enum CodingKeys: String, CodingKey {
        case audioPath, language, wantTimestamps, diarize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.audioPath = try c.decode(String.self, forKey: .audioPath)
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.wantTimestamps = try c.decodeIfPresent(Bool.self, forKey: .wantTimestamps) ?? true
        self.diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? true
    }
}
