#!/usr/bin/env bash
# CI job: one conformance leg or tier score. Arguments go to
# scripts/run-conformance.sh, e.g. `--spec-version 2026-07-28` or
# `--requirements 2025-11-25`; with none it runs the bare leg in both modes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_tools node
ci_step "node $(node --version), conformance $*"
exec "$ROOT/scripts/run-conformance.sh" "$@"
