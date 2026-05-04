import Foundation

/// A named voice. Linked to one or more (recording, speakerIndex) slots
/// via `PersonSpeakerLink`. Renamed via `RecordingStore.renamePerson`.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var displayName: String
    /// Per-Person match threshold override; nil falls back to the global
    /// default in `SpeakerReIDService`.
    public var matchThreshold: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64,
        displayName: String,
        matchThreshold: Double? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.matchThreshold = matchThreshold
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// "Speaker S in recording R is Person P, confirmed at T."
/// PRIMARY KEY (recording_id, speaker_index) — a slot can only link to
/// one Person.
public struct PersonSpeakerLink: Sendable, Equatable {
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let confirmedAt: Date

    public init(personID: Int64, recordingID: Int64, speakerIndex: Int, confirmedAt: Date) {
        self.personID = personID
        self.recordingID = recordingID
        self.speakerIndex = speakerIndex
        self.confirmedAt = confirmedAt
    }
}

/// Surfaced in Inspector + Person review queue. Created by the suggestion
/// engine; cleared on Confirm or Dismiss.
public struct PendingSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { "\(personID)-\(recordingID)-\(speakerIndex)" }
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let score: Double
    public let createdAt: Date

    public init(
        personID: Int64,
        recordingID: Int64,
        speakerIndex: Int,
        score: Double,
        createdAt: Date
    ) {
        self.personID = personID
        self.recordingID = recordingID
        self.speakerIndex = speakerIndex
        self.score = score
        self.createdAt = createdAt
    }
}

/// What the People-sidebar VM reads. Person + derived fields.
public struct PersonRowItem: Sendable, Equatable, Identifiable {
    public var id: Int64 { person.id }
    public let person: Person
    public let suggestionCount: Int
    public let lastSeen: Date?

    public init(person: Person, suggestionCount: Int, lastSeen: Date?) {
        self.person = person
        self.suggestionCount = suggestionCount
        self.lastSeen = lastSeen
    }
}

/// Aggregate statistics for a Person's detail view.
public struct PersonStats: Sendable, Equatable {
    public var recordingCount: Int
    public var totalSpeakingMs: Int
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(recordingCount: Int, totalSpeakingMs: Int, firstSeen: Date?, lastSeen: Date?) {
        self.recordingCount = recordingCount
        self.totalSpeakingMs = totalSpeakingMs
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// A single spoken utterance excerpt, harvested from a recording's .json sidecar.
/// Used in `PersonDetailView` to show recent speech samples.
public struct UtteranceExcerpt: Sendable, Equatable, Identifiable {
    public var id: String { "\(recordingID)-\(speakerIndex)-\(startMs)" }
    public let recordingID: Int64
    public let recordingTitle: String
    public let speakerIndex: Int
    public let startMs: Int
    public let snippet: String

    public init(recordingID: Int64, recordingTitle: String, speakerIndex: Int, startMs: Int, snippet: String) {
        self.recordingID = recordingID
        self.recordingTitle = recordingTitle
        self.speakerIndex = speakerIndex
        self.startMs = startMs
        self.snippet = snippet
    }
}
