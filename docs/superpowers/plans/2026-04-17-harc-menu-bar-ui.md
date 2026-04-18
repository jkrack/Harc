# Harc Menu Bar Popover UI Implementation Plan (Plan 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plan 4's `NSMenu` with a SwiftUI popover attached to the menu-bar `NSStatusItem`, giving users a real recording UI: prominent Start/Stop button, recording timer, scrollable list of recent recordings, a separate detail window for full transcripts, a Settings window for preferences, and a global hotkey. Visual language follows the Stitch "Auditory Lens" design system (Tech-Lavender + Deep Cobalt palette, glass materials, no-line section separation).

**Architecture:** New SwiftPM library `HarcUI` owns design-system tokens, shared view modifiers, and reusable views. The app target gains a `RecordingState` ObservableObject that AppDelegate mutates as the recording lifecycle proceeds — the SwiftUI popover and detail windows observe it. The popover is an `NSPopover` anchored to the status item; Transcription Detail and Settings open as separate `NSWindow`s. Recording files are enumerated by a `RecordingsIndex` service that scans the destination folder (no database yet — Plan 6 adds GRDB). Global hotkey uses [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).

**Tech Stack:** Swift 6.0, SwiftPM, SwiftUI, AppKit (`NSPopover`, `NSStatusItem`, `NSWindow`, `NSViewController`), KeyboardShortcuts 2.3+, Combine (`@Published`, `AsyncStream` bridge). macOS 14+.

---

## Prerequisites

- Plans 1–4 complete. Latest commit `4b207d5 fix: add @preconcurrency import AVFAudio to silence Xcode 26 warnings`. `swift test` passes 46 tests in 20 suites. The app runs end-to-end: Start → record → Stop produces `.wav` + `.txt` + `.json` in `~/Documents/Harc/`.
- Plan 4's `RecordingSession`, `ChunkedTranscriber`, `DaemonLauncher`, `HarcSTTClient` all ready to be driven by the new UI.
- Recordings from Plan 4 smoke testing already exist in `~/Documents/Harc/2026/2026-04-17/` — Plan 5's list UI will render them on first run.

## Scope Boundary

