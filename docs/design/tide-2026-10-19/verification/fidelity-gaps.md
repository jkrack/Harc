# Tide fidelity pass — November 1, 2026

Base: `7cfb9e7`, `claude/jolly-lamport-ei6djr`. All app captures use isolated DEBUG roots and synthetic PCM. They do not establish real capture, voice recognition, pairing or transfer reliability. No production Library was opened or changed.

## State matrix (defined before presentation changes)

| Surface | State selector | Required contents | Dark | Light |
| --- | --- | --- | --- | --- |
| Mac Library | `complete` | 42 minutes; title, transcript, summary, three speakers, two actions, notes | Captured manually | Captured manually |
| Mac Library | `untitled` | No title or suggestion; empty OKF transcript, no summary | Captured manually | Captured manually |
| Mac Library | `zero` | Zero PCM frames, no envelope | Captured manually | Captured manually |
| Mac Library | `short` | 0.4 seconds, no useful duration | Captured manually | Captured manually |
| Mac Library | `integrity` | Complete fixture plus persisted buffer-overrun warning | Captured manually | Captured manually |
| Mac Library | `origins` | Two recordings: named iPhone origin and absent origin | Captured manually | Captured manually |
| Mac Library | `live` | Existing DEBUG fake capture loop, no microphone | Captured manually | Captured manually |
| Mac Library | `short-day` | 18 distinct rows, 0/0.4/1 seconds, two seconds apart; top and scrolled | Captured manually | Captured manually |
| Mac Library | `empty` | No rows | Captured manually | Captured manually |
| iPhone Record / Library / Search / Setup | unpaired | Existing scoped simulator fixture, no Host | Captured | Captured |
| iPhone Record / Setup | paired with waiting transfers | No existing UI fixture: existing cache fixture creates neither adoption nor transfers | Deferred | Deferred |
| iPhone recording | recording | Existing UI test requires physical microphone; simulator has no capture UI fixture | Deferred | Deferred |
| iPhone Live Activity | recording / expanded / compact | Existing physical UI test and intent unit fixtures; no simulator ActivityKit presentation fixture | Deferred | Deferred |

Mac launch: `HARC_UI_TESTING=1 HARC_UI_TEST_SEED_LIBRARY=1 HARC_UI_TEST_OPEN_LIBRARY=1 HARC_UI_TEST_ROOT=<fresh root> HARC_UI_TEST_LIBRARY_STATE=<selector> HARC_UI_TEST_APPEARANCE=dark|light`. Run `HarcAppUITests/testTideFidelityStateMatrix` for the repeatable matrix. iPhone: `HarcMobileReleaseReadinessUITests/testTideFidelityUnpairedStateMatrix`, using the existing root/reset arguments and the same appearance environment key.

## Gaps (recorded before fixes)

References were opened from the checked-in HTML over loopback HTTP. Mock data, calendar entries, topics and summary pins must not become invented product data. The table distinguishes source findings from captured observations; pending rows are not visual verification.

