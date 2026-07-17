import SwiftUI

public struct AboutSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @ObservedObject private var updateChecker = UpdateChecker.shared

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
            Text("Checks GitHub for new releases; sends nothing about you.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates") {
                    Task { await updateChecker.checkNow() }
                }
                .disabled(updateChecker.manualCheckStatus == .checking)
                manualCheckResult
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var manualCheckResult: some View {
        switch updateChecker.manualCheckStatus {
        case .checking:
            Text("Checking…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        case .upToDate:
            Text("You're up to date.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        case .updateAvailable(let update):
            HStack(spacing: 4) {
                Text("Harc \(update.version) available —")
                    .font(.subheadline)
                Link("View release", destination: update.url)
                    .font(.subheadline)
            }
        case .failed:
            Text("Couldn't reach GitHub.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        case nil:
            EmptyView()
        }
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
            Text("No cloud STT. No external telemetry. No accounts. Every byte of audio, every transcript, and every summary stays on this Mac. Harc cannot phone home because it has no home to call.")
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
