# Meeting Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Companion design doc:** `docs/superpowers/specs/2026-04-19-meeting-detection-design.md`

**Goal:** Detect when a monitored meeting app (Zoom, Microsoft Teams, Slack) launches and proactively offer to record — via a pulsing menu bar icon and a macOS notification banner with a "Record" action. Lives in a new `HarcMeetingDetect` target, wires into AppDelegate, and adds a Recording-tab Settings section with per-app + global toggles.

**Tech Stack:** Swift 6, AppKit (`NSWorkspace`), UserNotifications, SwiftUI for settings, existing `HarcDesign` tokens.

**Out of scope:** calendar integration, Google Meet (dropped — in-browser), auto-record without prompt, custom apps UI.

---

## Ordered task list

| # | Task | Effort | Depends on |
|---|---|---|---|
| 1 | `HarcMeetingDetect` package target scaffold | S | — |
| 2 | `MeetingApp` + `MeetingCatalog` model types | S | 1 |
| 3 | `WorkspaceObserving` protocol + `SystemWorkspace` + `FakeWorkspace` | M | 1 |
| 4 | `MeetingDetector` core — observe, debounce, emit | M | 2, 3 |
| 5 | Unit tests for `MeetingDetector` | M | 4 |
| 6 | Preferences — `meetingDetectionEnabled` + per-app map | S | 2 |
| 7 | `MeetingNotificationPresenter` — UNUserNotificationCenter category + post/withdraw | M | 4 |
| 8 | Menu bar pulse state + animation in AppDelegate | M | 4 |
| 9 | AppDelegate wiring — detector lifecycle, delegate → pulse + notification, action → start recording | M | 4, 7, 8 |
| 10 | Settings UI — Recording tab section (global + per-app toggles + denied-permission banner) | M | 6 |
| 11 | Info.plist and entitlements review (no changes expected; confirm) | S | 9 |
| 12 | Manual verification on live Zoom / Teams / Slack launches | M | 9, 10 |
| 13 | Documentation touch-up (CLAUDE.md status line, optional) | S | 12 |

Effort key: **S** ≤ 1 hr, **M** 1–3 hr, **L** 3+ hr.

---

## Dependency graph

```
  1 ── 2 ── 4 ── 5
  │    │    │
  │    │    ├── 7 ── 9 ── 11, 12, 13
  │    │    │        │
  │    │    └── 8 ───┘
  │    │
  │    └── 6 ── 10
  │
  └── 3 ── 4
```

---

### Task 1: Scaffold the `HarcMeetingDetect` target

**Effort:** S

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/.gitkeep` (replaced in Task 2)
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcMeetingDetectTests/.gitkeep` (replaced in Task 5)

- [ ] **Step 1:** In `Package.swift`, add a new library product and target.

Under `products:` add:
```swift
.library(name: "HarcMeetingDetect", targets: ["HarcMeetingDetect"]),
```

Under `targets:` add (between `HarcClient` and `HarcStore` is fine — alphabetical isn't enforced elsewhere):
```swift
.target(
    name: "HarcMeetingDetect",
    dependencies: ["HarcCore"]
),
```

And the matching test target:
```swift
.testTarget(
    name: "HarcMeetingDetectTests",
    dependencies: ["HarcMeetingDetect", "HarcCore"]
),
```

- [ ] **Step 2:** Add `HarcMeetingDetect` to the `HarcUI` target's dependency list so UI bits (Settings) can read `MeetingCatalog`:

```swift
.target(
    name: "HarcUI",
    dependencies: [
        "HarcCore",
        "HarcAudio",
        "HarcClient",
        "HarcStore",
        "HarcMeetingDetect",        // new
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    ]
),
```

- [ ] **Step 3:** Verify the project builds with the empty target. `swift build` from the repo root should succeed. XcodeGen regeneration via `scripts/` if present (check `ls /Users/jlane/GitHub/Harc/scripts/`) — run whatever regenerates `Harc.xcodeproj`.

**Verification:**
- `swift build` exits 0.
- `swift package describe` lists the new target.

---

### Task 2: `MeetingApp` model and `MeetingCatalog`

**Effort:** S
**Depends on:** 1

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/MeetingApp.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/MeetingCatalog.swift`

- [ ] **Step 1: `MeetingApp.swift`**

```swift
import Foundation

/// A meeting app known to Harc's detection system. One catalog entry may match
/// multiple runtime bundle IDs via `aliasBundleIDs` (e.g. new vs. classic Teams).
public struct MeetingApp: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let bundleID: String
    public let aliasBundleIDs: [String]
    public let displayName: String
    public let symbolName: String
    public let settingsNote: String?

    public init(id: String,
                bundleID: String,
                aliasBundleIDs: [String] = [],
                displayName: String,
                symbolName: String,
                settingsNote: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.aliasBundleIDs = aliasBundleIDs
        self.displayName = displayName
        self.symbolName = symbolName
        self.settingsNote = settingsNote
    }

    /// Whether this catalog entry matches the given runtime bundle ID.
    public func matches(bundleID candidate: String) -> Bool {
        bundleID == candidate || aliasBundleIDs.contains(candidate)
    }
}
```

- [ ] **Step 2: `MeetingCatalog.swift`**

```swift
import Foundation

