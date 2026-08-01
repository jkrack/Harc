import SwiftUI
import AppKit

public struct AboutSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var bridge: HarcAppBridge

    /// Permission repair lives here rather than in Recording: it's a recovery
    /// tool for a broken install, not something to walk past every time you
    /// adjust a hotkey.
    @State private var permissionRepairError: String?

    public init() {}

    public var body: some View {
        Section {
            heroRow
            updatesBlock
            architectureBlock
            privacyBlock
            footerRow
        } header: {
            Text("About")
        }

        agentsSection

        StorageSettingsSection()

        troubleshootingSection
    }

    // MARK: - Connect agents (MCP)

    /// The bundled harc-mcp bridge, discoverable where the rest of the
    /// install-level facts live. It exposes search + safe metadata writes to
    /// MCP hosts the user runs on their own account; the app itself still
    /// makes no cloud calls.
    private var agentsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("Harc ships a small MCP server so AI agents you run — Claude Desktop, Claude Code, or any MCP client — can search your transcripts and write back titles, tags, speaker names, summaries, and appended notes. It talks directly to the library on this Mac, works while Harc is closed, and opens no network connections of its own: the agent brings its model and account. Transcripts are read-only to agents, and agent notes are append-only with an author stamp.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: HarcSpacing.sm) {
                    Text(mcpAddCommand)
                        .font(.harcMono)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, HarcSpacing.sm)
                        .padding(.vertical, HarcSpacing.xs)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(mcpAddCommand, forType: .string)
                    }
                    .controlSize(.small)
                }

                Text("That command registers it with Claude Code. For Claude Desktop, add the same executable path under \u{201C}mcpServers\u{201D} in claude_desktop_config.json.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)
        } header: {
            Text("Connect Agents (MCP)")
        }
    }

    /// Resolved from the running bundle so dev builds show their real path.
    private var mcpAddCommand: String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/harc-mcp").path
        return "claude mcp add harc -- \(path)"
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        Section {
            HStack(alignment: .top, spacing: HarcSpacing.md) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                    Text("Permissions")
                        .font(.harcBody)
                    Text("Use this when macOS shows Harc enabled but recording, dictation, or pasting still says permission is missing — most often after reinstalling or updating, when the grants get attached to the old copy of the app.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(RecordingPermissionService.allCases, id: \.rawValue) { service in
                        HStack(spacing: HarcSpacing.sm) {
                            Image(systemName: service.isGranted ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(service.isGranted ? Color.harc(.ready) : Color.secondary)
                            Text(service.displayName)
                                .font(.harcCaption)
                            Spacer()
                            if !service.isGranted {
                                Button("Open Settings") {
                                    RecordingPermissionRepair.openSettings(for: service)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    Button("Reset All Permissions…") {
                        resetRecordingPermissions()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, HarcSpacing.xs)

            if let permissionRepairError {
                Label(permissionRepairError, systemImage: "exclamationmark.triangle")
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.attention))
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Reset clears Harc's Microphone, Screen & System Audio, and Accessibility grants, then restarts Harc automatically and walks you through granting them again. Restarting is required — macOS keeps the old answer until the app relaunches.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
    }

    /// Reset every grant, then put the app back on screen.
    ///
    /// The old flow reset, opened System Settings, and quit — which stranded
    /// the user, because Harc is `LSUIElement` and leaves nothing behind to
    /// click when it exits. The relaunch is scheduled *before* terminating so
    /// the app returns on its own with the repair flow showing.
    private func resetRecordingPermissions() {
        permissionRepairError = nil
        guard let plan = RecordingPermissionRepairPlan.current() else {
            permissionRepairError = RecordingPermissionRepair.Error.missingBundleID.localizedDescription
            return
        }

        let alert = NSAlert()
        alert.messageText = "Reset all Harc permissions?"
        alert.informativeText = """
            This clears Harc's Microphone, Screen & System Audio, and Accessibility grants for \(plan.bundleID).

            Harc will restart itself and reopen the setup guide so you can grant them again. Recordings and transcripts are not affected.
            """
        alert.addButton(withTitle: "Reset and Restart")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try RecordingPermissionRepair.reset(plan: plan)
        } catch {
            permissionRepairError = error.localizedDescription
            return
        }

        // Only quit if we can guarantee a way back. If spawning the relaunch
        // helper fails, stay open and hand the user the manual path rather
        // than disappearing on them — the exact failure this flow had.
        guard RecordingPermissionRepair.scheduleRelaunch() else {
            permissionRepairError = "Permissions were reset, but Harc couldn't schedule its restart. Quit Harc and reopen it to finish."
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Sub-views

    private var heroRow: some View {
        HStack(spacing: HarcSpacing.md) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HarcBrand.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.harcTitle.weight(.semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Harc")
                    .font(.harcTitle)
                    .fontWeight(.semibold)
                Text("Local-first speech-to-text for meetings.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                Text(versionLine)
                    .font(.harcMono)
                    .foregroundStyle(Color.secondary)
                // Read from the bundle rather than hard-coded, for the same
                // reason the version is: a second copy of a fact drifts.
                Text(copyrightLine)
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private var updatesBlock: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            Text("Updates")
                .font(.harcTitle)
            Toggle("Check for updates automatically", isOn: $prefs.updateChecksEnabled)
            Text("Updates install in place via Sparkle; checks send nothing about you.")
                .font(.harcCaption)
                .foregroundStyle(Color.secondary)
            HStack(spacing: HarcSpacing.md) {
                Button("Check for Updates") {
                    bridge.onCheckForUpdates?()
                }
                .disabled(bridge.onCheckForUpdates == nil)
                if let update = bridge.availableUpdate {
                    HStack(spacing: HarcSpacing.xs) {
                        Text("Harc \(update.version) available —")
                            .font(.harcLabel)
                        if bridge.onInstallUpdate != nil {
                            Button("Install") { bridge.onInstallUpdate?() }
                                .buttonStyle(.link)
                                .font(.harcLabel)
                        } else {
                            Link("View release", destination: update.url)
                                .font(.harcLabel)
                        }
                    }
                }
            }
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private var architectureBlock: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            Text("Architecture")
                .font(.harcTitle)
            bullet("Apple Silicon native — runs on the Neural Engine via Core ML.")
            bullet("Speech-to-text by FluidAudio + Parakeet TDT, hosted in a separate daemon process so model load amortizes across recordings.")
            bullet("Audio is mixed from your microphone (AVAudioEngine) and system audio (ScreenCaptureKit) into a durable WAV — your meeting survives a crash.")
            bullet("Recordings are transcribed in rolling 60-second chunks during capture, so the transcript is ~90% done the moment you hit stop.")
            bullet("Diarization and speaker re-identification group the transcript by voice and remember speakers across meetings.")
            bullet("On-device summarization by Gemma 4 via MLX. The library is stored in GRDB/SQLite at ~/Library/Application Support/Harc.")
            // Moved here from the Library footer: static for the lifetime of
            // an install, so it reads as reference, not status.
            bullet("Runs on \(HardwareInfo.appleSiliconDisplayName) via the Neural Engine · speech model parakeet-tdt-0.6b-v3 · fully local.")
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.harc(.ready))
                Text("Local-first")
                    .font(.harcTitle)
            }
            Text("No cloud STT. No external telemetry. No accounts. Every byte of audio, every transcript, and every summary stays on this Mac. Harc's only network use is downloading models once from Hugging Face — your audio and text never leave this Mac.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private var footerRow: some View {
        HStack {
            Text("Made for macOS 26.")
                .font(.harcCaption)
                .foregroundStyle(Color.secondary)
            Spacer()
            Link("github.com/jkrack/Harc", destination: URL(string: "https://github.com/jkrack/Harc")!)
                .font(.harcCaption)
        }
        .padding(.top, HarcSpacing.xs)
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
            Text("•")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.harcLabel)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var copyrightLine: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 CloudArchitech LLC"
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }
}
