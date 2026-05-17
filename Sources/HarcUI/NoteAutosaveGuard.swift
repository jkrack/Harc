import Foundation
import HarcStore

struct NoteSaveRequest: Equatable {
    var id: String
    var title: String
    var body: String
    var generation: Int
    var baseUpdatedAt: Date?
    var updateDraftIfSelected: Bool
}

struct NoteSaveConflict: Identifiable, Equatable {
    var id: String { noteID }
    var noteID: String
    var title: String
    var diskUpdatedAt: Date
    var draftTitle: String
    var draftBody: String
    var diskTitle: String
    var diskBody: String
}

enum NoteSaveDecision: Equatable {
    case save
    case stale
    case conflict(NoteSaveConflict)
}

enum NoteAutosaveGuard {
    static func shouldSave(
        request: NoteSaveRequest,
        currentGeneration: Int,
        selectedNoteID: String?,
        diskNote: Note?,
        allowOverwrite: Bool = false
    ) -> NoteSaveDecision {
        if request.updateDraftIfSelected,
           selectedNoteID == request.id,
           request.generation < currentGeneration {
            return .stale
        }

        guard !allowOverwrite,
              let baseUpdatedAt = request.baseUpdatedAt,
              let diskNote,
              diskNote.updatedAt > baseUpdatedAt,
              diskNote.title != request.title || diskNote.body != request.body
        else {
            return .save
        }

        return .conflict(NoteSaveConflict(
            noteID: request.id,
            title: diskNote.title,
            diskUpdatedAt: diskNote.updatedAt,
            draftTitle: request.title,
            draftBody: request.body,
            diskTitle: diskNote.title,
            diskBody: diskNote.body
        ))
    }
}
