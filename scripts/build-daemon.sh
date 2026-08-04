#!/usr/bin/env bash
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH must be set}"

cd "$SRCROOT"

SCRATCH="$SRCROOT/.build-daemon"
BUILD_JOBS="${HARC_EMBED_BUILD_JOBS:-2}"
echo "note: building harc-stt into $SCRATCH"

swift build \
  --jobs "$BUILD_JOBS" \
  -c release \
  --product harc-stt \
  --scratch-path "$SCRATCH" \
  --arch arm64

DAEMON_SRC="$SCRATCH/arm64-apple-macosx/release/harc-stt"
DAEMON_DST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS/harc-stt"

mkdir -p "$(dirname "$DAEMON_DST")"
cp "$DAEMON_SRC" "$DAEMON_DST"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi

echo "note: signing $DAEMON_DST with identity '$IDENTITY'"
codesign --force --sign "$IDENTITY" --options runtime "$DAEMON_DST"

echo "note: embedded harc-stt at $DAEMON_DST"
