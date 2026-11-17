# Independent challenge output lock (before gold release)

Original input-only run used exact56664b4, frozen policy
38e499ce710ee345fc8e6511f79de5052c0472b3790831ea3e6c827d7495d310,
input8725 bytes SHA a2a870aaa54476c6199676d6a9930bc30f553fe13314aa14d7b3ad9029816338.

Locked `independent-challenge.json`:14349 bytes, SHA256
`2240337562b3fb5b51f923fcbf139896369b9d538ef9354d9e245671840dc17d`.
Contains all24 case IDs, one normal stop each,13 source-valid suggestions and11
abstentions, no parser/runtime error. No gold labels or semantic scoring were
available to runner/implementer before this output lock.

## Actual isolation procedure

A separate author created and froze inputs/gold before disclosure. The author
sent only the four-field input JSON after policy/code review and freeze. I copied
only that message into the Mac fixture, verified exact byte hash, and ran the
input-only runner. I did not access the author's private folder or gold/rationale
files. No labels/expected claims/anchors were sent before lock. The report flag
`goldUnavailableAtRun` describes this procedure; it is not a technical access
control or cryptographic attestation. Request gold only after this commit/hash
is shared. Never modify raw outputs or prompt retrospectively.

## Interrupted observation, recovered original output

The computer connection dropped during waiting. I reattached, observed the same
XCTest PID75039 still running, and waited without restarting. It subsequently
exited and both original report files appeared. Final XCTest pass/exit status
was not captured: the surviving log ends after build completion. Therefore do
not claim an observed XCTest pass for this run. All24 report rows have one normal
completion and strict source validation; final snapshot scratch was0B, process
absent,69% memory free. Per-case cleanup assertions exist in the runner but their
final test summary was unavailable. No duplicate or resumed evaluation was run.

Median copy/load/inference/cleanup latency16.136s; max29.390s; sum417.753s.
Observed process cumulative MLX peak3,357,488,676bytes, not totalRSS or isolated
operation peak. Headroom72% initially, monitored low31%,69% after, no thermal
warning at checked samples, no active Harc audio writes. No user apps terminated,
model downloads, private recordings, production Library reads or UI activation.
