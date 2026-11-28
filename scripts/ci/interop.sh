#!/usr/bin/env bash
# CI job: the interop matrix against the Go, Python and TypeScript SDKs.
# Arguments go to scripts/run-interop.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_tools go uv node ps
ci_step "$(go version), $(uv --version), node $(node --version), interop $*"
exec "$ROOT/scripts/run-interop.sh" "$@"
