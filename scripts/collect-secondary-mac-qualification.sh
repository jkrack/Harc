#!/usr/bin/env bash
set -euo pipefail

# Collects privacy-bounded, read-only evidence for one named two-Mac
# qualification checkpoint. It never copies audio, transcripts, pairing
# secrets, route capabilities, Keychain items, or database contents.
#
# Run on both the Host and Client after each scenario:
#   ./scripts/collect-secondary-mac-qualification.sh \
#     --role client --run-id 2026-08-23-candidate-1 \
#     --scenario host-restart --result pass \
#     --output-dir /path/to/new/evidence-directory \
#     --app /Applications/Harc.app

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLE=""
RUN_ID=""
SCENARIO=""
RESULT=""
OUTPUT_DIR=""
APP_PATH="/Applications/Harc.app"
ALLOW_DIRTY=0

usage() {
  echo "usage: $0 --role host|client --run-id <id> --scenario <id> --result pass|fail --output-dir <new-directory> [--app <Harc.app>] [--allow-dirty-diagnostic]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      ROLE="$2"
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      RUN_ID="$2"
      shift 2
      ;;
    --scenario)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      SCENARIO="$2"
      shift 2
      ;;
    --result)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      RESULT="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --app)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      APP_PATH="$2"
      shift 2
      ;;
    --allow-dirty-diagnostic)
      ALLOW_DIRTY=1
      shift
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ "$ROLE" != "host" && "$ROLE" != "client" ]]; then
  echo "error: --role must be host or client" >&2
  exit 64
fi
if [[ "$RESULT" != "pass" && "$RESULT" != "fail" ]]; then
  echo "error: --result must be pass or fail" >&2
  exit 64
fi
if [[ -z "$RUN_ID" || -z "$SCENARIO" || -z "$OUTPUT_DIR" ]]; then
  usage
  exit 64
fi
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ || ! "$SCENARIO" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: run and scenario IDs may contain only letters, digits, dot, underscore, and hyphen" >&2
  exit 64
fi
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "error: output path already exists: $OUTPUT_DIR" >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "Harc.app" ]]; then
  echo "error: Harc app not found at $APP_PATH" >&2
  exit 1
fi

for TOOL in git shasum codesign spctl plutil defaults sw_vers sysctl log; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "error: required tool is unavailable: $TOOL" >&2
    exit 1
  }
done

AVAILABLE_GIB="$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
if [[ "$AVAILABLE_GIB" -lt 5 ]]; then
  echo "error: free disk is ${AVAILABLE_GIB} GiB; stop below the 5 GiB operational floor" >&2
  exit 1
fi

cd "$REPO_ROOT"
SOURCE_HEAD="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain=v1 --untracked-files=all)"
if [[ -n "$SOURCE_STATUS" && "$ALLOW_DIRTY" -ne 1 ]]; then
  echo "error: release qualification requires a clean tree; use --allow-dirty-diagnostic only for non-release evidence" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SOURCE_FILE_LIST="$(git ls-files --cached --others --exclude-standard | LC_ALL=C sort)"
while IFS= read -r SOURCE_FILE; do
  [[ -n "$SOURCE_FILE" ]] || continue
  shasum -a 256 "$SOURCE_FILE"
done <<< "$SOURCE_FILE_LIST" > "$OUTPUT_DIR/source-files.sha256"
SOURCE_FINGERPRINT="$(shasum -a 256 "$OUTPUT_DIR/source-files.sha256" | awk '{ print $1 }')"
printf '%s\n' "$SOURCE_STATUS" > "$OUTPUT_DIR/source-status.txt"

APP_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Harc"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PLIST" 2>/dev/null || true)"
APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PLIST" 2>/dev/null || true)"
APP_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PLIST" 2>/dev/null || true)"
APP_BUILD_SHA="$(plutil -extract HarcBuildSHA raw -o - "$APP_PLIST" 2>/dev/null || true)"
APP_EXECUTABLE_SHA256="$(shasum -a 256 "$APP_EXECUTABLE" | awk '{ print $1 }')"
CONFIGURED_ROLE="$(defaults read "$APP_BUNDLE_ID" harc.runtimeRole 2>/dev/null || echo unset)"

set +e
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  > "$OUTPUT_DIR/codesign-verify.txt" 2>&1
CODESIGN_STATUS=$?
spctl --assess --type execute --verbose=4 "$APP_PATH" \
  > "$OUTPUT_DIR/gatekeeper-assessment.txt" 2>&1
GATEKEEPER_STATUS=$?
set -e
codesign -dvvv "$APP_PATH" > "$OUTPUT_DIR/codesign-details.txt" 2>&1 || true
APP_SIGNING_AUTHORITY="$(sed -n 's/^Authority=//p' "$OUTPUT_DIR/codesign-details.txt" | head -n 1)"
APP_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' "$OUTPUT_DIR/codesign-details.txt" | head -n 1)"
APP_HARDENED_RUNTIME=false
if grep -Eq '^flags=.*\(runtime\)' "$OUTPUT_DIR/codesign-details.txt"; then
  APP_HARDENED_RUNTIME=true
fi

{
  sw_vers
  echo "architecture=$(uname -m)"
  echo "hardware_model=$(sysctl -n hw.model 2>/dev/null || true)"
  echo "memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)"
  echo "computer_name_hash=$(scutil --get ComputerName 2>/dev/null | shasum -a 256 | awk '{ print $1 }')"
} > "$OUTPUT_DIR/machine.txt"

