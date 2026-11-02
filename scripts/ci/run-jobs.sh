#!/usr/bin/env bash
# Runs jobs from scripts/ci/jobs, one after another, and prints a summary.
# A failing job does not stop the rest.
#
# Usage: scripts/ci/run-jobs.sh [--gate | --advisory] [--strict] [--timeout <minutes>] [<id-regex>...]
#
#   <id-regex>         Run the jobs whose id matches one of these extended
#                      regular expressions (default: every job).
#   --gate             On Linux, only the jobs marked `gate`.
#   --advisory         On Linux, only the jobs marked `advisory`.
#   --strict           Advisory failures fail the run too.
#   --timeout <m>      Stop a job after <m> minutes (needs GNU timeout, or
#                      gtimeout on macOS; otherwise jobs are not limited).
#
# On Linux an advisory job's failure is reported but does not fail the run;
# an advisory job that passes is reported as ready to gate. On macOS every
# job gates. GitHub Actions and scripts/ci-linux.sh run jobs through this
# script.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

SELECT=all
STRICT=0
TIMEOUT=""
PATTERNS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gate) SELECT=gate; shift ;;
        --advisory) SELECT=advisory; shift ;;
        --strict) STRICT=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "run-jobs.sh: unknown option $1" >&2; exit 2 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done

LINUX=0
[[ "$(uname -s)" == Linux ]] && LINUX=1

TIMEOUT_CMD=()
if [[ -n "$TIMEOUT" ]]; then
    # GNU timeout runs the job in its own process group and stops all of it,
    # so a hung harness cannot leave a fixture holding a port for the next job.
    if command -v timeout >/dev/null && timeout --version >/dev/null 2>&1; then
        TIMEOUT_CMD=(timeout --kill-after=30s "${TIMEOUT}m")
    elif command -v gtimeout >/dev/null; then
        TIMEOUT_CMD=(gtimeout --kill-after=30s "${TIMEOUT}m")
    else
        echo "run-jobs.sh: no GNU timeout; jobs are not time-limited" >&2
    fi
fi

selected() { # id
    [[ ${#PATTERNS[@]} -eq 0 ]] && return 0
    local pattern
    for pattern in "${PATTERNS[@]}"; do
        [[ "$1" =~ ^($pattern)$ ]] && return 0
    done
    return 1
}

SUMMARY=()
STATUS=0
COUNT=0
while read -r id gate script args; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    selected "$id" || continue
    [[ $LINUX -eq 0 ]] && gate=gate
    [[ $SELECT != all && $LINUX -eq 1 && $gate != "$SELECT" ]] && continue
    COUNT=$((COUNT + 1))
    printf '\n\033[1;35m::: %s\033[0m (scripts/ci/%s.sh %s)\n' "$id" "$script" "$args"
    start=$SECONDS
    rc=0
    # stdin is the job list: a job reading it would end this loop.
    # shellcheck disable=SC2086 # the job file's arguments are plain words
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$ROOT/scripts/ci/$script.sh" $args </dev/null || rc=$?
    case $rc in
        0) result=PASS ;;
        124 | 137) result=TIMEOUT ;;
        *) result=FAIL ;;
    esac
    note=""
    if [[ $gate == advisory ]]; then
        if [[ $result == PASS ]]; then
            note="advisory on Linux, now passes: make it gate in scripts/ci/jobs"
        else
            note="advisory on Linux (design/linux.md)"
            [[ $STRICT -eq 1 ]] && STATUS=1
        fi
    elif [[ $result != PASS ]]; then
        STATUS=1
    fi
    SUMMARY+=("$(printf '%-7s %-30s %5ds  %s' "$result" "$id" $((SECONDS - start)) "$note")")
done <"$ROOT/scripts/ci/jobs"

if [[ $COUNT -eq 0 ]]; then
    echo "run-jobs.sh: no job matches ${PATTERNS[*]:-} ($SELECT)" >&2
    exit 2
fi
printf '\n== Summary\n'
printf '%s\n' "${SUMMARY[@]}"
exit $STATUS
