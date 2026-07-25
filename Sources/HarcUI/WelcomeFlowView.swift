import SwiftUI
import KeyboardShortcuts
import ServiceManagement

public struct WelcomeFlowStep: Identifiable {
    public let id: String
    public let eyebrow: String
    public let title: String
    public let body: String
    public let primaryPoint: String
    public let secondaryPoint: String
    public let symbolName: String
    public let tint: Color

    public init(
        id: String,
        eyebrow: String,
        title: String,
        body: String,
        primaryPoint: String,
        secondaryPoint: String,
        symbolName: String,
        tint: Color
    ) {
        self.id = id
        self.eyebrow = eyebrow
        self.title = title
        self.body = body
        self.primaryPoint = primaryPoint
        self.secondaryPoint = secondaryPoint
        self.symbolName = symbolName
        self.tint = tint
    }
}

@MainActor
public final class WelcomeFlowModel: ObservableObject {
    @Published public private(set) var selectedIndex: Int
    public let steps: [WelcomeFlowStep]

    public init(steps: [WelcomeFlowStep] = WelcomeFlowModel.defaultSteps, selectedIndex: Int = 0) {
        precondition(!steps.isEmpty, "WelcomeFlowModel requires at least one step")
        self.steps = steps
        self.selectedIndex = min(max(0, selectedIndex), steps.count - 1)
    }

    public var selectedStep: WelcomeFlowStep { steps[selectedIndex] }
    public var isFirstStep: Bool { selectedIndex == 0 }
    public var isLastStep: Bool { selectedIndex == steps.count - 1 }
    public var progressText: String { "\(selectedIndex + 1) of \(steps.count)" }

    public func goBack() {
        selectedIndex = max(0, selectedIndex - 1)
    }

    public func goForward() {
        selectedIndex = min(steps.count - 1, selectedIndex + 1)
    }

    public func select(_ step: WelcomeFlowStep) {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        selectedIndex = index
    }

    /// Position of a step, for the page-dot accessibility labels — a dot
    /// announced only as its title gives no sense of where you are.
    public func index(of step: WelcomeFlowStep) -> Int {
        steps.firstIndex(where: { $0.id == step.id }) ?? 0
    }

    public static let defaultSteps: [WelcomeFlowStep] = [
        WelcomeFlowStep(
            id: "canvas",
            eyebrow: "The canvas",
            title: "A workspace for captured thinking",
            body: "Harc opens to a focused Library canvas where recordings and people stay connected. Search across everything, jump into the transcript, then copy the context you need for an LLM.",
            primaryPoint: "Recordings are durable source material, not disposable clips.",
            secondaryPoint: "Speaker labels and search make an hour of audio easy to navigate.",
            symbolName: "rectangle.3.group",
            tint: .blue
        ),
        WelcomeFlowStep(
            id: "local",
            eyebrow: "Local first",
            title: "Private by design, fast on Apple Silicon",
            body: "Speech-to-text, diarization, summaries, and audio all stay on this Mac. Harc records to disk while it captures, then processes locally in rolling chunks.",
            primaryPoint: "No cloud STT, no external telemetry, no account requirement.",
            secondaryPoint: "Models are downloaded once from Hugging Face; your audio and text never leave this Mac.",
            symbolName: "lock.shield",
            tint: .teal
        ),
        WelcomeFlowStep(
            id: "dictation",
            eyebrow: "Dictation",
            title: "Speak anywhere, type nowhere",
            body: "Hold the dictation hotkey (⌃⌥D out of the box), speak, release — the text lands at your cursor in whatever app you're in. Modes can clean it up, turn it into an email, or answer a question about your selected text, all with the local model.",
            primaryPoint: "Inserting at the cursor needs the Accessibility permission — enable it below or later from Settings.",
            secondaryPoint: "Change the hotkey below; modes live in Settings.",
            symbolName: "mic.badge.plus",
            tint: .purple
        ),
        WelcomeFlowStep(
            id: "setup",
            eyebrow: "Set up",
            title: "Get the models and permissions in place",
            body: "Harc's speech model (~460 MB) downloads automatically in the background — recording works once it's ready. Summaries and dictation modes use a second, optional model you can grab now or later.",
            primaryPoint: "Everything below is one-time. Downloads come from Hugging Face; nothing you record ever leaves this Mac.",
            secondaryPoint: "You can skip any of this — each item is also reachable from Settings.",
            symbolName: "arrow.down.circle",
            tint: .indigo
        ),
        WelcomeFlowStep(
            id: "start",
            eyebrow: "Start",
            title: "Make the first capture boring",
            body: "Use the menu bar button or hotkey to start and stop. Harc saves the audio, transcript, JSON, and searchable library row.",
            primaryPoint: "Reliability beats live text. Stop when the meeting ends.",
            secondaryPoint: "Copy or paste the full transcript into your LLM when it is ready.",
            symbolName: "record.circle",
            tint: HarcBrand.live
        ),
    ]

