# Speaker review refresh generation

Base: edb40cc2b786f1b636838c6544a25d8aafdc48e3 (PR 197).

## Failure and scope

CI run 43604284567 passed the exact unassigned picker-state wait, then failed the final relink in `testBoundSpeakerCreateUnassignAndRelinkSurviveRelaunch` with the stale-assignment message. Playback, mobile configuration, package, and relay checks passed. The predicate correction alone did not resolve relink.

A stale post-mutation callback could begin an inspector load with an old Recording after the observed current row had already begun its refresh. It replaced the current load generation, then rejected itself at the final exact-row guard. The valid load rejected its superseded generation, leaving stale editing authority while names refreshed independently.

`SpeakerReviewLoadGeneration` now rejects stale or cancelled loads before advancing the generation. Completion still requires the latest generation, exact selected Recording, and a noncancelled task. Store-bound evidence, captured-review validation, and mutation guards are unchanged.

## Validation

- Deterministic red phase used the extracted coordinator with its original unconditional admission behavior: four tests executed, stale/cancelled admission cases failed four assertions; newer-load and completion rejection cases passed.
- Corrected coordinator: 16 tests across SpeakerReviewLoadGenerationTests, SpeakerReviewRefreshTests, PersonDetailViewModelTests, and SpeakerReviewPresentationTests passed, zero skips.
- SSD Xcode Debug build-for-testing passed, including the app, tests, and embedded helpers.
- Local macOS UI execution remains blocked before test cases by XCTest automation-mode startup timeout. No additional blind retry. Hosted relink acceptance is still required; the deterministic regression and build are not a runtime pass.
- No installation, real recording mutation, publication, merge, or release performed for this change.

Local logs under `/Volumes/MacMiniSDD/HarcBuilds/dev-20261114/`: `speaker-load-generation-red.log`, `speaker-load-generation-green.log`, `speaker-load-generation-xcode.log`.
