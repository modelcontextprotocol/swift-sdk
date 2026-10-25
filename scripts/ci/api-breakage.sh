#!/usr/bin/env bash
# CI job: no breaking change to the public API of the MCP product within a
# major version (VERSIONING.md).
#
# Usage: scripts/ci/api-breakage.sh [<baseline>]
#
#   <baseline>  A git ref to compare with, or `none` to skip. Default: the
#               newest release tag `X.Y.Z` (X >= 1) that is an ancestor of
#               HEAD. Without one the job passes and says so.
#
# Runs `swift package diagnose-api-breaking-changes`, which builds the
# baseline in a temporary copy. Needs the tags: a shallow clone fetches them.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

baseline="${1:-}"
if [[ -z "$baseline" ]]; then
    git fetch --quiet --tags 2>/dev/null || true
    baseline="$(git tag --merged HEAD --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname \
        | grep -E '^[1-9][0-9]*\.[0-9]+\.[0-9]+$' | head -1 || true)"
    if [[ -z "$baseline" ]]; then
        echo "api-breakage: no 1.x release tag before HEAD; nothing to compare with"
        exit 0
    fi
fi
if [[ "$baseline" == none ]]; then
    echo "api-breakage: skipped"
    exit 0
fi

ci_step "swift package diagnose-api-breaking-changes $baseline --products MCP"
swift package diagnose-api-breaking-changes "$baseline" --products MCP
