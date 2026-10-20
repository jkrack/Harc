#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"
minimum_free_kib=$((5 * 1024 * 1024))
available_free_kib=$(df -Pk "$repository_root" | awk 'NR == 2 { print $4 }')
if [[ "$available_free_kib" -lt "$minimum_free_kib" ]]; then
    echo "Publication qualification requires at least 5 GiB free." >&2
    exit 1
fi

evidence_root="${HARC_PUBLICATION_EVIDENCE_DIR:-$repository_root/build/qualification/publication-cross-volume-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$evidence_root"
temporary_root=$(mktemp -d /private/tmp/harc-publication-volume.XXXXXX)
mount_point="$temporary_root/mounted"
image_path="$temporary_root/destination.sparseimage"
mounted=0
cleanup() {
    result=$?
    trap - EXIT INT TERM
    if [[ "$mounted" == 1 ]]; then
        if ! hdiutil detach "$mount_point" >>"$evidence_root/cleanup.log" 2>&1; then
            echo "Detach failed; preserving owned image and mount at $temporary_root" >&2
            exit 1
        fi
    fi
    rm -rf -- "$temporary_root"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git rev-parse HEAD > "$evidence_root/source-commit.txt"
git status --short > "$evidence_root/worktree.txt"
swift --version > "$evidence_root/toolchain.txt"
python3 - "$evidence_root" <<'PY'
from pathlib import Path
import hashlib, json, sys
paths = [
    'Sources/HarcCore/RecordingPublication.swift',
    'Sources/HarcCore/DurableFileIO.swift',
    'Tests/HarcCoreTests/RecordingPublicationTests.swift',
    'scripts/qualify-publication-cross-volume.sh',
    'Package.swift', 'Package.resolved',
]
manifest = {
    'classification': 'diagnostic disposable APFS disk-image qualification',
    'limitations': ['not physical power-loss evidence', 'not removable-drive or network-filesystem qualification'],
    'files': {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},
}
(Path(sys.argv[1])/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY

hdiutil create -size 128m -fs APFS -type SPARSE -volname HarcPublicationQualification \
    "$image_path" > "$evidence_root/create.log" 2>&1
mkdir -p "$mount_point"
mounted=1
hdiutil attach -nobrowse -mountpoint "$mount_point" -plist "$image_path" \
    > "$evidence_root/attachment.plist" 2> "$evidence_root/attach.log"
python3 - "$mount_point" "$evidence_root/attachment.plist" <<'PY'
import plistlib, sys
with open(sys.argv[2], 'rb') as f:
    entities = plistlib.load(f)['system-entities']
if not any(e.get('mount-point') == sys.argv[1] for e in entities):
    raise SystemExit('Attached volume did not match the owned mount point')
PY

options=(--jobs 2)
if [[ "${HARC_SKIP_BUILD:-0}" == 1 ]]; then
    options+=(--skip-build)
fi
HARC_CROSS_VOLUME_DESTINATION="$mount_point" \
    swift test "${options[@]}" --filter 'RecordingPublicationTests/crossVolumePublication' \
    2>&1 | tee "$evidence_root/tests.log"
python3 - "$evidence_root/tests.log" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
expected = '✔ Test "publication crosses a separately mounted volume without losing the original bytes" passed'
if expected not in text or '✔ Test run with 1 test in 1 suite passed' not in text:
    raise SystemExit('Cross-volume test did not execute and pass; skips are not qualification')
PY
echo "Publication cross-volume diagnostic passed; evidence: $evidence_root"
