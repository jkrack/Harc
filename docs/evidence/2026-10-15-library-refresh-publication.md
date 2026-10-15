# Library refresh publication under concurrent observation

PR119 CI run 38683188751, head `8481c8e300b3285409e688cedca3fc2401f1aece`,
failed one of 1,608 Swift Testing tests. The customer-actions E2E test failed
at `CustomerExperienceE2ETests.swift:146` waiting for a renamed row after switching
from a day filter to All. Package build and the blocking-I/O regression passed;
the mobile job was skipped. The existing bounded wait and its assertions remain
unchanged.

PR112 (`6bce7bdd00c0086e33d205b22f305020ffa17b70`) replaced a fixed search
sleep in the other customer E2E test. That search test passed in this failed run.
This change does not duplicate or revert PR112.

Investigation exposed a production publication race consistent with the failed
rename/filter assertion. An empty-query refresh captured its day filter and a
store snapshot before suspension, then could publish both after a newer observed
rename and a filter change. Cancellation also failed to stop an old empty refresh
from clearing a newer nonempty query's results. CI has no interleaving trace, so
the exact runtime schedule of its failure is not asserted here.

Refresh now uses the current filter at publication, refetches if a store
observation superseded its snapshot, and checks cancellation before publishing.
Search results and errors also verify that their query is still current.

Two deterministic tests use an in-memory RecordingStore and a continuation-gated
real store snapshot. They invoke the same production observation publisher and
external-refresh entry point. The first publishes a real renamed row, changes
the filter to All, then releases the old snapshot; both rows and the renamed
title must survive. The second completes a current keyword search, then releases
a cancelled empty snapshot; the keyword hit must survive. No sleeps or expanded
E2E deadlines are used. Internal injection/read-only task access supports this
schedule without exposing a new public initializer.

The mechanically extracted baseline failed both tests with three assertions.
The corrected production source passed both tests. Focused execution uses exact
Core, Domain, Store and LibraryViewModel sources in a temporary SwiftPM package
with the cached GRDB dependency; it does not build the rest of HarcUI. Logs and
two-worker, 6-GiB-floor watchdog receipts are in `/tmp/harc-sync-evidence` as
`library-refresh-baseline` and `library-refresh-fixed`. Minimum free disk was
11.90 GiB. Full CI and the macOS app build provide broader validation separately.

All test content is synthetic metadata in a temporary directory. No microphone,
phone, production transfer, credential, security setting, or release action ran.
