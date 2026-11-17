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
strong guarantee is required, qualify a loader consuming verified immutable in-memory bytes or mappings with proven copy
semantics instead of path-based reopening; current SDK does not expose that
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

A separate internal synthetic-only copier now exercises flat-file manifests,
no-follow descriptor-relative opens, regular-file checks, exclusive copies,
destination hashes, exact source/destination file sets and scoped cleanup.
It caps each file at 1 MiB and total input at 4 MiB, deliberately preventing use
with real weights. It is not a production manifest resolver or resident receipt.
Synthetic tests cover copied fake-loader input, corrupt bytes, extra/nested files,
symlinks, invalid paths and consumer cancellation. Production loading and service
load-generation receipt binding remain unimplemented. No semantic quality or
real-model qualification is asserted.

Qualification evidence for this slice: five synthetic test functions passed
(including four adversarial-input variants). An initial assertion compared URL
representations with differing trailing slashes; comparing parent paths corrected
the test without changing copier behavior. No actual model files were used.
Service-generation receipt tests are deferred with the still-unimplemented
production loader binding; existing PR215 tests cover unload invalidation and
producer cleanup ordering, not a verified model receipt.

Snapshot hardening: roots are canonicalized before opening; just before consumer
handoff, path-opened parent and snapshot device/inode identities must match the
retained descriptors. A deterministic scratch rename/replacement regression
rejects the replacement before consumer execution while cleanup removes only
the original owned staging directory. This is point-in-time accidental-change
protection, not an atomic defense against a hostile writer after the check.
Directory enumeration now stops above manifest count and checks cancellation
on each entry. A real caller task cancellation while detached preparation is
paused verifies cancellation propagation and owned-directory cleanup.
Seven synthetic snapshot test functions passed after handoff/cancellation fixes.
The first cancellation fixture used a semaphore wait from an async context and
failed compilation; the corrected fixture uses nonblocking locked state while
only the synchronous preparation hook waits. No failing run is counted as pass.

Cleanup also verifies the named child directory's device/inode against its retained
descriptor before removing the directory name. If the child was renamed and an
unrelated empty replacement created, cleanup removes only its copied files via
the owned descriptor and skips pathname removal. The renamed empty staging
directory may remain; this conservative leak is preferable to deleting an
unowned replacement. A deterministic child-swap regression checks both remain.
This remains a point-in-time check, not hostile same-user race protection.

### Concrete fake-loader consumer before receipt machinery

A test-only cross-module harness connects the existing synthetic copier to
SummarizerService's existing serialized preload/evidence paths. The fake loader
checks exact bytes at the passed snapshot path and the fake generator rereads
those bytes to verify lifetime. Tests require a distinct snapshot load rather
than reuse of an earlier ordinary preload, rejection after unload, cleanup after
scope, and zero loader calls for a bad manifest.

This does NOT turn ordinary preload into a qualified load or create a trusted
receipt. It establishes a concrete consumer and lifetime contract before adding
production provenance state. A production receipt must still be minted only by
a verified-bundle loader and bound to its exact successful container/load epoch,
not supplied by a caller or inferred from these tests.

### Minimal production integration boundary (not implemented)

Prefer one scoped qualified-evidence operation over a second resident-model
state machine. A future verified-bundle module owns an opaque snapshot lease
(private initializer, catalog verification only); the service must not accept a
caller-constructed digest/directory as qualification. Its lifetime begins before
loading and ends only after retained generation cleanup AND container unload.
A held synthetic generation test now proves files remain readable while paused,
including an error return followed by explicit unload before scope cleanup.

The first production adapter can reject when an unrelated resident model exists
rather than evicting it or loading a second multi-GB container. With operation
ownership held and no resident container, capture a fresh attempt nonce plus
loadGeneration, load the exact opaque snapshot, then mint a private receipt only
for that returned container. Receipt fields: catalog/revision/manifest identity,
snapshot nonce/canonical directory, successful-load nonce, service generation
and qualified context. Ordinary preload must never mint or upgrade this receipt.
Model switch/unload/failed load invalidate it; every evidence call checks it
before and after producer completion. Finally unload before releasing the lease.

This is a concrete future consumer of the snapshot, not implemented provenance.
The production snapshot factory still needs real-bundle resource limits,
complete loader-input verification and lifetime ownership qualification. No
real-model download/copy/load or default selection change is performed here.

### Scoped concrete entry, still unactivated

The next stack adds `QualifiedEvidenceSnapshotFactory`: only the fixed E2B
catalog ID/revision is accepted; every pinned input is copied and destination
SHA256-verified. Only the two named Harc marker files are ignored at source;
unknown loader inputs are rejected. The factory checks config before copying,
checks available disk headroom, then qualifies the copied config. Limits rise
only through this catalog-only factory (4 GiB total); default copier fixture
limits remain small. Nothing downloads or alters installed source files.

`generateQualifiedEvidence` is internal with no app/UI callsite. It owns the
existing service operation across factory scope, load, strict prepared-input
generation/producer join, resident unload and snapshot cleanup. It refuses any
existing unrelated resident before copying. Successful loader result identity
is scoped locally with snapshot/manifest metadata and service generation; no
ordinary preload is retroactively qualified. Cleanup clears only the scoped
resident and preserves unrelated queued callers. An externally requested unload
still invalidates a suspended load/generation.

Synthetic tests exercise the actual shared operation composition with fake
loaders, including success/error suspension and cancel/unload during loading.
These do not qualify Metal execution, a real 3.6GB snapshot copy, disk endurance,
semantic quality or full app behavior. No real-model copy/load was run. The
same-user non-hostile corruption/concurrent-update threat limitation remains;
this is not hostile-process attestation. Independent review and actual synthetic
local-model evaluation must precede any caller activation.

### Actual installed-model offline smoke, 2026-11-17

After tiny fixed-manifest factory success/error tests passed (3 test functions),
one explicitly opt-in synthetic smoke exercised the real scoped entry. The
already-installed Gemma4 E2B fixed catalog revision
`99d9a53ff828d365a8ecae538e45f80a08d612cd` supplied all eight SHA-pinned model
inputs. No download, owner recording or transcript was used; no prompt/response
content was logged. An internal observer records only numeric completion data.

Verified result: one XCTest passed, no skip/failure; prompt 32 tokens, generated
6 tokens, authoritative stop reason `stop`, expected abstain JSON schema.
Elapsed 15.10 seconds includes verified snapshot copying, loading, generation,
producer completion, unload and cleanup. Peak MLX allocation 2,689,271,390 bytes;
active MLX after unload 5,116 bytes. Snapshot scratch returned to 0 bytes, service
resident ID nil. System had 16GiB RAM, memory-pressure free percentage 51% before,
44% observed during copying and 49% after; SSD had ~1.4TiB available. No installed
app was closed or altered. Host was not recording at preflight, no writable audio
handles; no active local build/model process was present.

This qualifies the mechanical offline scoped runtime path for this one model and
short synthetic response, NOT semantic evidence quality, accuracy, long input,
thermal endurance, full app lifecycle, or UI readiness. Source-span validation,
semantic positive/negative synthetic cases and cancellation during real model
work remain separate qualification. No app caller or default was activated.
