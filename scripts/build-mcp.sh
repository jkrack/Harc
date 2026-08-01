#!/usr/bin/env bash
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH must be set}"

cd "$SRCROOT"

# Shares the daemon's scratch dir — same package, same dependency graph, so
# a combined build reuses every module the harc-stt phase already compiled.
SCRATCH="$SRCROOT/.build-daemon"
echo "note: building harc-mcp into $SCRATCH"

swift build \
  -c release \
  --product harc-mcp \
  --scratch-path "$SCRATCH" \
  --arch arm64

MCP_SRC="$SCRATCH/arm64-apple-macosx/release/harc-mcp"
MCP_DST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS/harc-mcp"

mkdir -p "$(dirname "$MCP_DST")"
cp "$MCP_SRC" "$MCP_DST"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi

echo "note: signing $MCP_DST with identity '$IDENTITY'"
codesign --force --sign "$IDENTITY" --options runtime "$MCP_DST"

echo "note: embedded harc-mcp at $MCP_DST"
