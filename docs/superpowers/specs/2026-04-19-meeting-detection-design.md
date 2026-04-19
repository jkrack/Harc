# Meeting Detection Design Doc

**Date:** 2026-04-19
**Status:** Draft — ready for implementation
**Owner:** Harc core
**Related plan:** `docs/superpowers/plans/2026-04-19-meeting-detection-plan.md`

---

## Problem & User Story

The number-one complaint about competing tools like Otter, Fireflies, Granola, etc. is:

> **"I forgot to turn it on."**

A user sits down, joins a Zoom call, talks for an hour, then realizes nothing was captured. Every minute of that meeting is lost. This is not a model-quality problem or a UX-polish problem — it's a *proactivity* problem. The tool needs to see the meeting coming and remind the human.

**User story.**

> As a Harc user, when I launch Zoom / Teams / Slack at the start of a meeting, I want Harc to notice immediately and offer a one-click "Record" button — so I don't have to remember a hotkey in the 30 seconds between "am I unmuted?" and "sorry, I was on mute."

**Success criteria.**
- Harc detects a monitored meeting app launching within ~1 second on a warm machine.
- The user sees both a pulsing menu bar icon and a notification banner with a "Record" action.
- One click on "Record" starts a recording identical to hitting the global hotkey.
- If the user declines (or ignores), Harc goes quiet and does not pester them again for the same app instance.
- The feature can be fully disabled with a single toggle, and per-app allowlists are easy to edit.

---

## Scope (v1)

**In scope:**
- App-launch detection via `NSWorkspace.shared.notificationCenter` (`didLaunchApplicationNotification`).
- Built-in allowlist: Zoom, Microsoft Teams, Slack.
- Per-app opt-in/opt-out toggles in Settings → **Recording** tab.
- Global "Enable meeting detection" master toggle.
- Menu bar icon pulse animation while a detection prompt is active.
- macOS user notification banner with a "Record" action button.
- First-run `UNUserNotificationCenter` authorization request (deferred until the first detection fires, not at app launch).
- Debouncing: one prompt per "meeting app session" (launch → terminate cycle).
- Auto-dismiss: pulse + notification stop when the user clicks Record, starts recording via another path, or dismisses the banner.

**Explicit non-goals:**
- **No calendar integration.** EventKit is not used. Approved by user — a running-app signal is stronger and has zero false positives from cancelled meetings.
- **No auto-record without prompt.** The user always confirms. Silent auto-capture is a trust violation for a tool that handles private meeting audio.
- **No Google Meet in v1.** See *App allowlist* below.
- **No "are you still in the meeting?" nagging.** One prompt per app-launch event. If the user dismisses it, we stay out of their way.
- **No in-meeting activity detection.** We do not probe whether a Zoom call is actually connected — only whether the app is running. Launching Zoom and quitting without joining produces one wasted prompt; acceptable.
- **No cross-device coordination.** The detection signal is local to this Mac.

---

## Architecture

### Module placement

Create a new Swift target: `HarcMeetingDetect`. It sits between HarcCore and HarcUI:

```
HarcCore        → IPC types, versioning (unchanged)
HarcMeetingDetect  ← NEW — NSWorkspace observation + notification scheduling
HarcUI          → Settings UI + pulse animation state
HarcApp         → wires MeetingDetector into AppDelegate
```

`HarcMeetingDetect` depends on AppKit (for `NSWorkspace`) and UserNotifications. It does **not** depend on HarcAudio or HarcClient — detection is decoupled from recording. The app layer (`AppDelegate`) is the only place those two worlds meet.

### Core types

```swift
// HarcMeetingDetect/MeetingApp.swift
public struct MeetingApp: Identifiable, Hashable, Codable, Sendable {
    public let id: String          // stable identifier, matches bundleID
    public let bundleID: String
    public let displayName: String
    public let symbolName: String  // SF Symbol for the notification/settings row
}

public enum MeetingCatalog {
    public static let builtIn: [MeetingApp] = [
        MeetingApp(id: "us.zoom.xos",
                   bundleID: "us.zoom.xos",
                   displayName: "Zoom",
                   symbolName: "video.fill"),
        MeetingApp(id: "com.microsoft.teams2",
                   bundleID: "com.microsoft.teams2",  // new Teams
                   displayName: "Microsoft Teams",
                   symbolName: "person.2.wave.2.fill"),
        // Legacy Teams is com.microsoft.teams — include both, see App Allowlist
        MeetingApp(id: "com.tinyspeck.slackmacgap",
                   bundleID: "com.tinyspeck.slackmacgap",
                   displayName: "Slack",
                   symbolName: "bubble.left.and.bubble.right.fill"),
    ]
}
```

