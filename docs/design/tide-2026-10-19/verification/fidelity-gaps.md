# Tide fidelity pass — November 1, 2026

Base: `7cfb9e7`, `claude/jolly-lamport-ei6djr`. Mac captures use isolated DEBUG Libraries with synthetic PCM; iPhone captures use scoped simulator storage and simulator microphone input. They do not establish real capture, voice recognition, pairing or transfer reliability. No production Library was opened or changed.

## State matrix (defined before presentation changes)

| Surface | State selector | Required contents | Dark | Light |
| --- | --- | --- | --- | --- |
| Mac Library | `complete` | 42 minutes; title, transcript, summary, three speakers, two actions, notes | Before / after captured | Before / after captured |
| Mac Library | `untitled` | No title or suggestion; empty OKF transcript, no summary | Before / after captured | Before / after captured |
| Mac Library | `zero` | Zero PCM frames, no envelope | Before / after captured | Before / after captured |
| Mac Library | `short` | 0.4 seconds, no useful duration | Before / after captured | Before / after captured |
| Mac Library | `integrity` | Complete fixture plus persisted buffer-overrun warning | Before / after captured | Before / after captured |
| Mac Library | `origins` | Two recordings: named iPhone origin and absent origin | Before / after captured | Before / after captured |
| Mac Library | `live` | Existing DEBUG fake capture loop, no microphone | Before / after captured | Before / after captured |
| Mac Library | `short-day` | 18 distinct rows, 0/0.4/1 seconds, two seconds apart; top and scrolled | Before / after captured | Before / after captured |
| Mac Library | `empty` | No rows | Before / after captured | Before / after captured |
| iPhone Record / Library / Search / Setup | unpaired | Existing scoped simulator fixture, no Host | Captured | Captured |
| iPhone Record / Setup | paired with waiting transfers | No existing UI fixture: existing cache fixture creates neither adoption nor transfers | Deferred | Deferred |
| iPhone Record / Library | recording | Existing navigation-shell UI test starts and stops simulator capture; four supplementary recording captures | Captured | Captured |
| iPhone Live Activity | recording / expanded / compact | Existing physical UI test and intent unit fixtures; no simulator ActivityKit presentation fixture | Deferred | Deferred |

Mac launch: `HARC_UI_TESTING=1 HARC_UI_TEST_SEED_LIBRARY=1 HARC_UI_TEST_OPEN_LIBRARY=1 HARC_UI_TEST_ROOT=<fresh root> HARC_UI_TEST_LIBRARY_STATE=<selector> HARC_UI_TEST_APPEARANCE=dark|light`. Run `HarcAppUITests/testTideFidelityStateMatrixDark` and `HarcAppUITests/testTideFidelityStateMatrixLight` for the repeatable matrix. iPhone: `HarcMobileReleaseReadinessUITests/testTideFidelityUnpairedStateMatrix`, using the existing root/reset arguments and the same appearance environment key.

## Gaps (recorded before fixes)

References were opened from the checked-in HTML over loopback HTTP. Mock data, calendar entries, topics and summary pins must not become invented product data. The table distinguishes captured observations from source findings. Supplementary gaps were recorded before their own fixes. Light appearance adapts the same hierarchy and color roles from the dark artboards.

