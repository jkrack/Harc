#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_DIR="$ROOT/Sources/HarcUI/Resources/NoteEditor"
PORT="${PORT:-8765}"
NODE_BIN="${NODE_BIN:-node}"

cd "$EDITOR_DIR"
npm install

python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/harc-note-editor-preview.log 2>&1 &
SERVER_PID=$!
cleanup() {
  trap - EXIT
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$EDITOR_DIR/node_modules"
}
trap cleanup EXIT

for _ in {1..30}; do
  if curl -sS "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

"$NODE_BIN" validate-fixture.mjs "http://127.0.0.1:$PORT/index.html?fixture=full-markdown"