public enum MeetingCatalog {
    /// Apps Harc detects out of the box.
    public static let builtIn: [MeetingApp] = [
        MeetingApp(
            id: "us.zoom.xos",
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            symbolName: "video.fill"
        ),
        MeetingApp(
            id: "com.microsoft.teams2",
            bundleID: "com.microsoft.teams2",
            aliasBundleIDs: ["com.microsoft.teams"],  // classic Teams
            displayName: "Microsoft Teams",
            symbolName: "person.2.wave.2.fill"
        ),
        MeetingApp(
            id: "com.tinyspeck.slackmacgap",
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            symbolName: "bubble.left.and.bubble.right.fill",
            settingsNote: "Will prompt on app launch, not just huddles."
        ),
    ]

    /// Returns the catalog entry matching a runtime bundle ID, or nil.
    public static func entry(forBundleID bundleID: String) -> MeetingApp? {
        builtIn.first { $0.matches(bundleID: bundleID) }
    }
}
```

**Verification:**
- `swift build` succeeds.
- Adding an inline `#Preview` or a throwaway print in a scratch test confirms `MeetingCatalog.entry(forBundleID: "com.microsoft.teams")?.displayName == "Microsoft Teams"`.

---

### Task 3: `WorkspaceObserving` protocol, production + fake implementations

**Effort:** M
**Depends on:** 1

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/WorkspaceObserving.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/SystemWorkspace.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/FakeWorkspace.swift`

- [ ] **Step 1: `WorkspaceObserving.swift`**

```swift
import Foundation

/// A seam over `NSWorkspace` so detection can be unit-tested with a fake.
public protocol WorkspaceObserving: AnyObject {
    /// Snapshot of currently running apps' bundle IDs (nils filtered).
    var runningAppBundleIDs: [String] { get }

    /// Register a handler invoked with each launched app's bundle ID.
    /// Returned token identifies the subscription for `removeObserver`.
    func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol

    /// Register a handler invoked with each terminated app's bundle ID.
    func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol

    /// Remove a handler registered via one of the `add…Observer` methods.
    func removeObserver(_ token: NSObjectProtocol)
}
```

- [ ] **Step 2: `SystemWorkspace.swift`**

```swift
import AppKit

/// Production adapter over `NSWorkspace.shared.notificationCenter`.
public final class SystemWorkspace: WorkspaceObserving {
    public static let shared = SystemWorkspace()

    public var runningAppBundleIDs: [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    }

    public func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            handler(id)
        }
    }

    public func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            handler(id)
        }
    }

    public func removeObserver(_ token: NSObjectProtocol) {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}
```

- [ ] **Step 3: `FakeWorkspace.swift`** — *in Sources (not Tests) so tests in either module can use it.*

```swift
import Foundation

/// Test double — fires synthetic launch/terminate events on demand.
public final class FakeWorkspace: WorkspaceObserving {
    public var runningAppBundleIDs: [String] = []

    private final class Token: NSObject {}
    private var launchHandlers: [(Token, @Sendable (String) -> Void)] = []
    private var terminateHandlers: [(Token, @Sendable (String) -> Void)] = []

    public init() {}

    public func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        let token = Token()
        launchHandlers.append((token, handler))
        return token
    }

    public func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        let token = Token()
        terminateHandlers.append((token, handler))
        return token
    }

    public func removeObserver(_ token: NSObjectProtocol) {
        if let t = token as? Token {
            launchHandlers.removeAll { $0.0 === t }
            terminateHandlers.removeAll { $0.0 === t }
        }
    }

    // Test helpers
    public func simulateLaunch(bundleID: String) {
        launchHandlers.forEach { $0.1(bundleID) }
    }
    public func simulateTerminate(bundleID: String) {
        terminateHandlers.forEach { $0.1(bundleID) }
    }
}
```

**Verification:**
- `swift build` succeeds.
- Nothing to run yet — tests land in Task 5.

---

### Task 4: `MeetingDetector` core logic

**Effort:** M
**Depends on:** 2, 3

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/MeetingDetector.swift`

