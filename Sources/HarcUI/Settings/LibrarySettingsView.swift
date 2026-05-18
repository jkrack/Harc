import SwiftUI
import AppKit
import ApplicationServices
import HarcContext
import HarcModels
import HarcStore

public struct LibrarySettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var models: ModelManagerStore
    @EnvironmentObject private var bridge: HarcAppBridge
    @State private var notesMissing: Bool = false

    public init() {}

    public var body: some View {
        Section {
            LocalStackHealthView(
                items: LocalStackHealthModel.items(for: settingsLocalStackInput),
                onFix: { item in openFixTarget(for: item) }
            )
        } header: {
            Text("Local Stack")
        } footer: {
            Text("These local dependencies affect capture, paste, search, summaries, speaker naming, and macOS notifications.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes folder")
                    .font(.subheadline.weight(.semibold))
                Text(prefs.notesPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            if notesMissing {
                Label("This folder is missing. Harc can create it when saving a note, or you can choose another folder.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }

            HStack {
                Button("Choose Notes Folder...") { chooseNotesFolder() }
                Button("Reset to Default") {
                    prefs.notesPath = HarcPreferences.defaultNotesPath
                    refreshMissingState()
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Notes are Markdown files saved as YYYY/MM/DD/<id>.md. A note can stand alone or link back to one or more recordings.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }

        Section {
            let rows = RecoveryInboxModel.rows(for: bridge.recoveryArtifacts)
            if rows.isEmpty {
                Label("No recording artifacts need recovery.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: row.artifact.status == .recovered ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark")
                                .foregroundStyle(row.artifact.status == .recovered ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(row.statusText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(row.sourcePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Button("Recover") { bridge.onRecoverRecoveryArtifact(row.id) }
                                .disabled(!row.canRecover)
                            Button("Reveal") { bridge.onRevealRecoveryArtifact(row.id) }
                                .disabled(!row.canReveal)
                            Button("Discard") { bridge.onDiscardRecoveryArtifact(row.id) }
                                .disabled(!row.canDiscard)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Recover imports a preserved artifact into the Library. Discard hides it from Harc recovery without deleting the source file.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }

        Section {
            if prefs.sourceRoots.isEmpty {
                Label("No source folders connected.", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prefs.sourceRoots) { root in
                    HStack(spacing: 10) {
                        Image(systemName: root.kind == .repository ? "chevron.left.forwardslash.chevron.right" : "folder")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.displayName)
                                .lineLimit(1)
                            Text(root.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(root.readOnly ? "Read-only" : "Writable")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button {
                            removeSourceRoot(root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove source")
                    }
                }
            }

            HStack {
                Button("Add Source Folder...") { chooseSourceFolder() }
            }

            Stepper(value: $prefs.sourceScanLimit, in: HarcPreferences.sourceScanLimitRange, step: 10) {
                Text("Scan up to \(prefs.sourceScanLimit) documents per source")
            }
        } header: {
            Text("Context Sources")
        } footer: {
            Text("Source folders and repos are indexed read-only. Harc skips generated/vendor folders by default: \(LocalSourceScanner.defaultExcludeGlobs.joined(separator: ", ")). Raise the scan limit for broader reviews, or narrow the folder for more focused proposals.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .onAppear { refreshMissingState() }
        .onChange(of: prefs.notesPath) { _, _ in refreshMissingState() }
    }

    private var settingsLocalStackInput: LocalStackHealthInput {
        let summarizer = ModelCatalog.descriptor(for: prefs.activeSummarizerID)
        let summarizerName = summarizer?.tierDisplayName ?? summarizer?.displayName ?? "Summarizer"
        let summarizerInstalled = models.state(of: prefs.activeSummarizerID).isInstalled
        let embedder = ModelCatalog.descriptor(for: prefs.activeEmbedderID)
        let embedderName = embedder?.displayName ?? "Search embedder"
        let embedderInstalled = models.state(of: prefs.activeEmbedderID).isInstalled

        return LocalStackHealthInput(
            destinationReady: prefs.destinationFolderExists(),
            destinationText: prefs.destinationFolderExists() ? prefs.destinationPath : "Destination folder missing",
            captureReady: true,
            captureText: "Mic and system-audio permissions are checked during recording",
            sttReady: true,
            sttText: "Local STT daemon installed with Harc",
            summarizerReady: summarizerInstalled && prefs.autoSummarizeEnabled,
            summarizerText: summarizerInstalled ? "\(summarizerName) installed" : "\(summarizerName) not installed",
            embedderReady: embedderInstalled,
            embedderText: embedderInstalled ? "\(embedderName) installed" : "\(embedderName) not installed",
            speakerIDReady: prefs.speakerReIDEnabled,
            speakerIDText: prefs.speakerReIDEnabled ? "Speaker ID enabled" : "Speaker ID disabled",
            notificationsReady: prefs.postStopNotificationEnabled,
            notificationsText: prefs.postStopNotificationEnabled ? "Post-stop notifications enabled" : "Post-stop notifications off",
            accessibilityReady: AXIsProcessTrusted(),
            accessibilityText: AXIsProcessTrusted() ? "Paste permission granted" : "Paste needs Accessibility permission",
            pendingRecoveryCount: RecoveryInboxModel.unresolvedCount(in: bridge.recoveryArtifacts)
        )
    }

    private func openFixTarget(for item: LocalStackHealthItem) {
        switch item.id {
        case .capture:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .systemAudio:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .notifications:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func refreshMissingState() {
        notesMissing = !prefs.notesFolderExists()
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = prefs.notesFolderExists()
            ? prefs.notesURL
            : FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let chosen = panel.url {
            prefs.notesPath = chosen.path
        }
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Connect"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let chosen = panel.url {
            let root = LocalSourceRoot(path: chosen.path, readOnly: true)
            guard !prefs.sourceRoots.contains(where: { $0.path == root.path }) else { return }
            prefs.sourceRoots.append(root)
        }
    }

    private func removeSourceRoot(_ root: LocalSourceRoot) {
        prefs.sourceRoots.removeAll { $0.id == root.id }
    }
}
