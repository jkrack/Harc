import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts
import UniformTypeIdentifiers
import HarcMeetingDetect

public struct RecordingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var notificationsDenied: Bool = false
    @State private var destinationMissing: Bool = false
    @State private var permissionRepairError: String?

    public init() {}

    public var body: some View {
        Group {
            Section {
                LabeledContent {
                    HStack {
                        Text(prefs.destinationPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Choose…", action: pickFolder)
                    }
                } label: {
                    Label("Folder", systemImage: "folder")
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

                Divider()

                ForEach(pasteDenyListRows, id: \.self) { bundleID in
                    pasteDenyListRow(bundleID)
                }

                Button {
                    pickPasteDenyListApp()
                } label: {
                    Label("Add app…", systemImage: "plus")
                }
            } header: {
                Text("Auto-paste")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("When recording stops, the prompt-formatted transcript is pasted into the frontmost app.")
                    Text("Hold ⇧ while clicking Stop, or ⌥-click the menu-bar icon, to skip for one recording. Locked apps are always skipped; you can add or remove your own apps above.")
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
                KeyboardShortcuts.Recorder("Dictation:", name: .pushToTalkDictation)
                Picker("Trigger", selection: $prefs.dictationTriggerStyle) {
                    ForEach(HarcPreferences.DictationTriggerStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Keep dictation ready", isOn: $prefs.keepDictationWarm)
                Toggle("Keep dictation history", isOn: $prefs.dictationHistoryEnabled)
            } header: {
                Text("Dictation")
            } footer: {
                Text("Push-to-talk: hold the key to dictate, release to insert. Toggle: tap to start and stop. Dictated text is inserted at the cursor in the frontmost app. Keep-ready holds the speech model in memory so the first dictation is instant; history keeps your last \(DictationHistoryStore.maxEntries) dictations on this Mac.")
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording access")
                            .font(.body)
                        Text("Use this when macOS shows Harc enabled but recording still asks for Screen & System Audio permission.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Open Privacy Settings") {
                                RecordingPermissionRepair.openScreenCaptureSettings()
                            }
                            Button("Reset Harc Permissions…") {
                                resetRecordingPermissions()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

                if let permissionRepairError {
                    Label(permissionRepairError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Reset removes Harc's current Microphone and Screen & System Audio grants, opens System Settings, and then quits Harc. Reopen Harc and grant the prompts again.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
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

    private var pasteDenyListRows: [String] {
        prefs.pasteDenyListBundleIDs.sorted { lhs, rhs in
            let leftLocked = PasteDenyList.lockedBundleIDs.contains(lhs)
            let rightLocked = PasteDenyList.lockedBundleIDs.contains(rhs)
            if leftLocked != rightLocked { return leftLocked }
            return pasteDenyListDisplayName(for: lhs).localizedCaseInsensitiveCompare(
                pasteDenyListDisplayName(for: rhs)
            ) == .orderedAscending
        }
    }

    private func pasteDenyListRow(_ bundleID: String) -> some View {
        let locked = PasteDenyList.lockedBundleIDs.contains(bundleID)
        return HStack(spacing: 12) {
            Image(systemName: locked ? "lock.fill" : "app.dashed")
                .foregroundStyle(locked ? Color.secondary : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(pasteDenyListDisplayName(for: bundleID))
                    .font(.body)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if locked {
                Text("Locked")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                Button(role: .destructive) {
                    prefs.removePasteDenyListBundleID(bundleID)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove from auto-paste deny list")
            }
        }
        .padding(.vertical, 3)
    }

    private func pasteDenyListDisplayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return fallbackPasteDenyListDisplayName(for: bundleID)
        }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func fallbackPasteDenyListDisplayName(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.loginwindow": return "Login Window"
        case "com.apple.finder": return "Finder"
        case "com.apple.systempreferences": return "System Settings"
        case "com.apple.ScreenSaver.Engine": return "Screen Saver"
        case "com.agilebits.onepassword7", "com.agilebits.onepassword8": return "1Password"
        case "com.bitwarden.desktop": return "Bitwarden"
        case "com.lastpass.LastPass": return "LastPass"
        case "org.keepassxc.keepassxc": return "KeePassXC"
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2": return "Microsoft Teams"
        case "com.tinyspeck.slackmacgap": return "Slack"
        default: return bundleID
        }
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
            Text("Coming soon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private var notificationsDeniedWarning: some View {
        NativeStatusCallout(intent: .warning) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications disabled")
                        .font(.caption.weight(.semibold))
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

    private func resetRecordingPermissions() {
        permissionRepairError = nil
        guard let plan = RecordingPermissionRepairPlan.current() else {
            permissionRepairError = RecordingPermissionRepair.Error.missingBundleID.localizedDescription
            return
        }

        let alert = NSAlert()
        alert.messageText = "Reset Harc recording permissions?"
        alert.informativeText = "This removes Harc's current Microphone and Screen & System Audio privacy grants for \(plan.bundleID). Harc will open System Settings and quit; reopen it and grant the prompts again."
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try RecordingPermissionRepair.reset(plan: plan)
            RecordingPermissionRepair.openScreenCaptureSettings()
            NSApp.terminate(nil)
        } catch {
            permissionRepairError = error.localizedDescription
        }
    }

    private var destinationMissingWarning: some View {
        NativeStatusCallout(intent: .danger) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination folder not found")
                        .font(.caption.weight(.semibold))
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

    private func pickPasteDenyListApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return
        }

        prefs.addPasteDenyListBundleID(bundleID)
    }
}