### `MeetingDetector` — the observation actor

```swift
// HarcMeetingDetect/MeetingDetector.swift
@MainActor
public final class MeetingDetector {
    public protocol Delegate: AnyObject {
        func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp)
    }

    public weak var delegate: Delegate?

    private let workspace: WorkspaceObserving    // protocol — mockable
    private var token: NSObjectProtocol?
    private var activeDetections: Set<String> = []  // bundleIDs we've already prompted for

    public init(workspace: WorkspaceObserving = SystemWorkspace.shared) { ... }

    public func start() { /* register didLaunch + didTerminate observers */ }
    public func stop()  { /* remove observers */ }
    public func isEnabled(for app: MeetingApp) -> Bool { /* reads prefs */ }
    public func dismiss(bundleID: String) { /* user dismissed prompt */ }
}
```

Launch notifications carry the `NSRunningApplication` in `userInfo[NSWorkspaceApplicationKey]`. We extract `bundleIdentifier`, look it up in the catalog, check per-app and global prefs, check debouncing state, and — if all green — tell the delegate.

Terminate notifications clear the bundleID from `activeDetections` so a re-launch of the same app later in the day re-arms detection.

### `WorkspaceObserving` — the test seam

```swift
public protocol WorkspaceObserving {
    var runningApps: [NSRunningApplicationSnapshot] { get }
    func addDidLaunchObserver(_ handler: @escaping (String) -> Void) -> NSObjectProtocol
    func addDidTerminateObserver(_ handler: @escaping (String) -> Void) -> NSObjectProtocol
    func removeObserver(_ token: NSObjectProtocol)
}

public struct NSRunningApplicationSnapshot: Sendable {
    public let bundleID: String
}
```

Production: `SystemWorkspace` adapter over `NSWorkspace.shared.notificationCenter`. Tests: `FakeWorkspace` fires synthesized launch/terminate events.

### Event flow

```
NSWorkspace (system)
     │  didLaunchApplicationNotification(us.zoom.xos)
     ▼
MeetingDetector
     │  filter by allowlist + prefs + debounce
     ▼
delegate.meetingDetector(_:didDetect:)    (on MainActor)
     │
     ▼
AppDelegate.handleMeetingDetected(_:)
     ├─► RecordingState.beginPulse(for: "Zoom")     // icon pulses
     └─► MeetingNotificationPresenter.present(app)   // banner with "Record"

User clicks notification "Record" action
     │  UNUserNotificationCenterDelegate.didReceive
     ▼
AppDelegate.startRecording()   (same entry point as hotkey)
     └─► RecordingState.endPulse()                  // icon reverts
```

### Why a separate module?

- Isolates AppKit/UserNotifications code from HarcCore (which is intentionally deps-free).
- Lets `HarcMeetingDetect` be unit-tested without launching the app shell.
- Makes it easy to swap or extend the detection strategy later (e.g. add an EventKit strategy) without churning AppDelegate.

---

## App Allowlist — Bundle IDs and Google Meet

### Zoom
- **Bundle ID:** `us.zoom.xos`
- Native app. Clean launch signal. No known aliases.

### Microsoft Teams
- **Bundle ID (new Teams):** `com.microsoft.teams2`
- **Bundle ID (classic Teams):** `com.microsoft.teams`
- Microsoft is mid-migration. We register **both** in the catalog under a single user-visible entry "Microsoft Teams" so the Settings toggle controls the pair.
- **Implementation note:** `MeetingApp` gets an optional `aliasBundleIDs: [String]` so the same catalog entry matches multiple runtime bundles.

### Slack (with huddles)
- **Bundle ID:** `com.tinyspeck.slackmacgap`
- Native app. Launch signal covers both regular Slack use and huddles.
- **Caveat:** detecting that Slack launched does not mean a huddle is starting — the user might be opening Slack to read a message. We surface this honestly in the Settings copy: "Slack (will prompt on app launch, not just huddles)."
- **Mitigation:** per-app toggle is **off by default for Slack** in v1. Zoom and Teams are on by default. Users opt into Slack if they want it.

### Google Meet — dropped from v1

**The problem.** Google Meet runs inside a browser tab. There is no stable, user-facing "Meet app" bundle ID to observe. Candidate signals all have serious flaws:

