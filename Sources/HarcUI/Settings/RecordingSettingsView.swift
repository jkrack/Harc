import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts
import HarcMeetingDetect

public struct RecordingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var notificationsDenied: Bool = false

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
        .task { await refreshNotificationStatus() }
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
