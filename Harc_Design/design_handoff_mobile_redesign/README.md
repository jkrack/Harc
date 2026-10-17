# Handoff (DRAFT, still iterating): HarcMobile redesign (iOS 26)

## Overview

This redesign takes HarcMobile from a three-tab status dashboard to a two-tab
recording tool. It applies the calm quality of the Record tab (the
`design_handoff_mobile_record_screen` handoff, already shipped) to the rest of
the app.

Four structural changes:

1. **Tabs.** The app uses the iOS 26 Liquid Glass tab bar with two tabs,
   **Record** and **Library**, plus a system search tab (`Tab(role: .search)`).
   The **Host tab is removed.**
2. **Setup & Sync menu.** One sheet holds pairing, sending, Library refresh,
   storage, privacy, and diagnostics. It opens from the host pill at the top
   right of both tabs.
3. **One Library list.** "On This iPhone" and "Host Library" are no longer
   separate sections. There is one day-grouped list, and where a recording
   lives is shown as a badge.
4. **Content-first detail.** Summary, action items, and transcript come
   first. Status internals and edit forms move behind a Details row.

The deployment floor is already **iOS 26** (commit "Raise HarcMobile
deployment floor to iOS 26"). Do not add `#available` fallbacks for iOS 18.

## About the design files

`reference/*.dc.html` are static HTML mockups. They are a reference for
layout, hierarchy, and copy, not production code. Rebuild them in SwiftUI in
`HarcMobileApp/`. Hex values are approximations; use system materials, system
colors, and the existing palette (see Tokens). Links inside the files point
at the canvas's own file names and can be ignored.

| File | Screen |
|---|---|
| `P1-Record.dc.html` | Record tab, idle |
| `B-GlassTabBarWhileRecording.dc.html` | Library tab while a recording runs (tab bar + bottom accessory) |
| `P2-Library.dc.html` | Library tab, one list |
| `P3-RecordingDetail.dc.html` | Recording detail |
| `P4-SetupAndSync.dc.html` | Setup & Sync sheet (root) |
| `P5-SendingToMac.dc.html` | Setup › Sending to Mac |
| `P6-PairAMac.dc.html` | Pairing flow, step 2 (compare words) |
| `P7-Advanced.dc.html` | Setup › Advanced |

The recording-in-progress screen on the Record tab does not change. Keep
`HarcMobileCaptureHeroView` as shipped.

## Fidelity

High fidelity for information architecture, hierarchy, copy, and state
mapping. Medium fidelity for exact spacing: follow the system defaults of
`List`, `Form`, and `NavigationStack` before matching pixels.

## Shell and navigation

Files: `HarcMobileRootView.swift`, new files as needed.

- `TabView` with `Tab("Record", systemImage: "mic")`,
  `Tab("Library", systemImage: "rectangle.stack")`, and
  `Tab(role: .search)`. The search tab presents Library search (it moves out
  of the inline `.searchable` drawer on the Library list).
- `.tabBarMinimizeBehavior(.onScrollDown)` on the Library.
- `.tabViewBottomAccessory` appears only while a capture is recording or
  stopping, and only when the selected tab is not Record. Content: pulsing
  live dot, elapsed time (monospaced), recording title, round Stop button.
  When the bar is minimized (placement `.inline`), show only the dot, the
  time, and Stop. This replaces today's `captureBanner` safe-area inset.
- While recording, the Record tab label keeps the live elapsed time
  (`HarcMobileRecordTabLabel`, already shipped).
- **Host pill** (`HarcMobileHostPill`, already exists): add a trailing
  chevron-down glyph. Tapping it presents the Setup & Sync sheet instead of
  switching tabs. Use the same pill on Record (header) and Library
  (navigation bar trailing item).
- The rejected-capture-metadata warning currently pinned to the top inset
  moves to a row at the top of the Library list and the Setup sheet.

## Screens

### P1 Record, idle

- Header: "Record" (`.title2.bold`) and the host pill.
- Hero: unchanged blob and "Tap to record". Subline changes to **"Saved on
  this iPhone first, then sent to your Mac"** in `.footnote` with
  `.secondary` (the shipped code uses `.primary`; fix it).
- Bottom: the **Last recording** card replaces the pending card. It shows the
  newest local or Host recording: title (fall back to "Recording h:mm a"),
  "Today · 31 min · On this iPhone", and a trailing capsule "N waiting" when
  `effectivePendingCount > 0`. Tapping it opens that recording's detail.
- The "Recovered N durable recordings" label moves into the Library
  attention row. It should not compete with the hero.
- The terminal states (saved, storage full, failed) keep their logic. The
  "Saved locally" state adds an "Open recording" link next to Record Again.

### P2 Library

- Large title "Library" and the host pill as the trailing toolbar item. No
  cache menu and no review-sample button in the toolbar (both move to
  Advanced).
- **Attention row** (conditional, top of the list): one neutral rounded row,
  for example "2 recordings waiting to send to Studio Mac ›", which opens
  Sending to Mac. Show it only when something is pending, failing, or
  conflicted. Priority, one line only: security blocked (the only amber
  treatment) › conflicts › pending transfers › offline cache. Hide it when
  nothing is wrong.
- **One list**, grouped by day (Today, Yesterday, then dates). Merge
  `transferCoordinator.localRecordings` with `libraryCoordinator.recordings`.
  Once the Host has a recording, the Host row wins, so a recording never
  appears twice. Use upload identity or the receipt to map one to the other;
  if no reliable key exists, keep local rows separate and badged, and flag it.
- Row: title (semibold), "time · duration · N speakers", and up to two lines
  of summary snippet. Local-only rows show a small "iPhone" capsule badge and
  the subline "Transcript arrives after it reaches your Mac". Processing rows
  show "Transcribing on {Mac}…". Pinned rows show a pin glyph.
- Local-row actions (Play, Export) move to swipe actions and the detail
  screen. They are no longer inline buttons.
- Search results (search tab) reuse the same row with a highlighted snippet.

### P3 Recording detail

Replaces `HarcMobileRecordingDetailView`'s section order. Top to bottom:

1. Title as an inline editable text field (large, bold). Commit on submit or
   blur through the existing title mutation.
2. Meta line: "Wed, Oct 15 · 10:00 AM · 42 min".
3. Speaker chips, one per speaker label. Tapping a chip opens a small sheet
   to set the name (the existing `setSpeakerLabel`). An unnamed speaker shows
   a dashed chip, "Speaker 3 · Name".
4. Compact player: play/pause, scrubber, and elapsed time. It reuses the
   current canonical-audio download and play logic, with progress shown
   inline.
5. Segmented control: **Summary | Transcript | Notes**.
   - Summary: the generated summary paragraph, then "Action items". Render
     the action items as a list. Checkboxes are visual only unless a
     persisted completion field exists; do not invent storage.
   - Transcript: the existing transcript text.
   - Notes: the editable notes field with the existing save mutation.
6. **Details** row with the trailing summary "On Studio Mac · verified". It
   pushes a screen with the current Status rows (processing, projection, Host
   audio, revision), capture interruptions, and edit conflicts.

Toolbar trailing: Share (existing export flow) and a "More" menu with Pin or
Unpin, Edit tags, Export, and Details. Remove the "Edit on Host" form
section; title, tags, notes, and pin live where described above. Pending and
conflict mutation messages appear as a transient inline banner under the
title.

Local-only recordings use the same layout, with: no speakers, no summary,
the Transcript tab empty state "Transcript arrives after it reaches your
Mac", and a player that uses the protected local master.

### P4 Setup & Sync sheet

A `.sheet` with a `NavigationStack`, titled "Setup & Sync", with a Done
button.

- **Mac card:** Mac glyph, Host display name, status dot, and the line
  "Connected · checked 2 min ago" (from `HarcMobileHostHealthStatus` and
  `lastVerifiedAt`). Two buttons: **Check now** (`hostHealthCoordinator
  .refresh()`) and **Change Mac** (pairing flow). When unpaired, the card
  becomes "Pair your Mac" with one primary "Pair a Mac" button. When repair is
  required, it shows "Pairing needs repair" with a primary "Repair" button.
- Section **Sync**: "Sending to Mac" with the trailing value "N waiting" or
  "Up to date" (pushes P5). "Mac Library" with "Updated 5 min ago" (pushes P5,
  scrolled to the Library section).
- Section **This iPhone**: "Recordings & storage" with the trailing size
  (computed from the local masters; show nothing until computed). It pushes
  the existing local recordings list. "Privacy & data" pushes the existing
  `HarcMobilePrivacyView`.
- **Advanced** row (pushes P7).
- Footer: "Audio stays on your iPhone and your Mac. No cloud account."

### P5 Sending to Mac

- Status card: a small state chip (Paused, Sending, Up to date, Needs
  attention), a title ("2 recordings waiting"), and one plain-language
  paragraph from `HarcMobileSyncStatusPresentation`.
- This is **the only place** the transfer gate is explained. The
  `codecQualificationRequired` copy is: "Sending to your Mac isn't turned on
  in this version of Harc yet. Your recordings are safe here, and you can play
  or export them anytime."
- Section **Queue**: one row per pending local recording with title,
  date and duration, and a trailing state (Waiting, Sending, Failed, Retry).
- **Send now** is a full-width button that retries transfers. It is disabled
  while gated.
- Footer: "Each recording stays on this iPhone until your Mac confirms it has
  a verified copy."
- Section **Mac Library**: "Last updated" and "Refresh Library".

### P6 Pair a Mac

The existing pairing coordinator states, presented as a three-step flow in
a sheet: **1 Scan code**, **2 Compare words**, **3 Approve on Mac**. A
progress strip is shown at the top.

- Step 1: an explainer, then the camera scanner (`HarcPairingScannerView`).
  The permissions sentence moves here from the Host tab footer.
- Step 2 (mockup): heading "Do these words match?", the line "{Mac} is
  showing four words. They should be exactly the same as these.", the four
  words in a 2×2 grid (monospaced), "Code expires in N minutes", a primary
  **They match** button, and a destructive text button **They don't match**.
- Step 3: spinner and "Approve this iPhone on {Mac}."
- Success dismisses to the Setup sheet with the Mac card updated. Failure
  shows the message and a "Try again" button.

### P7 Advanced

- **Connection:** Transport ("Pinned TLS, signed grant"), Transfer format
  ("Lossless · not qualified" or "Lossless · qualified"), and Device ID
  (truncated, with a Copy button).
- **Mac Library cache:** "Clear downloaded audio" and "Rebuild Library
  cache", with the footer "Recordings on this iPhone are never touched by
  these."
- **Recovery:** "Files needing recovery" with a count, and "Open offline
  review sample".
- **Forget {Mac}** (destructive, keeps the existing confirmation dialog). The
  footer explains that this is local-only and that recordings stay.

## Copy rules

- User-facing **"Host" becomes "Mac"** ("Sending to Mac", "Mac Library",
  "Pair a Mac"). Code names stay.
- Remove every user-facing "in this build" string: the pending card, the sync
  row, and the row label "Transfer not enabled". The gate explanation lives
  only in P5.
- Drop jargon in UI copy: "canonical", "durable", "projection", "protected
  master", "receipt". These may appear in Advanced and Details only.

## Tokens

- Add an iOS token layer mirroring the Mac `Sources/HarcUI/DesignSystem/`
  idea: status colors only through one intent function (ready, working,
  attention, failure, live). Stop using raw `.orange`, `.red`, and `.green`
  in `HarcMobileApp/`.
- Delete the `HarcMobilePalette` duplicate of the private
  `HarcPresenceUI` palette. Expose what is needed from `HarcPresenceUI`
  instead (AGENTS.md: the presence package owns the palette).
- **Live red:** use the Mac's `HarcBrand.live` value (#F0554D) for recording
  chrome. The iOS coral (#E8334D) is retired for chrome; the blob's internal
  palette is untouched.
- **Interactive tint:** `Color.accentColor`, with the asset catalog accent
  set to the system blue. The mockups use a darker #0066D6 only for contrast
  in static HTML.
- Spacing: 20pt screen margins, 14pt card radius, 10pt row radius in list
  insets (system default).

## Accessibility

- Keep every existing `HarcMobileAccessibilityID`. Add IDs for the Setup
  sheet, the bottom accessory Stop, the Library attention row, and the detail
  segmented control.
- The bottom accessory Stop button has the label "Stop recording" and a
  44pt minimum target.
- Speaker chips and the segmented control must work with VoiceOver and the
  largest Dynamic Type sizes. At accessibility sizes, chips wrap and the
  player stacks.

## Tests to update

`HarcMobileUITests/` currently asserts on:
- `tabBars.buttons["Host"]`
- "Transfers not enabled in this build"
- "No Host paired"
- "Sync status" and `harc.mobile.library.sync-status`
- "On This iPhone"
- the `captureBanner` stop identifier

Update them to reach the same flows through the host pill, the Setup sheet,
and the bottom accessory. Keep the behaviors they protect: retry, local
recordings visible with no Host, review sample reachable, recovery label,
and storage-full and saved states.

## Suggested PR sequence

1. Shell: two tabs, search tab, bottom accessory, and the host pill opening a
   placeholder sheet that contains today's Host view. Remove the Host tab.
   Update the UI tests.
2. Setup & Sync sheet: P4, P5, P6, and P7, built from today's Host and sync
   views.
3. Library: one merged list, attention row, swipe actions, and search tab
   results.
4. Recording detail: P3.
5. Copy and tokens: the copy rules, the iOS intent colors, and the palette
   deduplication.

Each PR should build for the iOS 26 simulator, pass `HarcMobileAppTests` and
`HarcMobileUITests`, and keep the readiness gates in
`scripts/preflight-harcmobile-app-store.sh` green.

## Out of scope

- The Mac app.
- A Lock Screen Live Activity for capture. It is recommended as a follow-up
  but needs its own spec.
- Recording markers (shown only on the rejected tray option A).
- Any change to capture, transfer, pairing security, or storage behavior.
  This is a UI reorganization over the existing coordinators.
