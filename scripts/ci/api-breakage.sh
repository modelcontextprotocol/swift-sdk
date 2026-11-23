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
# The default baseline is the newest release whatever major version HEAD
# develops: a pull request that starts the next major version sets the job's
# line in scripts/ci/jobs to `api-breakage gate api-breakage none` (or a
# ref), and the release that tags X.0.0 restores it.
#
# Runs `swift package diagnose-api-breaking-changes`, which builds the
# baseline in a temporary copy. Needs the history and the tags: a shallow
# clone fetches them, and the job fails when it cannot. Outside a git
# checkout (a source tarball, as scripts/ci-linux.sh runs it) the job is
# skipped and says so.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

baseline="${1:-}"
if [[ -z "$baseline" ]]; then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "api-breakage: not a git checkout; skipped"
        exit 0
    fi
    if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
        # A shallow clone has neither the release tags nor their commits.
        if ! git fetch --quiet --unshallow --tags; then
            echo "api-breakage: shallow clone, and fetching the history and tags failed;" \
                "fetch them (git fetch --unshallow --tags) or pass a baseline" >&2
            exit 1
        fi
    else
        git fetch --quiet --tags 2>/dev/null || true
    fi
    baseline="$(git tag --merged HEAD --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname \
        | grep -E '^[1-9][0-9]*\.[0-9]+\.[0-9]+$' | head -1 || true)"
    if [[ -z "$baseline" ]]; then
        echo "api-breakage: no release tag X.Y.Z (X >= 1) before HEAD; nothing to compare with"
        exit 0
    fi
fi
if [[ "$baseline" == none ]]; then
    echo "api-breakage: skipped"
    exit 0
fi

ci_step "swift package diagnose-api-breaking-changes $baseline --products MCP"
swift package diagnose-api-breaking-changes "$baseline" --products MCP