**In:**
- SwiftUI popover replacing the current `NSMenu` (Start/Stop, timer, recent list)
- Transcription Detail window (full transcript, copy, reveal, delete)
- Settings window (destination folder, diarization toggle, hotkey binding)
- Global hotkey via KeyboardShortcuts library
- Live transcript preview in the popover during recording
- Eager daemon launch on app start (so ⌘R doesn't wait for model load)

**Out (later plans):**
- SQLite/GRDB-backed library with FTS search (Plan 6)
- Rename, pin, soft-delete, multi-select of recordings (Plan 6)
- Auto-paste into frontmost app (Plan 7?)
- Cross-chunk speaker stitching (open decision, future)
- Onboarding UI / TCC permission helper (polish pass)

## File Structure

After Plan 5:

```
Harc/
├── Package.swift                                       (modified — +HarcUI product, +KeyboardShortcuts dep)
├── project.yml                                         (modified — +HarcUI dep on Harc target)
├── Sources/
│   ├── HarcUI/                                         (new library target)
│   │   ├── DesignTokens.swift                          T1
│   │   ├── GlassBackground.swift                       T1
│   │   ├── RecordingState.swift                        T2
│   │   ├── RecordingsIndex.swift                       T4
│   │   ├── PopoverRootView.swift                       T2 (stub) + T3/T4 (content)
│   │   ├── RecordingControlsView.swift                 T3
│   │   ├── RecentRecordingsView.swift                  T4
│   │   ├── TranscriptionDetailView.swift               T5
│   │   ├── SettingsView.swift                          T6
│   │   └── HotkeyNames.swift                           T7
│   └── (existing HarcCore, HarcAudio, HarcClient, HarcSTT unchanged)
├── HarcApp/
│   ├── AppDelegate.swift                               (modified across T2, T5, T6, T7, T8)
│   └── WindowControllers/
│       ├── TranscriptionDetailWindowController.swift   T5
│       └── SettingsWindowController.swift              T6
└── Tests/
    └── HarcUITests/                                    (new test target)
        ├── RecordingStateTests.swift                   T2
        ├── RecordingsIndexTests.swift                  T4
        └── DesignTokensSmokeTests.swift                T1
```

### Responsibilities

- **`DesignTokens`** — Palette (tech lavender `#0058BB`, primary container `#6C9FFF`, etc.), typography scale (Display/Title/Body/Label), spacing scale, corner radii. Static let constants on a `HarcDesign` namespace enum, plus `Color` extensions for named palette colors.
- **`GlassBackground`** — SwiftUI view modifier wrapping `.background(.ultraThinMaterial)` with rounded corners + optional ambient shadow. The "Glass & Gradient" rule from the design system.
- **`RecordingState`** — `@MainActor public final class RecordingState: ObservableObject`. `@Published` properties for `isRecording: Bool`, `recordingStartedAt: Date?`, `livePreviewText: String`, `lastResult: RecordingResult?`. AppDelegate calls `startRecording()` / `stopRecording()` on it; the class internally owns/drives the `RecordingSession` lifecycle and subscribes to the transcriber's `updates` stream.
- **`RecordingsIndex`** — filesystem enumerator. Scans the destination folder hierarchy for `.wav` files, pairs each with its `.txt` / `.json` siblings if present, returns `[RecordingEntry]` newest-first. `refresh()` reads from disk; no caching within the instance (simple, fast enough for hundreds of files).
- **`PopoverRootView`** — top-level SwiftUI view shown inside the popover. Lays out recording controls + recent recordings list. Observes `RecordingState` and `RecordingsIndex`.
- **`RecordingControlsView`** — the Start/Stop button + timer + live preview area. Subscribes to `RecordingState`.
- **`RecentRecordingsView`** — scrollable list of recent recordings with icon + title + timestamp + three-dot menu. Clicking opens the Transcription Detail window.
- **`TranscriptionDetailView`** — full transcript, Copy button (→ `NSPasteboard`), Reveal in Finder, Delete.
- **`SettingsView`** — destination folder picker, diarization toggle, chunk duration slider, hotkey binding via `KeyboardShortcuts.Recorder`.
- **`HotkeyNames`** — extends `KeyboardShortcuts.Name` with `toggleRecording` name.
- **`TranscriptionDetailWindowController` / `SettingsWindowController`** — thin AppKit wrappers that host the SwiftUI views in `NSWindow`s.
- **`AppDelegate`** — creates the `RecordingState` + `RecordingsIndex`, installs them into SwiftUI via `.environmentObject`, wires the popover + status bar, registers the hotkey, calls `DaemonLauncher.ensureRunning()` on app start.

### Why split this way

- `HarcUI` is a pure-UI library with no knowledge of capture hardware or IPC. It imports `HarcAudio` + `HarcClient` only to receive types (`RecordingResult`, `TranscribeResult`) — state mutation flows through `RecordingState`.
- View models (`RecordingState`, `RecordingsIndex`) are `@MainActor` so SwiftUI bindings are thread-safe without extra ceremony.
- Each view is one concern (controls, list, detail, settings). Files stay under ~150 lines.

## Testing Notes

- UI layout isn't unit-tested — we rely on the compiler for type-correctness and manual smoke tests for visual correctness.
- `RecordingState` has logic tests (start → isRecording == true, stop → resets, live preview updates).
- `RecordingsIndex` has tests against a temp directory populated with fake `.wav`/`.txt`/`.json` trios.
- `DesignTokens` has one smoke test (values are non-default — catches accidental nil Color bugs).
- Manual smoke is the real verification: run the app, click the menu bar icon, see the popover, start a recording, etc.

---

### Task 1: `HarcUI` target + design tokens + glass background

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Modify: `/Users/jlane/GitHub/Harc/project.yml`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/DesignTokens.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/GlassBackground.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/DesignTokensSmokeTests.swift`

- [ ] **Step 1: Rewrite `Package.swift`** — add `HarcUI` library + test target + KeyboardShortcuts dependency (used in T7).

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcAudio", targets: ["HarcAudio"]),
        .library(name: "HarcClient", targets: ["HarcClient"]),
        .library(name: "HarcUI", targets: ["HarcUI"]),
        .executable(name: "harc-stt", targets: ["HarcSTT"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.13.5")
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            from: "2.3.0"
        ),
    ],
    targets: [
        .target(name: "HarcCore"),
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore", "HarcClient"]
        ),
        .target(
            name: "HarcClient",
            dependencies: ["HarcCore"]
        ),
        .target(
            name: "HarcUI",
            dependencies: [
                "HarcCore",
                "HarcAudio",
                "HarcClient",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "HarcSTT",
            dependencies: [
                "HarcCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "HarcCoreTests", dependencies: ["HarcCore"]),
        .testTarget(
            name: "HarcSTTTests",
            dependencies: ["HarcSTT", "HarcCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HarcAudioTests",
            dependencies: ["HarcAudio", "HarcCore", "HarcClient"]
        ),
        .testTarget(
            name: "HarcClientTests",
            dependencies: ["HarcClient", "HarcCore"]
        ),
        .testTarget(
            name: "HarcUITests",
            dependencies: ["HarcUI", "HarcCore"]
        ),
    ]
)
```

- [ ] **Step 2: Modify `project.yml`** — add HarcUI as a fourth product dep under `targets.Harc.dependencies:`.

The existing block reads:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
      - package: HarcCore
        product: HarcClient
```
Change to:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
      - package: HarcCore
        product: HarcClient
      - package: HarcCore
        product: HarcUI
```

- [ ] **Step 3: Write `Sources/HarcUI/DesignTokens.swift`**

```swift
import SwiftUI

/// Design tokens for the "Auditory Lens" design system.
/// Palette + typography + spacing + corner radii.
public enum HarcDesign {
    // MARK: Palette

    /// Primary action color — Tech-Lavender → Deep Cobalt base.
    public static let primary = Color(red: 0.0, green: 0x58/255.0, blue: 0xBB/255.0)
    public static let primaryContainer = Color(red: 0x6C/255.0, green: 0x9F/255.0, blue: 1.0)
    /// Accent/creative tint — Tertiary purple for AI-generated features.
    public static let tertiary = Color(red: 0x88/255.0, green: 0x3C/255.0, blue: 0x93/255.0)
    /// Error/danger color — reserved for destructive actions only.
    public static let error = Color(red: 0xB3/255.0, green: 0x1B/255.0, blue: 0x25/255.0)

    /// On-surface text — soft dark, NOT pure black (per "Don't use #000000" rule).
    public static let onSurface = Color(red: 0x2D/255.0, green: 0x2F/255.0, blue: 0x33/255.0)
    public static let onSurfaceVariant = Color(red: 0x5A/255.0, green: 0x5B/255.0, blue: 0x60/255.0)
    public static let outlineVariant = Color(red: 0xAC/255.0, green: 0xAD/255.0, blue: 0xB1/255.0)

    /// Primary gradient for hero actions (135-degree angle).
    public static let primaryGradient = LinearGradient(
        colors: [primary, primaryContainer],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Corner radii

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let full: CGFloat = 9999
    }

    // MARK: Spacing — base 4px grid

    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    // MARK: Typography

    public enum Font {
        /// Display — editorial hero, tight letter-spacing, bold.
        public static let displayMd = SwiftUI.Font.system(size: 28, weight: .bold, design: .default)
        /// Title — primary anchor for sections.
        public static let titleLg = SwiftUI.Font.system(size: 18, weight: .semibold, design: .default)
        public static let titleSm = SwiftUI.Font.system(size: 14, weight: .semibold, design: .default)
        /// Body — meeting transcripts, dense readable text.
        public static let bodyMd = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        public static let bodySm = SwiftUI.Font.system(size: 11, weight: .regular, design: .default)
        /// Label — all-caps metadata, technical pro-app feel.
        public static let labelMd = SwiftUI.Font.system(size: 11, weight: .medium, design: .default)
    }
}

public extension Color {
    /// Convenience on `Color` for design-system palette access.
    static let harcPrimary = HarcDesign.primary
    static let harcPrimaryContainer = HarcDesign.primaryContainer
    static let harcTertiary = HarcDesign.tertiary
    static let harcError = HarcDesign.error
    static let harcOnSurface = HarcDesign.onSurface
    static let harcOnSurfaceVariant = HarcDesign.onSurfaceVariant
    static let harcOutlineVariant = HarcDesign.outlineVariant
}
```

- [ ] **Step 4: Write `Sources/HarcUI/GlassBackground.swift`**

```swift
import SwiftUI

/// Glass-morphism background modifier. Matches the design system's "Glass & Gradient"
/// rule: translucent Material with rounded corners and ambient shadow.
public struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat
    let material: Material

    public init(cornerRadius: CGFloat = HarcDesign.Radius.lg, material: Material = .regularMaterial) {
        self.cornerRadius = cornerRadius
        self.material = material
    }

    public func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 32, x: 0, y: 8)
    }
}

public extension View {
    /// Applies the glass background treatment (translucent material + rounded corners + ambient shadow).
    func glassBackground(cornerRadius: CGFloat = HarcDesign.Radius.lg) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
```

- [ ] **Step 5: Write the smoke test `Tests/HarcUITests/DesignTokensSmokeTests.swift`**

```swift
import Testing
import SwiftUI
@testable import HarcUI

@Suite("Design tokens smoke")
struct DesignTokensSmokeTests {
    @Test("spacing tokens are monotonic")
    func spacingMonotonic() {
        #expect(HarcDesign.Space.xxs < HarcDesign.Space.xs)
        #expect(HarcDesign.Space.xs < HarcDesign.Space.sm)
        #expect(HarcDesign.Space.sm < HarcDesign.Space.md)
        #expect(HarcDesign.Space.md < HarcDesign.Space.lg)
        #expect(HarcDesign.Space.lg < HarcDesign.Space.xl)
    }

    @Test("corner radii are monotonic")
    func radiusMonotonic() {
        #expect(HarcDesign.Radius.sm < HarcDesign.Radius.md)
        #expect(HarcDesign.Radius.md < HarcDesign.Radius.lg)
        #expect(HarcDesign.Radius.lg < HarcDesign.Radius.xl)
        #expect(HarcDesign.Radius.xl < HarcDesign.Radius.full)
    }
}
```

- [ ] **Step 6: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: `Build complete!` (first build fetches KeyboardShortcuts — ~2 min), 48 tests in 21 suites passed (46 prior + 2 new).

- [ ] **Step 7: Regenerate Xcode project and verify app still builds**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate 2>&1 | tail -3
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Package.resolved project.yml Sources/HarcUI Tests/HarcUITests
git commit -m "feat: HarcUI library with design tokens + glass background + KeyboardShortcuts dep"
```

---

### Task 2: `RecordingState` view model + `NSPopover` shell

Replaces Plan 4's `NSMenu` with an `NSPopover` hosting a SwiftUI view. `RecordingState` is the binding between AppDelegate's recording lifecycle and the SwiftUI popover.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingState.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PopoverRootView.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/RecordingStateTests.swift`

- [ ] **Step 1: Write the failing test `Tests/HarcUITests/RecordingStateTests.swift`**

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcUI

@Suite("RecordingState")
@MainActor
struct RecordingStateTests {
    @Test("starts idle")
    func startsIdle() {
        let state = RecordingState()
        #expect(state.isRecording == false)
        #expect(state.recordingStartedAt == nil)
        #expect(state.livePreviewText.isEmpty)
        #expect(state.lastResult == nil)
    }

    @Test("markStarted sets isRecording and startedAt")
    func markStarted() {
        let state = RecordingState()
        let now = Date()
        state.markStarted(at: now)
        #expect(state.isRecording == true)
        #expect(state.recordingStartedAt == now)
        #expect(state.livePreviewText.isEmpty)
    }

    @Test("markStopped resets recording flags and stores result URL")
    func markStopped() {
        let state = RecordingState()
        state.markStarted(at: Date())
        state.livePreviewText = "partial transcript"

        let wavURL = URL(fileURLWithPath: "/tmp/fake.wav")
        state.markStopped(wavURL: wavURL, txtURL: nil, jsonURL: nil)

        #expect(state.isRecording == false)
        #expect(state.recordingStartedAt == nil)
        #expect(state.livePreviewText.isEmpty)
        #expect(state.lastResult?.wavURL == wavURL)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingStateTests 2>&1 | tail -15
```

Expected: `RecordingState` not found.

- [ ] **Step 3: Write `Sources/HarcUI/RecordingState.swift`**

```swift
import Foundation
import Combine
import HarcAudio

/// Binding between AppDelegate's recording lifecycle and the SwiftUI popover.
/// AppDelegate mutates this on its own thread via the Main actor; SwiftUI views observe it.
@MainActor
public final class RecordingState: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingStartedAt: Date? = nil
    @Published public var livePreviewText: String = ""
    @Published public private(set) var lastResult: RecordingResult? = nil

    public init() {}

    public func markStarted(at date: Date) {
        isRecording = true
        recordingStartedAt = date
        livePreviewText = ""
    }

    public func markStopped(wavURL: URL, txtURL: URL?, jsonURL: URL?) {
        isRecording = false
        recordingStartedAt = nil
        livePreviewText = ""
        lastResult = RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    public func appendPreview(_ text: String) {
        livePreviewText = text
    }
}
```

- [ ] **Step 4: Write a stub `Sources/HarcUI/PopoverRootView.swift`**

This file is expanded in Tasks 3 and 4. For Task 2 it's a minimal view showing the Start/Stop button hooked to `RecordingState` — just enough to prove the popover wiring.

```swift
import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState

    /// Closure AppDelegate wires in; called when user hits Start or Stop.
    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(spacing: HarcDesign.Space.md) {
            Text("Harc")
                .font(HarcDesign.Font.titleLg)
                .foregroundStyle(Color.harcOnSurface)

            Button(action: onToggle) {
                Text(state.isRecording ? "Stop Recording" : "Start Recording")
                    .font(HarcDesign.Font.titleSm)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(state.isRecording ? Color.harcError : HarcDesign.primaryGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 360)
    }
}
```

- [ ] **Step 5: Rewrite `HarcApp/AppDelegate.swift`** — replace `NSMenu` with `NSPopover` hosting `PopoverRootView`.

```swift
import AppKit
import SwiftUI
import HarcAudio
import HarcClient
import HarcUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()
    private let state = RecordingState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self

        let root = PopoverRootView(onToggle: { [weak self] in
            Task { await self?.toggleRecording() }
        })
        .environmentObject(state)

        pop.contentViewController = NSHostingController(rootView: root)
        pop.contentSize = NSSize(width: 360, height: 120)

        self.statusItem = item
        self.popover = pop
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func toggleRecording() async {
        if state.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard session == nil else { return }

        updateMenuBarIcon(recording: true)
        state.markStarted(at: Date())

        do {
            _ = try await launcher.ensureRunning()
            let client = HarcSTTClient()
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: true,
                chunkDurationSeconds: 60.0
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: RecordingDestination.defaultBaseDirectory()),
                transcriber: transcriber
            )
            self.session = session
            try await session.start(at: state.recordingStartedAt ?? Date())
        } catch {
            presentError(error)
            resetAfterFailure()
        }
    }

    private func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stop()
            state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
            notifyRecordingSaved(result: result)
        } catch {
            presentError(error)
        }
        resetAfterFailure()
    }

    private func resetAfterFailure() {
        session = nil
        if state.isRecording {
            state.markStopped(
                wavURL: URL(fileURLWithPath: "/dev/null"),
                txtURL: nil,
                jsonURL: nil
            )
        }
        updateMenuBarIcon(recording: false)
    }

    private func updateMenuBarIcon(recording: Bool, on item: NSStatusItem? = nil) {
        let target = item ?? statusItem
        guard let target else { return }
        let symbol = recording ? "record.circle.fill" : "waveform"
        let label = recording ? "Harc — recording" : "Harc"
        target.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    private func notifyRecordingSaved(result: RecordingResult) {
        let alert = NSAlert()
        alert.messageText = "Recording saved"
        if result.txtURL != nil {
            alert.informativeText = "Audio, transcript, and structured JSON written next to each other.\n\n\(result.wavURL.path)"
        } else {
            alert.informativeText = result.wavURL.path
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([result.wavURL])
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
```

- [ ] **Step 6: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingStateTests 2>&1 | tail -15
swift test 2>&1 | tail -5
```

Expected: `RecordingStateTests` passes 3 tests. Full suite: 51 tests in 22 suites.

- [ ] **Step 7: Rebuild Xcode project + app build sanity**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate 2>&1 | tail -3
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The app still launches, but the menu-bar icon now opens an `NSPopover` instead of an `NSMenu`.

- [ ] **Step 8: Smoke test — open the popover**

```bash
cd /Users/jlane/GitHub/Harc
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Click the waveform icon in the menu bar — a small popover should appear with "Harc" title and a gradient "Start Recording" button. Click outside to dismiss. Click the icon again to re-open. No crashes, no lingering windows on quit.

Known limitation: the popover's "Start Recording" button works for the recording flow, but doesn't yet show the timer or the recent list — those come in Tasks 3 and 4.

- [ ] **Step 9: Commit**

```bash
git add Sources/HarcUI/RecordingState.swift \
        Sources/HarcUI/PopoverRootView.swift \
        HarcApp/AppDelegate.swift \
        Tests/HarcUITests/RecordingStateTests.swift
git commit -m "feat: NSPopover shell hosting SwiftUI PopoverRootView + RecordingState view model"
```

---

### Task 3: `RecordingControlsView` — timer, live preview, gradient button

Adds a proper header, Start/Stop button with gradient, elapsed-time display, and live-preview area that updates while recording.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingControlsView.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PopoverRootView.swift`

- [ ] **Step 1: Write `Sources/HarcUI/RecordingControlsView.swift`**

```swift
import SwiftUI

/// The top half of the popover: app header, live transcript preview, big Start/Stop button.
public struct RecordingControlsView: View {
    @EnvironmentObject private var state: RecordingState
    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            header
            previewArea
            toggleButton
        }
    }

    private var header: some View {
        HStack {
            Text("Harc")
                .font(HarcDesign.Font.titleLg)
                .foregroundStyle(Color.harcOnSurface)
            Spacer()
            if state.isRecording {
                HStack(spacing: HarcDesign.Space.xxs) {
                    Circle()
                        .fill(Color.harcError)
                        .frame(width: 8, height: 8)
                    Text(elapsedText)
                        .font(HarcDesign.Font.labelMd.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
            }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if state.isRecording {
            ScrollView {
                Text(state.livePreviewText.isEmpty ? "Listening…" : state.livePreviewText)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(state.livePreviewText.isEmpty ? Color.harcOnSurfaceVariant : Color.harcOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HarcDesign.Space.sm)
            }
            .frame(height: 80)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
        } else {
            EmptyView()
        }
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            Text(state.isRecording ? "Stop Recording" : "Start Recording")
                .font(HarcDesign.Font.titleSm)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    state.isRecording
                        ? AnyShapeStyle(Color.harcError)
                        : AnyShapeStyle(HarcDesign.primaryGradient),
                    in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .onChange(of: state.isRecording) { _, isRecording in
            if isRecording {
                startTicker()
            } else {
                stopTicker()
            }
        }
        .onAppear {
            if state.isRecording { startTicker() }
        }
    }

    private func startTicker() {
        updateElapsed()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in updateElapsed() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsedText = "0:00"
    }

    private func updateElapsed() {
        guard let start = state.recordingStartedAt else {
            elapsedText = "0:00"
            return
        }
        let seconds = Int(Date().timeIntervalSince(start))
        let m = seconds / 60
        let s = seconds % 60
        elapsedText = String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Rewrite `Sources/HarcUI/PopoverRootView.swift`** to host the new controls

```swift
import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 360)
    }
}
```

- [ ] **Step 3: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

Launch the app, click the menu bar icon. You should see the "Harc" title, the Start Recording button (gradient purple→blue). Click Start — the button should flip to red "Stop Recording" and a timer should appear at top-right, ticking 0:01, 0:02, etc. No live preview text yet (Task 8 connects the transcriber's `updates` stream).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/RecordingControlsView.swift Sources/HarcUI/PopoverRootView.swift
git commit -m "feat: RecordingControlsView with timer, live preview placeholder, gradient button"
```