SUPPORT_ROOT="$HOME/Library/Application Support/Harc"
CLIENT_ROOT="$SUPPORT_ROOT/ClientState"
if [[ "$ROLE" == "client" ]]; then
  DIAGNOSTIC_LOG="$CLIENT_ROOT/Logs/client-diagnostics.jsonl"
  if [[ -f "$DIAGNOSTIC_LOG" ]]; then
    cp -p "$DIAGNOSTIC_LOG" "$OUTPUT_DIR/client-diagnostics.jsonl"
  else
    : > "$OUTPUT_DIR/client-diagnostics-missing.txt"
  fi
  for STATE_FILE in \
    "$CLIENT_ROOT/Transfer/HarcTransfer.sqlite" \
    "$CLIENT_ROOT/LibraryCache/HarcLibraryCache.sqlite" \
    "$CLIENT_ROOT/host-route.json"; do
    if [[ -f "$STATE_FILE" ]]; then
      printf '%s  %s  %s\n' \
        "$(basename "$STATE_FILE")" \
        "$(stat -f '%z' "$STATE_FILE")" \
        "$(shasum -a 256 "$STATE_FILE" | awk '{ print $1 }')"
    fi
  done > "$OUTPUT_DIR/client-state-file-identities.txt"
else
  HOST_DB="$SUPPORT_ROOT/HarcHost.db"
  if [[ -f "$HOST_DB" ]]; then
    printf '%s  %s  %s\n' \
      "$(basename "$HOST_DB")" \
      "$(stat -f '%z' "$HOST_DB")" \
      "$(shasum -a 256 "$HOST_DB" | awk '{ print $1 }')" \
      > "$OUTPUT_DIR/host-state-file-identity.txt"
  else
    : > "$OUTPUT_DIR/host-state-file-missing.txt"
  fi
fi

# Unified logging honors Harc's OSLog privacy annotations. This bounded window
# is operational evidence only and does not include app state databases.
log show --last 2h --style ndjson \
  --predicate 'subsystem BEGINSWITH "com.harc"' \
  > "$OUTPUT_DIR/harc-unified-log.ndjson" 2> "$OUTPUT_DIR/log-errors.txt" \
  || true

ROLE_MATCH=true
if [[ "$CONFIGURED_ROLE" != "$ROLE" ]]; then
  ROLE_MATCH=false
fi

{
  echo "run_id=$RUN_ID"
  echo "scenario=$SCENARIO"
  echo "tester_result=$RESULT"
  echo "role=$ROLE"
  echo "configured_role=$CONFIGURED_ROLE"
  echo "configured_role_matches=$ROLE_MATCH"
  echo "collected_at=$STARTED_AT"
  echo "source_head=$SOURCE_HEAD"
  echo "source_manifest_sha256=$SOURCE_FINGERPRINT"
  echo "tree_clean=$([[ -z "$SOURCE_STATUS" ]] && echo true || echo false)"
  echo "diagnostic_dirty_tree=$([[ "$ALLOW_DIRTY" -eq 1 ]] && echo true || echo false)"
  echo "app_path=$APP_PATH"
  echo "app_bundle_id=$APP_BUNDLE_ID"
  echo "app_version=$APP_VERSION"
  echo "app_build=$APP_BUILD"
  echo "app_build_sha=$APP_BUILD_SHA"
  echo "app_executable_sha256=$APP_EXECUTABLE_SHA256"
  echo "app_signing_authority=$APP_SIGNING_AUTHORITY"
  echo "app_team_id=$APP_TEAM_ID"
  echo "app_hardened_runtime=$APP_HARDENED_RUNTIME"
  echo "codesign_status=$CODESIGN_STATUS"
  echo "gatekeeper_status=$GATEKEEPER_STATUS"
  echo "available_gib=$AVAILABLE_GIB"
} > "$OUTPUT_DIR/qualification.txt"

shasum -a 256 "$OUTPUT_DIR"/* > "$OUTPUT_DIR/evidence-files.sha256"

if [[ "$ROLE_MATCH" != true ]]; then
  echo "error: configured role '$CONFIGURED_ROLE' does not match requested role '$ROLE'" >&2
  exit 1
fi
if [[ "$CODESIGN_STATUS" -ne 0 ]]; then
  echo "error: app signature verification failed" >&2
  exit 1
fi
if [[ "$GATEKEEPER_STATUS" -ne 0 ]]; then
  echo "error: Gatekeeper rejected the installed Harc app" >&2
  exit 1
fi
if [[ "$APP_BUILD_SHA" != "$SOURCE_HEAD" ]]; then
  echo "error: app source commit '$APP_BUILD_SHA' does not match reviewed source '$SOURCE_HEAD'" >&2
  exit 1
fi
if [[ "$APP_SIGNING_AUTHORITY" != Developer\ ID\ Application:* ]]; then
  echo "error: app is not signed with a Developer ID Application identity" >&2
  exit 1
fi
if [[ "$APP_TEAM_ID" != "63TNU5M7P4" ]]; then
  echo "error: app Team Identifier '$APP_TEAM_ID' is not the Harc release team" >&2
  exit 1
fi
if [[ "$APP_HARDENED_RUNTIME" != true ]]; then
  echo "error: app signature does not enable the hardened runtime" >&2
  exit 1
fi
if [[ "$ROLE" == "client" && ! -f "$OUTPUT_DIR/client-diagnostics.jsonl" ]]; then
  echo "error: Client diagnostic log is missing; the Client runtime was not evidenced" >&2
  exit 1
fi
if [[ "$ROLE" == "host" && ! -f "$OUTPUT_DIR/host-state-file-identity.txt" ]]; then
  echo "error: HarcHost.db is missing; the Host runtime was not evidenced" >&2
  exit 1
fi

echo "Evidence: $OUTPUT_DIR"
echo "Source manifest SHA-256: $SOURCE_FINGERPRINT"
echo "App executable SHA-256: $APP_EXECUTABLE_SHA256"
echo "Tester result: $RESULT"
