import SwiftUI
import HarcStore

/// An inspector `Section` that surfaces file metadata for a `Recording` — the
/// WAV/TXT/JSON paths, recording start time, and derived duration.
public struct FileInspectorSection: View {
    private let recording: Recording

    public init(recording: Recording) {
        self.recording = recording
    }

    public var body: some View {
        Section {
            if let duration = durationString {
                LabeledContent("Duration", value: duration)
            }
            LabeledContent("Started", value: startedString)
            LabeledContent("Audio") {
                Text(URL(fileURLWithPath: recording.wavPath).lastPathComponent)
                    .font(.harcMono)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let txtPath = recording.txtPath {
                LabeledContent("Transcript") {
                    Text(URL(fileURLWithPath: txtPath).lastPathComponent)
                        .font(.harcMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let jsonPath = recording.jsonPath {
                LabeledContent("Sidecar") {
                    Text(URL(fileURLWithPath: jsonPath).lastPathComponent)
                        .font(.harcMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("File")
        }
    }

    private var durationString: String? {
        guard let endedAt = recording.endedAt else { return nil }
        let total = max(0, Int(endedAt.timeIntervalSince(recording.startedAt).rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private var startedString: String {
        RelativeTimeFormatter.relativeOrDated(recording.startedAt)
    }
}
