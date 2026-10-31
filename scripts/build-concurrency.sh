# Shared local build concurrency. Sourced by Bash/Zsh build scripts.
# Leave local scheduling to the tool unless the owner supplies an override.
# Hosted CI retains its existing two-worker budget.
harc_configure_build_jobs() {
  HARC_BUILD_JOB_COUNT="${1:-${HARC_BUILD_JOBS:-}}"
  if [ -z "$HARC_BUILD_JOB_COUNT" ]; then
    case "${CI:-}" in true|1) HARC_BUILD_JOB_COUNT=2 ;; esac
  fi
  case "$HARC_BUILD_JOB_COUNT" in
    "") ;;
    *[!0-9]*|0*) echo "error: build job override must be a positive integer" >&2; return 64 ;;
  esac
}

harc_swift() {
  local action="$1"
  shift
  if [ -n "$HARC_BUILD_JOB_COUNT" ]; then
    swift "$action" --jobs "$HARC_BUILD_JOB_COUNT" "$@"
  else
    swift "$action" "$@"
  fi
}

harc_xcodebuild() {
  if [ -n "$HARC_BUILD_JOB_COUNT" ]; then
    xcodebuild -jobs "$HARC_BUILD_JOB_COUNT" \
      "SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=$HARC_BUILD_JOB_COUNT" "$@"
  else
    xcodebuild "$@"
  fi
}
