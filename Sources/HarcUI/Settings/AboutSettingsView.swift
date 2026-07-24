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
            Text("Troubleshooting")
        } footer: {
            Text("Reset removes Harc's current Microphone and Screen & System Audio grants, opens System Settings, and then quits Harc. Reopen Harc and grant the prompts again.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
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

    // MARK: - Sub-views

    private var heroRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HarcBrand.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Harc")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Local-first speech-to-text for meetings.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Text(versionLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var updatesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.headline)
            Toggle("Check for updates automatically", isOn: $prefs.updateChecksEnabled)
            Text("Updates install in place via Sparkle; checks send nothing about you.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates") {
                    bridge.onCheckForUpdates?()
                }
                .disabled(bridge.onCheckForUpdates == nil)
                if let update = bridge.availableUpdate {
                    HStack(spacing: 4) {
                        Text("Harc \(update.version) available —")
                            .font(.subheadline)
                        if bridge.onInstallUpdate != nil {
                            Button("Install") { bridge.onInstallUpdate?() }
                                .buttonStyle(.link)
                                .font(.subheadline)
                        } else {
                            Link("View release", destination: update.url)
                                .font(.subheadline)
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
                .font(.headline)
            bullet("Apple Silicon native — runs on the Neural Engine via Core ML.")
            bullet("Speech-to-text by FluidAudio + Parakeet TDT, hosted in a separate daemon process so model load amortizes across recordings.")
            bullet("Audio is mixed from your microphone (AVAudioEngine) and system audio (ScreenCaptureKit) into a durable WAV — your meeting survives a crash.")
            bullet("Recordings are transcribed in rolling 60-second chunks during capture, so the transcript is ~90% done the moment you hit stop.")
            bullet("Diarization and speaker re-identification group the transcript by voice and remember speakers across meetings.")
            bullet("On-device summarization by Gemma 4 via MLX. The library is stored in GRDB/SQLite at ~/Library/Application Support/Harc.")
        }
        .padding(.vertical, 4)
    }

    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.green)
                Text("Local-first")
                    .font(.headline)
            }
            Text("No cloud STT. No external telemetry. No accounts. Every byte of audio, every transcript, and every summary stays on this Mac. Harc's only network use is downloading models once from Hugging Face — your audio and text never leave this Mac.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var footerRow: some View {
        HStack {
            Text("Made for macOS 26.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Spacer()
            Link("github.com/jkrack/Harc", destination: URL(string: "https://github.com/jkrack/Harc")!)
                .font(.caption)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }
}
