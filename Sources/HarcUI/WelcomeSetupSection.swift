import SwiftUI
import AVFoundation
import CoreGraphics
import HarcModels

/// Live state behind the Welcome flow's "Set up" step: speech-model
/// readiness (mirrored from the bridge by AppDelegate), the suggested
/// summarizer download, destination folder, and capture permissions.
@MainActor
public final class WelcomeSetupModel: ObservableObject {
    /// Mirrors `bridge.sttReady` / `bridge.sttReadinessText`.
    @Published public var sttReady: Bool = false
    @Published public var sttText: String = "Starting the speech engine…"
    /// Mirrors `bridge.sttDownloadProgress` — non-nil while the speech
    /// model is downloading and the daemon reports fractional progress.
    @Published public var sttProgress: Double? = nil
    @Published public private(set) var micGranted: Bool
    @Published public private(set) var screenAudioGranted: Bool
    @Published public private(set) var destinationDisplayPath: String

    public let prefs: HarcPreferences
    public let modelStore: ModelManagerStore
    public let suggestedSummarizer: ModelDescriptor?

    public init(prefs: HarcPreferences, modelStore: ModelManagerStore) {
        self.prefs = prefs
        self.modelStore = modelStore
        self.suggestedSummarizer = Self.suggestedSummarizer(ramGB: Self.physicalRAMGB())
        self.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        self.screenAudioGranted = CGPreflightScreenCaptureAccess()
        self.destinationDisplayPath = (prefs.destinationPath as NSString).abbreviatingWithTildeInPath
    }

    /// The tier to offer during onboarding: the best of Standard/Quality
    /// that fits this Mac's RAM. Higher tiers stay a deliberate choice in
    /// Settings → Models — onboarding shouldn't suggest a 16 GB download.
    public static func suggestedSummarizer(ramGB: Int) -> ModelDescriptor? {
        let candidates = ModelCatalog.descriptors(for: .summarizer)
            .filter { $0.tier == .standard || $0.tier == .quality }
            .filter { $0.recommendedRAMGB <= ramGB }
        return candidates.max { $0.recommendedRAMGB < $1.recommendedRAMGB }
            ?? ModelCatalog.descriptor(for: ModelCatalog.defaultSummarizerID)
    }

    public func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in self?.micGranted = granted }
        }
    }

    public func requestScreenAudioAccess() {
        // Triggers the Screen Recording prompt (system audio rides on it).
        // The grant lands after the user acts in System Settings; re-check
        // optimistically — the readiness panel stays the source of truth.
        CGRequestScreenCaptureAccess()
        screenAudioGranted = CGPreflightScreenCaptureAccess()
    }

    public func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.destinationFolderExists()
            ? prefs.destinationURL
            : FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let chosen = panel.url {
            prefs.destinationPath = chosen.path
            destinationDisplayPath = (chosen.path as NSString).abbreviatingWithTildeInPath
        }
    }

    public func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenAudioGranted = CGPreflightScreenCaptureAccess()
    }

    private static func physicalRAMGB() -> Int {
        max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)))
    }
}

/// The interactive body of the Welcome flow's "Set up" step.
struct WelcomeSetupSection: View {
    @ObservedObject var model: WelcomeSetupModel
    @ObservedObject var store: ModelManagerStore

    init(model: WelcomeSetupModel) {
        self.model = model
        self.store = model.modelStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            speechModelRow
            summarizerRow
            destinationRow
            permissionsRow
        }
        .onAppear { model.refreshPermissions() }
    }

    // MARK: Speech model (required, automatic)

    private var speechModelRow: some View {
        setupRow(
            icon: model.sttReady ? "checkmark.circle.fill" : "arrow.down.circle",
            iconColor: model.sttReady ? .green : .accentColor,
            title: "Speech model",
            detail: model.sttText
        ) {
            if !model.sttReady {
                if let progress = model.sttProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 96)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Summarizer (optional, offered)

    @ViewBuilder
    private var summarizerRow: some View {
        if let d = model.suggestedSummarizer {
            let state = store.state(of: d.id)
            setupRow(
                icon: state.isInstalled ? "checkmark.circle.fill" : "sparkles",
                iconColor: state.isInstalled ? .green : .purple,
                title: "Summaries + dictation modes (optional)",
                detail: state.isInstalled
                    ? "\(d.tierDisplayName) installed"
                    : "\(d.tierDisplayName) · \(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file)) — powers meeting summaries and dictation modes. More tiers in Settings → Models."
            ) {
                switch state {
                case .installed:
                    EmptyView()
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 96)
                case .verifying:
                    ProgressView()
                        .controlSize(.small)
                case .failed, .absent:
                    Button("Download") {
                        Task { try? await store.download(d.id) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Destination

    private var destinationRow: some View {
        setupRow(
            icon: "folder",
            iconColor: .secondary,
            title: "Recordings folder",
            detail: model.destinationDisplayPath
        ) {
            Button("Choose…") { model.chooseDestination() }
                .controlSize(.small)
        }
    }

    // MARK: Permissions

    private var permissionsRow: some View {
        setupRow(
            icon: "lock.shield",
            iconColor: .secondary,
            title: "Permissions",
            detail: "Microphone records you; Screen Recording captures the other side of a call."
        ) {
            HStack(spacing: 6) {
                if model.micGranted {
                    Label("Mic", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Grant mic") { model.requestMicAccess() }
                        .controlSize(.small)
                }
                if model.screenAudioGranted {
                    Label("Audio", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Grant screen audio") { model.requestScreenAudioAccess() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Row scaffold

    private func setupRow(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
