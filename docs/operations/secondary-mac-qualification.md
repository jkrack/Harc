# Secondary Mac and two-network qualification

This runbook is the production gate for the macOS Client-first operating model.
Passing package tests, loopback pinned-TLS tests, or the relay emulator does not
replace it. Run the matrix against one clean, sealed commit and the exact same
signed Harc application bytes on both Macs.

## What this gate proves

- The capturing Mac records and transcribes locally without waiting for Host
  reachability or Host inference.
- Route changes, wake, relaunch, and Host restart repair themselves through an
  authenticated direct route before encrypted-relay fallback.
- Trust, route, session, recording delivery, processing delivery, speaker sync,
  and last authenticated contact remain independently truthful.
- Pairing rejection is terminal and actionable; ordinary network loss is
  retryable. Neither condition risks the protected local master.
- The Host accepts complete compatible Client processing, otherwise schedules
  fallback only when it has spare cycles.
- Canonical speaker decisions converge without silently overwriting a local
  no-match or revision conflict.

## Candidate controls

1. Install the same signed build on both Macs. Record the sealed commit,
   version/build, Developer ID identity, and executable SHA-256.
2. Use one Mac in **Host** role and one in **Client** role. Do not reuse evidence
   from Standalone mode or from an earlier build.
3. Start with at least 5 GiB free on each machine. Keep Swift/Xcode work to two
   workers on the constrained development Mac.
4. Clear neither app state nor the Keychain during a run. A failure must remain
   available for recovery inspection.
5. Use a new shared run ID. Evidence directories are append-only; the collector
   refuses to overwrite an existing directory.

The collector is read-only with respect to Harc state. It copies only Harc's
privacy-bounded diagnostic log and OSLog output, and records hashes/sizes—not
contents—for route and database files. It never copies audio, transcripts,
pairing secrets, relay capabilities, or Keychain material.

```sh
./scripts/collect-secondary-mac-qualification.sh \
  --role client \
  --run-id 2026-08-23-candidate-1 \
  --scenario baseline-pairing \
  --result pass \
  --output-dir /path/to/evidence/client-baseline-pairing \
  --app /Applications/Harc.app
```

Run the corresponding command on the Host with `--role host`. A dirty tree is
diagnostic-only and requires `--allow-dirty-diagnostic`; it cannot close a
release gate.

## Required scenario matrix

Perform three consecutive complete passes. Any source or shipped-app-byte
change resets the count to zero.

| Scenario ID | Exercise | Required observable result |
| --- | --- | --- |
| `baseline-pairing` | Fresh invitation, matching four words, Host approval, five-minute Client recording | Client capture starts immediately, local transcript completes, authenticated Host contact appears, recording and processing receipts both converge |
| `client-offline-relaunch` | Quit Host, record on Client, quit/relaunch Client, then restore Host | Protected master and pending work survive; Client remains locally usable; retry resumes without user action |
| `direct-route-change` | Move Host to another LAN address while relay remains healthy | Saved direct route fails, authenticated Bonjour replacement is persisted, and direct connection wins before relay |
| `client-sleep-wake` | Sleep Client with queued work, wake on the same network | Wake triggers bounded retry; no duplicate Host recording or upload generation appears |
| `host-restart` | Restart Harc Host during an active upload, then reopen it | Client retains all work, authenticates a replacement session, and resumes idempotently |
| `concurrent-capture-upload` | Begin a second recording while the first uploads and processes | New audio remains smooth; upload/repair yields to capture; both recordings eventually converge independently |
| `host-under-load` | Saturate Host processing while Client completes local transcription/diarization | Client processing remains smooth; Host reports deferred fallback rather than duplicate or misleading active work |
| `host-fallback-spare-cycles` | Withhold/interrupt a Client processing artifact after audio commit, then return Host to nominal load | Host observes the grace period, admits fallback only under healthy load, and publishes one compatible canonical result |
| `speaker-sync` | Create/rename/link a speaker on Host, refresh Client, then produce a new unmatched local speaker | Canonical change reaches Client; unmatched speaker remains explicitly pending/no-match until a Host decision arrives |
| `speaker-conflict` | Edit the same speaker decision from stale Client and current Host revisions | Host revision wins canonically; Client surfaces a conflict and never silently overwrites either decision |
| `revocation-repair` | Revoke Client on Host while idle, wait for health probe, then attempt queued transfer and re-pair | Client reports pairing repair—not route outage—stops automatic trust retries, keeps recordings safe, and resumes only after explicit foreground re-pair |
| `two-network-relay` | Put Macs on separate real networks, exercise relay, then restore direct reachability | End-to-end content remains inside pinned TLS; replacement sessions work; direct route is preferred after authenticated recovery; relay retains no plaintext/content |

For every scenario, record one Host and one Client evidence directory with the
same run/scenario IDs. Mark a scenario `fail` if any required state is unclear,
requires an unplanned manual retry, duplicates work, loses a speaker decision,
or cannot prove local-master retention. Do not convert a failure to a pass by
rerunning only the final step.

## Smoothness and endurance observations

During `concurrent-capture-upload` and `host-under-load`, capture a ten-minute
sample and record:

- start acknowledgement latency;
- stop-to-durable-local-save latency;
- dropped/discontinuous audio count;
- local transcription completion time;
- UI stalls longer than one second;
- peak memory and thermal state on the Client; and
- whether Host upload, fallback, or speaker work changed recording behavior.

Acceptance is fail-closed: zero silent transcript holes, zero lost masters, zero
duplicate canonical recordings, zero unreported speaker conflicts, and no
recording start blocked on model warmup or Host availability.

## Evidence review

Before signing the gate:

1. Both machines must report the same source manifest and app executable
   SHA-256 for every scenario.
2. `configured_role_matches=true`, `codesign_status=0`, and a present Client
   diagnostic log/Host state identity are mandatory.
3. Review Client diagnostics for authenticated contact, recovered route,
   bounded retry, upload receipt, processing receipt, and speaker convergence.
4. Review failures without deleting state. Fixes require a new sealed candidate
   and three new complete passes.
5. Keep the direct and relay pinned-TLS lifecycle scripts green as software
   evidence, but report them separately from this physical gate.
