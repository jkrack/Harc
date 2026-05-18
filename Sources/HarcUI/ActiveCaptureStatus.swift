import Foundation

public struct ActiveCaptureStatus: Equatable, Sendable {
    public enum SourceState: String, Equatable, Sendable {
        case checking
        case micAndSystemAudio
        case micOnly

        public var displayText: String {
            switch self {
            case .checking: return "Checking audio sources"
            case .micAndSystemAudio: return "Mic + system audio"
            case .micOnly: return "Mic only"
            }
        }

        public var warningText: String? {
            switch self {
            case .micOnly:
                return "System audio is unavailable. Other participants may be absent."
            case .checking, .micAndSystemAudio:
                return nil
            }
        }
    }

    public var sourceState: SourceState
    public var cachePath: String
    public var destinationPath: String
    public var startedAt: Date
    public var lastTranscriptUpdateAt: Date?

    public init(
        sourceState: SourceState,
        cachePath: String,
        destinationPath: String,
        startedAt: Date,
        lastTranscriptUpdateAt: Date? = nil
    ) {
        self.sourceState = sourceState
        self.cachePath = cachePath
        self.destinationPath = destinationPath
        self.startedAt = startedAt
        self.lastTranscriptUpdateAt = lastTranscriptUpdateAt
    }

    public func updatingSource(_ sourceState: SourceState) -> ActiveCaptureStatus {
        var copy = self
        copy.sourceState = sourceState
        return copy
    }

    public func markingTranscriptUpdate(at date: Date) -> ActiveCaptureStatus {
        var copy = self
        copy.lastTranscriptUpdateAt = date
        return copy
    }

    public func transcriptAgeText(referenceDate: Date = Date()) -> String {
        guard let lastTranscriptUpdateAt else {
            return "Transcript waiting"
        }

        let seconds = max(0, Int(referenceDate.timeIntervalSince(lastTranscriptUpdateAt)))
        if seconds < 2 {
            return "Transcript just updated"
        }
        if seconds < 60 {
            return "Transcript updated \(seconds)s ago"
        }
        let minutes = seconds / 60
        return "Transcript updated \(minutes)m ago"
    }
}
