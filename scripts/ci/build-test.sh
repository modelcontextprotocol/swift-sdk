#!/usr/bin/env bash
# CI job: build the package, run the unit tests, and run the hello example
# over stdio. Arguments go to `swift test` (CI may pass --xunit-output).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ci_step "swift --version"
swift --version
ci_step "swift build"
swift build -v
ci_step "swift test $*"
swift test "$@"
ci_step "HelloClient -> HelloServer (stdio)"
BIN="$(swift build --show-bin-path)"
"$BIN/HelloClient" "$BIN/HelloServer"
