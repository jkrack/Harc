# Selected untrusted preview lifecycle (inactive)

This slice connects the inert preview session to actual Store invalidations. It has **no application caller, model invocation, confirmation action, graph write, or automatic retry**.

## Authority and lifetime
- Resident Host availability defaults unavailable; the future app owner must explicitly forward availability and selection changes. A database Host tuple is not proof of a live writer.
- A GRDB region observation is registered on the writer queue before the first source snapshot read. It signals invalidation, without fetching/copying full transcripts into observation events.
- Selected canonical identity, transcript, deletion, project payload/version/brief and Host tuple changes invalidate the session. Cross-process Library notifications invalidate conservatively; cursor progress is not watched.
- Registration remains active through response validation and display. Stream termination and error both invalidate; the Store maps errors to the same content-free terminal signal.
- Each generation owns a separate session and opaque response token. After each suspension, stale/cancelled work cannot publish into the newer generation.
- Cancellation/dismissal removes controller-owned source and preview references and cancels the registration. An already suspended database/actor operation may retain its own temporary value until it returns; this is not secure memory erasure.
- Full source and brief accompany the highlight; model label remains explicitly unverified. Exact quotation is not semantic verification.

## Validation
On November 17, focused Swift package tests passed on the Mac mini with SSD scratch:
- 7 new lifecycle tests (12 invocations including parameterized cases): unchanged display/dismissal, actual transcript/project/trash/Host/canonical mutations, mutation and cancellation during a suspended initial read, resident availability loss, external notification, stale response token, observation normal termination, cancellation during suspended freshness check, and concurrent/late duplicate response rejection.
- 12 existing strict-contract and inert-session tests passed.
- No audio, real Library data, installed model loading, app UI, VoiceOver, or distribution run was used.

## Remaining gates
No real app view observes this controller yet. Future presentation must forward selection and resident runtime changes and release any copies it owns on dismissal. GRDB observation/freshness reads are not atomic with rendering, and an external process notification can be delayed. No displayed value can authorize a future write: confirmation must bind the captured source/project/decision/Host identities in the authoritative transaction. Actual GRDB error injection, live multi-process notification delivery, SwiftUI lifecycle, and device UI qualification remain untested.


## Review correction
Independent review found that concurrent calls could both accept the same response token before an awaited freshness read. The second session completion could invalidate the first valid preview. The controller now consumes the response token and enters processing state synchronously before suspension. A deterministic suspended-freshness regression exercises both concurrent and late duplicates; only the first response can publish.