| Screen | State | Element | What the mock does | What the build does before its fix | Fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Mac Library | all | Window/title bar/footer | One opaque navy-to-blue surface | Transparent title bar but default window backdrop remains; gradients restart in child columns (source) | Make window backdrop opaque; keep the gradient under chrome and an opaque darker sidebar as in the mock; move search into the toolbar; omit the repeated navigation title | fixed |
| Mac Library | inspector open | Inspector surface | The Library window uses the same opaque Tide color roles; no separate inspector artboard | Source review found an explicit thin material behind the grouped inspector | Hide its scroll backdrop and use an opaque Tide surface | fixed |
| Mac Library | all | Search bezel | Quiet blue field on Tide surface | Captured dark search bezel is visibly brown over Red Orange wallpaper | Explicit field fill and border, retain native search semantics | fixed |
| Mac Library | complete | Primary toolbar action | Cyan Copy for Prompt capsule | Baseline uses the system toolbar treatment and retains a repeated window title | Explicit cyan capsule, quiet secondary controls, no shared glass background | fixed |
| Mac Library | integrity | Warning color | Gold is reserved for decision/action pins | Baseline integrity warning uses the gold attention color | Keep the warning text and triangle in primary foreground | fixed |
| Mac Library | search | Clear button | Clearing search returns the recording list | During this pass, the existing UI test exposed a clear-action regression in the toolbar field | Keep native button tracking, draw only the cell interior, and synchronize native search actions with the binding | fixed |
| Mac Library | selected | Sidebar selection | Soft cyan wash | Captured selection is a solid gray system fill; reported blue depends on active accent. Both cover the intended soft tint | Suppress native row selection and render shared cyan selection token | fixed |
| Mac Library | filtered / short-day | Today count | Same day's inventory and total duration | Captured counts agree at 1, 2 and 18 rows; source uses filtered `recordings`, so search can change the overview. The reported unfiltered mismatch was not reproduced | Derive overview from full observed inventory; keep rows unchanged | fixed: full-inventory derivation; original unfiltered mismatch not reproduced |
| Mac Library | untitled | Summary availability | No unavailable actions | Captured untitled, zero and subsecond states show Generate beside No transcript available | Use loaded editor content for both presentations | fixed |
| Mac Library | zero / short | Audio panel | Deliberate compact empty treatment | Captured zero frame WAV retains disabled play and 0:00/0:00; 0.4 sec draws a full chart with repeated 0:00 ticks | Compact no-audio row; show playback only with audio; no invented envelope | fixed |
| Mac Library | today / short-day | Repeated date | One Today heading above the day and its rows | Baseline repeats Today below the date scope bar | Omit the redundant Today section header; retain older date groups | fixed |
| Mac Library | empty | Detail | Intentional empty surface | Captured generic No Item Selected beside a second empty-Library message | One clear record-first empty message | fixed |
| Mac Library | origins | Device copy | Plain named device | Captured “Recording origin unavailable” for absent origin; known iPhone label is retained | Missing origin: omit device clause; unresolved device label: “Recorded on another device”; retain known label | fixed |
| Mac Library | complete / short-day | Duration captions | Human units such as 42 min, alongside the playback clock | Baseline uses clock strings for metadata too | Use compact duration units in metadata; keep the precise playback clock | fixed |
| Mac Library | untitled | Empty title invitation | Real titles use normal foreground | Native title prompt is gray when there is no title or suggestion | Preserve an editable naming invitation; never save a fabricated title | intentional deviation: native prompt remains distinct from saved content |
| Mac Library | short-day | Row title and time | Readable titles and distinct recording times | All 18 short rows show the same minute and 0:00/0:01 | Primary row titles, human duration units, and seconds for short rows; retain every row | fixed |
| Mac Library | complete | Speaker color agreement | Each speaker keeps the same hue in transcript, lane and talk time | Captured Jason is orange in the transcript but purple in the lane and talk-time card | Reuse the existing transcript name-color policy for all three presentations | fixed |
| Mac Library | complete | Summary / talk time density | Mock has a caption header, no model metadata in the card, and one line per speaker | Captured model ID and relative time take two extra lines; each speaker uses a separate bar line; notes fall below the initial viewport | Keep provenance in the header tooltip, use inline talk-time bars, compact notes minimum height | fixed |
| Mac Library | complete | Type hierarchy | Rounded bold title/numerals; small rounded conditions and captions | Title/numerals partially match; talk-time rows inherit body size (source) | Shared Tide title/numeral roles; caption talk-time rows | fixed |
| Mac/iPhone traces | saved / live | Curve and fill | Smooth blue unplayed, white played; transparent lower fill | Captured light played segment is black at 6:40; both appearances draw dense jagged straight joins and a nonclear fill baseline | Shared bounded smooth path; white played token and fully fading fill | fixed |
| Mac/iPhone traces | saved / live | Now dot | Red dot with white ring on curve | Cyan live dot / primary day dot; Mac playback dot sits on baseline (source) | Shared recording-red dot and white ring at actual interpolated level | fixed |
| Mac Library | complete | Insights | Aligned with transcript top | Insights add 12pt top inset, transcript starts above (source) | Remove extra top inset, consistent padding/radius | fixed |
| Mac Library | short-day scrolled | Date-scope boundary | Rows stay within scroll area | No text crossed the date bar in the captured top/scrolled offsets; reported clipping was not reproduced | Clip list below bar and remove scroll-edge material | fixed: explicit clipping boundary; original overlap not reproduced |
| Mac Library | playback | Play action color | Interactive emphasis uses cyan; data remains blue | Source uses the curve-blue tint behind a white Play icon | Use shared adaptive cyan and on-accent foreground for the existing button | fixed |
| Mac Library | complete / playback | Curve controls | Plot and ringed marker remain unobscured | Supplementary review at `7f20299`: overlaid Play and clock can cover the curve at the ends | Move existing Play to the axis row; retain the large clock above the plot | fixed |
| iPhone Record | unpaired | Privacy caption contrast | Subordinate but readable privacy copy | Existing accessibility audit at `7f20299` fails contrast for the native secondary caption | Shared adaptive Tide caption color, keeping the smaller type hierarchy | fixed |
| Mac Library | complete | Distinct speaker hues | Mock gives all three speakers distinct colors | Existing name hash gives Amy and Priya the same hue | Reuse the current name-color policy consistently in transcript, lane and talk time | intentional deviation: preserve stable name colors across recordings; no palette-policy redesign |
| Mac/iPhone | all | Decision/action curve pins | Gold pins at actual timestamps | Summary has no decision/action timestamps | Requires new summarizer data; no fake pins | deferred: data outside this pass |
| Mac/iPhone | day overview | Day curve | Illustrative speech-energy day curve | Actual data is recording intervals, not measured full-day audio energy | Keep honest intervals; red now dot; do not synthesize energy | intentional deviation: no day-energy data |
| iPhone Record | unpaired | Empty Today chart | Day card carries actual meetings | Captured empty card is 120pt of axis and a lone dot; also shows 0 to send and a success line | Compact empty-day copy; omit zero transfer condition and empty success line | fixed |
| iPhone Library / Search / Setup | unpaired | Card surfaces | Quiet translucent-blue cards within Tide | Captured cards are system black/white blocks over the blue gradient | Use shared Tide card fill for these existing rows | fixed |
| iPhone Record / tabs | unpaired | Interactive color and copy | Cyan controls, plain Mac names | Captured system-blue tabs/actions and “Pair a Host” | Shared adaptive cyan tint and readable accent-button foreground; “Pair a Mac” and “No Mac paired” | fixed |
| iPhone Record | recording | Hierarchy and plot | Conditions, bold clock, Recording heading, 200pt past-audio plot, 96pt stop presence | Retained baseline has Recording above conditions, a 110pt blue plot with a cyan dot, and the 194pt hero control | Reorder existing clock/heading, use white for measured past activity, add a readable light plot surface and a Tide size for the existing renderer | fixed |
| iPhone Record | recording | Timer type | Rounded 56pt bold numerals | Retained pre-fix simulator capture shows a 56pt light clock | Keep its Dynamic Type scaling and use bold weight | fixed |
| iPhone Record | unpaired | Type | Rounded bold Tap to record; subordinate privacy line | Captured Tap to record uses regular system hierarchy | Rounded headline and adaptive Tide privacy-caption color | fixed |
| iPhone Record | recording | Name, discard, quality status | Mock includes a name input, discard action and Level good | Existing surface has no recording-name editor, discard action or measured quality verdict | Do not add editing/discard behavior or invent a quality verdict | deferred: new behavior or data outside this pass |
| iPhone Record / Setup | paired with waiting transfers | Visual evidence | Mock shows a named Mac and pending transfers | Existing cached-library fixture supplies metadata, not adoption or transfer state | Require a proper paired UI fixture or authorized Host qualification; do not fake trust | deferred: no existing paired/waiting UI fixture |
| iPhone Live Activity | system presentation | Visual evidence | Mock shows lock-screen and Dynamic Island layouts | Existing UI presentation test requires a physical iPhone and is skipped on the simulator | Obtain physical presentation captures without expanding activity data | deferred: physical UI evidence not captured |
| iPhone Live Activity | recording | Title / energy | Named recording and energy curve | Attributes contain capture ID and start, state contains phase and durable seconds, but no title or energy | No new activity payload in a fidelity pass | deferred: new data contract |

