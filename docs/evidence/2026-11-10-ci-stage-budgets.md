# Separate CI build and execution budgets

Recorded November 10, 2026. This correction is stacked on #190 at
`1dd2ae5a1ccb552c5eeddab7765873e36497c67e`. It changes CI orchestration,
not production behavior, test selection, assertions or result acceptance.

## Observed failures

[CI run 42870561962](https://github.com/jkrack/Harc/actions/runs/42870561962)
retains both attempts. In attempt 1, the macOS job exhausted its configured
60-minute job limit. Its app build alone took 46 minutes 27 seconds; test
compilation consumed further time. Retained output reports 104 app tests and
10 completed UI tests passing before interruption. The remaining UI cases,
execution gate and embedded-helper checks did not complete. This is not a
passing macOS lane.

The first mobile job never acquired a hosted runner and executed no steps.
One scoped retry in attempt 2 reached all 89 selected tests: 68 XCTest,
14 Swift Testing and seven UI cases passed in the retained log. However, the
1,800-second guard covered compilation, execution and result finalization
together. It expired during the final UI case, sampled its owned process and
interrupted finalization after test-success output. The retained xcresult lacks
Info.plist; the diagnostic could not read a summary and the execution gate did
not pass. Textual passes do not qualify this run.

Retained artifact integrity checks matched GitHub's published digests:

- macos-validation, artifact 13792374782:
  `1f15d4a12f5730166f0b7b682bd5ca4eb807fbfc90787b4508426c08198ba0ac`
- mobile-configuration-evidence, artifact 13796886679:
  `e5729a08c03a48dcc3cba7a0c296701cd7c6763070b801054f5044ea5e2a4fa1`

## Correction

Both Xcode lanes now build test products with `build-for-testing`, then run
`test-without-building` using the same scheme and destination. The mobile
script also shares one argument array, including the exact source SHA,
derived-data directory and unchanged test selections.

- Mobile: 30-minute build guard and separate 25-minute execution/finalization
  guard, inside a 57-minute step and 65-minute job. Preserve separate build and
  test diagnostics. The unchanged owned-process runner still returns failure
  on timeout, even if test-success text appears during cleanup.
- Mac: a 65-minute build-for-testing step and separate 25-minute execution step,
  inside a 100-minute job. This budgets the measured cold compilation and
  leaves time for the unchanged execution gate, helper checks and artifacts.

These are finite budgets, not a success grace period. Build failure prevents
execution; execution failure or timeout prevents result acceptance. The existing
xcresult summary/tree checker and all required tests remain unchanged. No test
is omitted, retried automatically or reclassified. The two-minute mobile step
margin is ordinary overhead, not a guarantee that unusually slow diagnostic
sampling will finish before the outer bound; such a case still fails closed.

## Local validation

All 196 tooling tests passed on the Mac mini, including five new synthetic
mobile-flow cases and the updated ten-case CI partition suite. The new harness
executes the production shell script with synthetic build/result tools and the
real result checker. It covers shared arguments, separate finite budgets,
build failure stopping execution, test nonzero/timeout propagation, and
missing/corrupt result rejection. Existing runner lifecycle tests cover actual
owned-process timeout cleanup.

The separate-budget contract fails against the unchanged baseline's single
1,800-second invocation, then passes with this correction. Shell syntax and
whitespace checks passed. Independent review found no blocking issue.

No real app, simulator, physical phone, live Host or recording was used for
these tooling checks. Hosted CI on the final commit is still required to verify
actual Xcode build/test behavior, sealed results and timing. This correction
does not close physical-device, codec, release-artifact or App Store gates.
