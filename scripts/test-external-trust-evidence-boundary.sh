#!/bin/bash

set -euo pipefail

HARC_BOUNDARY_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HARC_BOUNDARY_REPO_ROOT=$(CDPATH= cd -- "$HARC_BOUNDARY_SCRIPT_DIR/.." && pwd)
HARC_BOUNDARY_FIXTURE="Tests/ExternalConstructionBoundaryFixtures/TrustEvidenceForgery.swift"
HARC_HOST_BOUNDARY_FIXTURE="Tests/ExternalConstructionBoundaryFixtures/HostTestingSeam.swift"
HARC_CSQLITE_MODULE_MAP=".build/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
HARC_BOUNDARY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harc-trust-boundary.XXXXXX")
trap 'rm -rf "$HARC_BOUNDARY_TMP"' EXIT

cd "$HARC_BOUNDARY_REPO_ROOT"

env \
    SWIFT_MODULECACHE_PATH="$HARC_BOUNDARY_TMP/build-module-cache" \
    CLANG_MODULE_CACHE_PATH="$HARC_BOUNDARY_TMP/build-clang-cache" \
    swift build --disable-sandbox --target HarcHost
env \
    SWIFT_MODULECACHE_PATH="$HARC_BOUNDARY_TMP/build-module-cache" \
    CLANG_MODULE_CACHE_PATH="$HARC_BOUNDARY_TMP/build-clang-cache" \
    swift build --disable-sandbox --target HarcProtocol

HARC_BOUNDARY_BIN_PATH=$(env \
    SWIFT_MODULECACHE_PATH="$HARC_BOUNDARY_TMP/path-module-cache" \
    CLANG_MODULE_CACHE_PATH="$HARC_BOUNDARY_TMP/path-clang-cache" \
    swift build --disable-sandbox --show-bin-path)
HARC_BOUNDARY_DIAGNOSTICS="$HARC_BOUNDARY_TMP/diagnostics.txt"

set +e
env \
    SWIFT_MODULECACHE_PATH="$HARC_BOUNDARY_TMP/typecheck-module-cache" \
    CLANG_MODULE_CACHE_PATH="$HARC_BOUNDARY_TMP/typecheck-clang-cache" \
    swiftc \
        -typecheck \
        -I "$HARC_BOUNDARY_BIN_PATH/Modules" \
        "$HARC_BOUNDARY_FIXTURE" \
        >"$HARC_BOUNDARY_DIAGNOSTICS" 2>&1
HARC_BOUNDARY_STATUS=$?
set -e

if [[ $HARC_BOUNDARY_STATUS -eq 0 ]]; then
    echo "error: external code unexpectedly constructed Harc trust evidence" >&2
    exit 1
fi

HARC_BOUNDARY_OUTPUT=$(<"$HARC_BOUNDARY_DIAGNOSTICS")
HARC_BOUNDARY_TRANSPORT_ERROR="'ValidatedTransportSetEvidence' initializer is inaccessible due to 'package' protection level"
HARC_BOUNDARY_GRANT_ERROR="'ValidatedDeviceGrantEvidence' initializer is inaccessible due to 'package' protection level"
HARC_BOUNDARY_ADOPTION_ERROR="'ValidatedClientAdoptionEvidence' initializer is inaccessible due to 'package' protection level"
HARC_BOUNDARY_AUTHORITY_REPLACEMENT_ERROR="'ValidatedClientAuthorityReplacementEvidence' initializer is inaccessible due to 'package' protection level"
HARC_BOUNDARY_CURRENT_GRANT_ERROR="'HarcCurrentGrantBindingV1' initializer is inaccessible due to 'package' protection level"

if [[ "$HARC_BOUNDARY_OUTPUT" != *"$HARC_BOUNDARY_TRANSPORT_ERROR"* ]]; then
    echo "error: missing external-construction failure for transport evidence" >&2
    echo "$HARC_BOUNDARY_OUTPUT" >&2
    exit 1
fi

if [[ "$HARC_BOUNDARY_OUTPUT" != *"$HARC_BOUNDARY_GRANT_ERROR"* ]]; then
    echo "error: missing external-construction failure for grant evidence" >&2
    echo "$HARC_BOUNDARY_OUTPUT" >&2
    exit 1
fi

if [[ "$HARC_BOUNDARY_OUTPUT" != *"$HARC_BOUNDARY_ADOPTION_ERROR"* ]]; then
    echo "error: missing external-construction failure for adoption evidence" >&2
    echo "$HARC_BOUNDARY_OUTPUT" >&2
    exit 1
fi

if [[ "$HARC_BOUNDARY_OUTPUT" != *"$HARC_BOUNDARY_AUTHORITY_REPLACEMENT_ERROR"* ]]; then
    echo "error: missing external-construction failure for authority-replacement evidence" >&2
    echo "$HARC_BOUNDARY_OUTPUT" >&2
    exit 1
fi

if [[ "$HARC_BOUNDARY_OUTPUT" != *"$HARC_BOUNDARY_CURRENT_GRANT_ERROR"* ]]; then
    echo "error: missing external-construction failure for current grant binding" >&2
    echo "$HARC_BOUNDARY_OUTPUT" >&2
    exit 1
fi

HARC_HOST_BOUNDARY_DIAGNOSTICS="$HARC_BOUNDARY_TMP/host-diagnostics.txt"
set +e
env \
    SWIFT_MODULECACHE_PATH="$HARC_BOUNDARY_TMP/host-typecheck-module-cache" \
    CLANG_MODULE_CACHE_PATH="$HARC_BOUNDARY_TMP/host-typecheck-clang-cache" \
    swiftc \
        -typecheck \
        -I "$HARC_BOUNDARY_BIN_PATH/Modules" \
        -Xcc "-fmodule-map-file=$HARC_BOUNDARY_REPO_ROOT/$HARC_CSQLITE_MODULE_MAP" \
        "$HARC_HOST_BOUNDARY_FIXTURE" \
        >"$HARC_HOST_BOUNDARY_DIAGNOSTICS" 2>&1
HARC_HOST_BOUNDARY_STATUS=$?
set -e

if [[ $HARC_HOST_BOUNDARY_STATUS -eq 0 ]]; then
    echo "error: external code unexpectedly accessed a host testing seam" >&2
    exit 1
fi

HARC_HOST_BOUNDARY_OUTPUT=$(<"$HARC_HOST_BOUNDARY_DIAGNOSTICS")
HARC_HOST_TESTING_SEAM_ERROR="'replaceForTesting' is inaccessible due to 'internal' protection level"
if [[ "$HARC_HOST_BOUNDARY_OUTPUT" != *"$HARC_HOST_TESTING_SEAM_ERROR"* ]]; then
    echo "error: missing external-access failure for host testing seam" >&2
    echo "$HARC_HOST_BOUNDARY_OUTPUT" >&2
    exit 1
fi

echo "External trust-evidence, live-grant, and host testing-seam boundaries passed."