| Signal | Why it fails |
|---|---|
| Watch for Chrome/Safari/Arc launch | Fires on every browser open — thousands of false positives per day. Users would disable detection entirely. |
| Scripting bridges (`AppleScript` to read the frontmost tab URL) | Requires Automation permission, fragile across browsers, feels invasive, and doesn't work when the user has tabs open in the background. |
| Accessibility API to scan window titles for "Meet" | Requires Accessibility permission (a much bigger ask than notifications), brittle, cross-browser nightmare. |
| PWA/installed-Meet apps (`com.google.Chrome.app.<hash>` bundle IDs) | Bundle IDs are per-install hashes — no stable identifier. Most users don't install Meet as a PWA anyway. |

**Recommendation: drop Google Meet from v1. Document the gap.**

In Settings, show a disabled "Google Meet — coming soon" row with a muted footnote: *"Meet runs in your browser, which makes reliable detection harder. We're tracking this."* This sets expectations honestly and gives us a place to land a future solution (likely a Chrome extension that signals Harc over a local endpoint, or tighter integration via a browser-specific shortcut).

**If the user demands Meet in v1** (future change): the least-bad shim is the Chrome PWA approach — ask the user to install Meet as a Chrome PWA, then let them add that PWA's bundle ID manually via a "Custom apps" section. Punted.

### Catalog extension mechanism

Beyond the built-in set, users can add arbitrary bundle IDs in a "Custom apps" table in Settings (stretch goal, flagged in Future Work — v1 ships with built-ins only).

---

## Event Debouncing & Edge Cases

The naive approach (prompt on every `didLaunchApplicationNotification`) misbehaves in several realistic scenarios. The rules below are the contract:

### Rule 1 — one prompt per launch cycle
A given bundle ID produces **at most one** detection event between a `didLaunch` and the next `didTerminate`. If the app is already in `activeDetections` when we observe a launch, ignore it.

### Rule 2 — app already running at Harc startup
When `MeetingDetector.start()` is called on app launch, we snapshot `NSWorkspace.shared.runningApplications`. Any monitored app already running is added to `activeDetections` **without** firing a prompt. Rationale: if Zoom was already open when the user launched Harc, they already know about it — no need to interrupt.

### Rule 3 — already recording
If `RecordingState.isRecording == true` when a detection fires, **suppress** both the pulse and the notification. Log to console for debugging. Rationale: prompting a user mid-recording to start a recording is absurd. When the current recording stops, we do **not** retroactively fire queued detections — that ship has sailed.

### Rule 4 — launch-then-quit before user reacts
If the app terminates before the user interacts with the notification, withdraw the notification (`UNUserNotificationCenter.removeDeliveredNotifications`) and stop the pulse. The user shouldn't get a "Record Zoom?" banner 10 seconds after they've already quit Zoom.

### Rule 5 — relaunch churn
Some apps quit and relaunch themselves on update. The `didTerminate` → `didLaunch` pair clears and re-arms the debounce set. That's fine — the user will see a second prompt on genuine relaunches. If this proves annoying in practice (e.g. Teams updating itself three times an hour), we add a 5-minute cooldown per bundleID. Not in v1 unless testing demands it.

### Rule 6 — per-prompt ignore
If the user dismisses the notification (swipe away / hits the close button), we mark the current detection as dismissed. Same semantics as Rule 1: no repeat until next terminate → launch cycle.

### Rule 7 — global toggle off
When the global "Enable meeting detection" pref is `false`, `MeetingDetector.start()` is a no-op and observers are not registered. Flipping the toggle on starts observation; flipping it off stops it and clears `activeDetections`.

---

## Notification UX

### Banner content

**Title:** `Meeting detected`
**Subtitle:** `Zoom is now running`  *(app display name varies)*
**Body:** `Start recording this meeting with Harc?`
**Actions:**
1. `Record` — primary action. Triggers start-recording.
2. `Not now` — dismisses. (Banners always have a Dismiss affordance; we add the explicit button so it's discoverable.)

Implementation uses `UNNotificationCategory` with a custom category identifier `harc.meetingDetected` carrying the two actions. The notification's `threadIdentifier` is set to the bundleID so macOS groups repeat prompts sanely.

### Menu bar icon pulse

**Visual spec.**
- Base icon: unchanged (`waveform` SF Symbol).
- Pulse overlay: the icon's `contentTintColor` animates between `nil` (default label color) and `HarcDesign.tertiary` (the purple "AI-generated" accent — distinct from the red "recording" state so users don't mistake the pulse for "already recording").
- Cadence: 1.2-second cycle, ease-in-out — not jarring.
- Implementation: a `Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true)` flipping a `pulseOn` boolean on `RecordingState` / a dedicated `MeetingDetectionState`, observed in the `updateMenuBarIcon` path.
- **Never** pulse while `isRecording == true` — recording state wins, pulse is cleared on `startRecording`.