---

### Task 4: `RecordingsIndex` + `RecentRecordingsView`

Scans the destination folder for past recordings and shows them as a scrollable list under the controls.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingsIndex.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecentRecordingsView.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PopoverRootView.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/RecordingsIndexTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import HarcUI

@Suite("RecordingsIndex")
@MainActor
struct RecordingsIndexTests {
    private func tempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-idx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func fakeRecording(base: URL, year: String, day: String, time: String, withSiblings: Bool) throws -> URL {
        let dir = base.appendingPathComponent(year).appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("\(time).wav")
        try "fake".write(to: wav, atomically: true, encoding: .utf8)
        if withSiblings {
            try "hello world\n".write(to: dir.appendingPathComponent("\(time).txt"), atomically: true, encoding: .utf8)
            try "{}".write(to: dir.appendingPathComponent("\(time).json"), atomically: true, encoding: .utf8)
        }
        return wav
    }

    @Test("refresh returns recordings sorted newest-first")
    func newestFirst() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-15", time: "10-00-00", withSiblings: true)
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "09-30-15", withSiblings: true)
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-16", time: "14-22-00", withSiblings: false)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()

        #expect(index.entries.count == 3)
        #expect(index.entries[0].date.contains("2026-04-17"))
        #expect(index.entries[1].date.contains("2026-04-16"))
        #expect(index.entries[2].date.contains("2026-04-15"))
    }

    @Test("entry includes txt preview when sibling exists")
    func textPreview() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00", withSiblings: true)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()
        let entry = try #require(index.entries.first)
        #expect(entry.preview?.contains("hello world") == true)
    }

    @Test("entries without siblings still appear with nil preview")
    func missingSiblings() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00", withSiblings: false)

        let index = RecordingsIndex(baseDirectory: base)
        index.refresh()
        let entry = try #require(index.entries.first)
        #expect(entry.preview == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingsIndexTests 2>&1 | tail -15
