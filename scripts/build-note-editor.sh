#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_DIR="$ROOT/Sources/HarcUI/Resources/NoteEditor"

cd "$EDITOR_DIR"
npm install
npm run build
rm -rf node_modules