**Pulse lifecycle.**
- Starts: on `didDetect`.
- Stops: on any of (a) user starts a recording, (b) user clicks the menu bar icon (opens popover — treated as "I saw it"), (c) the source app terminates, (d) 2 minutes elapse without interaction (timeout — clears pulse and withdraws notification).

### "Clicking the menu bar icon" path

When the user clicks the pulsing icon, the popover opens (existing behavior). The popover already has a giant gradient record CTA — no new UI needed. The pulse stops because, per above, opening the popover counts as acknowledgment.

---

## User Permission Flow

### First-run UNUserNotificationCenter authorization

`UNUserNotificationCenter.requestAuthorization` is triggered **lazily, on first detection**, not at app launch. Rationale: asking for notification permission during onboarding when the user hasn't even seen the feature yet has poor consent UX and lower opt-in rates.

Flow:

1. User installs Harc → no notification prompt yet.
2. User enables "Meeting detection" in Settings (default: ON in a future release; v1 ships OFF by default until the UX is proven — noted as an Open Question).
3. User launches Zoom → `MeetingDetector` fires delegate callback.
4. `MeetingNotificationPresenter.present(app)` calls `getNotificationSettings` →
   - `.notDetermined`: call `requestAuthorization([.alert, .sound])`. If granted, proceed to post notification. If denied, fall through to "pulse only" (see next section).
   - `.authorized` / `.provisional`: post the notification.
   - `.denied`: skip the notification, pulse the icon only. First time this happens in a session, log one line to the debug log; don't nag.

### Graceful degradation — notifications denied

If the user has denied notification permission:
- The menu bar icon still pulses exactly as specified.
- A small hint appears in the popover header row when the pulse is active: *"Zoom detected — click record"* rendered in `HarcDesign.Font.labelMd`, `onSurfaceVariant`. This substitutes for the banner CTA.
- The Settings → Recording row for "Meeting detection" shows a small warning: *"Notifications are disabled — only the menu bar icon will pulse."* with a "Open System Settings" shortcut button that deep-links to `x-apple.systempreferences:com.apple.preference.notifications?id=$(bundleID)`.

No downgrade for the Record action — the user can always click the pulsing icon.

---

## Settings UI

Lives in the **Recording** tab of the tabbed Settings window (existing scaffold assumption — the current `SettingsView` body becomes the Recording tab, with tab scaffolding from the separate Settings-tabs migration).

### Section shape

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

        // Google Meet — coming soon, disabled row
        HStack(spacing: HarcDesign.Space.sm) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Meet")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Text("Runs in your browser — reliable detection is coming")
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

    if meetingNotificationsDenied {
        Section {
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.harcError)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications disabled")
                        .font(HarcDesign.Font.labelMd)
                    Text("Only the menu bar icon will pulse.")
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Spacer()
                Button("Open System Settings", action: openNotificationSettings)
            }
        }
    }
}
```

### Preference storage

Add to `HarcPreferences`:

```swift
@Published public var meetingDetectionEnabled: Bool { didSet { ... } }
// Per-app: store as a [String: Bool] encoded via JSON in a single UserDefaults key.
@Published public var meetingAppEnabled: [String: Bool] { didSet { ... } }