- [ ] **Step 1:** Write `MeetingDetector`:

```swift
import Foundation

@MainActor
public final class MeetingDetector {
    public protocol Delegate: AnyObject {
        /// Called on main when a monitored app's launch was observed and should
        /// be surfaced to the user (allowlisted, enabled, debounced, not
        /// suppressed by an active recording).
        func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp)
    }

    public weak var delegate: Delegate?

    private let workspace: WorkspaceObserving
    private let isGloballyEnabled: () -> Bool
    private let isAppEnabled: (MeetingApp) -> Bool
    private let isRecordingInProgress: () -> Bool

    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    private var activeDetections: Set<String> = []  // bundleIDs currently debounced

    public init(workspace: WorkspaceObserving = SystemWorkspace.shared,
                isGloballyEnabled: @escaping () -> Bool,
                isAppEnabled: @escaping (MeetingApp) -> Bool,
                isRecordingInProgress: @escaping () -> Bool) {
        self.workspace = workspace
        self.isGloballyEnabled = isGloballyEnabled
        self.isAppEnabled = isAppEnabled
        self.isRecordingInProgress = isRecordingInProgress
    }

    public func start() {
        guard isGloballyEnabled() else { return }
        guard launchToken == nil else { return }

        // Pre-seed: any monitored app already running is silently added to
        // the debounce set, so we don't prompt about apps the user opened
        // before Harc started.
        for bundleID in workspace.runningAppBundleIDs {
            if MeetingCatalog.entry(forBundleID: bundleID) != nil {
                activeDetections.insert(bundleID)
            }
        }

        launchToken = workspace.addDidLaunchObserver { [weak self] id in
            Task { @MainActor in self?.handleLaunch(bundleID: id) }
        }
        terminateToken = workspace.addDidTerminateObserver { [weak self] id in
            Task { @MainActor in self?.handleTerminate(bundleID: id) }
        }
    }

    public func stop() {
        if let t = launchToken { workspace.removeObserver(t); launchToken = nil }
        if let t = terminateToken { workspace.removeObserver(t); terminateToken = nil }
        activeDetections.removeAll()
    }

    /// Mark a detection as user-acknowledged. Prevents re-prompt until the
    /// source app terminates and relaunches.
    public func markHandled(bundleID: String) {
        activeDetections.insert(bundleID)
    }

    private func handleLaunch(bundleID: String) {
        guard isGloballyEnabled() else { return }
        guard let app = MeetingCatalog.entry(forBundleID: bundleID) else { return }
        guard isAppEnabled(app) else { return }
        guard !activeDetections.contains(bundleID) else { return }
        guard !isRecordingInProgress() else {
            activeDetections.insert(bundleID)  // still mark it, so re-fires are suppressed
            return
        }
        activeDetections.insert(bundleID)
        delegate?.meetingDetector(self, didDetect: app)
    }

    private func handleTerminate(bundleID: String) {
        activeDetections.remove(bundleID)
        // Also remove any alias bundleIDs — if com.microsoft.teams terminates,
        // drop the debounce for its aliases too so relaunch of the other
        // variant fires a fresh prompt.
        if let app = MeetingCatalog.entry(forBundleID: bundleID) {
            activeDetections.remove(app.bundleID)
            for alias in app.aliasBundleIDs { activeDetections.remove(alias) }
        }
    }
}
```

**Verification:**
- `swift build` succeeds.
- Smoke: in `main.swift` of a throwaway executable, run with the fake — covered in Task 5.

---

### Task 5: Unit tests for `MeetingDetector`

**Effort:** M
**Depends on:** 4

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcMeetingDetectTests/MeetingDetectorTests.swift`

- [ ] **Step 1:** Build a test harness that captures delegate calls and lets the test twiddle prefs/recording state via closures:

```swift
import XCTest
@testable import HarcMeetingDetect

