# Verified local evidence load snapshot: proposed contract

Status: design only. PR216 qualifies config, not resident model provenance.
No model loading, copy of owner weights, download or activation authorized by
this document. Existing summary/dictation containers continue unchanged.

## Isolated preparation

1. Owner-approved model ID resolves only through the fixed catalog. Require the
   supported schema and manifestVerified revision, unique relative file paths,
   nonnegative exact byte sizes and SHA256 for every input. Never take hashes or
   a substitute descriptor from a model directory.
2. Resolve source directory once. Enumerate without following symlinks. Reject
   symlink files/directories, paths escaping the root, duplicate normalized paths
   and every unlisted loader-relevant file anywhere below it. In particular,
   SDK loadWeights recursively reads all safetensors, so an extra nested tensor
   file is not harmless. Allow only explicitly named Harc install-marker files
   in the source, never copy them into model inputs. Fail unknown file types.
3. Check source byte sizes and available destination space. Allocate a unique
   app-owned staging directory under the configured SSD build/model scratch
   location, never in the user's installed-model tree. Do not mutate originals,
   change security permissions, use hardlinks or reuse a prior receipt.
4. Stream each regular file to a new destination with bounded buffers and
   cancellation. Hash the DESTINATION bytes, compare exact size and SHA256 to
   catalog. Enumerate the destination again: exact manifest file set only, no
   symlinks/extras. Parsing the copied config must independently qualify context.
5. Only after all verification succeeds create an opaque prepared-snapshot
   receipt containing catalog ID/revision, exact manifest digest, canonical
   staging directory, fresh nonce and qualified context. Failure/cancellation
   removes only this invocation's staging directory. Never delete source files.

## Binding and lifetime

A prepared snapshot is not a resident-model receipt. Dedicated qualified loading
must run under SummarizerService's existing operation ownership, with a captured
loadGeneration. It may not relabel an arbitrary cached summary container. Load
only the prepared snapshot; successful return plus unchanged generation creates
an internal resident receipt bound to that exact container and snapshot nonce.
Any unload, model switch, stale generation, failed load or cleanup invalidates
it. Strict evidence generation checks this receipt before and after the retained
producer finishes. Reject a different model ID/directory even if config matches.

Snapshot verification protects against a corrupt/changing source, but writable
snapshot paths are not a cryptographic isolation boundary from another process
running as the same user. A robust implementation must define the local threat
model and prevent in-app mutation during loading. Do not claim that pre/post
hashes prove intermediate bytes against an adversarial same-user writer. If that
strong guarantee is required, qualify a loader consuming retained verified input
handles/bytes instead of path-based reopening; current SDK does not expose that
whole-bundle contract. No security-setting or permission changes are proposed.

## Synthetic test matrix before touching real model data

- Manifest rejection: absolute/../duplicate paths, missing hash, unknown ID.
- File-set rejection: nested extra .safetensors, alternative tokenizer/template,
  unexpected generation config, FIFO/device and file/directory symlinks.
- Integrity: same-size mutation, truncation, growth during copy; hash destination,
  not source metadata; immutable expected manifest supplied by test fixture only.
- Cancellation/disk failure leaves source untouched, removes own staging only.
- Concurrent invocations have distinct snapshots/nonces and cannot clean up each
  other's directories. Source symlink retarget cannot rebind a captured root.
- Fake loader receives only verified snapshot path; source path is never passed.
- Generation invalidation while fake loader is suspended must reject receipt.
- Existing resident unqualified container cannot satisfy evidence request.
- Early evidence failure retains producer cleanup ownership (PR215 regression).

No synthetic snapshot tests have been implemented or run yet. This design does
not assert on-device semantic quality or model qualification.
