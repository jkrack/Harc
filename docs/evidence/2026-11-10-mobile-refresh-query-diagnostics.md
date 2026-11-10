# Mobile refresh-status query diagnostics

This is test-fixture instrumentation, not a production fix or a release qualification.

## Why

PR #191 CI run [42889236799](https://github.com/jkrack/Harc/actions/runs/42889236799)
sealed 89 mobile results: 88 passed, one failed, none skipped. The failed
`testLocalLibraryIsReachableWithoutHost` exceeded its unchanged ten-second
expectation for the refresh-status label. Its retained video shows the expected
“Couldn’t refresh Mac Library” state at 90 seconds. The existence query begins
at 70.58 seconds, predicate evaluation at 85.13 seconds, label resolution at
85.40 seconds, and diagnostic capture at 94.54 seconds. The exported debug
attachment contains only the unresolved query chain. This supports investigating
accessibility-query latency, but does not prove the failure's cause.

The retained mobile artifact is 13798604830, SHA-256
`a0263f00fbfb190d050dcca5c595d14d95c23568fa37d1a113f3a804700b3507`.
An earlier local query-wait experiment remains separate and unpublished: both
its unchanged baseline and candidate passed once on iOS 27, while hosted CI uses
iOS 26.5. Those passes did not establish an improvement.

## Instrumentation boundary

A test-only KVC adapter forwards each original element label read exactly once,
returns the unchanged string to the original predicate, and logs only a fixed
state token, monotonic elapsed/duration milliseconds and a bounded read ordinal.
The first sixteen reads have begin/end markers; one further marker reports the
logging limit, without suppressing any subsequent predicate reads. Expectation
begin/end markers bracket the same ten-second wait. An additional final assertion
checks the original element directly after success. No raw labels, arbitrary
error text, identifiers, paths or accessibility trees are logged by the adapter.

The helper regression verifies positive/negative predicate behavior, one read per
evaluation, output redaction/capping and XCTest's asynchronous KVC path. The
hosted mobile runner explicitly selects and requires that regression. Existing
test selections, predicate, timeout, navigation assertions and execution gates
remain unchanged. Logging is not timing-neutral and cannot itself establish that
a passing rerun fixes the earlier failure.

## Local validation

The final instrumentation compiled and passed both the original navigation test
and helper regression on the isolated iPhone 17 simulator running iOS 27.0. Both
required cases are present in the sealed result and execution gate. The run
finished in 469 seconds within its unchanged 600-second guard. All 196 tooling
regressions pass, including the deliberate extra selector/gate while the original
selector fingerprints remain unchanged. Independent source review found no
blocking issue. Hosted iOS 26.5 validation and diagnostic observation remain
pending; local success does not reproduce or resolve the hosted failure.
