#!/usr/bin/env bash
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH must be set}"

cd "$SRCROOT"

SCRATCH="$SRCROOT/.build-daemon"
mkdir -p "$SCRATCH"
# Use one cache identity when regenerable output is symlinked to an SSD.
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
source "$SRCROOT/scripts/build-concurrency.sh"
harc_configure_build_jobs "${HARC_EMBED_BUILD_JOBS:-${HARC_BUILD_JOBS:-}}"
echo "note: building harc-stt into $SCRATCH"

harc_swift build \
  -c release \
  --product harc-stt \
  --scratch-path "$SCRATCH" \
  --arch arm64

# SwiftPM's default build engine changed in Xcode 27; query its output path.
BIN_DIR="$(harc_swift build -c release --product harc-stt \
  --scratch-path "$SCRATCH" --arch arm64 --show-bin-path)"
DAEMON_SRC="$BIN_DIR/harc-stt"
DAEMON_DST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS/harc-stt"

mkdir -p "$(dirname "$DAEMON_DST")"
cp "$DAEMON_SRC" "$DAEMON_DST"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi

echo "note: signing $DAEMON_DST with identity '$IDENTITY'"
codesign --force --sign "$IDENTITY" --options runtime "$DAEMON_DST"

echo "note: embedded harc-stt at $DAEMON_DST"
