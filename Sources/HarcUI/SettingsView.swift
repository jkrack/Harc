import SwiftUI
import AppKit
import KeyboardShortcuts

public struct SettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack {
                    Text(prefs.destinationPath)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickFolder)
                }
            } header: {
                Text("Destination folder")
            } footer: {
                Text("Recordings are written here as YYYY/YYYY-MM-DD/HH-mm-ss.{wav,txt,json}.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
            } footer: {
                Text("When on, transcripts include per-speaker segments.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                HStack {
                    Text("Chunk duration")
                    Spacer()
                    Text("\(Int(prefs.chunkDurationSeconds)) s")
                        .font(HarcDesign.Font.labelMd.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Slider(value: $prefs.chunkDurationSeconds, in: 15...120, step: 15)
            } footer: {
                Text("How often the transcriber processes a slice during recording.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            } header: {
                Text("Global hotkey")
            }
        }
        .formStyle(.grouped)
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.destinationURL
        if panel.runModal() == .OK, let chosen = panel.url {
            prefs.destinationPath = chosen.path
        }
    }
}
