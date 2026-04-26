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
                if destinationMissing {
                    destinationMissingWarning
                }
            } header: {
                Text("Destination folder")
            } footer: {
                Text("Recordings are written here as YYYY/YYYY-MM-DD/HH-mm-ss.{wav,txt,json}.")
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
                Toggle("Voice-activity detection", isOn: $prefs.vadEnabled)
                    .tint(HarcDesign.primary)
            } header: {
                Text("Processing")
            } footer: {
                Text("Skips silent regions before transcription. Faster and quieter on battery; disable if you suspect a word is being clipped.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            autoStopSection

            Section {
                Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)
                    .tint(HarcDesign.primary)
            } header: {
                Text("Auto-paste")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("When recording stops, the prompt-formatted transcript is pasted into the frontmost app.")
                    Text("Hold ⇧ while clicking Stop, or ⌥-click the menu-bar icon, to skip for one recording. Paste is always skipped for password managers, Finder, and meeting apps.")
                }
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            } header: {
                Text("Global hotkey")
            }

            Section {
                Toggle("Enable meeting detection", isOn: $prefs.meetingDetectionEnabled)
                    .tint(HarcDesign.primary)
            } header: {
                Text("Meeting detection")
            } footer: {
                Text("Harc notices when you launch a video meeting app and offers to start recording.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
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
        .formStyle(.grouped)
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
                .tint(HarcDesign.primary)

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
                .tint(HarcDesign.primary)

            if prefs.hardCapEnabled {
                Stepper(value: $prefs.hardCapMinutes, in: 15...720, step: 15) {
                    HStack {
                        Text("Maximum length")
                        Spacer()
                        Text(formatCap(prefs.hardCapMinutes))
                            .font(HarcDesign.Font.labelMd.monospacedDigit())
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                    }
                }
            }

            Toggle("Post-stop notification", isOn: $prefs.postStopNotificationEnabled)
                .tint(HarcDesign.primary)
        } header: {
            Text("Auto-stop")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stops recording automatically when both the mic and system audio have been silent. Warns 60 s before stopping so you can keep recording.")
                Text("The hard cap stops recording regardless of silence. The tray banner always shows after an auto-stop; the macOS notification is additive and respects Do Not Disturb.")
            }
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurfaceVariant)
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
        HStack(spacing: HarcDesign.Space.sm) {
            Image(systemName: app.symbolName)
                .font(.body)
                .foregroundStyle(Color.harcTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurface)
                if let note = app.settingsNote {
                    Text(note)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
            }
            Spacer()
            Toggle("", isOn: prefs.meetingAppBinding(for: app))
                .labelsHidden()
                .tint(HarcDesign.primary)
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }

    private var googleMeetComingSoonRow: some View {
        HStack(spacing: HarcDesign.Space.sm) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Meet")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Text("Runs in your browser — reliable detection is coming.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }

    private var notificationsDeniedWarning: some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harcError)
            VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                Text("Notifications disabled")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurface)
                Text("Harc will still pulse the menu bar icon, but can't show a banner until you re-enable notifications.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }

    private func refreshDestinationStatus() {
        destinationMissing = !prefs.destinationFolderExists()
    }

    private var destinationMissingWarning: some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harcError)
            VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                Text("Destination folder not found")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurface)
                Text("Harc can't write recordings here until you choose a different folder or restore the missing one. New recordings will fail to save until this is resolved.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcDesign.Space.sm) {
                    Button("Choose…", action: pickFolder)
                        .controlSize(.small)
                    Button("Use Default") {
                        prefs.destinationPath = HarcPreferences.defaultDestinationPath
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, HarcDesign.Space.xxs)
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