```

Expected: `RecordingsIndex` not found.

- [ ] **Step 3: Write `Sources/HarcUI/RecordingsIndex.swift`**

```swift
import Foundation
import Combine

/// A row in the recordings list. `wavURL` is the canonical key; `txtURL`/`jsonURL`
/// may be nil for recordings where transcription failed or is still in flight.
public struct RecordingEntry: Identifiable, Hashable, Sendable {
    public let id: URL        // wavURL
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?
    public let date: String   // "2026-04-17 09:30:15"
    public let preview: String?  // first ~120 chars of the .txt, if present
}

/// Scans the destination folder on demand for `.wav` recordings + siblings.
/// Plan 6 will replace this with a GRDB-backed index + FTS search.
@MainActor
public final class RecordingsIndex: ObservableObject {
    @Published public private(set) var entries: [RecordingEntry] = []

    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func refresh() {
        let fm = FileManager.default
        var found: [RecordingEntry] = []

        guard let yearDirs = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }

        for yearDir in yearDirs where isDirectory(yearDir) {
            guard let dayDirs = try? fm.contentsOfDirectory(
                at: yearDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for dayDir in dayDirs where isDirectory(dayDir) {
                guard let files = try? fm.contentsOfDirectory(
                    at: dayDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for wav in files where wav.pathExtension.lowercased() == "wav" {
                    let stem = wav.deletingPathExtension().lastPathComponent
                    let parent = wav.deletingLastPathComponent()
                    let txt = parent.appendingPathComponent("\(stem).txt")
                    let json = parent.appendingPathComponent("\(stem).json")

                    let txtExists = fm.fileExists(atPath: txt.path)
                    let jsonExists = fm.fileExists(atPath: json.path)

                    let day = dayDir.lastPathComponent
                    let dateString = "\(day) \(stem.replacingOccurrences(of: "-", with: ":"))"

                    let preview: String?
                    if txtExists, let text = try? String(contentsOf: txt, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        preview = String(trimmed.prefix(120))
                    } else {
                        preview = nil
                    }

                    found.append(RecordingEntry(
                        id: wav,
                        wavURL: wav,
                        txtURL: txtExists ? txt : nil,
                        jsonURL: jsonExists ? json : nil,
                        date: dateString,
                        preview: preview
                    ))
                }
            }
        }

        // Newest first by date string (YYYY-MM-DD HH:MM:SS sorts lexicographically).
        found.sort { $0.date > $1.date }
        entries = found
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
```

- [ ] **Step 4: Write `Sources/HarcUI/RecentRecordingsView.swift`**

```swift
import SwiftUI

public struct RecentRecordingsView: View {
    @EnvironmentObject private var index: RecordingsIndex

    /// Called when the user clicks a row.
    let onOpen: (RecordingEntry) -> Void

    public init(onOpen: @escaping (RecordingEntry) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("Recent")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1.2)

            if index.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(index.entries.prefix(8)) { entry in
                            row(for: entry)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var emptyState: some View {
        Text("No recordings yet. Press Start Recording to begin.")
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurfaceVariant)
            .padding(.vertical, HarcDesign.Space.sm)
    }

    private func row(for entry: RecordingEntry) -> some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.harcPrimary)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    if let preview = entry.preview, !preview.isEmpty {
                        Text(preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .lineLimit(2)
                    } else {
                        Text("(no transcript)")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.vertical, HarcDesign.Space.xs)
            .padding(.horizontal, HarcDesign.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 5: Rewrite `Sources/HarcUI/PopoverRootView.swift`**

```swift
import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var index: RecordingsIndex

    let onToggle: () -> Void
    let onOpen: (RecordingEntry) -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (RecordingEntry) -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
    }
}
```

- [ ] **Step 6: Update `HarcApp/AppDelegate.swift`** to create a `RecordingsIndex` and pass it into the SwiftUI view.

Find the existing `private let state = RecordingState()` declaration, ADD below it:

```swift
    private let recordingsIndex = RecordingsIndex(baseDirectory: RecordingDestination.defaultBaseDirectory())
```

In `applicationDidFinishLaunching`, after `pop.delegate = self`, REPLACE the old `let root = ...` line with:

```swift
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] entry in
                self?.openDetail(for: entry)
            }
        )
        .environmentObject(state)
        .environmentObject(recordingsIndex)
```

Update the `pop.contentSize` line to:
```swift
        pop.contentSize = NSSize(width: 400, height: 400)
```

ADD a new method near the bottom of AppDelegate (stubbed for Task 5, which wires the detail window):

```swift
    private func openDetail(for entry: RecordingEntry) {
        // Transcription detail window lands in Task 5.
        // For now, just reveal the recording in Finder on click so the click does something visible.
        NSWorkspace.shared.activateFileViewerSelecting([entry.wavURL])
    }
```

After a successful `stopRecording()` call (inside the `do` block, after `notifyRecordingSaved(result:)`), ADD:

```swift
            recordingsIndex.refresh()
```

ALSO refresh on app launch — at the end of `applicationDidFinishLaunching`, ADD:

```swift
        recordingsIndex.refresh()
```

- [ ] **Step 7: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: build clean, 54 tests in 23 suites (51 prior + 3 RecordingsIndex tests).

- [ ] **Step 8: Rebuild + smoke**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Click the menu-bar icon. The popover should now show:
- Harc title + Start Recording button at top
- A "RECENT" label
- A list containing the `19-35-51.wav` recording from your Plan 4 smoke test (with a preview like "hello test recording harc" — whatever you said)

Click a row → Finder opens to the `.wav`. That's the placeholder behavior; Task 5 replaces it with a proper detail window.

- [ ] **Step 9: Commit**

```bash
git add Sources/HarcUI/RecordingsIndex.swift \
        Sources/HarcUI/RecentRecordingsView.swift \
        Sources/HarcUI/PopoverRootView.swift \
        HarcApp/AppDelegate.swift \
        Tests/HarcUITests/RecordingsIndexTests.swift
git commit -m "feat: RecordingsIndex + RecentRecordingsView with scrollable list"
```

---

### Task 5: `TranscriptionDetailView` + detail window

Replace the "reveal in Finder" placeholder with a proper detail window showing the full transcript, with Copy / Reveal / Delete actions.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift`
- Create: `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Write `Sources/HarcUI/TranscriptionDetailView.swift`**

```swift
import SwiftUI
import AppKit

public struct TranscriptionDetailView: View {
    let entry: RecordingEntry
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var transcript: String = ""
    @State private var loadError: String? = nil
    @State private var deleteConfirm = false

    public init(
        entry: RecordingEntry,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.entry = entry
        self.onReveal = onReveal
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(entry.date)
                        .font(HarcDesign.Font.titleLg)
                        .foregroundStyle(Color.harcOnSurface)
                    Text(entry.wavURL.lastPathComponent)
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Spacer()
                toolbar
            }

            if let loadError {
                Text(loadError)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcError)
            } else if transcript.isEmpty {
                Text("(no transcript)")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } else {
                ScrollView {
                    Text(transcript)
                        .font(HarcDesign.Font.bodyMd)
                        .foregroundStyle(Color.harcOnSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HarcDesign.Space.md)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
            }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: load)
    }

    private var toolbar: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
            }
            .disabled(transcript.isEmpty)

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }

            Button(role: .destructive) {
                deleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .alert("Delete recording?", isPresented: $deleteConfirm) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Also removes the .txt and .json siblings. This cannot be undone.")
            }
        }
    }

    private func load() {
        guard let txt = entry.txtURL else {
            loadError = "No transcript file — recording likely had no transcription."
            return
        }
        do {
            transcript = try String(contentsOf: txt, encoding: .utf8)
        } catch {
            loadError = "Failed to load transcript: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Write `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`**

```swift
import AppKit
import SwiftUI
import HarcUI

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        entry: RecordingEntry,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        let root = TranscriptionDetailView(entry: entry, onReveal: onReveal, onDelete: onDelete)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(entry.date)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
```

- [ ] **Step 3: Update `HarcApp/AppDelegate.swift`**

Replace the existing `openDetail(for:)` method:

```swift
    private var detailWindows: [URL: TranscriptionDetailWindowController] = [:]

    private func openDetail(for entry: RecordingEntry) {
        if let existing = detailWindows[entry.wavURL] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = TranscriptionDetailWindowController(
            entry: entry,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([entry.wavURL])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(entry: entry)
            }
        )
        detailWindows[entry.wavURL] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Activate the app so the window pops to the front even though we're LSUIElement.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deleteRecording(entry: RecordingEntry) {
        let fm = FileManager.default
        for url in [entry.wavURL, entry.txtURL, entry.jsonURL].compactMap({ $0 }) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        detailWindows[entry.wavURL]?.close()
        detailWindows.removeValue(forKey: entry.wavURL)
        recordingsIndex.refresh()
    }
```

Make sure `private var detailWindows` is declared in the class (before `applicationDidFinishLaunching`).

Also import HarcUI at the top if not already (it should already be there from Task 2).

- [ ] **Step 4: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
open "$APP"
```

Click the menu bar icon, click a row in Recent. A window should open with the full transcript. Click Copy → paste into another app to verify. Click Reveal → Finder shows the `.wav`. Click Delete → confirm → the entry disappears from Recent (moved to Trash).

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/TranscriptionDetailView.swift \
        HarcApp/WindowControllers/TranscriptionDetailWindowController.swift \
        HarcApp/AppDelegate.swift
git commit -m "feat: TranscriptionDetailView window with copy/reveal/delete actions"
```

---

### Task 6: `SettingsView` + settings window + persisted preferences

Adds a Settings window with destination folder, diarization toggle, chunk duration. Persists via `UserDefaults`.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/SettingsView.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`
- Create: `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/SettingsWindowController.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Write `Sources/HarcUI/HarcPreferences.swift`**

```swift
import Foundation
import Combine

/// App-wide preferences backed by UserDefaults. SwiftUI views observe.
@MainActor
public final class HarcPreferences: ObservableObject {
    private enum Key {
        static let destinationPath = "harc.destinationPath"
        static let diarize = "harc.diarize"
        static let chunkDurationSeconds = "harc.chunkDurationSeconds"
    }

    @Published public var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Key.destinationPath) }
    }

    @Published public var diarize: Bool {
        didSet { UserDefaults.standard.set(diarize, forKey: Key.diarize) }
    }

    @Published public var chunkDurationSeconds: Double {
        didSet { UserDefaults.standard.set(chunkDurationSeconds, forKey: Key.chunkDurationSeconds) }
    }

    public static let shared = HarcPreferences()

    public init() {
        let defaults = UserDefaults.standard
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc").path
        self.destinationPath = defaults.string(forKey: Key.destinationPath) ?? defaultPath
        self.diarize = defaults.object(forKey: Key.diarize) as? Bool ?? true
        self.chunkDurationSeconds = defaults.object(forKey: Key.chunkDurationSeconds) as? Double ?? 60.0
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath, isDirectory: true)
    }
}
```

- [ ] **Step 2: Write `Sources/HarcUI/SettingsView.swift`**

```swift
import SwiftUI
import AppKit
import KeyboardShortcuts

