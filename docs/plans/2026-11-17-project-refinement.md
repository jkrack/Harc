# Evidence-backed project refinement: isolated foundation

This change is a local Store contract, not an enabled feature or released UI.
It deliberately does not change the current Apple transcription release.

## Implemented contract

- Explicit project identity and per-recording suggested relationship. No automatic
  alias promotion, voice enrollment, inferred commitments or remote inference.
- Exact canonical recording identity, recording revision (provenance only), transcript SHA-256,
  verbatim source excerpt, generator identity and project snapshot.
- Accept / reject / unsure persist distinctly. Regeneration never overwrites a
  human answer. Accepted reviews form explicit human assignments; stale evidence is labelled separately.
- One transaction commits the answer and idempotent operation receipt. Impact is
  actual newly linked recordings (0 or 1), never an estimated precision increase.
- Undo checks the current version and refuses newer edits. Restored human assignments
  retain their evidence freshness status. Deletion cascades reviews and their event history.
- Transcript changes mark evidence stale without deleting explicit human assignments.
  General metadata revisions do not invalidate unchanged transcript evidence. Trash
  hides assignments and blocks new suggestions and decisions.

## Deliberately not enabled yet

No review queue UI, haptics, extraction job, Host RPC or phone synchronization.
No migration of folder-based projects; these new identities are distinct from
folders. No timed seek claims: transcript chunk times can be approximate.
Stale suggestions need an explicit refreshed-evidence review API before UI rollout.
Project rename/delete and cross-device authority need qualification before exposure.
The UI must retain operation IDs, disable repeat taps while saving, differentiate
historical replay receipts from new effects, and fire success haptics only after
commit. It must offer inspection and undo, not call suggested links verified facts.

## Validation

Focused target: `swift test --filter ProjectRefinementTests`.
Full Store/migration and Xcode validation remain required before integration.
Do not compete with release archives on the constrained mini; use SSD build cache.