## Capture-start concern

Real libraries reportedly contain several 0:00–0:01 recordings in the same minute. The `short-day` fixture preserves all 18 distinct recordings and includes true zero-frame WAVs. This is a possible capture-start failure; this presentation-only pass must not hide the rows or claim to diagnose the capture path.

## Validation and evidence

All 38 retained before/after pairs were visually reviewed: 26 Mac pairs and 12 iPhone pairs. The Mac matrix contributes 22 states; paused playback at 6:40 and the inspector add four supplementary states. All captured surfaces have dark and light versions. Diagnostic evidence is separate from release or physical-device qualification.

| Final suite | Passed | Failed | Skipped | Source |
| --- | ---: | ---: | ---: | --- |
| Mac app tests | 78 | 0 | 0 | `71434cb` |
| Mac UI tests, including both complete matrices | 12 | 1 | 0 | `71434cb` |
| Mac speaker relink, isolated retry | 1 | 0 | 0 | `71434cb` |
| iPhone simulator app tests, normal bundle ID | 107 | 0 | 0 | `71434cb` |
| iPhone simulator UI suite | 13 | 0 | 5 | `b1995f2` |

The final full Mac run was **90 passed / 1 failed / 0 skipped**. The failed speaker-relink case terminated by SIGKILL. Its separate unchanged-product retry passed **1 / 0 / 0**; these attempts are not combined into a green full-suite claim. Both full state matrices passed in the final run. The earlier `7f20299` checkpoint passed all 91 cases, before the final caption, plot-control, inspector and capture-activation refinements.

