# Explicit single-source project mention UI

Separate graph branch above PR212, not a release feature claim.

The Host Connections sheet offers an initially collapsed source chooser tied to
the recording selected in Library. It names that source, lets the owner select
an existing knowledge project or explicitly create one, then requires an unchecked
consent toggle before Find name mentions becomes available. No view appearance,
project creation or selection automatically scans content. Consent resets after
operation or source/project changes. Source canonical identity is checked inside
preparation, and Host/source evidence is revalidated at commit. Reads and writes
remain on the local Host; no audio or other recordings are scanned.

Project creation and chooser reads bind to the expected Host tuple. The chooser
reads at most100 projects and discloses that limit. Results explicitly separate
new suggestions, preserved existing rows, absent literal mentions, oversized,
unavailable and changed sources. No assignment or accuracy gain is claimed.

Store regression run:28 functions passed across project refinement/producer
suites, including Host-bound project creation/listing, source consent identity,
and a source growing beyond256KB before commit. Package HarcUI compiled.

A new required CI UI case checks project creation does not imply consent,
Find remains disabled until consent, a selected-source suggestion is produced,
and consent resets. App UI execution and visual/manual qualification remain
pending until verified separately; package tests are not app UI evidence.

App qualification follow-up: Xcode build-for-testing passed for app and UI tests.
Manual Computer Use in a fresh synthetic Host Library verified collapsed entry,
named source, disabled Find before consent, project creation without scanning,
checkbox enabling Find, one newly generated pending suggestion, honest receipt,
and checkbox/Find reset afterward. Light-mode screenshot was inspected; review
cards scroll below the producer. Diagnostic app quit afterward. Production app
and Library untouched. No XCTest execution or VoiceOver pass is claimed; CI must
execute the new selector. Dark-mode consent expansion remains unqualified.

Consent hardening: opt-in now binds row/canonical identity, Host tuple and project
version; changes invalidate the key immediately. Store preparation also rejects
an expected project version that changed after picker selection. Project-list
load generations suppress late appearance reads after project creation. UI copy
explicitly discloses case-sensitive matching.

Executed after hardening:28 Store tests;2 consent-key/load-generation tests;
13 existing presentation tests, all passing. These are separate executed filters,
not an assumption that a combined filter exercised every target.
The hardened app and app UI tests also passed Xcode build-for-testing. Hosted CI
was still pending when this follow-up was pushed. No app UI-execution pass or
physical/VoiceOver qualification is inferred from compilation.

Dark/keyboard follow-up: isolated hardened app showed case-sensitive copy,
unchecked consent and disabled Find. Typed project name via keyboard; project
creation left consent off. With consent on, popup Up/Return changed project and
cleared consent/disabled Find. Escape dismissed the sheet. Settled expanded dark
screenshot showed the full source explanation, project limit and controls.
Immediate post-expansion capture can show transient disclosure animation; no
persistent clipping defect is claimed. Producer content now preserves natural
vertical height while the review list remains scrollable.

Full Tab-only traversal was not established under the current Mac keyboard
settings. AX names are present, but actual VoiceOver spoken output and navigation
remain unqualified. No accessibility/security preference changes were made.
A fresh one-test local XCTest attempt failed before entering the consent test:
`Timed out while enabling automation mode` after60seconds. Result bundle:
`mention-consent-local-ui.xcresult` in the isolated qualification build directory.
No local app XCTest pass is claimed and no automation permissions were changed.
