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
                Text("Recordings are written here as YYYY/YYYY-MM-DD/HH-mm-ss.{wav,md,json}.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            }

            preRollSection

            autoStopSection

            Section {
                Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)
                    .tint(Color.accentColor)

                // No Divider here: inside a grouped Form, a bare divider is
                // laid out as its own full-height row, so it showed up as an
                // empty gap between the toggle and the first app. The Form
                // already draws separators between rows.
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
                .font(.harcLabel)
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
                    .font(.harcLabel)
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
    /// Retroactive record. The footer is deliberately blunt about the mic being
    /// held open: this is the one setting in Harc that changes what the machine
    /// is doing while the user isn't using it, and burying that would be the
    /// wrong trade even though the audio never leaves the device.
    private var preRollSection: some View {
        Section {
            Toggle("Capture before you press record", isOn: $prefs.preRollEnabled)
                .tint(Color.accentColor)

            if prefs.preRollEnabled {
                HStack {
                    Text("Keep the last")
                    Spacer()
                    Picker("", selection: $prefs.preRollMinutes) {
                        Text("1 min").tag(1)
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                LabeledContent {
                    Text(preRollMemoryEstimate)
                        .font(.harcCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Memory used")
                }
            }
        } header: {
            Text("Retroactive record")
        } footer: {
            Text(prefs.preRollEnabled
                 ? "Harc holds the microphone open while idle and keeps the last \(prefs.preRollMinutes) minute\(prefs.preRollMinutes == 1 ? "" : "s") in memory — macOS shows the orange mic indicator the whole time. Nothing is written to disk or sent anywhere until you start a recording, and starting one includes what was already said."
                 : "Start a recording and keep what was said just before it. Audio is held in memory only, never written to disk until you record. Requires holding the microphone open while Harc is idle.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
    }

    /// 16 kHz mono Int16 → 32 KB/s. Shown because "keep the last 10 minutes"
    /// otherwise gives no sense of what it costs.
    private var preRollMemoryEstimate: String {
        let megabytes = Double(prefs.preRollMinutes) * 60.0 * 32_000.0 / 1_048_576.0
        return String(format: "%.0f MB", megabytes.rounded())
    }

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
                            .font(.harcCaption.monospacedDigit())
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
            .font(.harcLabel)
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
                .font(.harcBody)
                .foregroundStyle(Color.accentColor) // app glyphs are decoration, not status
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.harcBody)
                    .foregroundStyle(Color.primary)
                if let note = app.settingsNote {
                    Text(note)
                        .font(.harcLabel)
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
            // The row already resolves each app's bundle to get its display
            // name, so it can show the real icon too. A column of identical
            // dashed placeholders next to "Finder", "Slack" and "Zoom" read as
            // icons that had failed to load.
            if let icon = pasteDenyListIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: locked ? "lock.fill" : "app.dashed")
                    .foregroundStyle(locked ? Color.secondary : Color.accentColor)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pasteDenyListDisplayName(for: bundleID))
                    .font(.harcBody)
                Text(bundleID)
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if locked {
                Text("Locked")
                    .font(.harcCaption)
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

    /// The installed app's icon, or nil when the bundle isn't on this Mac —
    /// the deny list ships entries (LastPass, KeePassXC) the user may not have.
    private func pasteDenyListIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
                .font(.harcBody)
                .foregroundStyle(Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Meet")
                    .font(.harcBody)
                    .foregroundStyle(Color.secondary)
                Text("Runs in your browser — reliable detection is coming.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Text("Coming soon")
                .font(.harcCaption.weight(.semibold))
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
                    .foregroundStyle(Color.harc(.attention))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications disabled")
                        .font(.harcCaption.weight(.semibold))
                    Text("Harc will still pulse the menu bar icon, but can't show a banner until you re-enable notifications.")
                        .font(.harcLabel)
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

    private var destinationMissingWarning: some View {
        NativeStatusCallout(intent: .danger) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.harc(.failure))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination folder not found")
                        .font(.harcCaption.weight(.semibold))
                    Text("Harc can't write recordings here until you choose a different folder or restore the missing one. New recordings will fail to save until this is resolved.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Choose…", action: pickFolder)
                            .controlSize(.small)
                        Button("Use Default") {
                            prefs.destinationPath = HarcPreferences.defaultDestinationPath
                            prefs.ensureDefaultDestinationExists()
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