@MainActor
final class MeetingDetectorTests: XCTestCase {
    final class TestDelegate: MeetingDetector.Delegate {
        var detectedApps: [MeetingApp] = []
        func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp) {
            detectedApps.append(app)
        }
    }

    var workspace: FakeWorkspace!
    var delegate: TestDelegate!
    var globallyEnabled: Bool = true
    var appEnabled: [String: Bool] = [:]
    var recording: Bool = false

    func makeDetector() -> MeetingDetector {
        let d = MeetingDetector(
            workspace: workspace,
            isGloballyEnabled: { [weak self] in self?.globallyEnabled ?? false },
            isAppEnabled: { [weak self] app in self?.appEnabled[app.id] ?? true },
            isRecordingInProgress: { [weak self] in self?.recording ?? false }
        )
        d.delegate = delegate
        return d
    }

    override func setUp() async throws {
        workspace = FakeWorkspace()
        delegate = TestDelegate()
        globallyEnabled = true
        appEnabled = [:]
        recording = false
    }

    // Test 1 — single launch fires once
    func test_launchFiresOnce() async {
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertEqual(delegate.detectedApps.map(\.id), ["us.zoom.xos"])
    }

    // Test 2 — duplicate launches debounced
    func test_duplicateLaunchDebounced() async {
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertEqual(delegate.detectedApps.count, 1)
    }

    // Test 3 — terminate re-arms detection
    func test_terminateReArms() async {
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        workspace.simulateTerminate(bundleID: "us.zoom.xos")
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertEqual(delegate.detectedApps.count, 2)
    }

    // Test 4 — already-running at start() skipped
    func test_alreadyRunningSkipped() async {
        workspace.runningAppBundleIDs = ["us.zoom.xos"]
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertTrue(delegate.detectedApps.isEmpty)
    }

    // Test 5 — per-app opt-out
    func test_perAppOptOut() async {
        appEnabled["us.zoom.xos"] = false
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertTrue(delegate.detectedApps.isEmpty)
    }

    // Test 6 — global disabled skips start
    func test_globalDisabledSkipsStart() async {
        globallyEnabled = false
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertTrue(delegate.detectedApps.isEmpty)
    }

    // Test 7 — unknown bundleID ignored
    func test_unknownBundleIgnored() async {
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "com.apple.finder")
        XCTAssertTrue(delegate.detectedApps.isEmpty)
    }

    // Test 8 — recording-in-progress suppression
    func test_recordingInProgressSuppresses() async {
        recording = true
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        XCTAssertTrue(delegate.detectedApps.isEmpty)
    }

    // Test 9 — Teams aliasing: legacy bundleID matches the new-Teams catalog entry
    func test_teamsAliasing() async {
        let d = makeDetector(); d.start()
        workspace.simulateLaunch(bundleID: "com.microsoft.teams")  // legacy
        XCTAssertEqual(delegate.detectedApps.first?.id, "com.microsoft.teams2")
    }
}
```

**Verification:**
- `swift test --filter HarcMeetingDetectTests` passes all 9 tests.

---

### Task 6: Preferences — global toggle + per-app map

**Effort:** S
**Depends on:** 2

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`

- [ ] **Step 1:** Add new keys, published properties, and helpers.

At the top, add to `Key`:
```swift
static let meetingDetectionEnabled = "harc.meetingDetectionEnabled"
static let meetingAppEnabled = "harc.meetingAppEnabled"      // JSON: [String: Bool]
```

Import `HarcMeetingDetect` at the top of the file.

Add properties (after `chunkDurationSeconds`):

```swift
@Published public var meetingDetectionEnabled: Bool {
    didSet { UserDefaults.standard.set(meetingDetectionEnabled, forKey: Key.meetingDetectionEnabled) }
}

@Published public var meetingAppEnabled: [String: Bool] {
    didSet {
        if let data = try? JSONEncoder().encode(meetingAppEnabled) {
            UserDefaults.standard.set(data, forKey: Key.meetingAppEnabled)
        }
    }
}
```

Update `init()` — after existing assignments, append:

```swift
self.meetingDetectionEnabled = defaults.object(forKey: Key.meetingDetectionEnabled) as? Bool ?? false
if let data = defaults.data(forKey: Key.meetingAppEnabled),
   let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
    self.meetingAppEnabled = decoded
} else {
    // Built-in defaults: Zoom + Teams on, Slack off.
    self.meetingAppEnabled = [
        "us.zoom.xos": true,
        "com.microsoft.teams2": true,
        "com.tinyspeck.slackmacgap": false,
    ]
}
```

- [ ] **Step 2:** Add a `Binding<Bool>` helper:

```swift
public func meetingAppBinding(for app: MeetingApp) -> Binding<Bool> {
    Binding(
        get: { self.meetingAppEnabled[app.id] ?? true },
        set: { newValue in
            var copy = self.meetingAppEnabled
            copy[app.id] = newValue
            self.meetingAppEnabled = copy
        }
    )
}
```

You'll need `import SwiftUI` at the top (already imported via Combine in practice; verify).

**Verification:**
- `swift build` succeeds.
- Manual UserDefaults poke from the Settings view (next tasks) round-trips the values.

---

### Task 7: `MeetingNotificationPresenter`

