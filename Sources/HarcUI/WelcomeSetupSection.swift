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
    @Published public private(set) var accessibilityGranted: Bool
    @Published public private(set) var destinationDisplayPath: String
    /// Set once the user grants Screen Recording in this process. macOS keeps
    /// the pre-grant answer until the app restarts, so the UI has to say so
    /// rather than let the user believe a working grant is broken.
    @Published public private(set) var screenAudioNeedsRelaunch: Bool = false

    public let prefs: HarcPreferences
    public let modelStore: ModelManagerStore
    public let suggestedSummarizer: ModelDescriptor?

    public init(prefs: HarcPreferences, modelStore: ModelManagerStore) {
        self.prefs = prefs
        self.modelStore = modelStore
        self.suggestedSummarizer = Self.suggestedSummarizer(ramGB: Self.physicalRAMGB())
        let snapshot = PermissionSnapshot.current()
        self.micGranted = snapshot.microphone
        self.screenAudioGranted = snapshot.screenCapture
        self.accessibilityGranted = snapshot.accessibility
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

    /// Ask for a grant the only way that can still produce a prompt.
    ///
    /// Each of these system prompts fires at most once per install. Calling
    /// the request API after that returns silently with nothing on screen —
    /// which is exactly how a "Grant" button turns into a button that appears
    /// broken. So when in-process prompting is spent, open the System
    /// Settings pane instead. Every path here puts *something* in front of
    /// the user.
    public func request(_ service: RecordingPermissionService) {
        guard !service.isGranted else {
            refreshPermissions()
            return
        }

        switch service {
        case .microphone where service.canPromptInProcess:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.micGranted = granted
                    if !granted {
                        // Denied at the prompt — the only way back is System
                        // Settings, and there will never be another prompt.
                        RecordingPermissionRepair.openSettings(for: .microphone)
                    }
                }
            }
        case .screenCapture:
            // Fires the prompt on a first ask and is a no-op afterwards, so
            // pair it with the Settings pane rather than trusting it alone.
            CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                RecordingPermissionRepair.openSettings(for: .screenCapture)
            }
            refreshPermissions()
        default:
            RecordingPermissionRepair.openSettings(for: service)
        }
    }

    public func requestMicAccess() { request(.microphone) }
    public func requestScreenAudioAccess() { request(.screenCapture) }
    public func requestAccessibilityAccess() { request(.accessibility) }

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

    /// Re-read every grant. Called on appear *and* whenever Harc becomes
    /// active — the user grants permissions in System Settings, so the moment
    /// they switch back is the moment this view is most likely to be wrong.
    public func refreshPermissions() {
        let snapshot = PermissionSnapshot.current()
        if snapshot.screenCapture, !screenAudioGranted {
            // Granted while we were running: the process keeps the old answer
            // until relaunch, so capture will still fall back to mic-only.
            screenAudioNeedsRelaunch = true
        }
        micGranted = snapshot.microphone
        screenAudioGranted = snapshot.screenCapture
        accessibilityGranted = snapshot.accessibility
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
                    : "\(d.tierDisplayName) · \(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file)) — powers meeting summaries and dictation modes. Downloaded from Hugging Face, version-pinned and checksum-verified. More tiers in Settings → Models."
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

    @ViewBuilder
    private var permissionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionGrantRow(.microphone, granted: model.micGranted)
            permissionGrantRow(.screenCapture, granted: model.screenAudioGranted)
            permissionGrantRow(.accessibility, granted: model.accessibilityGranted)

            if model.screenAudioNeedsRelaunch {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Screen Recording is granted, but macOS keeps the old answer until Harc restarts. Quit and reopen to capture system audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Quit & Reopen") {
                        RecordingPermissionRepair.scheduleRelaunch()
                        NSApp.terminate(nil)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// One line per permission. Granted rows collapse to a checkmark and the
    /// name — the explanation only earns its space when the user still has a
    /// decision to make about that permission.
    private func permissionGrantRow(
        _ service: RecordingPermissionService,
        granted: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.shield")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName)
                    .font(.caption.weight(.medium))
                if !granted {
                    Text(service.purpose)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !granted {
                // Label the action honestly: when the system prompt is spent,
                // this opens System Settings and the button should say so.
                Button(service.canPromptInProcess ? "Grant" : "Open Settings") {
                    model.request(service)
                }
                .controlSize(.small)
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
