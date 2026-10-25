#!/usr/bin/env bash
# Runs CI jobs on Linux in a container on this Mac, with Apple's `container`
# CLI, in a Swift builder image.
#
# Usage: scripts/ci-linux.sh [options] all
#        scripts/ci-linux.sh [options] <id-regex>...
#        scripts/ci-linux.sh [options] <script> [args...]
#        scripts/ci-linux.sh [options] --shell
#
#   all               Every job in scripts/ci/jobs, then a summary. A failing
#                     job does not stop the rest; jobs marked `advisory` are
#                     reported but do not fail the run (--strict: they do).
#   <id-regex>...     The jobs of scripts/ci/jobs whose ids match, e.g.
#                     conformance-2026-07-28-client or 'conformance-.*' interop.
#   <script> [args]   scripts/ci/<script>.sh with any arguments, e.g.
#                     `conformance --spec-version 2025-11-25 --mode client`.
#   --shell           An interactive shell in the prepared container, at /w.
#
#   --gate, --advisory, --strict
#                     Passed to scripts/ci/run-jobs.sh: only the gated, or only
#                     the advisory, jobs; count advisory failures.
#   --image <ref>     Builder image (default: $CI_LINUX_IMAGE, else
#                     swift:6.1-rhel-ubi9).
#   --platform <p>    linux/arm64 (Apple silicon default) or linux/amd64
#                     (x86_64; emulated, much slower).
#   --cpus <n>        CPUs for the container (default: 8).
#   --memory <size>   Memory for the container (default: 16G).
#   --clean           Delete the build volume for this image first.
#   --job-timeout <m> Stop a job after <m> minutes (default: 30); it counts as
#                     failed.
#
# Each run starts from a copy of the working tree at /w: tracked files and
# untracked files that are not ignored, so uncommitted changes are included
# and the Mac's .build is not touched. /w/.build and the package caches
# (SwiftPM, npm, Go, uv) are named volumes, so later runs are incremental.
# Node, Go and uv come from scripts/ci/deps-linux.sh, baked into a local
# derived image that is rebuilt when the script or the base image changes.
#
# Results (conformance and interop reports and logs) are copied to
# .build/linux/<image>-<arch>/. With --update-baseline or --update-results
# among the arguments, the regenerated conformance/baseline*.yml and
# interop/RESULTS.md are copied back into the working tree.
#
# Environment passed through when set: npm_config_registry, GOPROXY,
# GONOSUMDB, GOFLAGS, UV_INDEX_URL, PIP_INDEX_URL, CONFORMANCE_PKG,
# CLIENT_TIMEOUT_MS. DEPS_NODE_DNF_PACKAGE is passed to scripts/ci/deps-linux.sh
# when the derived image is built.
#
# Needs: container (`brew install container && container system start`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${CI_LINUX_IMAGE:-swift:6.1-rhel-ubi9}"
PLATFORM=""
CPUS=8
MEMORY=16G
CLEAN=0
SHELL_MODE=0
JOB_TIMEOUT=30
RUN_JOBS_FLAGS=()

info() { printf '\033[0;32m[ci-linux]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ci-linux]\033[0m %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --cpus) CPUS="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --job-timeout) JOB_TIMEOUT="$2"; shift 2 ;;
        --gate | --advisory | --strict) RUN_JOBS_FLAGS+=("$1"); shift ;;
        --shell) SHELL_MODE=1; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) break ;;
    esac
done
[[ $SHELL_MODE -eq 1 || $# -gt 0 ]] || { usage; exit 2; }
command -v container >/dev/null || die "needs container: brew install container && container system start"
container system status >/dev/null 2>&1 || die "the container service is not running: container system start"

case "${PLATFORM:-linux/$(uname -m)}" in
    linux/arm64 | linux/aarch64) ARCH=arm64 ;;
    linux/amd64 | linux/x86_64) ARCH=amd64 ;;
    *) die "unsupported platform $PLATFORM (expected linux/arm64 or linux/amd64)" ;;
esac
PLATFORM="linux/$ARCH"

# MARK: Command

# What runs in the container, from /w.
COMMAND=()
if [[ $SHELL_MODE -eq 0 ]]; then
    if [[ "$1" == all ]]; then
        COMMAND=(scripts/ci/run-jobs.sh --timeout "$JOB_TIMEOUT" ${RUN_JOBS_FLAGS[@]+"${RUN_JOBS_FLAGS[@]}"})
    elif [[ -x "$ROOT/scripts/ci/$1.sh" && "$1" != run-jobs ]]; then
        COMMAND=(timeout --kill-after=30s "${JOB_TIMEOUT}m" "scripts/ci/$1.sh" "${@:2}")
    else
        COMMAND=(scripts/ci/run-jobs.sh --timeout "$JOB_TIMEOUT" ${RUN_JOBS_FLAGS[@]+"${RUN_JOBS_FLAGS[@]}"} "$@")
    fi
fi
WRITE_BACK=0
for arg in ${COMMAND[@]+"${COMMAND[@]}"}; do
    [[ "$arg" == --update-baseline || "$arg" == --update-results ]] && WRITE_BACK=1
done

# MARK: Image

