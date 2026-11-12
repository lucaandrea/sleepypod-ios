#!/bin/bash
set -euo pipefail

# Shared test bundles run on the same runner family; a second architecture doubles compilation.
runner_architecture="$(uname -m)"
case "$runner_architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported simulator runner architecture: %s\n' "$runner_architecture" >&2; exit 2 ;;
esac

exec xcodebuild build-for-testing -destination 'generic/platform=iOS Simulator' \
  "$@" "ARCHS=$runner_architecture"
