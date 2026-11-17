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
