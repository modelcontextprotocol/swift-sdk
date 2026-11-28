#!/usr/bin/env bash
# CI job: the tests of the CI scripts. The exit status of
# scripts/run-conformance.sh and the tier scorer, with a fake harness
# (scripts/tests/run-conformance-test.sh), and the baseline that
# scripts/ci/api-breakage.sh picks for each branch
# (scripts/tests/api-breakage-test.sh). No network.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_tools node
ci_step "scripts/tests/run-conformance-test.sh"
"$ROOT/scripts/tests/run-conformance-test.sh"
ci_step "scripts/tests/api-breakage-test.sh"
exec "$ROOT/scripts/tests/api-breakage-test.sh"
