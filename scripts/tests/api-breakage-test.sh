#!/bin/bash
# Tests the baseline scripts/ci/api-breakage.sh picks for each target branch,
# in a scratch repository with release branches and tags, and a fake `swift`
# that records its arguments. Needs git; no network.
#
# Usage: scripts/tests/api-breakage-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
REPO="$WORK/repo"

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $expected, got $actual"
    FAILED=1
  fi
}

# Git without the user's configuration: no signing, no hooks, a fixed identity.
g() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$REPO" "$@"
}
commit() { g commit --quiet --allow-empty -m "$1"; }

mkdir -p "$REPO/scripts/ci" "$WORK/bin"
cp "$ROOT/scripts/ci/api-breakage.sh" "$ROOT/scripts/ci/lib.sh" "$REPO/scripts/ci/"
cat >"$WORK/bin/swift" <<EOF
#!/bin/sh
echo "\$3" >"$WORK/compared"
EOF
chmod +x "$WORK/bin/swift"

# The baseline the script compares with for the checked-out commit, or
# "skipped" when it does not call swift. Extra arguments are VAR=value pairs.
baseline() {
  local args=()
  [[ "${1:-}" == --arg ]] && { args=("$2"); shift 2; }
  rm -f "$WORK/compared"
  (cd "$REPO" && env -u API_BREAKAGE_BRANCH -u GITHUB_BASE_REF -u GITHUB_REF_NAME \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="$WORK/bin:$PATH" "$@" \
    scripts/ci/api-breakage.sh ${args[@]+"${args[@]}"}) >/dev/null
  if [[ -f "$WORK/compared" ]]; then cat "$WORK/compared"; else echo skipped; fi
}

g init --quiet --initial-branch=main
commit "0.x"
g tag 0.12.1
check "no release tag X.Y.Z (X >= 1): skipped" skipped "$(baseline)"

# main: 0.12.1 - 1.0.0 - m1 - m2
#   release-1.0 from 1.0.0: 1.0.1
#   release-1.1 from m1:    1.1.0 - 1.1.1 (not on main)
commit "1.0.0"
g tag 1.0.0
g branch release-1.0
commit "m1"
g branch release-1.1
commit "m2"
g switch --quiet release-1.0
commit "1.0.1"
g tag 1.0.1
g switch --quiet release-1.1
commit "1.1.0"
g tag 1.1.0
commit "1.1.1"
g tag 1.1.1

g switch --quiet main
check "main: the newest release on any branch" 1.1.1 "$(baseline)"
check "a pull request into main" 1.1.1 "$(baseline GITHUB_BASE_REF=main GITHUB_REF_NAME=7/merge)"
check "an explicit baseline wins" 1.0.0 "$(baseline --arg 1.0.0)"
check "an explicit none skips" skipped "$(baseline --arg none)"

g switch --quiet release-1.0
check "release-1.0: its newest patch" 1.0.1 "$(baseline)"
check "a push to release-1.0" 1.0.1 "$(baseline GITHUB_BASE_REF= GITHUB_REF_NAME=release-1.0)"
check "release-1.1: its newest patch" 1.1.1 "$(g switch --quiet release-1.1 && baseline)"

g switch --quiet --create fix release-1.0
commit "fix"
check "a branch off release-1.0, run locally: like main" 1.1.1 "$(baseline)"
check "a pull request into release-1.0" 1.0.1 \
  "$(baseline GITHUB_BASE_REF=release-1.0 GITHUB_REF_NAME=8/merge)"
check "API_BREAKAGE_BRANCH overrides the pull request's base" 1.0.1 \
  "$(baseline API_BREAKAGE_BRANCH=release-1.0 GITHUB_BASE_REF=main)"

g switch --quiet --detach 1.0.1
check "a detached HEAD: like main" 1.1.1 "$(baseline)"

exit "$FAILED"