| Screen | State | Element | What the mock does | What the build does at baseline | Fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Mac Library | all | Window/title bar/footer | One opaque navy-to-blue surface | Transparent title bar but default window backdrop remains; gradients restart in child columns (source) | Make window backdrop opaque; keep the gradient under chrome and an opaque darker sidebar as in the mock; move search into the toolbar; omit the repeated navigation title | Implemented; awaiting recheck |
| Mac Library | inspector open | Inspector surface | The Library window uses the same opaque Tide color roles; no separate inspector artboard | Source review found an explicit thin material behind the grouped inspector | Hide its scroll backdrop and use an opaque Tide surface | Recorded before this fix |
| Mac Library | all | Search bezel | Quiet blue field on Tide surface | Captured dark search bezel is visibly brown over Red Orange wallpaper | Explicit field fill and border, retain native search semantics | Implemented; awaiting recheck |
| Mac Library | complete | Primary toolbar action | Cyan Copy for Prompt capsule | Baseline uses the system toolbar treatment and retains a repeated window title | Explicit cyan capsule, quiet secondary controls, no shared glass background | Recorded before this fix |
| Mac Library | integrity | Warning color | Gold is reserved for decision/action pins | Baseline integrity warning uses the gold attention color | Keep the warning text and triangle in primary foreground | Recorded before this fix |
| Mac Library | search | Clear button | Clearing search returns the recording list | Existing UI test exposed stale bound query after the native toolbar clear action | Keep native button tracking, draw only the cell interior, and synchronize native search actions with the binding | Recorded before this fix |
| Mac Library | selected | Sidebar selection | Soft cyan wash | Captured selection is a solid gray system fill; reported blue depends on active accent. Both cover the intended soft tint | Suppress native row selection and render shared cyan selection token | Implemented; awaiting recheck |
| Mac Library | filtered / short-day | Today count | Same day's inventory and total duration | Captured counts agree at 1, 2 and 18 rows; source uses filtered `recordings`, so search can change the overview. The reported unfiltered mismatch was not reproduced | Derive overview from full observed inventory; keep rows unchanged | Implemented; awaiting recheck |
| Mac Library | untitled | Summary availability | No unavailable actions | Captured untitled, zero and subsecond states show Generate beside No transcript available | Use loaded editor content for both presentations | Implemented; awaiting recheck |
| Mac Library | zero / short | Audio panel | Deliberate compact empty treatment | Captured zero frame WAV retains disabled play and 0:00/0:00; 0.4 sec draws a full chart with repeated 0:00 ticks | Compact no-audio row; show playback only with audio; no invented envelope | Implemented; awaiting recheck |
| Mac Library | today / short-day | Repeated date | One Today heading above the day and its rows | Baseline repeats Today below the date scope bar | Omit the redundant Today section header; retain older date groups | Recorded before this fix |
| Mac Library | empty | Detail | Intentional empty surface | Captured generic No Item Selected beside a second empty-Library message | One clear record-first empty message | Implemented; awaiting recheck |
| Mac Library | origins | Device copy | Plain named device | Captured “Recording origin unavailable” for absent origin; known iPhone label is retained | Missing origin: omit device clause; unknown named origin: “Another device”; retain known label | Implemented; awaiting recheck |
| Mac Library | complete / short-day | Duration captions | Human units such as 42 min, alongside the playback clock | Baseline uses clock strings for metadata too | Use compact duration units in metadata; keep the precise playback clock | Recorded before this fix |
| Mac Library | untitled / short-day | Title and row time | Content in normal foreground | Captured gray title invitation; all 18 short rows show the same minute and 0:00/0:01 | Foreground untitled title invitation; include seconds for short rows without hiding any | Implemented; awaiting recheck |
| Mac Library | complete | Speaker color agreement | Each speaker keeps the same hue in transcript, lane and talk time | Captured Jason is orange in the transcript but purple in the lane and talk-time card | Reuse the existing transcript name-color policy for all three presentations | Recorded before this fix |
| Mac Library | complete | Summary / talk time density | Mock has a caption header, no model metadata in the card, and one line per speaker | Captured model ID and relative time take two extra lines; each speaker uses a separate bar line; notes fall below the initial viewport | Keep provenance in the header tooltip, use inline talk-time bars, compact notes minimum height | Recorded before this fix |
| Mac Library | complete | Type hierarchy | Rounded bold title/numerals; small rounded conditions and captions | Title/numerals partially match; talk-time rows inherit body size (source) | Shared Tide title/numeral roles; caption talk-time rows | Implemented; awaiting recheck |
| Mac/iPhone traces | saved / live | Curve and fill | Smooth blue unplayed, white played; transparent lower fill | Captured light played segment is black at 6:40; both appearances draw dense jagged straight joins and a nonclear fill baseline | Shared bounded smooth path; white played token and fully fading fill | Implemented; awaiting recheck |
| Mac/iPhone traces | saved / live | Now dot | Red dot with white ring on curve | Cyan live dot / primary day dot; Mac playback dot sits on baseline (source) | Shared recording-red dot and white ring at actual interpolated level | Implemented; awaiting recheck |
| Mac Library | complete | Insights | Aligned with transcript top | Insights add 12pt top inset, transcript starts above (source) | Remove extra top inset, consistent padding/radius | Implemented; awaiting recheck |
| Mac Library | short-day scrolled | Date-scope boundary | Rows stay within scroll area | No text crossed the date bar in the captured top/scrolled offsets; reported clipping was not reproduced | Clip list below bar and remove scroll-edge material | Implemented; awaiting recheck |
| Mac Library | playback | Play action color | Interactive emphasis uses cyan; data remains blue | Source uses the curve-blue tint behind a white Play icon | Use shared adaptive cyan and on-accent foreground for the existing button | Recorded before this fix |
| Mac Library | complete / playback | Curve controls | Plot and ringed marker remain unobscured | Supplementary review at `7f20299`: overlaid Play and clock can cover the curve at the ends | Move existing Play to the axis row; retain the large clock above the plot | Recorded before this fix |
| iPhone Record | unpaired | Privacy caption contrast | Subordinate but readable privacy copy | Existing accessibility audit at `7f20299` fails contrast for the native secondary caption | Shared adaptive Tide caption color, keeping the smaller type hierarchy | Recorded before this fix |
| Mac/iPhone | all | Decision/action curve pins | Gold pins at actual timestamps | Summary has no decision/action timestamps | Requires new summarizer data; no fake pins | Deferred: data outside this pass |
| Mac/iPhone | day overview | Day curve | Illustrative speech-energy day curve | Actual data is recording intervals, not measured full-day audio energy | Keep honest intervals; red now dot; do not synthesize energy | Intentional deviation: no day-energy data |
| iPhone Record | unpaired | Empty Today chart | Day card carries actual meetings | Captured empty card is 120pt of axis and a lone dot; also shows 0 to send and a success line | Compact empty-day copy; omit zero transfer condition and empty success line | Implemented; awaiting recheck |
| iPhone Library / Search / Setup | unpaired | Card surfaces | Quiet translucent-blue cards within Tide | Captured cards are system black/white blocks over the blue gradient | Use shared Tide card fill for these existing rows | Implemented; awaiting recheck |
| iPhone Record / tabs | unpaired | Interactive color and copy | Cyan controls, plain Mac names | Captured system-blue tabs/actions and “Pair a Host” | Shared adaptive cyan tint and readable accent-button foreground; “Pair a Mac” and “No Mac paired” | Implemented; awaiting recheck |
| iPhone Record | recording | Hierarchy and plot | Conditions, bold clock, Recording heading, 200pt past-audio plot, 96pt stop presence | Retained baseline has Recording above conditions, a 110pt blue plot with a cyan dot, and the 194pt hero control | Reorder existing clock/heading, use white for measured past activity, add a readable light plot surface and a Tide size for the existing renderer | Supplementary retained baseline; implemented, awaiting capture |
| iPhone Record | recording | Timer type | Rounded 56pt bold numerals | Retained pre-fix simulator capture shows a 56pt light clock | Keep its Dynamic Type scaling and use bold weight | Recorded before this fix |
| iPhone Record | unpaired | Type | Rounded bold Tap to record; subordinate privacy line | Captured Tap to record uses regular system hierarchy | Rounded headline and secondary privacy caption | Implemented; awaiting recheck |
| iPhone Live Activity | recording | Title / energy | Named recording and energy curve | Attributes contain capture ID and start, state contains phase and durable seconds, but no title or energy | No new activity payload in a fidelity pass | Deferred: new data contract |

## Capture-start concern

Real libraries reportedly contain several 0:00–0:01 recordings in the same minute. The `short-day` fixture preserves all 18 distinct recordings and includes true zero-frame WAVs. This is a possible capture-start failure; this presentation-only pass must not hide the rows or claim to diagnose the capture path.

## Validation and evidence

Implemented; awaiting recheck build, captures and post-fix test runs. A test attempt or successful build is not a visually inspected screenshot. Exact results and any blocked rows will be recorded here.
