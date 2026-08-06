#!/usr/bin/env bash
set -euo pipefail

# Copy HarcMobile's Application Support directory from one attached iPhone and
# report nonsecret persistence counts. This is a read-only product-path audit;
# it does not use XCTest and does not mutate either client or Host databases.
#
# Usage:
#   ./scripts/audit-mobile-state.sh <device-name-or-identifier> [new-output-dir]
#
# The copied snapshot cannot prove the original iOS Data Protection class or
# backup-exclusion metadata. Those attributes require a separate on-device
# physical qualification check.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <device-name-or-identifier> [new-output-dir]" >&2
  exit 1
fi

DEVICE_SELECTOR="$1"
if [[ $# -eq 2 ]]; then
  AUDIT_DESTINATION="$2"
  if [[ -e "$AUDIT_DESTINATION" ]]; then
    echo "error: output path already exists: $AUDIT_DESTINATION" >&2
    exit 1
  fi
  mkdir -p "$AUDIT_DESTINATION"
else
  AUDIT_DESTINATION="$(mktemp -d /private/tmp/harc-mobile-audit.XXXXXX)"
fi

APP_SUPPORT_SOURCE="Library/Application Support/HarcMobile"
TRANSFER_DB="$AUDIT_DESTINATION/Transfer/HarcTransferStore.sqlite"
LIBRARY_DB="$AUDIT_DESTINATION/LibraryCache/HarcLibraryCache.sqlite"
HOST_DB="$HOME/Library/Application Support/Harc/HarcHost.db"

echo "==> Copying HarcMobile state read-only from $DEVICE_SELECTOR"
xcrun devicectl device copy from \
  --device "$DEVICE_SELECTOR" \
  --domain-type appDataContainer \
  --domain-identifier com.harc.HarcMobile \
  --source "$APP_SUPPORT_SOURCE" \
  --destination "$AUDIT_DESTINATION"

if [[ ! -f "$TRANSFER_DB" ]]; then
  echo "error: copied snapshot has no transfer database: $TRANSFER_DB" >&2
  exit 1
fi
if [[ ! -f "$LIBRARY_DB" ]]; then
  echo "error: copied snapshot has no library-cache database: $LIBRARY_DB" >&2
  exit 1
fi

echo ""
echo "==> Mobile transfer state"
sqlite3 -readonly -header -column "$TRANSFER_DB" <<'SQL'
SELECT 'adoption_history' AS table_name, COUNT(*) AS count FROM adoption_history
UNION ALL SELECT 'grant_slots', COUNT(*) FROM grant_slots
UNION ALL SELECT 'finalized_captures', COUNT(*) FROM finalized_captures
UNION ALL SELECT 'recording_outbox', COUNT(*) FROM recording_outbox
UNION ALL SELECT 'upload_attempts', COUNT(*) FROM upload_attempts
UNION ALL SELECT 'upload_chunks', COUNT(*) FROM upload_chunks
UNION ALL SELECT 'upload_batches', COUNT(*) FROM upload_batches
UNION ALL SELECT 'background_task_mappings', COUNT(*) FROM background_task_mappings
UNION ALL SELECT 'verified_recording_receipts', COUNT(*) FROM verified_recording_receipts
UNION ALL SELECT 'cleanup_intents', COUNT(*) FROM cleanup_intents
UNION ALL SELECT 'transfer_conflicts', COUNT(*) FROM transfer_conflicts;

SELECT 'recording_outbox' AS table_name, state, COUNT(*) AS count
FROM recording_outbox GROUP BY state ORDER BY state;
SELECT 'upload_attempts' AS table_name, state, COUNT(*) AS count
FROM upload_attempts GROUP BY state ORDER BY state;
SELECT 'upload_batches' AS table_name, state, COUNT(*) AS count
FROM upload_batches GROUP BY state ORDER BY state;
SQL

echo ""
echo "==> Mobile library cache"
sqlite3 -readonly -header -column "$LIBRARY_DB" <<'SQL'
SELECT 'cache_cursor' AS table_name, COUNT(*) AS count FROM cache_cursor
UNION ALL SELECT 'cached_recordings', COUNT(*) FROM cached_recordings
UNION ALL SELECT 'cached_tombstones', COUNT(*) FROM cached_tombstones
UNION ALL SELECT 'offline_metadata_mutations', COUNT(*) FROM offline_metadata_mutations
UNION ALL SELECT 'library_conflicts', COUNT(*) FROM library_conflicts;
SQL

CAPTURE_FILE_COUNT=0
CAPTURE_FILE_BYTES=0
if [[ -d "$AUDIT_DESTINATION/Capture" ]]; then
  while IFS= read -r -d '' CAPTURE_FILE; do
    ((++CAPTURE_FILE_COUNT))
    CAPTURE_BYTES="$(stat -f '%z' "$CAPTURE_FILE")"
    ((CAPTURE_FILE_BYTES += CAPTURE_BYTES))
  done < <(find "$AUDIT_DESTINATION/Capture" -type f -print0)
fi

echo ""
echo "==> Mobile capture files"
echo "Files: $CAPTURE_FILE_COUNT"
echo "Bytes: $CAPTURE_FILE_BYTES"

if [[ -f "$HOST_DB" ]]; then
  echo ""
  echo "==> Live Host ingest state"
  sqlite3 -readonly -header -column "$HOST_DB" <<'SQL'
SELECT 'devices' AS table_name, COUNT(*) AS count FROM devices
UNION ALL SELECT 'uploads', COUNT(*) FROM uploads
UNION ALL SELECT 'staged_chunks', COUNT(*) FROM staged_chunks
UNION ALL SELECT 'upload_batches', COUNT(*) FROM upload_batches
UNION ALL SELECT 'publication_journal', COUNT(*) FROM publication_journal;

SELECT 'uploads' AS table_name, attempt_status AS state, journal_state,
       COUNT(*) AS count
FROM uploads GROUP BY attempt_status, journal_state
ORDER BY attempt_status, journal_state;
SELECT 'publication_journal' AS table_name, state, COUNT(*) AS count
FROM publication_journal GROUP BY state ORDER BY state;
SQL
else
  echo ""
  echo "==> Live Host ingest state"
  echo "Not available on this Mac: $HOST_DB"
fi

echo ""
echo "Snapshot: $AUDIT_DESTINATION"
echo "Note: copied files do not prove their original iOS protection or backup attributes."