    /// Step id that carries the "Enable Accessibility" call-to-action.
    public static let dictationStepID = "dictation"
    /// Step id that renders the interactive models/permissions section.
    public static let setupStepID = "setup"
    /// Final step id — carries the launch-at-login offer.
    public static let startStepID = "start"
}

public struct WelcomeFlowView: View {
    @StateObject private var model = WelcomeFlowModel()
    public let onFinish: () -> Void
    public let onSkip: () -> Void
    public let onOpenSettings: () -> Void
    /// Optional CTA on the dictation step — opens the Accessibility privacy
    /// pane. Never required; the step is fully skippable.
    public let onEnableAccessibility: (() -> Void)?
    /// Live state behind the "Set up" step (models, folder, permissions).
    /// Nil (previews/tests) renders the step as informational only.
    public let setup: WelcomeSetupModel?
    @State private var launchAtLogin = false

    public init(
        onFinish: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onEnableAccessibility: (() -> Void)? = nil,
        setup: WelcomeSetupModel? = nil
    ) {
        self.onFinish = onFinish
        self.onSkip = onSkip
        self.onOpenSettings = onOpenSettings
        self.onEnableAccessibility = onEnableAccessibility
        self.setup = setup
    }

    public var body: some View {
        HStack(spacing: 0) {
            visualPane
                .frame(width: 360)
            Divider()
            contentPane
                .frame(minWidth: 420, maxWidth: 520)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var visualPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            VStack(alignment: .leading, spacing: 18) {
                brandHeader
                Spacer(minLength: 8)
                canvasIllustration(step: model.selectedStep)
                Spacer(minLength: 8)
                stepRail
            }
            .padding(28)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HarcBrand.gradient)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Harc")
                    .font(.title3.weight(.semibold))
                Text("Meeting memory for your Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func canvasIllustration(step: WelcomeFlowStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(step.tint)
                    .frame(width: 8, height: 8)
                Text(step.eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: step.symbolName)
                    .font(.title3)
                    .foregroundStyle(step.tint)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(model.steps) { railStep in
                        Capsule()
                            .fill(railStep.id == step.id ? step.tint.opacity(0.75) : Color.secondary.opacity(0.18))
                            .frame(width: railStep.id == step.id ? 96 : 68, height: 8)
                    }
                }
                .frame(width: 104, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(step.tint.opacity(0.14))
                        .frame(height: 96)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: step.symbolName)
                                    .font(.system(size: 32, weight: .medium))
                                    .foregroundStyle(step.tint)
                                Text(step.title)
                                    .font(.caption.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.horizontal, 14)
                            }
                        )
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(index == 0 ? step.tint.opacity(0.55) : Color.secondary.opacity(0.2))
                                .frame(width: 26, height: 18)
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule()
                                    .fill(Color.primary.opacity(index == 0 ? 0.26 : 0.16))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(Color.secondary.opacity(0.16))
                                    .frame(width: index == 2 ? 84 : 128, height: 6)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var stepRail: some View {
        HStack(spacing: 7) {
            ForEach(model.steps) { step in
                Button {
                    model.select(step)
                } label: {
                    Circle()
                        .fill(step.id == model.selectedStep.id ? model.selectedStep.tint : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
                .help(step.title)
                .accessibilityLabel("\(step.title), step \(model.index(of: step) + 1) of \(model.steps.count)")
            }
        }
    }

    /// The body of the current step. Lifted out of `contentPane` so it can be
    /// wrapped in a ScrollView without the navigation row scrolling with it.
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.selectedStep.eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(model.selectedStep.tint)
            Text(model.selectedStep.title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.selectedStep.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                pointRow(model.selectedStep.primaryPoint, icon: "checkmark.circle.fill")
                pointRow(model.selectedStep.secondaryPoint, icon: "arrow.triangle.branch")
            }
            .padding(.top, 4)

            if model.selectedStep.id == WelcomeFlowModel.dictationStepID {
                VStack(alignment: .leading, spacing: 10) {
                    // Ready-to-use hotkey (ships with a ⌃⌥D default) —
                    // re-recordable right here so "hold the hotkey" is
                    // never a dead instruction.
                    KeyboardShortcuts.Recorder("Dictation hotkey", name: .pushToTalkDictation)
                    if let onEnableAccessibility {
                        Button {
                            onEnableAccessibility()
                        } label: {
                            Label("Enable Accessibility", systemImage: "accessibility")
                        }
                        .accessibilityIdentifier("harc.welcome.accessibility")
                    }
                }
            }

            if model.selectedStep.id == WelcomeFlowModel.setupStepID, let setup {
                WelcomeSetupSection(model: setup)
            }

            if model.selectedStep.id == WelcomeFlowModel.startStepID {
                Toggle("Launch Harc at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Text("A meeting recorder that isn't running misses the meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.progressText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip") {
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // accessibilityIdentifier is a UI-test hook, not a label —
                // it leaves AXDescription empty, so VoiceOver announced every
                // control in this flow as an unnamed "button".
                .accessibilityLabel("Skip setup")
                .accessibilityIdentifier("harc.welcome.skip")
            }
            .padding([.horizontal, .top], 28)

            // Scrolls independently of the Back/Next row below. Step content
            // is variable height — the Set up step in particular grows with
            // however many permissions and downloads it has to show. Without
            // a scroll container, a taller step silently pushes the navigation
            // off the bottom edge and the flow becomes impossible to advance.
            // The window is also resizable now, but that's the second guard;
            // this one holds even at the minimum size.
            ScrollView {
                stepContent
            }

            HStack(spacing: 10) {
                Button {
                    model.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(model.isFirstStep)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("harc.welcome.back")

                Spacer()

                if model.isLastStep {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .accessibilityLabel("Open Settings")
                    .accessibilityIdentifier("harc.welcome.settings")
                }

                Button {
                    if model.isLastStep {
                        onFinish()
                    } else {
                        model.goForward()
                    }
                } label: {
                    Label(model.isLastStep ? "Start Using Harc" : "Next", systemImage: model.isLastStep ? "checkmark" : "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(model.isLastStep ? "Start Using Harc" : "Next")
                .accessibilityIdentifier("harc.welcome.next")
            }
            .padding([.horizontal, .top], 28)

            // Honest acknowledgment when leaving setup behind an unfinished
            // download — recording works the moment the model lands.
            if model.isLastStep, let setup {
                WelcomeSTTFootnote(setup: setup)
                    .padding(.horizontal, 28)
            }
            Spacer(minLength: 20).frame(maxHeight: 28)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func pointRow(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(model.selectedStep.tint)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Observing wrapper so the last-step footnote live-updates (and disappears)
/// as the background speech-model download completes.
private struct WelcomeSTTFootnote: View {
    @ObservedObject var setup: WelcomeSetupModel

    var body: some View {
        if !setup.sttReady {
            Text("The speech model finishes downloading in the background — recording unlocks when it's ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
