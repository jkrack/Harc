import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts
import HarcMeetingDetect

public struct RecordingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var notificationsDenied: Bool = false
    @State private var destinationMissing: Bool = false

    public init() {}

    public var body: some View {
        Group {
            Section {
                HStack {
                    Text(prefs.destinationPath)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickFolder)
                }
                if destinationMissing {
                    destinationMissingWarning
                }
            } header: {
                Text("Destination folder")
            } footer: {
                Text("Recordings are written here as YYYY/YYYY-MM-DD/HH-mm-ss.{wav,txt,json}.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            Section {
                HStack {
                    Text("Chunk duration")
                    Spacer()
                    Text("\(Int(prefs.chunkDurationSeconds)) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $prefs.chunkDurationSeconds, in: 15...120, step: 15)
            } footer: {
                Text("How often the transcriber processes a slice during recording.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            Section {
                Toggle("Voice-activity detection", isOn: $prefs.vadEnabled)
                    .tint(Color.accentColor)
            } header: {
                Text("Processing")
            } footer: {
                Text("Skips silent regions before transcription. Faster and quieter on battery; disable if you suspect a word is being clipped.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            autoStopSection

            Section {
                Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)
                    .tint(Color.accentColor)
            } header: {
                Text("Auto-paste")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("When recording stops, the prompt-formatted transcript is pasted into the frontmost app.")
                    Text("Hold ⇧ while clicking Stop, or ⌥-click the menu-bar icon, to skip for one recording. Paste is always skipped for password managers, Finder, and meeting apps.")
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            } header: {
                Text("Global hotkey")
            }

            Section {
                Toggle("Enable meeting detection", isOn: $prefs.meetingDetectionEnabled)
                    .tint(Color.accentColor)
            } header: {
                Text("Meeting detection")
            } footer: {
                Text("Harc notices when you launch a video meeting app and offers to start recording.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            if prefs.meetingDetectionEnabled {
                Section {
                    ForEach(MeetingCatalog.builtIn) { app in
                        monitoredAppRow(app)
                    }
                    googleMeetComingSoonRow
                } header: {
                    Text("Monitored apps")
                }

                if notificationsDenied {
                    Section {
                        notificationsDeniedWarning
                    }
                }
            }
        }
        .task {
            await refreshNotificationStatus()
            refreshDestinationStatus()
        }
        .onChange(of: prefs.destinationPath) { _, _ in
            refreshDestinationStatus()
        }
    }

    // MARK: - Auto-stop

    @ViewBuilder
    private var autoStopSection: some View {
        Section {
            Toggle("Auto-stop when silent", isOn: $prefs.autoStopEnabled)
                .tint(Color.accentColor)

            if prefs.autoStopEnabled {
                HStack {
                    Text("Silence threshold")
                    Spacer()
                    Picker("", selection: $prefs.silenceThresholdMinutes) {
                        Text("3 min").tag(3)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
            }

            Toggle("Hard duration cap", isOn: $prefs.hardCapEnabled)
                .tint(Color.accentColor)

            if prefs.hardCapEnabled {
                Stepper(value: $prefs.hardCapMinutes, in: 15...720, step: 15) {
                    HStack {
                        Text("Maximum length")
                        Spacer()
                        Text(formatCap(prefs.hardCapMinutes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            Toggle("Post-stop notification", isOn: $prefs.postStopNotificationEnabled)
                .tint(Color.accentColor)
        } header: {
            Text("Auto-stop")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stops recording automatically when both the mic and system audio have been silent. Warns 60 s before stopping so you can keep recording.")
                Text("The hard cap stops recording regardless of silence. The tray banner always shows after an auto-stop; the macOS notification is additive and respects Do Not Disturb.")
            }
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
        }
    }

    private func formatCap(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return String(format: "%dh %02dm", h, m) }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func monitoredAppRow(_ app: MeetingApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.symbolName)
                .font(.body)
                .foregroundStyle(Color.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                if let note = app.settingsNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: prefs.meetingAppBinding(for: app))
                .labelsHidden()
                .tint(Color.accentColor)
        }
        .padding(.vertical, 4)
    }

    private var googleMeetComingSoonRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Meet")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                Text("Runs in your browser — reliable detection is coming.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
        }
        .padding(.vertical, 4)
    }

    private var notificationsDeniedWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications disabled")
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                Text("Harc will still pulse the menu bar icon, but can't show a banner until you re-enable notifications.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }

    private func refreshDestinationStatus() {
        destinationMissing = !prefs.destinationFolderExists()
    }

    private var destinationMissingWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination folder not found")
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                Text("Harc can't write recordings here until you choose a different folder or restore the missing one. New recordings will fail to save until this is resolved.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Choose…", action: pickFolder)
                        .controlSize(.small)
                    Button("Use Default") {
                        prefs.destinationPath = HarcPreferences.defaultDestinationPath
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Fall back to the home directory if the persisted destination
        // doesn't resolve (deleted, unmounted volume, missing iCloud
        // materialization). Otherwise the open panel anchors at a stale
        // path that may itself be unavailable.
        panel.directoryURL = prefs.destinationFolderExists()
            ? prefs.destinationURL
            : FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let chosen = panel.url {
            prefs.destinationPath = chosen.path
        }
    }
}
