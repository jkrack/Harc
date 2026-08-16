#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
minimum_free_kib=$((5 * 1024 * 1024))
available_free_kib=$(df -Pk "$repository_root" | awk 'NR == 2 { print $4 }')
run_marker="/tmp/harc-run-pairing-lifecycle-e2e-$UID"

if [[ -z "$available_free_kib" || "$available_free_kib" -lt "$minimum_free_kib" ]]; then
    print -u2 "Pairing lifecycle E2E stopped: Harc requires at least 5 GiB free."
    exit 1
fi

touch "$run_marker"
trap 'rm -f -- "$run_marker"' EXIT INT TERM
cd "$repository_root"
swift test \
    --jobs 2 \
    --filter PairingLifecycleLoopbackIntegrationTests
