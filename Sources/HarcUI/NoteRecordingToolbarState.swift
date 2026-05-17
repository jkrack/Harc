import Foundation

enum NoteRecordingToolbarState: Equatable {
    case idle
    case recordingIntoThisNote
    case recordingIntoAnotherNote
    case generalRecording

    static func resolve(
        isRecording: Bool,
        activeNoteID: String?,
        currentNoteID: String
    ) -> NoteRecordingToolbarState {
        guard isRecording else { return .idle }
        guard let activeNoteID else { return .generalRecording }
        return activeNoteID == currentNoteID ? .recordingIntoThisNote : .recordingIntoAnotherNote
    }

    var title: String {
        switch self {
        case .idle:
            return "Record into Note"
        case .recordingIntoThisNote:
            return "Stop Note Recording"
        case .recordingIntoAnotherNote:
            return "Recording into Another Note"
        case .generalRecording:
            return "General Recording Active"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "record.circle"
        case .recordingIntoThisNote:
            return "stop.circle.fill"
        case .recordingIntoAnotherNote:
            return "note.text.badge.plus"
        case .generalRecording:
            return "waveform.badge.magnifyingglass"
        }
    }

    var canToggleDirectly: Bool {
        self == .idle || self == .recordingIntoThisNote
    }
}
