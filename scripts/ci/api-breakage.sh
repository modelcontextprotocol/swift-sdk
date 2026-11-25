#!/usr/bin/env bash
# CI job: no breaking change to the public API of the MCP product within a
# major version (VERSIONING.md).
#
# Usage: scripts/ci/api-breakage.sh [<baseline>]
#
#   <baseline>  A git ref to compare with, or `none` to skip. Default: the
#               newest release tag `X.Y.Z` (X >= 1) for the target branch.
#               Without one the job passes and says so.
#
# The target branch is the pull request's base branch (GITHUB_BASE_REF), else
# the pushed branch (GITHUB_REF_NAME), else the checked-out branch;
# API_BREAKAGE_BRANCH overrides all three. A release branch `release-X.Y`
# compares with the newest release of X.Y or an earlier minor version: its own
# newest patch, or before X.Y.0 the newest release of the version before it.
# Any other branch, `main` included, compares with the newest release. Tags
# are looked up on every branch, because releases are tagged on their release
# branch (VERSIONING.md#release-branches). Release candidates (`X.Y.Z-rc.N`)
# are skipped. For a local run of a branch that goes to a release branch:
#
#   API_BREAKAGE_BRANCH=release-1.0 scripts/ci/api-breakage.sh
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
    branch="${API_BREAKAGE_BRANCH:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}}"
    if [[ -z "$branch" ]]; then
        branch="$(git symbolic-ref --quiet --short HEAD || true)"
    fi
    # Release tags only: a release candidate `X.Y.Z-rc.N` is never a baseline.
    # A release branch `release-X.Y` skips the releases of later minor versions.
    scope="" line_major="" line_minor=""
    if [[ "$branch" =~ ^release-([0-9]+)\.([0-9]+)$ ]]; then
        line_major="${BASH_REMATCH[1]}" line_minor="${BASH_REMATCH[2]}"
        scope=" up to $line_major.$line_minor"
    fi
    baseline=""
    while read -r tag; do
        [[ "$tag" =~ ^([1-9][0-9]*)\.([0-9]+)\.[0-9]+$ ]] || continue
        if [[ -n "$line_major" ]]; then
            major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}"
            if (( major > line_major || (major == line_major && minor > line_minor) )); then
                continue
            fi
        fi
        baseline="$tag"
        break
    done < <(git tag --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname)
    if [[ -z "$baseline" ]]; then
        echo "api-breakage: no release tag X.Y.Z (X >= 1)$scope" \
            "(branch ${branch:-unknown}); nothing to compare with"
        exit 0
    fi
    echo "api-breakage: branch ${branch:-unknown}: the newest release$scope is $baseline"
fi
if [[ "$baseline" == none ]]; then
    echo "api-breakage: skipped"
    exit 0
fi

ci_step "swift package diagnose-api-breaking-changes $baseline --products MCP"
swift package diagnose-api-breaking-changes "$baseline" --products MCP
