import Foundation

enum LibraryMutationAction: Equatable {
    case deleteRecording(String)
    case pinRecording(String)
    case clearSummary(String)
    case addPerson(String)
    case renameSpeaker
    case mergePeople
    case updateSpeakerThreshold
    case deletePerson
    case splitSpeakerEvidence
    case loadSpeakerEvidence
    case confirmSpeakerSuggestion
    case dismissSpeakerSuggestion
    case linkSpeaker
    case createAndLinkPerson(String)
    case unlinkSpeaker
    case createSession
    case dissolveSession(String)
    case renameSession(String)

    var title: String {
        switch self {
        case .deleteRecording:
            return "Could not delete recording"
        case .pinRecording:
            return "Could not update pin"
        case .clearSummary:
            return "Could not clear summary"
        case .addPerson:
            return "Could not add person"
        case .splitSpeakerEvidence:
            return "Could not split voice samples"
        case .loadSpeakerEvidence:
            return "Could not load voice samples"
        case .mergePeople:
            return "Could not merge people"
        case .updateSpeakerThreshold:
            return "Could not update match threshold"
        case .deletePerson:
            return "Could not delete person"
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
        case .createSession:
            return "Could not create session"
        case .dissolveSession:
            return "Could not dissolve session"
        case .renameSession:
            return "Could not rename session"
        }
    }

    var subject: String? {
        switch self {
        case .deleteRecording(let value),
             .pinRecording(let value),
             .clearSummary(let value),
             .addPerson(let value),
             .createAndLinkPerson(let value),
             .dissolveSession(let value),
             .renameSession(let value):
            return value
        case .renameSpeaker, .mergePeople, .updateSpeakerThreshold, .deletePerson, .splitSpeakerEvidence, .loadSpeakerEvidence,
             .confirmSpeakerSuggestion,
             .dismissSpeakerSuggestion,
             .linkSpeaker,
             .unlinkSpeaker,
             .createSession:
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
