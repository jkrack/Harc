import SwiftUI
import AppKit
import HarcContext

public struct LibrarySettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var notesMissing: Bool = false

    public init() {}

    public var body: some View {
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
        } header: {
            Text("Context Sources")
        } footer: {
            Text("Source folders and repos are indexed read-only. Harc writes synthesized wiki pages into its managed Wiki folder.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .onAppear { refreshMissingState() }
        .onChange(of: prefs.notesPath) { _, _ in refreshMissingState() }
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
