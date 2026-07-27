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

        StorageSettingsSection()

        troubleshootingSection
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(.harcBody)
                    Text("Use this when macOS shows Harc enabled but recording, dictation, or pasting still says permission is missing — most often after reinstalling or updating, when the grants get attached to the old copy of the app.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(RecordingPermissionService.allCases, id: \.rawValue) { service in
                        HStack(spacing: 6) {
                            Image(systemName: service.isGranted ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(service.isGranted ? Color.green : Color.secondary)
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
            .padding(.vertical, 4)

            if let permissionRepairError {
                Label(permissionRepairError, systemImage: "exclamationmark.triangle")
                    .font(.harcCaption)
                    .foregroundStyle(Color.orange)
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
        HStack(spacing: 12) {
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
        .padding(.vertical, 4)
    }

    private var updatesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.harcTitle)
            Toggle("Check for updates automatically", isOn: $prefs.updateChecksEnabled)
            Text("Updates install in place via Sparkle; checks send nothing about you.")
                .font(.harcCaption)
                .foregroundStyle(Color.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates") {
                    bridge.onCheckForUpdates?()
                }
                .disabled(bridge.onCheckForUpdates == nil)
                if let update = bridge.availableUpdate {
                    HStack(spacing: 4) {
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
        .padding(.vertical, 4)
    }

    private var architectureBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(.vertical, 4)
    }

    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.green)
                Text("Local-first")
                    .font(.harcTitle)
            }
            Text("No cloud STT. No external telemetry. No accounts. Every byte of audio, every transcript, and every summary stays on this Mac. Harc's only network use is downloading models once from Hugging Face — your audio and text never leave this Mac.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
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
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
