# Read-only accepted connections map

This PR229-based slice adds a first branching map of one selected recording and its accepted project associations. It is an unhosted reusable view, not a production entry point, live graph, semantic extraction engine, or graph writer. PR228 and its history are excluded and untouched.

`confirmedProjectMap` reads the expected Host library/authority/state, active selected canonical recording, accepted reviews and current project names in one database read snapshot. It validates SQL/payload identities, propagates errors, and returns a bounded 1–50 associations with an explicit `hasMore` indicator. Pending/rejected/unsure candidates and unrelated recordings are not included. No filesystem, audio, model or network reads occur. The selected transcript is hashed once per snapshot; changed transcript or project evidence is marked stale without removing the prior human association. Empty results do not assert that no semantic relationship exists.

The view draws a recording card and branches to project cards in a vertically scrolling, narrow-width layout. It labels the map as a point-in-time snapshot and accepted associations as distinct from verified facts. Stale supporting evidence has an explicit textual warning, not color alone. Original quotations are disclosed as historical partial context, not current facts. Project names, titles and quotes render literally. The panel has no Store reference, model capability, assignment/navigation/export action or automatic scan.

Before production integration, provide observation/selection lifecycle to dispose of stale snapshots on Host, source, trash, project and decision changes. This immutable view alone supplies no live invalidation. Qualify actual light/dark and narrow-window visuals, disclosure interaction, keyboard/VoiceOver, real app navigation and all required CI. Do not infer playback timing from the quote or mistake a link for a typed decision/commitment edge.

Validation uses disposable synthetic on-disk Host libraries and unhosted NSHostingView layout. No private recording or accessibility tree is collected. The first run exposed an invalid in-memory Host fixture; it was corrected to the required disposable on-disk library rather than bypassing the Host check. Final results are recorded below after execution.

## Verified results

Focused map run passed all 8 test methods (15 parameterized invocations). The expanded regression passed 29 test methods: 25 Store methods and 4 UI/source-partition methods, including Unicode byte/grapheme partition coverage. The UI check compiles and lays out synthetic content in a 360×480 host in light and dark appearance; it is not screenshot, accessibility or interaction acceptance. `swift test` is not full Xcode or release qualification.

Independent review found no blocking privacy/correctness issue for this inactive slice after identity-corruption and Host-tuple tests were added and transcript hashing was reduced to once per snapshot. Production invalidation, large-text performance, rendered accessibility and full app integration remain unqualified. The association count is bounded, but legacy quote/name/transcript byte sizes are not bounded by this change.
