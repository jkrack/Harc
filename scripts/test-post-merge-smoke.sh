#!/usr/bin/env bash
# Fast source/tooling checks for main. Full app and runtime validation stays on PRs.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${HARC_SMOKE_OUTPUT:-build/smoke}"
mkdir -p "$OUTPUT"
git rev-parse HEAD > "$OUTPUT/source.txt"
xcodebuild -version > "$OUTPUT/toolchain.txt"
swift --version >> "$OUTPUT/toolchain.txt"

swift package dump-package > "$OUTPUT/package.json"
./scripts/check-harc-protocol-schemas.sh 2>&1 | tee "$OUTPUT/protocol.log"
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v \
  2>&1 | tee "$OUTPUT/tooling-tests.log"
xcodegen generate 2>&1 | tee "$OUTPUT/project-generation.log"
echo "Repository smoke checks passed; full app/runtime validation is covered by PR CI."
