#!/usr/bin/env bash
# Runs CI jobs on Linux in a container on this Mac, with Apple's `container`
# CLI, in a Swift builder image.
#
# Usage: scripts/ci-linux.sh [options] all [--gate | --advisory | --strict]
#        scripts/ci-linux.sh [options] <id-regex>...
#        scripts/ci-linux.sh [options] <script> [args...]
#        scripts/ci-linux.sh [options] -- <command> [args...]
#        scripts/ci-linux.sh [options] --shell
#        scripts/ci-linux.sh --stop-session <name>
#
#   all               Every job in scripts/ci/jobs, then a summary. A failing
#                     job does not stop the rest; jobs marked `advisory` are
#                     reported but do not fail the run (--strict: they do).
#   <id-regex>...     The jobs of scripts/ci/jobs whose ids match, e.g.
#                     conformance-2026-07-28-client or 'conformance-.*' interop.
#   <script> [args]   scripts/ci/<script>.sh with any arguments, e.g.
#                     `conformance --spec-version 2025-11-25 --mode client`.
#                     A name that is also a job id (interop, docs) runs the job,
#                     with its arguments from scripts/ci/jobs, unless options
#                     for the script follow it (`interop --update-results`).
#   -- <command>      Any command, run in /w, e.g. `-- bash -c 'swift build
#                     --build-tests && swift test --skip-build --filter X'`.
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
#   --clean           Delete the build volume first (with --session, the
#                     session is restarted; refused while a run uses it).
#   --job-timeout <m> Stop a job, or a -- command, after <m> minutes
#                     (default: 30); it counts as failed.
#   --source <dir>    Run against another git working tree, e.g. a worktree of
#                     another branch (default: this repository). The image is
#                     still built from this repository's scripts/ci/deps-linux.sh;
#                     jobs and scripts come from <dir>, so a tree without
#                     scripts/ci/ can only run `-- <command>` or --shell.
#   --build-volume <name>
#                     The volume mounted at /w/.build (default:
#                     mcp-ci-build-<image>-<arch>). SwiftPM locks .build, and a
#                     volume can be attached to one running container at a
#                     time, so runs in parallel need one each. With a volume
#                     other than the default, results go to .build/linux/<name>/.
#   --seed-from <volume>
#                     When the build volume does not exist yet, create it as a
#                     copy of <volume>, so its first build compiles only what
#                     differs.
#   --session <name>  Run in a long-lived container, mcp-ci-session-<name>,
#                     started on first use with the image, volumes, CPUs and
#                     memory given then (stop it to change them). Each run
#                     re-syncs /w with the tree, keeping /w/.build, and skips
#                     the container start. One run at a time per session.
#   --stop-session <name>
#                     Stop that session's container. Its build volume stays.
#
# Each run starts from a copy of the working tree at /w: tracked files and
# untracked files that are not ignored, so uncommitted changes are included
# and the Mac's .build is not touched. Files of an earlier run are removed
# first, except /w/.build, and tar keeps modification times, so later runs are
# incremental. /w/.build is a named volume. The package caches (SwiftPM, npm,
# Go, uv) are at /root/.cache, a directory on this Mac shared by every run
# and session: ~/Library/Caches/mcp-swift-sdk-ci/cache-<arch> (or under
# $XDG_CACHE_HOME). File locks do not reach across containers, so two runs
# that fetch the same new package at the same moment can collide; rerun.
# Node, Go, uv and ps come from scripts/ci/deps-linux.sh, baked into a local
# derived image that is rebuilt when the script or the base image changes.
#
# Results (conformance and interop reports and logs of this run) are copied
# to .build/linux/<image>-<arch>/ in the working tree. With --update-baseline
# or --update-results among the arguments, the regenerated
# conformance/baseline*.yml and interop/RESULTS.md are copied back into it.
#
# Environment passed through when set: npm_config_registry, GOPROXY,
# GONOSUMDB, GOFLAGS, UV_INDEX_URL, PIP_INDEX_URL, CONFORMANCE_PKG,
# CLIENT_TIMEOUT_MS. DEPS_NODE_DNF_PACKAGE is passed to scripts/ci/deps-linux.sh
# when the derived image is built. CI_LINUX_DRY_RUN=1 prints the command that
# would run in /w, and stops.
#
# Needs: container (`brew install container && container system start`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT"
IMAGE="${CI_LINUX_IMAGE:-swift:6.1-rhel-ubi9}"
PLATFORM=""
CPUS=8
MEMORY=16G
CLEAN=0
SHELL_MODE=0
COMMAND_MODE=0
JOB_TIMEOUT=30
RUN_JOBS_FLAGS=()
BUILD_VOLUME=""
SEED_FROM=""
SESSION=""
STOP_SESSION=""

