# Read-only accepted connections map

This PR229-based slice adds a first branching map of one selected recording and its accepted project associations. It is an unhosted reusable view, not a production entry point, live graph, semantic extraction engine, or graph writer. PR228 and its history are excluded and untouched.

`confirmedProjectMap` reads the expected Host library/authority/state, active selected canonical recording, accepted reviews and current project names in one database read snapshot. It validates SQL/payload identities, propagates errors, and returns a bounded 1–50 associations with an explicit `hasMore` indicator. Pending/rejected/unsure candidates and unrelated recordings are not included. No filesystem, audio, model or network reads occur. The selected transcript is hashed once per snapshot; changed transcript or project evidence is marked stale without removing the prior human association. Empty results do not assert that no semantic relationship exists.

The view draws a recording card and branches to project cards in a vertically scrolling, narrow-width layout. It labels the map as a point-in-time snapshot and accepted associations as distinct from verified facts. Stale supporting evidence has an explicit textual warning, not color alone. Original quotations are disclosed as historical partial context, not current facts. Project names, titles and quotes render literally. The panel has no Store reference, model capability, assignment/navigation/export action or automatic scan.

Before production integration, provide observation/selection lifecycle to dispose of stale snapshots on Host, source, trash, project and decision changes. This immutable view alone supplies no live invalidation. Qualify actual light/dark and narrow-window visuals, disclosure interaction, keyboard/VoiceOver, real app navigation and all required CI. Do not infer playback timing from the quote or mistake a link for a typed decision/commitment edge.

Validation uses disposable synthetic on-disk Host libraries and unhosted NSHostingView layout. No private recording or accessibility tree is collected. The first run exposed an invalid in-memory Host fixture; it was corrected to the required disposable on-disk library rather than bypassing the Host check. Final results are recorded below after execution.

## Verified results

Focused map run passed all 8 test methods (15 parameterized invocations). The expanded regression passed 29 test methods: 25 Store methods and 4 UI/source-partition methods, including Unicode byte/grapheme partition coverage. The UI check compiles and lays out synthetic content in a 360×480 host in light and dark appearance; it is not screenshot, accessibility or interaction acceptance. `swift test` is not full Xcode or release qualification.

Independent review found no blocking privacy/correctness issue for this inactive slice after identity-corruption and Host-tuple tests were added and transcript hashing was reduced to once per snapshot. Production invalidation, large-text performance, rendered accessibility and full app integration remain unqualified. The association count is bounded, but legacy quote/name/transcript byte sizes are not bounded by this change.

## Test-only Store → window qualification follow-up

The opt-in `HARC_MAP_WINDOW_QA=1` harness now creates a disposable synthetic Host library, accepts two project associations, changes one project's brief, reads the authoritative snapshot and renders the actual panel in its own temporary window. No production entry point is installed. Both 360×640 light/dark view-only PNG captures were inspected: the selected recording, two association branches, current-source qualification and stale-evidence warning are readable. Disclosure controls remain collapsed; expanded excerpts, keyboard actions, screen-reader operation and contrast compliance were not qualified.

**Accessibility qualification failed / is inconclusive, not passed.** The final opt-in run returned exit 1 with 10 assertion issues across two appearances: three expected panel labels plus native and minimal SwiftUI control labels were not exposed in each appearance. Controls were attached to the same owned window, so this probe does not establish a map-specific accessibility defect. No permissions were changed or assertions weakened. The strict failing assertions are retained; the test is explicitly skipped without its opt-in environment variable, not counted as default-run coverage.

The diagnostic walks only the owned synthetic view, rejecting application/window/menu/unknown roles before reading text or traversing children, and records no raw accessibility dump. Captures contain only that view's synthetic pixels, never screen/window-server or global menu content. Independent review cleared the data/capture boundaries. A properly functioning scoped accessibility client and keyboard/VoiceOver checks remain an activation blocker. The previous 29-method regression pass does not supersede this failed qualification run.

## Lifecycle and scoped external accessibility follow-up

Added an inactive lifecycle adapter and presentation wrapper. Explicit selection registers a database-region observation before the atomic snapshot read. Selected recording/title/transcript/trash/canonical changes, review additions/decisions, linked-project changes and Host metadata changes invalidate and remove the visible snapshot. Resident Host loss, selection changes, distributed change notifications, dismissal and observer error/termination do the same. Generation checks reject late reads; no automatic re-read, inference, graph writes or production activation occurs. The future production caller still must forward resident Host/selection changes and present this wrapper rather than retain the immutable snapshot panel directly.

An independently run standalone synthetic app using a copy of the actual map panel implementation passed a separately scoped external accessibility check: heading, accepted-association label, unchanged-source and stale-source warnings were all found in the exact PID/title window (19 allowed nodes). This uses only `AXWindows` discovery and allowed-role children, not application children, menus or global trees; no permissions changed or raw AX values published. `AXHeading` was added to the test probe's allowlist. The standalone fixture uses snapshot/theme shims, not production Store/controller linking. This is positive scoped AX-label evidence, not VoiceOver, expanded-excerpt, keyboard or full app acceptance; the earlier in-process probe failure remains documented.

Independent lifecycle review found no blocking issue and requested an actual Store-mutation-during-read case, now included alongside dismissal, cancellation and selection invalidation races. No PR228 files or history were changed.