public struct SettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack {
                    Text(prefs.destinationPath)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickFolder)
                }
            } header: {
                Text("Destination folder")
            } footer: {
                Text("Recordings are written here as YYYY/YYYY-MM-DD/HH-mm-ss.{wav,txt,json}.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
            } footer: {
                Text("When on, transcripts include per-speaker segments.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                HStack {
                    Text("Chunk duration")
                    Spacer()
                    Text("\(Int(prefs.chunkDurationSeconds)) s")
                        .font(HarcDesign.Font.labelMd.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Slider(value: $prefs.chunkDurationSeconds, in: 15...120, step: 15)
            } footer: {
                Text("How often the transcriber processes a slice during recording.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            } header: {
                Text("Global hotkey")
            }
        }
        .formStyle(.grouped)
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.destinationURL
        if panel.runModal() == .OK, let chosen = panel.url {
            prefs.destinationPath = chosen.path
        }
    }
}
```

Note: `KeyboardShortcuts.Name.toggleRecording` is defined in Task 7. For Task 6, import it via `HarcUI` once Task 7 lands; if you're executing strictly top-to-bottom, comment out the `KeyboardShortcuts.Recorder` line in this file for now and re-enable it in Task 7. The rest of Settings works without it.

To keep the plan executable task-by-task without comment-out-then-uncomment dances, define the Name stub upfront:

Add a preliminary file `Sources/HarcUI/HotkeyNames.swift`:
```swift
import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("harc.toggleRecording")
}
```

This is a one-line extension so Task 6's SettingsView compiles. Task 7 adds the handler that actually watches `.toggleRecording`.

- [ ] **Step 3: Write `HarcApp/WindowControllers/SettingsWindowController.swift`**

```swift
import AppKit
import SwiftUI
import HarcUI

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(prefs: HarcPreferences) {
        let root = SettingsView()
            .environmentObject(prefs)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        self.init(window: window)
    }
}
```

- [ ] **Step 4: Update `HarcApp/AppDelegate.swift`**

Add above `applicationDidFinishLaunching`:
```swift
    private let prefs = HarcPreferences.shared
    private var settingsWindow: SettingsWindowController?
