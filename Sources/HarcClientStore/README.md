# HarcClientStore

The adopted-device store module owns two physical databases: a
complete-until-first-unlock transfer store for upload state, background-task
mappings, manifests, receipts, and cleanup intent; and a complete-protection
library cache for recording views, content, cursors, tombstones, offline
mutations, and conflicts. Both databases/sidecars and all client content are
excluded from OS backup under the implementation spec.

Neither is a copy of `HarcStore`; the module never becomes a canonical library writer, and
contains no host-local filesystem path.

Background mappings retain a terminal `retired` state when their task is replaced
or their upload loses authorization. Capability refresh retires old inactive
mappings atomically with credential replacement; a new mapping also retires old
inactive tasks for the same immutable batch. Late callbacks cannot change the
replacement's batch or recording state. Reconciliation quarantines forgotten,
revoked, superseded, and integrity-blocked work independently while preserving
its rows and files. Database corruption and I/O errors still surface.