The five simulator skips are four physical-only checks (microphone capture, background Live Activity Stop, storage exhaustion, force-quit recovery) and the opt-in App Store screenshot capture. The simulator navigation case does start and stop capture, but does not qualify a physical microphone, background recording or a lock-screen activity.

Source identities, executable hashes and environment are in [after-source.json](after-source.json); baseline provenance is in [baseline-source.json](baseline-source.json). The iPhone UI source at `b1995f2` includes the final shared style and mobile rendering. Later commits change Mac views/tests and add a mobile token-exempt comment. Normal-ID iPhone app tests use `71434cb`. No capture, transcription, transfer, pairing or storage behavior changed.

The before/after index and self-contained HTML gallery pair every retained state. Mac PNGs contain only the app window; iPhone PNGs contain the simulator screen. The original fixture-only baseline preceded presentation changes. Supplementary baseline replays use retained pre-fix binaries; they are identified in the provenance rather than presented as initial captures. Desktop-wide or occluded test attachments are excluded. The warm Red Orange desktop was checked with the final Mac app; Electric Blue was restored afterward. System sharing indicators, pointer highlights, focus changes and clocks are environment UI. Three old Mac baselines were refreshed from the same immutable pre-fix app to remove stale fixture text/loading, not to substitute a newer presentation.

The reported unfiltered Today-count mismatch and date-bar overlap were not reproduced. Full-inventory count derivation and an explicit list clipping boundary were added defensively; passing fixture checks do not establish the original real-library cause.

Earlier attempts are retained in [test-results.json](test-results.json). They include automation startup failures, bounded disk-floor stops, the native search clear regression, an overly exact floating-point assertion, an origin-selection fixture error, and UI runner termination. A passing 91-test checkpoint still produced two occluded empty-state images; visual review rejected those images and the fixture was hardened. The first full iPhone UI run was 12 passed / 1 failed / 5 skipped because the privacy caption failed contrast. Its corrected full rerun is 13 / 0 / 5. An earlier diagnostic-ID app run was 106 / 1 / 0 because the normal-ID metadata assertion correctly rejected the suffix; the normal-ID rerun passed without weakening that assertion.

Build caches and result bundles remain on `/Volumes/MacMiniSDD/HarcBuilds/tide-fidelity-20261101`. Builds and suites were serialized, used `xcodebuild -jobs 2` / `HARC_BUILD_JOBS=2`, and guarded the 5 GiB internal free-space floor. Xcode resolved Sparkle 2.10.1 (`ab7d71291238df6e0492143b120c9b696a35f603`); the Xcode-only pin and originHash churn are excluded from the PR.

CUA app/browser screenshots returned JPEG-encoded bytes; those files were normalized to actual PNG encoding without cropping, resizing or visual editing. Original encoded files remain on the SSD; details are in the source manifest.