**Effort:** M
**Depends on:** 4

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcMeetingDetect/MeetingNotificationPresenter.swift`

- [ ] **Step 1:** Define category constants and action IDs (module-visible, reused by the AppDelegate's `UNUserNotificationCenterDelegate`):

```swift
import Foundation
import UserNotifications

public enum MeetingNotification {
    public static let categoryID = "harc.meetingDetected"
    public static let recordActionID = "harc.meetingDetected.record"
    public static let dismissActionID = "harc.meetingDetected.dismiss"
    public static let bundleIDUserInfoKey = "bundleID"
    public static let appIDUserInfoKey = "appID"
}
```

- [ ] **Step 2:** Presenter:

```swift
@MainActor
public final class MeetingNotificationPresenter {
    public enum AuthStatus { case authorized, denied, notDetermined }

    public init() {}

    /// Register the custom category with its Record / Dismiss actions.
    /// Safe to call multiple times.
    public func registerCategory() {
        let record = UNNotificationAction(
            identifier: MeetingNotification.recordActionID,
            title: "Record",
            options: [.foreground]  // bring app forward so any subsequent alert is visible
        )
        let dismiss = UNNotificationAction(
            identifier: MeetingNotification.dismissActionID,
            title: "Not now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: MeetingNotification.categoryID,
            actions: [record, dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Returns current authorization status, requesting if `.notDetermined`.
    public func ensureAuthorization() async -> AuthStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return ok ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    /// Post the "Meeting detected" banner. No-op if not authorized.
    public func present(app: MeetingApp) async {
        let status = await ensureAuthorization()
        guard status == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.subtitle = "\(app.displayName) is now running"
        content.body = "Start recording this meeting with Harc?"
        content.categoryIdentifier = MeetingNotification.categoryID
        content.threadIdentifier = app.bundleID
        content.userInfo = [
            MeetingNotification.bundleIDUserInfoKey: app.bundleID,
            MeetingNotification.appIDUserInfoKey: app.id,
        ]
        content.sound = nil  // unobtrusive — the pulse is the primary signal

        let request = UNNotificationRequest(
            identifier: "harc.meetingDetected.\(app.bundleID)",
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Remove a delivered notification, e.g. when the source app terminates
    /// before the user reacted.
    public func withdraw(bundleID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["harc.meetingDetected.\(bundleID)"]
        )
    }
}
```

**Verification:**
- `swift build` succeeds.
- Hard to unit-test without `UNUserNotificationCenter` mock shim; covered by manual test in Task 12.

---

### Task 8: Menu bar pulse state + animation

**Effort:** M
**Depends on:** 4

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingState.swift` (add pulse flag) — or create a sibling `MeetingDetectionState.swift` for cleanliness. Plan chooses the sibling.
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/MeetingDetectionState.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1:** `MeetingDetectionState.swift`:

```swift
import Foundation
import Combine

@MainActor
public final class MeetingDetectionState: ObservableObject {
    /// Bundle IDs with a pending (un-acknowledged) detection. While non-empty,
    /// the menu bar icon pulses.
    @Published public private(set) var pendingBundleIDs: Set<String> = []
    /// Display name for the most-recent pending detection — used by the popover hint.
    @Published public private(set) var mostRecentDisplayName: String? = nil

    public init() {}

    public var isPulsing: Bool { !pendingBundleIDs.isEmpty }

    public func add(bundleID: String, displayName: String) {
        pendingBundleIDs.insert(bundleID)
        mostRecentDisplayName = displayName
    }

    public func clear(bundleID: String) {
        pendingBundleIDs.remove(bundleID)
        if pendingBundleIDs.isEmpty { mostRecentDisplayName = nil }
    }

    public func clearAll() {
        pendingBundleIDs.removeAll()
        mostRecentDisplayName = nil
    }
}
```

- [ ] **Step 2:** In `AppDelegate.swift`, add stored properties:

```swift
private let meetingState = MeetingDetectionState()
private var pulseTimer: Timer?
private var pulseOn = false
```

Add a helper:

```swift
private func applyPulse() {
    guard let button = statusItem?.button else { return }
    guard meetingState.isPulsing, !state.isRecording else {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = false
        // Reset tint unless we're recording (red takes precedence).
        if !state.isRecording { button.contentTintColor = nil }
        return
    }
    if pulseTimer == nil {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPulse() }
        }
    }
}

private func tickPulse() {
    guard let button = statusItem?.button else { return }
    guard meetingState.isPulsing, !state.isRecording else {
        applyPulse()
        return
    }
    pulseOn.toggle()
    button.contentTintColor = pulseOn ? NSColor(HarcDesign.tertiary) : nil
}
```

- [ ] **Step 3:** In `updateMenuBarIcon`, after setting the non-recording branch, call `applyPulse()`:

```swift
} else {
    menuBarTicker?.invalidate()
    menuBarTicker = nil
    button.title = ""
    applyPulse()  // new
}
```

And in the recording branch, clear pulse state (`meetingState.clearAll()`) before setting red tint.

- [ ] **Step 4:** Observe `meetingState.$pendingBundleIDs` in `applicationDidFinishLaunching` via Combine so changes to the pulse set drive the timer:

```swift
meetingState.$pendingBundleIDs
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.applyPulse() }
    .store(in: &cancellables)   // add `private var cancellables = Set<AnyCancellable>()`
```

**Verification:**
- Temporarily wire a debug menu item that calls `meetingState.add(bundleID: "us.zoom.xos", displayName: "Zoom")` — confirm the icon pulses and stops when cleared.
- `swift build` succeeds.

---

### Task 9: AppDelegate wiring — detector lifecycle + notification delegate

**Effort:** M
**Depends on:** 4, 7, 8

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1:** Import `HarcMeetingDetect` and `UserNotifications`.

- [ ] **Step 2:** Conform to `MeetingDetector.Delegate` and `UNUserNotificationCenterDelegate`:

```swift
extension AppDelegate: MeetingDetector.Delegate {
    func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp) {
        meetingState.add(bundleID: app.bundleID, displayName: app.displayName)
        Task { await notificationPresenter.present(app: app) }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let bundleID = info[MeetingNotification.bundleIDUserInfoKey] as? String
        let actionID = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            if let bundleID { self.meetingState.clear(bundleID: bundleID); self.detector?.markHandled(bundleID: bundleID) }
            switch actionID {
            case MeetingNotification.recordActionID, UNNotificationDefaultActionIdentifier:
                // Either explicit "Record" or tapping the notification body.
                if !self.state.isRecording { await self.startRecording() }
            default:
                break  // dismiss or unknown — pulse already cleared above
            }
        }
    }
}
```

- [ ] **Step 3:** Add stored properties:

```swift
private var detector: MeetingDetector?
private let notificationPresenter = MeetingNotificationPresenter()
```

- [ ] **Step 4:** In `applicationDidFinishLaunching`, after the existing setup:

```swift
notificationPresenter.registerCategory()
UNUserNotificationCenter.current().delegate = self
setupMeetingDetector()

// Observe pref changes so toggling the global switch starts/stops the detector.
prefs.$meetingDetectionEnabled
    .removeDuplicates()
    .receive(on: DispatchQueue.main)
    .sink { [weak self] enabled in
        guard let self else { return }
        if enabled { self.setupMeetingDetector() } else { self.tearDownMeetingDetector() }
    }
    .store(in: &cancellables)
```

- [ ] **Step 5:** Add the helpers:

```swift
private func setupMeetingDetector() {
    guard prefs.meetingDetectionEnabled else { return }
    guard detector == nil else { return }
    let d = MeetingDetector(
        isGloballyEnabled: { [weak self] in self?.prefs.meetingDetectionEnabled ?? false },
        isAppEnabled: { [weak self] app in self?.prefs.meetingAppEnabled[app.id] ?? true },
        isRecordingInProgress: { [weak self] in self?.state.isRecording ?? false }
    )
    d.delegate = self
    d.start()
    detector = d
}

private func tearDownMeetingDetector() {
    detector?.stop()
    detector = nil
    meetingState.clearAll()
    // Withdraw any live notifications for monitored apps.
    for app in MeetingCatalog.builtIn {
        notificationPresenter.withdraw(bundleID: app.bundleID)
        for alias in app.aliasBundleIDs { notificationPresenter.withdraw(bundleID: alias) }
    }
}
```

- [ ] **Step 6:** In `startRecording`, after `state.markStarted`, clear the pulse:

```swift
meetingState.clearAll()
```

- [ ] **Step 7:** Hook app-terminate withdrawal. In `setupMeetingDetector`, also watch workspace terminate events via the detector already — but we also want to withdraw delivered notifications when the source app terminates. Extend `MeetingDetector` with an optional `onTerminate: ((String) -> Void)?` callback, OR let AppDelegate install its own terminate observer via `SystemWorkspace.shared`:

Simplest: register a second observer in AppDelegate:

```swift
private var terminateToken: NSObjectProtocol?

private func registerTerminateWatchdog() {
    terminateToken = SystemWorkspace.shared.addDidTerminateObserver { [weak self] bundleID in
        Task { @MainActor in
            self?.meetingState.clear(bundleID: bundleID)
            self?.notificationPresenter.withdraw(bundleID: bundleID)
        }
    }
}
```

Call `registerTerminateWatchdog()` from `applicationDidFinishLaunching`. Mirror it with `removeObserver` on `applicationWillTerminate`.

- [ ] **Step 8:** Add the pulse-timeout (2 min) inside `meetingState.add` or in AppDelegate's observer. Cleanest: schedule a `DispatchQueue.main.asyncAfter(deadline: .now() + 120)` when a detection is added, which clears that specific bundleID if still present:

```swift
private func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp) {
    meetingState.add(bundleID: app.bundleID, displayName: app.displayName)
    Task { await notificationPresenter.present(app: app) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
        self?.meetingState.clear(bundleID: app.bundleID)
        self?.notificationPresenter.withdraw(bundleID: app.bundleID)
    }
}
```

**Verification:**
- Build the app, launch it, launch Zoom — icon pulses, banner appears (once permission granted).
- Full manual matrix is Task 12.

---

### Task 10: Settings UI — Recording tab section

**Effort:** M
**Depends on:** 6

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/SettingsView.swift`

Assumption: the tabs scaffold exists. If it doesn't yet, add a `TabView` wrapping existing sections into a "Recording" tab — this plan assumes the tab host exists and focuses purely on the Meeting Detection section content.

- [ ] **Step 1:** Import `HarcMeetingDetect`.

- [ ] **Step 2:** Add `@State private var notificationsDenied = false` and a `.task` that checks status on appear:

```swift
.task {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notificationsDenied = settings.authorizationStatus == .denied
}
```

- [ ] **Step 3:** Add new sections (placed after the global hotkey section, before the model section so the grouping is: recording flow → detection → advanced):

```swift
Section {
    Toggle("Enable meeting detection", isOn: $prefs.meetingDetectionEnabled)
        .tint(HarcDesign.primary)
} header: {
    Text("Meeting detection")
} footer: {
    Text("Harc notices when you launch a video meeting app and offers to start recording.")
        .font(HarcDesign.Font.bodySm)
        .foregroundStyle(Color.harcOnSurfaceVariant)
}

if prefs.meetingDetectionEnabled {
    Section {
        ForEach(MeetingCatalog.builtIn) { app in
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: app.symbolName)
                    .font(.body)
                    .foregroundStyle(Color.harcTertiary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(HarcDesign.Font.bodyMd)
                        .foregroundStyle(Color.harcOnSurface)
                    if let note = app.settingsNote {
                        Text(note)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                    }
                }
                Spacer()
                Toggle("", isOn: prefs.meetingAppBinding(for: app))
                    .labelsHidden()
                    .tint(HarcDesign.primary)
            }
            .padding(.vertical, HarcDesign.Space.xxs)
        }

        // Google Meet row — disabled, honest about the limitation.
        HStack(spacing: HarcDesign.Space.sm) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Meet")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Text("Runs in your browser — reliable detection is coming.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    } header: {
        Text("Monitored apps")
    }

    if notificationsDenied {
        Section {
            HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.harcError)
                VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                    Text("Notifications disabled")
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurface)
                    Text("Harc will still pulse the menu bar icon, but can't show a banner until you re-enable notifications.")
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, HarcDesign.Space.xxs)
        }
    }
}
```

**Verification:**
- Open Settings, toggle the master switch — per-app section appears/disappears.
- Toggle per-app switches, restart the app, confirm state persists (UserDefaults round-trip).
- Deny notifications in System Settings, reopen Settings — the warning section appears.

---

### Task 11: Entitlements and Info.plist confirmation

**Effort:** S
**Depends on:** 9

**Files:**
- Audit: `/Users/jlane/GitHub/Harc/HarcApp/Harc.entitlements`
- Audit: `/Users/jlane/GitHub/Harc/HarcApp/Info.plist`

- [ ] **Step 1:** Confirm `NSWorkspace` app-launch observation does **not** require additional entitlements. As of macOS 14+, this is public API with no sandbox or privacy gate.

- [ ] **Step 2:** Confirm no Info.plist `NSUserNotifications`-style purpose string is required. (`UNUserNotificationCenter` triggers its own permission prompt without a purpose string — different from mic/screen capture.)

- [ ] **Step 3:** If the app is sandboxed, verify `com.apple.security.app-sandbox` does not block NSWorkspace observation. Current entitlements file has no sandbox key → unsandboxed direct distribution, so no issue. Document this in a code comment near `SystemWorkspace.shared`.

**Verification:**
- App launches in release configuration and detection works without any "entitlement missing" runtime errors.
- No change expected to either file. If a change is required, stop and flag.

---

### Task 12: Manual verification on live meeting apps

**Effort:** M
**Depends on:** 9, 10

**This task MUST be executed on real hardware before the branch is merged.** No automated test covers live NSWorkspace behavior.

- [ ] **Step 1 — Zoom happy path.**
  1. Quit Zoom if running.
  2. Launch Harc. Confirm no pulse.
  3. Open Settings → enable "Meeting detection" (first time will grant notifications OR will lazy-ask on first detection — either is fine).
  4. Launch Zoom.
  5. **Expected:** within ~1s, menu bar icon pulses purple AND banner appears.
  6. Click "Record" in banner.
  7. **Expected:** recording starts, icon turns red, pulse stops, banner dismisses.
  8. Stop recording. Verify WAV/TXT/JSON exist in the destination folder.

- [ ] **Step 2 — Zoom quit before reaction.**
  1. With Harc running and detection enabled, launch Zoom.
  2. Wait for banner, do **not** click.
  3. Quit Zoom.
  4. **Expected:** banner is withdrawn, icon pulse stops.

- [ ] **Step 3 — Already-running Zoom.**
  1. Start Zoom.
  2. Launch Harc (or restart it).
  3. **Expected:** no pulse, no banner. Harc saw Zoom was already running.

- [ ] **Step 4 — Relaunch re-arms.**
  1. With Harc running, launch Zoom → dismiss banner → quit Zoom.
  2. Re-launch Zoom.
  3. **Expected:** a fresh banner appears.

- [ ] **Step 5 — Microsoft Teams (whichever variant the tester has).**
  1. Launch Teams.
  2. **Expected:** banner titled "Microsoft Teams". If tester has both new Teams and classic Teams, confirm both trigger using the same catalog entry.

- [ ] **Step 6 — Slack toggle respected.**
  1. Confirm Slack default is **off** in Settings.
  2. Launch Slack. **Expected:** no banner.
  3. Toggle Slack ON in Settings.
  4. Quit and relaunch Slack (or wait for a re-launch cycle).
  5. **Expected:** banner appears.

- [ ] **Step 7 — Recording-in-progress suppression.**
  1. Start a recording via hotkey.
  2. Launch Zoom.
  3. **Expected:** no pulse, no banner. Recording continues undisturbed.

- [ ] **Step 8 — Notifications denied graceful degradation.**
  1. System Settings → Notifications → Harc → Disallow.
  2. Restart Harc. Launch Zoom.
  3. **Expected:** icon pulses, no banner. Settings Recording tab shows the "Notifications disabled" warning.

- [ ] **Step 9 — Non-monitored app ignored.**
  1. Launch Safari, Finder, TextEdit in succession.
  2. **Expected:** no pulse, no banner at any point.

- [ ] **Step 10 — Global toggle off disables everything.**
  1. Toggle global "Enable meeting detection" OFF.
  2. Launch Zoom.
  3. **Expected:** nothing happens.

Document any deviations in a postmortem note at the top of the design doc.

**Verification:**
- All 10 scenarios pass. Blocking issues trigger follow-up tasks.

---

### Task 13: Optional — CLAUDE.md touch-up

**Effort:** S
**Depends on:** 12

**Files:**
- Modify (optional): `/Users/jlane/GitHub/Harc/CLAUDE.md`

- [ ] **Step 1:** Under "Harc-Specific Architecture (planned)", add a seventh bullet:

> 7. **Meeting detection** — `MeetingDetector` (in `HarcMeetingDetect`) observes `NSWorkspace.didLaunchApplicationNotification`. On a monitored app launch (Zoom, Teams, Slack), the menu bar icon pulses and a notification banner offers a "Record" action that calls the same recording entry point as the global hotkey. Per-app and global opt-outs live in Settings → Recording. No calendar integration; no auto-record.

- [ ] **Step 2:** (Skip if you prefer — CLAUDE.md is a living doc and the maintainer may have a preferred moment to update it.)

**Verification:**
- `git diff CLAUDE.md` is readable and confined to the new bullet.

---

## Success criteria for the whole plan

- [ ] `swift build` succeeds on arm64 macOS 14+.
- [ ] `swift test --filter HarcMeetingDetectTests` passes all 9 unit tests.
- [ ] Manual test matrix (Task 12) all green.
- [ ] Settings UI renders without layout regressions against existing tabs.
- [ ] No new required entitlements.
- [ ] Feature disables cleanly (global toggle OFF → zero observable behavior).

## Rollout

- v1: ship with global toggle **OFF by default**. Dogfood internally for a week.
- v1.1: flip default to **ON**. Optional: Slack default to ON if feedback warrants.
- v2: address open questions (Google Meet, calendar) per the design doc's Future Work section.
