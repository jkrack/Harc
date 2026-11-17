#!/bin/bash
# Explicit development-only synthetic .app + read-only external AX client.
set -euo pipefail
SCRATCH="${1:?Supply SSD Swift build scratch path}"
OUTPUT="${2:?Supply evidence output directory}"
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d /tmp/harc-preview-app-qa.XXXXXX)
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    if jobs -pr | grep -Fxq "$PID"; then kill -TERM "$PID" 2>/dev/null || true; fi
    for _ in {1..50}; do
      if ! jobs -pr | grep -Fxq "$PID"; then break; fi
      sleep 0.1
    done
    if jobs -pr | grep -Fxq "$PID"; then kill -KILL "$PID" 2>/dev/null || true; fi
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
mkdir -p "$OUTPUT"
HARC_BUILD_PREVIEW_QA=1 swift build --scratch-path "$SCRATCH" --product HarcPreviewQAFixture
BIN=$(HARC_BUILD_PREVIEW_QA=1 swift build --scratch-path "$SCRATCH" --show-bin-path)
swiftc Tools/PreviewAccessibilityProbe.swift -o "$ROOT/probe"
APP="$ROOT/SyntheticHarcPreview.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/HarcPreviewQAFixture" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.harc.synthetic-preview-qa</string>
<key>CFBundleName</key><string>Synthetic Harc Preview QA</string>
<key>CFBundleExecutable</key><string>HarcPreviewQAFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
"$APP/Contents/MacOS/HarcPreviewQAFixture" > "$OUTPUT/fixture.log" 2>&1 &
PID=$!
for _ in {1..100}; do
  if grep -q SYNTHETIC_PREVIEW_READY "$OUTPUT/fixture.log"; then break; fi
  sleep 0.1
done
grep -q SYNTHETIC_PREVIEW_READY "$OUTPUT/fixture.log"
"$ROOT/probe" "$PID" > "$OUTPUT/ax-tree.txt"
python3 - "$OUTPUT" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
text = (root / "ax-tree.txt").read_text()
checks = {
    "application_accessible": "0 AXRole: AXApplication" in text,
    "dismiss_button_identifier": bool(re.search(r"3 AXRole: AXButton\n(?:(?!\n\d+ AXRole:).)*untrusted-project-preview-dismiss", text, re.S)),
    "warning_present": "Unverified suggestion. No connection has been saved." in text,
    "source_heading": "AXDescription: Complete source transcript" in text,
    "full_source_correction": "FINAL SOURCE CORRECTION: approval remains blocked." in text,
    "source_identifier": "AXIdentifier: untrusted-project-preview-source" in text,
    "scroll_area": "AXRole: AXScrollArea" in text,
    "native_control": "NATIVE ACCESSIBILITY CONTROL MARKER" in text,
    "minimal_swiftui_control": "SWIFTUI ACCESSIBILITY CONTROL MARKER" in text,
}
(root / "assertions.json").write_text(json.dumps(checks, indent=2) + "\n")
assert all(checks.values()), checks
print("Read-only external AX assertions passed; no VoiceOver or AXPress claim.")
PY
