import SwiftUI

/// Host transcript remains authoritative when present. This read-only preview
/// never trains voices, writes Host metadata, or replaces a user edit.
struct HarcMobileLocalTranscriptSection: View {
    let recordingID: UUID
    @Environment(HarcMobileAppModel.self) private var model
    @State private var installing = false
    @State private var installationFailed = false

    var body: some View {
        Section("On-device transcript") {
            switch model.localTranscription?.states[recordingID] {
            case .ready(let transcript):
                Text(transcript.text.isEmpty ? "No speech was recognized." : transcript.text)
                    .textSelection(.enabled)
                Text("Transcribed on this iPhone. Speaker names and summaries are supplied separately by your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .available:
                ProgressView("Opening on-device transcript…")
            case .queued:
                Text("Queued on this iPhone. Transcription resumes when Harc is open and not recording.")
                    .foregroundStyle(.secondary)
            case .transcribing:
                ProgressView("Transcribing on this iPhone…")
            case .needsModel:
                Text("Download Apple’s speech model for your current language to transcribe on this iPhone. Your recording is not uploaded.")
                Button(installing ? "Downloading model…" : "Download speech model") {
                    installing = true
                    installationFailed = false
                    Task {
                        do {
                            try await HarcMobileAppleSpeech.installCurrentLanguage()
                            model.transcribeLocalRecording(recordingID)
                        } catch { installationFailed = true }
                        installing = false
                    }
                }
                .disabled(installing || model.captureCoordinator?.isRecording == true)
                if installationFailed {
                    Text("Model download did not finish. Your recording is safe; try again when connected.")
                        .foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("On-device speech is unavailable for this device or language. Your recording can still be processed by your Mac.")
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Local transcription did not finish. Your audio and transfer are unaffected.")
                Button("Retry on-device transcription") { model.transcribeLocalRecording(recordingID) }
            case nil:
                Button("Transcribe on this iPhone") { model.transcribeLocalRecording(recordingID) }
            }
        }
        .accessibilityIdentifier("harc.mobile.local.transcript.\(recordingID)")
        .task(id: model.localTranscription?.states[recordingID] == .available) {
            await model.localTranscription?.loadPreview(recordingID)
        }
    }
}
