#!/usr/bin/env bash
# CI job: the exit status of scripts/run-conformance.sh and the tier scorer,
# with a fake harness (scripts/tests/run-conformance-test.sh). No network.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_tools node
ci_step "scripts/tests/run-conformance-test.sh"
exec "$ROOT/scripts/tests/run-conformance-test.sh"
