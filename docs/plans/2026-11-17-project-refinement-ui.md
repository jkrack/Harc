# Project review UI follow-on (separate from PR209 and release)

Status: proposed implementation contract, not an enabled screen.

## First experience

An optional Library section, “A few connections to review,” presents at most
three useful unresolved project matches. No global node-cloud, streak pressure
or compulsory daily queue. Empty queue quietly disappears.

Each card asks “Does this recording belong to [current project name]?” and shows:
- recording title, capture date and one verbatim evidence excerpt;
- “Why this connection?” with suggestion origin and source freshness;
- “Open recording” using the existing selection route;
- Yes / No / Not sure; a source with unqualified timestamps opens the recording,
  not a fabricated exact audio position.

Yes is an explicit recording/project assignment, not proof that every extracted
claim is true. No suppresses that pair until explicitly reconsidered. Not sure
removes it from the current session without teaching a negative match. Starting
another recording remains immediate and independent of this background work.

## Store prerequisites before wiring

1. Add bounded pending-review query joining active recordings and current project
   display data. Do not scan the entire Library on the main actor.
2. Explicit refresh creates new evidence only with user-visible renewed review;
   it must not erase an existing human assignment, rejection or uncertainty.
3. Return an application outcome distinguishing newly committed, exact replay,
   superseded and undone operations. Historical receipts cannot replay rewards.
4. Add file-backed reopen and injected transaction-failure tests. Define project
   rename (display only) separately from changed project meaning/version.
5. Only expose local mutations under the current canonical writer authority.
   Do not enable secondary-client/phone writes until authenticated Host RPC/sync
   is deliberately implemented and qualified.

## View-model and interaction contract

A dedicated ProjectRefinementViewModel owns a bounded snapshot, in-flight
operation IDs and cancellation/selection generation. It calls the Store off
MainActor, then publishes only to the still-current screen. A retry reuses the
same operation ID; the UI disables duplicate buttons while pending.

After a newly committed Yes: “Added 1 recording to [project]” with Undo.
Already assigned: “Already in [project],” no new-impact celebration.
No: “Connection dismissed.” Not sure: “Saved for later.”
Never show a precision percentage or predicted reach as measured improvement.
Success haptic occurs only for a newly persisted user action, after commit;
no success haptic on tap, stale conflict, replay, failure or canceled navigation.
Use existing iOS haptic service if shared safely; macOS does not promise phone
haptics. Respect Reduce Motion and design tokens. No timeout silently removes
Undo before the person can understand the result.

Undo uses its original operation ID and version-protected Store API. Conflict
shows “This connection changed since your answer” with refresh, never force
rollback. A retained human assignment with stale evidence remains assigned and
shows “Source changed; review evidence” instead of disappearing.

## Validation before enabling

- deterministic model tests: duplicate tap, response-after-navigation, disk/DB
  failure, retry/replay, conflicting undo and session-level Not sure deferral;
- real soft-delete/restore, changed transcript and current project-name fixtures;
- keyboard, VoiceOver labels, Dynamic Type, Reduce Motion and source navigation;
- app-hosted UI tests plus actual app build, using isolated test library;
- no inference, Library scan or database work blocking capture/timer responsiveness;
- phones and secondary Macs remain read-only/hidden until authority path exists.

The graph picture comes later. This first experience earns trust through a small
number of useful decisions, visible source evidence and honest, reversible impact.
