import Foundation

enum LibraryMutationAction: Equatable {
    case deleteRecording(String)
    case archiveNote(String)
    case pinRecording(String)
    case pinNote(String)
    case clearSummary(String)
    case addPerson(String)
    case renameSpeaker
    case confirmSpeakerSuggestion
    case dismissSpeakerSuggestion
    case linkSpeaker
    case createAndLinkPerson(String)
    case unlinkSpeaker

    var title: String {
        switch self {
        case .deleteRecording:
            return "Could not delete recording"
        case .archiveNote:
            return "Could not delete note"
        case .pinRecording:
            return "Could not update pin"
        case .pinNote:
            return "Could not update note pin"
        case .clearSummary:
            return "Could not clear summary"
        case .addPerson:
            return "Could not add person"
        case .renameSpeaker:
            return "Could not rename speaker"
        case .confirmSpeakerSuggestion:
            return "Could not confirm speaker"
        case .dismissSpeakerSuggestion:
            return "Could not dismiss suggestion"
        case .linkSpeaker:
            return "Could not link speaker"
        case .createAndLinkPerson:
            return "Could not create person"
        case .unlinkSpeaker:
            return "Could not unlink speaker"
        }
    }

    var subject: String? {
        switch self {
        case .deleteRecording(let value),
             .archiveNote(let value),
             .pinRecording(let value),
             .pinNote(let value),
             .clearSummary(let value),
             .addPerson(let value),
             .createAndLinkPerson(let value):
            return value
        case .renameSpeaker,
             .confirmSpeakerSuggestion,
             .dismissSpeakerSuggestion,
             .linkSpeaker,
             .unlinkSpeaker:
            return nil
        }
    }
}

struct LibraryMutationFailure: Identifiable, Equatable {
    let id: UUID
    let action: LibraryMutationAction
    let detail: String

    init(id: UUID = UUID(), action: LibraryMutationAction, error: Error) {
        self.id = id
        self.action = action
        self.detail = error.localizedDescription
    }

    var title: String { action.title }

    var message: String {
        if let subject = action.subject, !subject.isEmpty {
            return "\(subject): \(detail)"
        }
        return detail
    }
}
