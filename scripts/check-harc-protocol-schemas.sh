#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_root"

fail() {
    printf 'Harc protocol schema guard: %s\n' "$1" >&2
    exit 1
}

expected_schema_files='Protos/harc_common.proto
Protos/harc_identity.proto
Protos/harc_library.proto
Protos/harc_migration.proto
Protos/harc_pairing.proto
Protos/harc_processing.proto
Protos/harc_transfer.proto'

schema_files=$(find Protos -maxdepth 1 -type f -name '*.proto' -print | LC_ALL=C sort)
[ "$schema_files" = "$expected_schema_files" ] || fail "the V1 schema inventory changed"

swift_sources=$(find Protos -maxdepth 1 -type f -name '*.swift' -print | LC_ALL=C sort)
[ "$swift_sources" = 'Protos/Module.swift' ] \
    || fail "HarcProtocolWire may contain only the Module.swift plugin sentinel"
if grep -Ev '^[[:space:]]*(//.*)?$' Protos/Module.swift | grep -q .; then
    fail "Module.swift must remain declaration-free"
fi

for schema in $schema_files; do
    [ "$(grep -Ec '^syntax = "proto3";$' "$schema")" -eq 1 ] \
        || fail "$schema must declare proto3 exactly once"
    [ "$(grep -Ec '^package harc\.v1;$' "$schema")" -eq 1 ] \
        || fail "$schema must declare package harc.v1 exactly once"
    [ "$(grep -Ec '^option swift_prefix = "Harc_V1_";$' "$schema")" -eq 1 ] \
        || fail "$schema must declare the Harc_V1_ Swift prefix exactly once"
done

generator_config=Protos/grpc-swift-proto-generator-config.json
[ -f "$generator_config" ] || fail "the protobuf generator configuration is missing"
grep -Eq '"clients"[[:space:]]*:[[:space:]]*true' "$generator_config" \
    || fail "client generation must remain enabled"
grep -Eq '"servers"[[:space:]]*:[[:space:]]*true' "$generator_config" \
    || fail "server generation must remain enabled"
grep -Eq '"messages"[[:space:]]*:[[:space:]]*true' "$generator_config" \
    || fail "message generation must remain enabled"
grep -Eq '"accessLevel"[[:space:]]*:[[:space:]]*"public"' "$generator_config" \
    || fail "generated declarations must remain public"
grep -Eq '"accessLevelOnImports"[[:space:]]*:[[:space:]]*true' "$generator_config" \
    || fail "generated imports must retain explicit access levels"
grep -Eq '"importPaths"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$generator_config" \
    || fail "the generator must not depend on undeclared import paths"

schema_source=$(
    for schema in $schema_files; do
        sed 's,//.*$,,' "$schema"
    done
)

if printf '%s\n' "$schema_source" | grep -Eq '(^|[^[:alnum:]_])map[[:space:]]*<'; then
    fail "protobuf map fields are prohibited; use canonical sorted repeated entries"
fi

field_names=$(
    printf '%s\n' "$schema_source" \
        | grep -Eo '[a-z][a-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+' \
        | sed -E 's/[[:space:]]*=.*$//' \
        || true
)

# `http_path` is the one path-shaped wire field: it is the capability-bound
# HTTP request target from Section 13.3, not a host filesystem path. Any other
# path-shaped field would expose a new wire concept and requires explicit review.
path_fields=$(printf '%s\n' "$field_names" | grep -E '(^path$|_path$)' || true)
[ "$path_fields" = 'http_path' ] \
    || fail "only the capability-bound http_path field may be path-shaped"

if printf '%s\n' "$field_names" \
    | grep -Eq '(^|_)(db|database|grdb|row)(_id)?($|_)'; then
    fail "database and row identifiers are prohibited on the wire"
fi

if ! awk '
    {
        sub(/\/\/.*/, "")
    }
    /^[[:space:]]*enum[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ {
        in_enum = 1
        enum_name = $2
        assignment_count = 0
        zero_count = 0
        enum_count += 1
        next
    }
    in_enum {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^[A-Z][A-Z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+;/) {
            value_name = line
            sub(/[[:space:]]*=.*/, "", value_name)
            number = line
            sub(/^.*=[[:space:]]*/, "", number)
            sub(/;.*/, "", number)
            assignment_count += 1
            if (number == 0) {
                zero_count += 1
            }
            if (assignment_count == 1 && (number != 0 || value_name !~ /_UNSPECIFIED$/)) {
                print enum_name " must begin with *_UNSPECIFIED = 0" > "/dev/stderr"
                failed = 1
            }
        }
        if ($0 ~ /^[[:space:]]*}/) {
            if (zero_count != 1) {
                print enum_name " must contain exactly one zero value" > "/dev/stderr"
                failed = 1
            }
            in_enum = 0
        }
    }
    END {
        if (in_enum) {
            print "unterminated enum declaration" > "/dev/stderr"
            failed = 1
        }
        if (enum_count != 29) {
            print "expected 29 V1 enums, found " enum_count > "/dev/stderr"
            failed = 1
        }
        exit failed
    }
' $schema_files; then
    fail "enum zero-value contract changed"
fi

services=$(
    printf '%s\n' "$schema_source" \
        | grep -E '^[[:space:]]*service[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{' \
        | sed -E 's/^[[:space:]]*service[[:space:]]+([A-Za-z0-9_]+).*/\1/' \
        | LC_ALL=C sort
)
expected_services='HostInfoService
LibraryService
PairingService
ProcessingService
RecordingTransferService
SessionService'
[ "$services" = "$expected_services" ] || fail "the six-service V1 inventory changed"

rpc_count=$(printf '%s\n' "$schema_source" | grep -Ec '^[[:space:]]*rpc[[:space:]]+')
[ "$rpc_count" -eq 27 ] || fail "the V1 service inventory must contain exactly 27 RPCs"

inventory_file=Protos/Fixtures/harc-protocol-sources-v1.sha256
[ -f "$inventory_file" ] || fail "the V1 schema checksum inventory is missing"
expected_inventory_paths='Protos/grpc-swift-proto-generator-config.json
Protos/harc_common.proto
Protos/harc_identity.proto
Protos/harc_library.proto
Protos/harc_migration.proto
Protos/harc_pairing.proto
Protos/harc_processing.proto
Protos/harc_transfer.proto'
inventory_paths=$(awk '{ print $2 }' "$inventory_file")
[ "$inventory_paths" = "$expected_inventory_paths" ] \
    || fail "the checksum inventory paths or order changed"
if ! shasum -a 256 -c "$inventory_file" >/dev/null; then
    fail "a schema or generator-config checksum changed; review and deliberately refresh the V1 inventory"
fi

printf 'Harc protocol schema guard passed: 7 schemas, 6 services, 27 RPCs, 29 enums.\n'