Final focused lifecycle/map/Unicode regression exited 0: 15 executed test methods passed (including 8 Store mutation, 4 lifecycle and 4 delayed-read parameter cases); the opt-in window/AX method was explicitly skipped. This does not replace its separately documented execution or full CI.

## Presentation teardown follow-through

The inactive wrapper now requires a captured presentation generation and uses
conditional dismissal. A late disappearance belonging to an old selection cannot
clear a newer map sharing its controller. The caller must capture the generation
**after `select` starts or completes**, and replace the wrapper/token for each new
selection; capturing before a deferred `.task` starts selection is not supported.
No production caller has been installed or qualified.

Regression coverage adds old-token dismissal followed by current-token dismissal,
and exercises current-token dismissal while a snapshot read is suspended. This is
controller-level coverage, not a SwiftUI sheet lifecycle qualification.

## Presentation content isolation follow-through

The inactive wrapper also gates content by the captured presentation identity,
not only teardown. An old wrapper cannot display the new selection's shared
controller snapshot while waiting to disappear. It instead shows an unavailable
message. The regression now selects two distinct synthetic recordings, checks
old/current ownership, and confirms old dismissal preserves the new snapshot.
Independent source review found no blocking issue; actual SwiftUI presentation
lifecycle/rendered interaction remains unqualified. No production entry point,
graph write, private source access or PR228 changes are included.

Final offline focused run passed all 5 lifecycle test methods (18 expanded
cases), zero failures/skips. This is not full CI, window interaction or release
qualification. Existing hosted Mac consent-test failure remains separate.

## Synchronous presentation preparation

The future caller no longer needs to race an asynchronous `select` to capture a
presentation ID. On the main actor, call `let ticket = controller.prepare(selection)`,
present the wrapper with `ticket.presentationID`, then `await controller.load(ticket)`
in its task. A ticket is consumed once, before suspension. A queued old ticket,
repeated task, or dismissed ticket cannot replace the newer selection or install
another observer. The existing async `select` convenience remains for non-view
callers/tests. This supersedes the earlier capture-after-select ordering contract.

The next user-visible integration should be an explicit read-only Accepted
connections action for the selected canonical recording in the existing resident
Host Connections flow. It must prepare synchronously, forward selection and Host
loss, and discard on dismissal. It must not run model extraction, scan other
recordings, or add a new graph writer. Before enabling it, qualify real app open,
selection change, dismiss/reopen, stale-source invalidation, and keyboard/VoiceOver
behavior plus CI. Phone/client graph sync is a separate protocol-qualified slice.
This change does not add that action or claim those qualifications.

Independent review found no blocking ticket lifecycle issue. Read/watch counters
now prove stale and dismissed tickets do no work, and duplicate loads add no
observer/read. Final offline regression passed 7 methods / 20 expanded cases,
zero failures/skips. SwiftUI integration and hosted CI remain separate gates.

## Actual SwiftUI wrapper lifecycle qualification

The opt-in `HARC_MAP_LIFECYCLE_WINDOW_QA=1` test now links the actual Store,
controller and selected-map SwiftUI wrapper in one owned synthetic NSWindow.
It prepares/loads recording A, observes its appearance, prepares/loads distinct
recording B, replaces the SwiftUI identity, verifies A's disappearance occurred
without clearing B, then removes B and verifies its disappearance clears the
snapshot. Bounded condition waits observe actual lifecycle callbacks rather
than assuming fixed animation delays. No screen capture, AX traversal, app
activation call, private source or production graph writer is used.

Independent review found no blocking correctness/privacy issue. This closes the
specific unhosted SwiftUI replacement/teardown gap; production sheet navigation,
Host-selection forwarding, keyboard/VoiceOver and full CI still require separate
qualification. The window test is explicitly opt-in, not default CI coverage.

Final opt-in run exited 0: all 8 test methods / 21 expanded cases passed,
including the actual window lifecycle test, with zero failures/skips.

## Explicit Host entry (draft integration, not distributed)

The draft now wires an explicit “Accepted connections for selected recording”
action into Host Connections. Merely opening Connections does not load a map.
The action prepares one canonical source ticket and asynchronously reads that
snapshot. Back, Done, source identity changes, sheet disappearance and observed
Host loss revoke it. Refresh is another explicit read of the same bound selected
source, not extraction or relationship mutation. A changed Host tuple stays
fail-closed; the UI instructs closing/reopening Connections for a fresh binding.

The sheet directly observes the bridge instead of assuming a canWrite closure
is observable. Production requires both live Host readiness and the existing
Store/runtime identity permission check. DEBUG UI fixtures use a separate
observable flag set only after the existing temporary-root guard and synthetic
Host lease succeed; they still require the fixture's exact Store/lease permission.
No real runtime is claimed to have started by that flag.

A synthetic app navigation test covers explicit open, exact source title,
Back/reopen, Refresh invocation, Escape and reopening without an automatically
loaded map. That new app test has not run locally; its Refresh assertion alone
is not proof of completed reload. Controller one-shot tests separately cover load
behavior. Package compilation/lifecycle evidence is not full app qualification.
The earlier “no production caller” descriptions above are historical; this draft
entry is now wired in source, but has not been merged, installed or released.

Final integration package build and opt-in synthetic lifecycle suite exited 0:
8 methods / 21 expanded cases passed, zero failures/skips. AppDelegate and app UI
test sources pass Swift parser checks only; full Xcode app/UI validation remains
pending on hosted CI, so this draft is not approved for merge or distribution.