info() { printf '\033[0;32m[ci-linux]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ci-linux]\033[0m %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
is_run_jobs_flag() { [[ "$1" == --gate || "$1" == --advisory || "$1" == --strict ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image | --platform | --cpus | --memory | --job-timeout | --source | --build-volume | --seed-from | --session | --stop-session)
            [[ $# -ge 2 ]] || die "$1 needs a value (see --help)" ;;
    esac
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --cpus) CPUS="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --job-timeout) JOB_TIMEOUT="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --build-volume) BUILD_VOLUME="$2"; shift 2 ;;
        --seed-from) SEED_FROM="$2"; shift 2 ;;
        --session) SESSION="$2"; shift 2 ;;
        --stop-session) STOP_SESSION="$2"; shift 2 ;;
        --gate | --advisory | --strict) RUN_JOBS_FLAGS+=("$1"); shift ;;
        --shell) SHELL_MODE=1; shift ;;
        --) COMMAND_MODE=1; shift; break ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) break ;;
    esac
done
for name in "$SESSION" "$STOP_SESSION"; do
    [[ -z "$name" || "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid session name $name"
done
# The name is also a directory of .build/linux.
[[ -z "$BUILD_VOLUME" || "$BUILD_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid --build-volume name $BUILD_VOLUME"
if [[ -z "$STOP_SESSION" ]]; then
    [[ $SHELL_MODE -eq 0 || $COMMAND_MODE -eq 0 ]] || die "--shell and -- <command> do not go together"
    [[ $SHELL_MODE -eq 1 || $# -gt 0 ]] || { usage; exit 2; }
fi
command -v container >/dev/null || die "needs container: brew install container && container system start"
container system status >/dev/null 2>&1 || die "the container service is not running: container system start"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/Library/Caches}/mcp-swift-sdk-ci"
SESSIONS="$CACHE_ROOT/sessions"

session_running() { # name
    container ls 2>/dev/null | awk -v n="mcp-ci-session-$1" 'NR > 1 && $1 == n { found = 1 } END { exit !found }'
}
stop_session() { # name
    info "stopping session mcp-ci-session-$1"
    container stop "mcp-ci-session-$1" >/dev/null 2>&1 || true
    rm -rf "${SESSIONS:?}/$1"
}
# Prints the pid of the run that holds the session's lock, when it is alive.
session_owner() { # name
    local owner
    owner="$(cat "$SESSIONS/$1/lock/pid" 2>/dev/null)" && [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null &&
        echo "$owner"
}

if [[ -n "$STOP_SESSION" ]]; then
    session_running "$STOP_SESSION" || info "session $STOP_SESSION is not running"
    stop_session "$STOP_SESSION"
    exit 0
fi

case "${PLATFORM:-linux/$(uname -m)}" in
    linux/arm64 | linux/aarch64) ARCH=arm64 ;;
    linux/amd64 | linux/x86_64) ARCH=amd64 ;;
    *) die "unsupported platform $PLATFORM (expected linux/arm64 or linux/amd64)" ;;
esac
PLATFORM="linux/$ARCH"

if [[ "$SOURCE" != "$ROOT" ]]; then
    SOURCE="$(git -C "$SOURCE" rev-parse --show-toplevel 2>/dev/null)" || die "--source: not a git working tree"
fi

# MARK: Command

# Whether the tree's scripts/ci/jobs lists this job id.
is_job() {
    [[ -f "$SOURCE/scripts/ci/jobs" ]] &&
        awk -v id="$1" '$1 == id { found = 1 } END { exit !found }' "$SOURCE/scripts/ci/jobs"
}

# Whether the arguments call a script of scripts/ci directly: one that is not
# a job id, or one followed by options of its own.
is_script_call() {
    [[ -x "$SOURCE/scripts/ci/$1.sh" && "$1" != run-jobs ]] || return 1
    is_job "$1" || return 0
    local arg
    for arg in "${@:2}"; do
        [[ "$arg" == -* ]] && ! is_run_jobs_flag "$arg" && return 0
    done
    return 1
}

# What runs in the container, from /w.
COMMAND=()
if [[ $COMMAND_MODE -eq 1 ]]; then
    COMMAND=(timeout --kill-after=30s "${JOB_TIMEOUT}m" "$@")
elif [[ $SHELL_MODE -eq 0 ]]; then
    [[ -x "$SOURCE/scripts/ci/run-jobs.sh" ]] || die "$SOURCE has no scripts/ci/run-jobs.sh; run a command with -- <command> [args...]"
    if [[ "$1" == all ]]; then
        for arg in "${@:2}"; do
            is_run_jobs_flag "$arg" || die "all takes only --gate, --advisory or --strict after it, not $arg"
            RUN_JOBS_FLAGS+=("$arg")
        done
        COMMAND=(scripts/ci/run-jobs.sh --timeout "$JOB_TIMEOUT" ${RUN_JOBS_FLAGS[@]+"${RUN_JOBS_FLAGS[@]}"})
    elif is_script_call "$@"; then
        COMMAND=(timeout --kill-after=30s "${JOB_TIMEOUT}m" "scripts/ci/$1.sh" "${@:2}")
    else
        COMMAND=(scripts/ci/run-jobs.sh --timeout "$JOB_TIMEOUT" ${RUN_JOBS_FLAGS[@]+"${RUN_JOBS_FLAGS[@]}"} "$@")
    fi
fi
WRITE_BACK=0
for arg in ${COMMAND[@]+"${COMMAND[@]}"}; do
    [[ "$arg" == --update-baseline || "$arg" == --update-results ]] && WRITE_BACK=1
done
if [[ -n "${CI_LINUX_DRY_RUN:-}" ]]; then
    printf '%q ' ${COMMAND[@]+"${COMMAND[@]}"}
    echo
    exit 0
fi

# MARK: Image

KEY="$(printf '%s' "$IMAGE" | sed -E 's|^[^/]*\.[^/]*/||; s|[^A-Za-z0-9._-]+|-|g')-$ARCH"
DEPS_HASH="$( (printf '%s\n' "$IMAGE" "${DEPS_NODE_DNF_PACKAGE:-}"; cat "$ROOT/scripts/ci/deps-linux.sh") | shasum -a 256 | cut -c1-12)"
CI_IMAGE="mcp-swift-sdk-ci:$KEY-$DEPS_HASH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-linux.XXXXXX")"
NAME="mcp-ci-$$"
SESSION_NAME="mcp-ci-session-$SESSION"
STATE="$SESSIONS/$SESSION"
BUILD_VOLUME="${BUILD_VOLUME:-mcp-ci-build-$KEY}"
SEEDING=0
LOCKED=0
RUNNING=0
EXEC_PID=""

# Stops what the session's current run started (stop.sh, written below):
# an interrupted `container exec` leaves its processes running.
stop_session_run() {
    container exec "$SESSION_NAME" bash -c '[[ ! -f /in/stop.sh ]] || bash /in/stop.sh' || true
}
cleanup() {
    container stop "$NAME" >/dev/null 2>&1 || true
    if [[ $SEEDING -eq 1 ]]; then
        info "deleting the partly seeded $BUILD_VOLUME"
        container volume rm "$BUILD_VOLUME" >/dev/null 2>&1 || true
    fi
    if [[ $RUNNING -eq 1 ]]; then
        stop_session_run
        kill "$EXEC_PID" 2>/dev/null || true
    fi
    [[ $LOCKED -eq 1 ]] && rm -rf "$STATE/lock"
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
    info "building $CI_IMAGE (Node, Go, uv and ps on $IMAGE)"
    mkdir -p "$WORK/image"
    cp "$ROOT/scripts/ci/deps-linux.sh" "$WORK/image/"
    cat >"$WORK/image/Dockerfile" <<EOF
FROM $IMAGE
COPY deps-linux.sh /tmp/deps-linux.sh
RUN DEPS_NODE_DNF_PACKAGE='${DEPS_NODE_DNF_PACKAGE:-}' bash /tmp/deps-linux.sh && rm /tmp/deps-linux.sh
EOF
    container build --platform "$PLATFORM" --progress plain -t "$CI_IMAGE" "$WORK/image"
fi

# MARK: Volumes

# A directory, not a volume: a volume can be attached to one running
# container at a time, and every run and session shares the caches.
CACHE_DIR="$CACHE_ROOT/cache-$ARCH"
mkdir -p "$CACHE_DIR"

# The running session, other than this run's, whose container has the volume.
volume_session() { # volume
    local dir name
    for dir in "$SESSIONS"/*/; do
        name="$(basename "$dir")"
        [[ -f "$dir/config" && "$name" != "$SESSION" ]] || continue
        grep -qxF "volume $1" "$dir/config" && session_running "$name" && { echo "$name"; return 0; }
    done
    return 1
}
if holder="$(volume_session "$BUILD_VOLUME")"; then
    die "$BUILD_VOLUME is attached to session $holder: use another --build-volume, or --stop-session $holder"
fi

if [[ $CLEAN -eq 1 ]]; then
    if [[ -n "$SESSION" ]] && session_running "$SESSION"; then
        if owner="$(session_owner "$SESSION")"; then die "session $SESSION is busy (run $owner)"; fi
        stop_session "$SESSION"
    fi
    info "deleting $BUILD_VOLUME"
    container volume rm "$BUILD_VOLUME" >/dev/null 2>&1 || true
fi
if ! container volume inspect "$BUILD_VOLUME" >/dev/null 2>&1; then
    if [[ -n "$SEED_FROM" ]]; then
        container volume inspect "$SEED_FROM" >/dev/null 2>&1 || die "--seed-from: no volume $SEED_FROM"
        if holder="$(volume_session "$SEED_FROM")"; then
            die "$SEED_FROM is attached to session $holder; --stop-session $holder to seed from it"
        fi
    fi
    container volume create "$BUILD_VOLUME" >/dev/null
    if [[ -n "$SEED_FROM" ]]; then
        info "seeding $BUILD_VOLUME from $SEED_FROM"
        SEEDING=1
        start=$SECONDS
        container run --rm --name "$NAME" --platform "$PLATFORM" -c "$CPUS" -m "$MEMORY" --progress none \
            -v "$SEED_FROM:/seed" -v "$BUILD_VOLUME:/build" --entrypoint cp "$CI_IMAGE" -a /seed/. /build/
        SEEDING=0
        info "seeded in $((SECONDS - start))s"
    fi
elif [[ -n "$SEED_FROM" ]]; then
    info "$BUILD_VOLUME exists; not seeded from $SEED_FROM"
fi

# MARK: Run

ENV_ARGS=(-e GOMODCACHE=/root/.cache/go-mod -e npm_config_cache=/root/.cache/npm)
# The cache is on the Mac, where root in the container cannot write into the
# read-only directories Go would make in its module cache.
ENV_ARGS+=(-e "GOFLAGS=${GOFLAGS:+$GOFLAGS }-modcacherw")
for var in npm_config_registry GOPROXY GONOSUMDB UV_INDEX_URL PIP_INDEX_URL CONFORMANCE_PKG CLIENT_TIMEOUT_MS; do
    [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done
CONTAINER_ARGS=(--platform "$PLATFORM" -c "$CPUS" -m "$MEMORY" --progress none
    -v "$BUILD_VOLUME:/w/.build" -v "$CACHE_DIR:/root/.cache" -w /w "${ENV_ARGS[@]}")
[[ $ARCH == amd64 && "$(uname -m)" == arm64 ]] && CONTAINER_ARGS+=(--rosetta)

# The tree goes in through /in; results come out through /out.
if [[ -n "$SESSION" ]]; then
    config="$(printf '%s\n' "image $CI_IMAGE" "platform $PLATFORM" "cpus $CPUS" "memory $MEMORY" \
        "volume $BUILD_VOLUME" "cache $CACHE_DIR")"
    if session_running "$SESSION"; then
        [[ "$(cat "$STATE/config" 2>/dev/null)" == "$config" ]] ||
            die "session $SESSION runs with other settings ($(tr '\n' ' ' <"$STATE/config" 2>/dev/null)); --stop-session $SESSION first"
    else
        rm -rf "$STATE"
        mkdir -p "$STATE/in" "$STATE/out"
        info "starting session $SESSION_NAME"
        container run -d --rm --init --name "$SESSION_NAME" "${CONTAINER_ARGS[@]}" \
            -v "$STATE/in:/in" -v "$STATE/out:/out" --entrypoint sleep "$CI_IMAGE" infinity >/dev/null
        printf '%s\n' "$config" >"$STATE/config"
    fi
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        if owner="$(session_owner "$SESSION")"; then die "session $SESSION is busy (run $owner)"; fi
    fi
    echo $$ >"$STATE/lock/pid"
    LOCKED=1
    # A run that did not finish (killed before its cleanup) may have left processes.
    [[ -f "$STATE/in/sid" ]] && info "session $SESSION: stopping what an earlier run left running"
    stop_session_run
    IN="$STATE/in"
    find "$STATE/out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
    IN="$WORK"
fi

# The working tree as a fresh checkout would see it, plus local changes; tar
# keeps modification times, so SwiftPM rebuilds only what changed.
(cd "$SOURCE" && git ls-files -z -co --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done |
    COPYFILE_DISABLE=1 tar --null --no-xattrs --no-mac-metadata -T - -cf "$IN/src.tar")

OUT="$SOURCE/.build/linux/$KEY"
# Runs in parallel against one tree each have a build volume of their own.
[[ "$BUILD_VOLUME" == "mcp-ci-build-$KEY" ]] || OUT="$SOURCE/.build/linux/$BUILD_VOLUME"
rm -rf "$OUT"
mkdir -p "$OUT"

cat >"$IN/sync.sh" <<'EOF'
# /w becomes the tree in /in/src.tar; /w/.build is the build volume and stays.
find /w -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
tar -C /w -xf /in/src.tar
cd /w
EOF
cat >"$IN/stop.sh" <<'EOF'
# Stops every process of the run's session (run.sh records its id), including
# those in process groups of their own, such as the test runner of swift test.
sid="$(cat /in/sid 2>/dev/null)" && [[ -n "$sid" ]] || exit 0
for signal in TERM KILL; do
    found=0
    for stat in /proc/[0-9]*/stat; do
        read -r line <"$stat" 2>/dev/null || continue
        fields=(${line##*) })
        [[ "${fields[3]}" == "$sid" ]] && kill "-$signal" "${stat//[^0-9]/}" 2>/dev/null && found=1
    done
    [[ $found -eq 1 && $signal == TERM ]] && sleep 2
done
rm -f /in/sid
EOF
cat >"$IN/run.sh" <<'EOF'
. /in/sync.sh
# The volume keeps results of earlier runs; only this run's are copied out.
rm -rf .build/conformance .build/interop/results .build/interop/logs .build/interop/report.md
status=0
# In a session of its own, so that what it leaves running, or all of it when
# the run is interrupted, can be stopped: in a session container nothing else
# would.
setsid -w bash -c 'echo $$ >/in/sid; exec "$@"' run "$@" || status=$?
bash /in/stop.sh
for dir in conformance interop/results interop/logs; do
    [[ -d ".build/$dir" ]] && mkdir -p "/out/$(dirname "$dir")" && cp -R ".build/$dir" "/out/$dir"
done
[[ -f .build/interop/report.md ]] && mkdir -p /out/interop && cp .build/interop/report.md /out/interop/
mkdir -p /out/tree/conformance /out/tree/interop
cp conformance/baseline*.yml /out/tree/conformance/ 2>/dev/null
cp interop/RESULTS.md /out/tree/interop/ 2>/dev/null
exit $status
EOF

info "image $CI_IMAGE, $PLATFORM, $CPUS CPUs, $MEMORY, ${BUILD_VOLUME}${SESSION:+, session $SESSION}"
start=$SECONDS
status=0
if [[ -n "$SESSION" ]]; then
    if [[ $SHELL_MODE -eq 1 ]]; then
        container exec -it -w /w "${ENV_ARGS[@]}" "$SESSION_NAME" bash -c '. /in/sync.sh && exec bash -l' || status=$?
        exit $status
    fi
    RUNNING=1
    # In the background: bash runs the INT and TERM traps during `wait`, but
    # only after a foreground command ends, and `container exec` does not end
    # on SIGINT.
    container exec -w /w "${ENV_ARGS[@]}" "$SESSION_NAME" bash /in/run.sh "${COMMAND[@]}" &
    EXEC_PID=$!
    wait "$EXEC_PID" || status=$?
    RUNNING=0
    cp -R "$STATE/out/." "$OUT/"
else
    RUN_ARGS=(--rm --name "$NAME" "${CONTAINER_ARGS[@]}" -v "$WORK:/in" -v "$OUT:/out" --entrypoint bash)
    if [[ $SHELL_MODE -eq 1 ]]; then
        container run -it "${RUN_ARGS[@]}" "$CI_IMAGE" -c '. /in/sync.sh && exec bash -l' || status=$?
        exit $status
    fi
    container run "${RUN_ARGS[@]}" "$CI_IMAGE" /in/run.sh "${COMMAND[@]}" || status=$?
fi

if [[ $WRITE_BACK -eq 1 ]]; then
    for file in "$OUT"/tree/conformance/*.yml "$OUT/tree/interop/RESULTS.md"; do
        [[ -f "$file" ]] || continue
        dest="$SOURCE/${file#"$OUT"/tree/}"
        if ! cmp -s "$file" "$dest"; then
            cp "$file" "$dest"
            info "updated ${dest#"$SOURCE"/}"
        fi
    done
fi
info "results in ${OUT#"$SOURCE"/} ($((SECONDS - start))s)"
exit $status