```

Change the `recordingsIndex` initialization to use the prefs' destination:
```swift
    private lazy var recordingsIndex = RecordingsIndex(baseDirectory: prefs.destinationURL)
```

Update the `RecordingSession` creation in `startRecording` to use the prefs:
```swift
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                chunkDurationSeconds: prefs.chunkDurationSeconds
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: prefs.destinationURL),
                transcriber: transcriber
            )
```

Add a menu item hook. Find the NSPopover creation block in `applicationDidFinishLaunching` and after `self.popover = pop`, ADD:

```swift
        // Settings menu item shown via right-click on the menu bar icon.
        let settingsMenu = NSMenu()
        settingsMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(
            withTitle: "Quit Harc",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = settingsMenu
        // Wire the left-click to popover, right-click to the settings menu
        // (NSStatusItem's button shows the menu only on left-click by default,
        //  so we use the action selector above for custom left-click handling
        //  and the menu below is shown via right-click via the alternateAction trick).
```

Actually — NSStatusItem's dual click handling is finicky. Simplest implementation: put "Settings…" + "Quit Harc" inside the popover UI itself as a small footer. Or keep it simple: add an "⋯" button to the popover that presents a contextual menu. The plan's spec uses the latter:

Replace the settings-menu snippet above with this simpler approach. REVERT any `item.menu = ...` lines; popover handles everything. Add a settings button inside `RecordingControlsView.header`:

Modify `Sources/HarcUI/RecordingControlsView.swift`. Find the existing `header` computed property. REPLACE it with:

```swift
    private var header: some View {
        HStack {
            Text("Harc")
                .font(HarcDesign.Font.titleLg)
                .foregroundStyle(Color.harcOnSurface)
            Spacer()
            if state.isRecording {
                HStack(spacing: HarcDesign.Space.xxs) {
                    Circle()
                        .fill(Color.harcError)
                        .frame(width: 8, height: 8)
                    Text(elapsedText)
                        .font(HarcDesign.Font.labelMd.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
            }
            Menu {
                Button("Settings…", action: onOpenSettings)
                Divider()
                Button("Quit Harc") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }
```

And add an `onOpenSettings` parameter to `RecordingControlsView`:

```swift
    let onToggle: () -> Void
    let onOpenSettings: () -> Void

    public init(onToggle: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpenSettings = onOpenSettings
    }
```

Update `PopoverRootView` to thread the new parameter:

```swift
public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var index: RecordingsIndex

    let onToggle: () -> Void
    let onOpen: (RecordingEntry) -> Void
    let onOpenSettings: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (RecordingEntry) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle, onOpenSettings: onOpenSettings)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
    }
}
```

Update `AppDelegate.applicationDidFinishLaunching` PopoverRootView construction to pass the new closure:

```swift
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] entry in
                self?.openDetail(for: entry)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        .environmentObject(state)
        .environmentObject(recordingsIndex)
        .environmentObject(prefs)
```

Add `openSettings` method:

```swift
    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController(prefs: prefs)
        settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 5: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
open "$APP"
```

Open the popover, click the `⋯` button → Settings → a window opens with destination folder, diarization toggle, chunk slider, and an unbound hotkey recorder. Change something, close the window, reopen — the value persists.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/HarcPreferences.swift \
        Sources/HarcUI/SettingsView.swift \
        Sources/HarcUI/HotkeyNames.swift \
        Sources/HarcUI/RecordingControlsView.swift \
        Sources/HarcUI/PopoverRootView.swift \
        HarcApp/WindowControllers/SettingsWindowController.swift \
        HarcApp/AppDelegate.swift
git commit -m "feat: Settings window with destination, diarization, chunk, hotkey preferences"
```

---

### Task 7: Global hotkey integration

Wire the hotkey name defined in Task 6 to actually toggle recording. User binds a chord in Settings, presses it anywhere → Harc starts/stops recording.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Add KeyboardShortcuts import + handler**

At the top of `AppDelegate.swift`, add:
```swift
import KeyboardShortcuts
```

At the end of `applicationDidFinishLaunching`, add:
```swift
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            Task { await self?.toggleRecording() }
        }
```

- [ ] **Step 2: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
open "$APP"
```

Open Settings, click the hotkey recorder, press `⌥⌘R`, save. Close Settings. In any app, press `⌥⌘R` — a recording should start. Press it again — it stops.

macOS will prompt for **Accessibility** or **Input Monitoring** permission on first hotkey install, via `KeyboardShortcuts`' built-in TCC flow. Grant it.

- [ ] **Step 3: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "feat: wire global hotkey to start/stop recording via KeyboardShortcuts"
```

---

### Task 8: Eager daemon launch + live transcript preview

Two polish items:
1. Launch the daemon on app startup (not on first recording) so ⌘R doesn't wait for model load.
2. Subscribe to `ChunkedTranscriber.updates` during recording → populate `state.livePreviewText` so the popover shows the transcript building up.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Launch the daemon on app startup**

In `applicationDidFinishLaunching`, after `recordingsIndex.refresh()`, add:

```swift
        // Pre-launch the daemon in the background so ⌘R doesn't have to wait for
        // model load. Failure is logged and retried lazily on next recording start.
        Task { [launcher] in
            do {
                _ = try await launcher.ensureRunning()
            } catch {
                FileHandle.standardError.write(Data(
                    "harc: background daemon launch failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }
```

- [ ] **Step 2: Subscribe to transcriber updates**

Modify `startRecording()`. After `self.session = session` but BEFORE `try await session.start(at: ...)`, capture the transcriber for the subscription. Replace:

```swift
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                chunkDurationSeconds: prefs.chunkDurationSeconds
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: prefs.destinationURL),
                transcriber: transcriber
            )
            self.session = session
            try await session.start(at: state.recordingStartedAt ?? Date())
```

with:

```swift
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                chunkDurationSeconds: prefs.chunkDurationSeconds
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: prefs.destinationURL),
                transcriber: transcriber
            )
            self.session = session

            // Pipe transcript updates into the UI.
            Task { [weak self, transcriber] in
                for await update in await transcriber.updates {
                    await MainActor.run {
                        self?.state.appendPreview(update.joinedTextSoFar)
                    }
                }
            }

            try await session.start(at: state.recordingStartedAt ?? Date())
```

- [ ] **Step 3: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate >/dev/null
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
open "$APP"
```

Launch → wait ~10s for the daemon to warm (watch `~/Library/Caches/Harc/daemon.log` for "ASR model loaded"). Open popover, press Start, speak for 90+ seconds. Every ~60s a chunk should post; the live preview area should populate with the accumulated transcript. Press Stop → the final tail chunk lands, the transcript window can now open with the complete text.

Verify the full flow: daemon cold start is hidden behind app launch, so ⌘R feels instant; popover shows live transcript; Stop writes `.wav`/`.txt`/`.json`.

- [ ] **Step 4: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "feat: eager daemon launch + live transcript preview in popover"
```

---

## Acceptance Criteria (Plan 5 complete when all true)

- `swift test` passes all existing + new HarcUITests. Expect ~54 tests in 23 suites (depending on final task count).
- `swift build` clean; `swift build -Xswiftc -strict-concurrency=complete` clean.
- `xcodegen generate && xcodebuild ... build` succeeds; `codesign --verify --deep --strict Harc.app` green.
- Clicking the menu-bar icon shows an SwiftUI popover (not an NSMenu) with:
  - Harc title + `⋯` menu (Settings, Quit)
  - Start/Stop button (gradient when idle, red when recording)
  - Elapsed-time counter during recording
  - Live transcript preview area that populates every ~60s during recording
  - RECENT section listing previous recordings (newest first) with date + preview text
- Clicking a Recent row opens a TranscriptionDetail window showing the full transcript with Copy / Reveal / Delete.
- Settings window (⌘,) has destination folder picker, diarization toggle, chunk duration slider, global hotkey recorder.
- Binding a hotkey and pressing it anywhere toggles recording.
- Daemon is pre-launched on app startup, so pressing Start feels instant (models already loaded).
- 8 new commits on `main`.

## Open Decisions

- **Sandboxing / Mac App Store distribution** — Plan 5 persists a plain `path: String` in UserDefaults. If we ever sandbox the app, we'd need security-scoped bookmarks for the destination folder. Currently out of scope per CLAUDE.md (notarized direct distribution).
- **Transcription Detail actions beyond Copy/Reveal/Delete** — rename, pin, favorite, export to PDF — all Plan 6 concerns.
- **Multi-window management** — currently one detail window per recording (keyed on `wavURL`). If the user opens many, the `detailWindows` dict grows; no cleanup until app quit. Acceptable for MVP; Plan 6 could add a single-window "library" with navigation.

## Self-Review

**Spec coverage (Plan 1's Plan 5 sketch):**
- "Replace the Task-6 stub with the full SwiftUI popover" → Task 2 (shell) + Tasks 3/4 (content).
- "Menu Bar Popover (primary surface)" → Tasks 2-4.
- "Recorder (large view for active session)" → folded into the popover's RecordingControlsView (live preview + timer). A separate "large" view is out of scope for MVP.
- "Library (list of past transcripts)" → Task 4's RecentRecordingsView.
- "Transcription Detail" → Task 5.
- "Settings" → Task 6.
- "Global hotkey" → Task 7 with KeyboardShortcuts.
- "Menu bar icon switches between waveform idle and animated red-dot recording indicator" → Task 2 (icon swap) — the "animated" part is deferred; using `record.circle.fill` static symbol is good-enough MVP.
- "Settings UI surfaces destination folder, hotkey, diarization toggle" → Task 6. "auto-paste" deferred to a future plan.
- "Use Stitch HTML as visual reference" → design tokens from Stitch designMd translated to Task 1's DesignTokens.

**Placeholder scan:** None. All tasks have complete code.

**Type consistency:**
- `RecordingState` (T2) used in T3 (controls), T4 (list row tap), T5 (detail window open), T8 (preview updates).
- `RecordingsIndex` (T4) used in T4 view, T5 (detail window opens entries), T6 (recordingsIndex init uses prefs).
- `RecordingEntry` (T4) consumed by TranscriptionDetailView (T5).
- `HarcPreferences` (T6) consumed by SettingsView (T6) and AppDelegate (T6, T8).
- `KeyboardShortcuts.Name.toggleRecording` defined in HotkeyNames.swift (T6 Step 2), used in SettingsView (T6) and AppDelegate (T7).
- All function signatures match across view-parameter threading in PopoverRootView.