// Defaults:
//   meetingDetectionEnabled = false   (v1 — prove the UX first; flip to true in v1.1)
//   meetingAppEnabled = ["us.zoom.xos": true,
//                         "com.microsoft.teams2": true,
//                         "com.tinyspeck.slackmacgap": false]
```

A small helper `meetingAppBinding(for:)` returns a `Binding<Bool>` for each catalog entry so the toggles bind cleanly.

---

## Error Handling

| Scenario | Behavior |
|---|---|
| `UNUserNotificationCenter` authorization call throws | Log to stderr, set internal `authorizationFailed = true`, pulse-only mode for the rest of the session. Next app launch retries. |
| `UNUserNotificationCenter.add(request:)` fails (rate limited, etc.) | Log, pulse-only fallback for this detection event. |
| Notification posts but NSWorkspace says the app already terminated before user tapped | Action callback checks `NSWorkspace.shared.runningApplications` — if the app isn't running, still start recording (the user asked for it explicitly). No app-state tie-in. |
| User clicks "Record" but recording fails to start (daemon down, mic denied, etc.) | Falls through to existing `presentError` alert path in AppDelegate. |
| `NSWorkspace` observation fails to fire at all | Not directly detectable. Mitigation: log when `MeetingDetector.start()` registers observers; unit tests use the fake workspace to verify our handler is invoked. Field issues manifest as "no pulse ever" and get diagnosed via console logs. |
| Two monitored apps launch within the same millisecond (Zoom + Slack at once) | Both detections fire. Pulse is an OR state — as long as *any* detection is active, icon pulses. Two notifications post (grouped by macOS on their bundleID `threadIdentifier`). Either "Record" action starts recording; the pulse clears for the app that was acted on, remaining active if the other is still pending. |
| `NSRunningApplication.bundleIdentifier` is nil (rare for unsigned processes) | Skip — nothing to match against the catalog. |

---

## Testing

### Unit testable via `WorkspaceObserving`

New test target: `HarcMeetingDetectTests`.

Test matrix:

1. **Launch → delegate fires once.** FakeWorkspace emits one launch event for `us.zoom.xos`. Assert delegate called with matching `MeetingApp`.
2. **Launch → launch → only one delegate call.** Same bundleID launched twice without terminate. Assert delegate called once (Rule 1).
3. **Launch → terminate → launch → delegate fires twice.** Full cycle. Assert two delegate invocations.
4. **Already-running skip.** FakeWorkspace `runningApps` includes Zoom at `start()`. Assert no delegate call for Zoom despite subsequent identity-match.
5. **Per-app opt-out.** Set `meetingAppEnabled["us.zoom.xos"] = false`. Launch Zoom. Assert no delegate call.
6. **Global disabled.** `meetingDetectionEnabled = false`. Call `start()`. Launch Zoom via fake. Assert no delegate call and no observer registered.
7. **Unknown bundleID ignored.** Launch `com.apple.finder`. Assert no delegate call.
8. **Recording-in-progress suppression.** Set RecordingState mock to `isRecording = true`. Launch Zoom. Assert no pulse / no notification posted.
9. **Teams aliasing.** Launch `com.microsoft.teams` (legacy). Assert we match the "Microsoft Teams" catalog entry.

### Manual test matrix

Must be exercised on actual hardware before merging. Tracked as a plan task.

| App | Test | Expected |
|---|---|---|
| Zoom | Launch Zoom fresh | Pulse + banner within ~1s |
| Zoom | Quit Zoom before reacting | Banner withdrawn, pulse stops |
| Zoom | Click Record in banner | Recording starts, pulse clears, icon turns red |
| Zoom | Already open when Harc launches | No prompt |
| Zoom | Quit Zoom, relaunch 10s later | Second prompt fires |
| Teams (new) | Launch | Prompt shows "Microsoft Teams" |
| Teams (classic) | Launch | Same — aliased to same catalog entry |
| Slack | Toggle OFF in Settings, launch Slack | No prompt |
| Slack | Toggle ON, launch Slack | Prompt fires (accept trade-off — will fire on non-huddle Slack launches) |
| Chrome / Safari (not in catalog) | Launch | No prompt |
| Any | While already recording | No prompt |
| Any | With notification permission denied | Pulse only, popover hint appears |
| Any | Global toggle off | No prompt ever |

---

## Future Work

- **Calendar integration (v2).** EventKit secondary signal: if a meeting event is on the calendar within ±10 min and a monitored app launches, upgrade the notification copy ("You have *Q3 Planning* on your calendar — record this meeting?") and pre-populate the recording title.
- **Auto-record-after-N-minutes (v2, opt-in).** After user ignores a detection for N minutes, silently start recording to the staging folder with a dismissable "currently recording" state. Requires strong visual indicators and explicit opt-in — do not enable by default.
- **User-extensible allowlist.** "Add custom app…" row in Settings with a native app picker.
- **Google Meet bridge (v2+).** Chrome/Arc extension that posts a local loopback event when the user joins a Meet URL. Ships separately from the app.
- **Smarter per-app heuristics.** E.g. for Slack, detect huddle-start specifically via the Accessibility API after a user grants permission; for Zoom, detect "in-meeting" vs. "launched-but-idle" by watching the process's audio-unit subscription.
- **Detection analytics (local only).** Count detections and conversion-to-recording locally; surface in a "You've captured 23/31 Zoom meetings this month" stat in the Library view. Zero network.

---

## Open Questions

- **Default for global toggle in v1:** ship OFF (current plan) or ON? On is higher-impact for UX but can annoy during rollout. Recommendation: OFF in v1, flip to ON in v1.1 after a week of dogfood.
- **Pulse timeout:** 2 minutes feels right, but is untested. Adjustable via internal constant.
- **Teams aliasing:** is there a world where a user wants "new Teams" monitored but not "classic Teams"? Probably not. Pair them.
- **Slack-on-by-default:** tentatively OFF to avoid annoying users who live in Slack all day. Revisit after usage data.