KEY="$(printf '%s' "$IMAGE" | sed -E 's|^[^/]*\.[^/]*/||; s|[^A-Za-z0-9._-]+|-|g')-$ARCH"
DEPS_HASH="$( (printf '%s\n' "$IMAGE" "${DEPS_NODE_DNF_PACKAGE:-}"; cat "$ROOT/scripts/ci/deps-linux.sh") | shasum -a 256 | cut -c1-12)"
CI_IMAGE="mcp-swift-sdk-ci:$KEY-$DEPS_HASH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-linux.XXXXXX")"
NAME="mcp-ci-$$"
cleanup() {
    container stop "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A run killed outright (SIGKILL) cannot stop its container; stop any whose
# runner process is gone, since they hold the same build volume.
for orphan in $(container ls 2>/dev/null | awk 'NR > 1 && $1 ~ /^mcp-ci-[0-9]+$/ { print $1 }'); do
    if ! kill -0 "${orphan#mcp-ci-}" 2>/dev/null; then
        info "stopping $orphan, left by a run that no longer exists"
        container stop "$orphan" >/dev/null 2>&1 || true
    fi
done

if ! container image inspect "$CI_IMAGE" >/dev/null 2>&1; then
    info "building $CI_IMAGE (Node, Go and uv on $IMAGE)"
    mkdir -p "$WORK/image"
    cp "$ROOT/scripts/ci/deps-linux.sh" "$WORK/image/"
    cat >"$WORK/image/Dockerfile" <<EOF
FROM $IMAGE
COPY deps-linux.sh /tmp/deps-linux.sh
RUN DEPS_NODE_DNF_PACKAGE='${DEPS_NODE_DNF_PACKAGE:-}' bash /tmp/deps-linux.sh && rm /tmp/deps-linux.sh
EOF
    container build --platform "$PLATFORM" --progress plain -t "$CI_IMAGE" "$WORK/image"
fi

BUILD_VOLUME="mcp-ci-build-$KEY"
CACHE_VOLUME="mcp-ci-cache-$ARCH"
if [[ $CLEAN -eq 1 ]]; then
    info "deleting $BUILD_VOLUME"
    container volume rm "$BUILD_VOLUME" >/dev/null 2>&1 || true
fi
for volume in "$BUILD_VOLUME" "$CACHE_VOLUME"; do
    container volume inspect "$volume" >/dev/null 2>&1 || container volume create "$volume" >/dev/null
done

# MARK: Run

# The working tree as a fresh checkout would see it, plus local changes; tar
# keeps modification times, so SwiftPM rebuilds only what changed.
(cd "$ROOT" && git ls-files -z -co --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done |
    COPYFILE_DISABLE=1 tar --null --no-xattrs --no-mac-metadata -T - -cf "$WORK/src.tar")

OUT="$ROOT/.build/linux/$KEY"
rm -rf "$OUT"
mkdir -p "$OUT"

cat >"$WORK/run.sh" <<'EOF'
tar -C /w -xf /in/src.tar
cd /w
status=0
"$@" || status=$?
for dir in conformance interop/results interop/logs; do
    [[ -d ".build/$dir" ]] && mkdir -p "/out/$(dirname "$dir")" && cp -R ".build/$dir" "/out/$dir"
done
[[ -f .build/interop/report.md ]] && cp .build/interop/report.md /out/interop/
mkdir -p /out/tree/conformance /out/tree/interop
cp conformance/baseline*.yml /out/tree/conformance/
cp interop/RESULTS.md /out/tree/interop/
exit $status
EOF

ENV_ARGS=(-e GOMODCACHE=/root/.cache/go-mod -e npm_config_cache=/root/.cache/npm)
for var in npm_config_registry GOPROXY GONOSUMDB GOFLAGS UV_INDEX_URL PIP_INDEX_URL CONFORMANCE_PKG CLIENT_TIMEOUT_MS; do
    [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done
RUN_ARGS=(--rm --name "$NAME" --platform "$PLATFORM" -c "$CPUS" -m "$MEMORY" --progress none
    -v "$WORK:/in" -v "$OUT:/out" -v "$BUILD_VOLUME:/w/.build" -v "$CACHE_VOLUME:/root/.cache"
    -w /w "${ENV_ARGS[@]}" --entrypoint bash)
[[ $ARCH == amd64 && "$(uname -m)" == arm64 ]] && RUN_ARGS+=(--rosetta)

info "image $CI_IMAGE, $PLATFORM, $CPUS CPUs, $MEMORY"
if [[ $SHELL_MODE -eq 1 ]]; then
    container run -it "${RUN_ARGS[@]}" "$CI_IMAGE" -c 'tar -C /w -xf /in/src.tar && exec bash -l'
    exit $?
fi

status=0
container run "${RUN_ARGS[@]}" "$CI_IMAGE" /in/run.sh "${COMMAND[@]}" || status=$?

if [[ $WRITE_BACK -eq 1 ]]; then
    for file in "$OUT"/tree/conformance/*.yml "$OUT/tree/interop/RESULTS.md"; do
        dest="$ROOT/${file#"$OUT"/tree/}"
        if ! cmp -s "$file" "$dest"; then
            cp "$file" "$dest"
            info "updated ${dest#"$ROOT"/}"
        fi
    done
fi
info "results in ${OUT#"$ROOT"/}"
exit $status
