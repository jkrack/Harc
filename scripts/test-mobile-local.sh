#!/usr/bin/env bash
# Local simulator regression with persistent SSD caches and a fresh result bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${HARC_LOCAL_IOS_ROOT:-}" ]]; then
  SSD=/Volumes/MacMiniSDD
  if [[ ! -d "$SSD" ]] || [[ "$(stat -f %d "$SSD")" == "$(stat -f %d /Volumes)" ]]; then
    echo "error: mount /Volumes/MacMiniSDD or set HARC_LOCAL_IOS_ROOT to another build volume" >&2
    exit 1
  fi
fi
ROOT="${HARC_LOCAL_IOS_ROOT:-/Volumes/MacMiniSDD/HarcBuilds/local-ios}"
[[ "$ROOT" == /* ]] || { echo "error: HARC_LOCAL_IOS_ROOT must be absolute" >&2; exit 1; }
mkdir -p "$ROOT"
for location in "$PWD" "$ROOT"; do
  df -Pk "$location" | awk 'NR == 2 { exit ($4 < 8388608) }' || {
    echo "error: at least 8 GiB free is required on $location before building" >&2
    exit 1
  }
done

# Separate worktrees retain their own incremental build state.
WORKTREE_KEY="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-16)"
CACHE="$ROOT/$WORKTREE_KEY"
mkdir -p "$CACHE/results" "$CACHE/packages"
export HARC_MOBILE_CONFIGURATION_DERIVED="$CACHE/DerivedData"
export HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE="$CACHE/packages"
export HARC_MOBILE_CONFIGURATION_OUTPUT
HARC_MOBILE_CONFIGURATION_OUTPUT="$(mktemp -d "$CACHE/results/run-XXXXXXXX")"
echo "Build cache: $HARC_MOBILE_CONFIGURATION_DERIVED"
echo "Evidence: $HARC_MOBILE_CONFIGURATION_OUTPUT"
xcodegen generate
bash scripts/test-mobile-configuration.sh 2>&1 | tee "$HARC_MOBILE_CONFIGURATION_OUTPUT/console.log"
