#!/usr/bin/env bash
# Interop matrix: the Swift SDK against the Go, Python and TypeScript SDKs (interop/README.md).
#
#   scripts/run-interop.sh [--update-results | --check]
#
# The other SDKs are pinned releases: the Go SDK in interop/go-client/go.mod
# (from the Go module proxy) and the Python SDK in
# interop/python-client/requirements.in (PyPI, and a GitHub commit for its
# conformance server), installed from the hashed lock requirements.txt, and
# the TypeScript SDK in interop/ts-client/package.json, installed with npm ci
# from package-lock.json (tasks and apps profiles only, 2025-11-25). The
# example servers come from the same commit and are checked against
# examples.sha256. The script builds the Swift fixtures, the Go conformance server and
# examples at the pinned version, installs the Python SDK in a venv, starts
# the HTTP servers, runs every client against every server in both protocol
# eras with each check profile (basic, advanced, connect, session, tasks, apps), and writes
# .build/interop/report.md. --update-results copies it to interop/RESULTS.md.
# --check fails the run when the report's results differ from
# interop/RESULTS.md (CI's gate; see interop/report.py).
#
# Needs: Swift, Go 1.25 or later, uv, Node 20 or later with npm, curl, perl, python3, sha256sum or
# shasum, and network access on the first run. Behind a TLS-intercepting proxy, export UV_SYSTEM_CERTS=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/interop"
BIN_GO="$WORK/bin"
RESULTS="$WORK/results"
LOGS="$WORK/logs"
UPDATE=0
CHECK=0
case "${1:-}" in
    --update-results) UPDATE=1 ;;
    --check) CHECK=1 ;;
    "") ;;
    *) echo "usage: scripts/run-interop.sh [--update-results | --check]" >&2; exit 2 ;;
esac

GO_MODULE=github.com/modelcontextprotocol/go-sdk
GO_SDK_VERSION="$(awk -v m="$GO_MODULE" '$1 == m || $2 == m { print ($1 == m ? $2 : $3); exit }' "$ROOT/interop/go-client/go.mod")"
PY_CLIENT="$ROOT/interop/python-client"
PY_SDK_TAG="v$(sed -n 's/^mcp==//p' "$PY_CLIENT/requirements.in")"
PY_SERVER_REQUIREMENT="$(grep '^mcp-everything-server @ ' "$PY_CLIENT/requirements.in")"
PY_SDK_COMMIT="$(sed -n 's/^mcp-everything-server @ .*@\([0-9a-f]\{40\}\)#.*/\1/p' "$PY_CLIENT/requirements.in")"
[[ -n "$PY_SDK_COMMIT" ]] || { echo "requirements.in must pin the conformance server to a commit" >&2; exit 2; }
PY_SDK_RAW="https://raw.githubusercontent.com/modelcontextprotocol/python-sdk/$PY_SDK_COMMIT"

for tool in swift go uv node npm curl perl python3; do
    command -v "$tool" >/dev/null || { echo "run-interop.sh needs $tool" >&2; exit 2; }
done
if command -v sha256sum >/dev/null; then
    verify_sha256() { sha256sum --status -c "$1"; }
elif command -v shasum >/dev/null; then
    verify_sha256() { shasum -a 256 -s -c "$1"; }
else
    echo "run-interop.sh needs sha256sum or shasum" >&2; exit 2
fi

info() { printf '\033[0;32m[interop]\033[0m %s\n' "$*"; }

rm -rf "$RESULTS" "$LOGS"
mkdir -p "$BIN_GO" "$RESULTS" "$LOGS" "$WORK/python-examples"

# MARK: Build

info "building Swift fixtures"
(cd "$ROOT" && swift build --product mcp-everything-server >/dev/null \
    && swift build --product mcp-interop-client >/dev/null \
    && swift build --product HelloServer >/dev/null \
    && swift build --product HelloClient >/dev/null)
BIN_SWIFT="$(cd "$ROOT" && swift build --show-bin-path)"

info "building Go SDK $GO_SDK_VERSION fixtures"
(cd "$ROOT/interop/go-client" \
    && go build -o "$BIN_GO/go-interop-client" . \
    && go build -o "$BIN_GO/go-everything-server" "$GO_MODULE/conformance/everything-server" \
    && go build -o "$BIN_GO/go-hello-server" "$GO_MODULE/examples/server/hello" \
    && go build -o "$BIN_GO/go-listfeatures" "$GO_MODULE/examples/client/listfeatures")

info "installing Python SDK $PY_SDK_TAG"
VENV="$WORK/py-venv"
STAMP="$VENV/.requirements"
if ! cat "$PY_CLIENT/requirements.in" "$PY_CLIENT/requirements.txt" | cmp -s - "$STAMP" 2>/dev/null; then
    rm -rf "$VENV"
    uv venv --quiet --python 3.12 "$VENV"
    uv pip sync --quiet --require-hashes --python "$VENV" "$PY_CLIENT/requirements.txt"
    # A git dependency has no hash; its commit pins it, and the lock has its dependencies
    # and its build backend. Nothing comes from the index: no build isolation, no index.
    uv pip install --quiet --no-deps --no-build-isolation --no-index --python "$VENV" "$PY_SERVER_REQUIREMENT"
    cat "$PY_CLIENT/requirements.in" "$PY_CLIENT/requirements.txt" >"$STAMP"
fi
PY="$VENV/bin/python"
# The example servers, downloaded once and checked before every run: from
# raw.githubusercontent.com, or from a shallow fetch of the commit where only
# github.com is reachable.
EXAMPLES="$WORK/python-examples"
if ! (cd "$EXAMPLES" && verify_sha256 "$PY_CLIENT/examples.sha256" 2>/dev/null); then
    rm -f "$EXAMPLES"/*.py
    while read -r _ example; do
        if ! curl -fsSL -o "$EXAMPLES/$example" "$PY_SDK_RAW/examples/snippets/servers/$example"; then
            clone="$WORK/python-sdk-$PY_SDK_COMMIT"
            # A fetch that failed leaves a repository without a commit.
            if ! git -C "$clone" rev-parse -q --verify HEAD >/dev/null 2>&1; then
                rm -rf "$clone"
                git init --quiet "$clone"
                git -C "$clone" fetch --quiet --depth 1 \
                    https://github.com/modelcontextprotocol/python-sdk "$PY_SDK_COMMIT"
                git -C "$clone" checkout --quiet FETCH_HEAD
            fi
            cp "$clone/examples/snippets/servers/$example" "$EXAMPLES/$example"
        fi
    done <"$PY_CLIENT/examples.sha256"
    (cd "$EXAMPLES" && verify_sha256 "$PY_CLIENT/examples.sha256") || {
        echo "the Python example servers do not match interop/python-client/examples.sha256" >&2
        exit 1
    }
fi

TS_CLIENT="$ROOT/interop/ts-client"
TS_SDK_VERSION="$(sed -n 's/.*"@modelcontextprotocol\/sdk": "\([^"]*\)".*/\1/p' "$TS_CLIENT/package.json")"
TS_APPS_VERSION="$(sed -n 's/.*"@modelcontextprotocol\/ext-apps": "\([^"]*\)".*/\1/p' "$TS_CLIENT/package.json")"
info "installing TypeScript SDK $TS_SDK_VERSION, ext-apps $TS_APPS_VERSION"
TS="$WORK/ts"
mkdir -p "$TS"
if ! cmp -s "$TS_CLIENT/package-lock.json" "$TS/package-lock.json" 2>/dev/null || [[ ! -d "$TS/node_modules" ]]; then
    cp "$TS_CLIENT/package.json" "$TS_CLIENT/package-lock.json" "$TS/"
    (cd "$TS" && npm ci --ignore-scripts --no-audit --no-fund --silent)
fi
cp "$TS_CLIENT"/*.mjs "$TS/"
NODE="$(command -v node)"

# MARK: Servers

# Live background processes: servers and the session cells' clients. A PID
# leaves the list once reaped, so cleanup never signals a reused PID. A
# session cell's PID is its subshell: its child, the limit, gets TERM too and
# stops the client's process group and tree.
PIDS=()
cleanup() {
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

track() { PIDS+=("$1"); }
reap() { # pid: waits for it and forgets it
    local pid="$1" keep=() other
    wait "$pid" 2>/dev/null || true
    for other in ${PIDS[@]+"${PIDS[@]}"}; do [[ "$other" == "$pid" ]] || keep+=("$other"); done
    PIDS=(${keep[@]+"${keep[@]}"})
}

# Fails when something already listens on a port, such as a server left by an
# earlier run: its results would be mistaken for this run's.
require_free() { # port...
    local port
    for port in "$@"; do
        if (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
            echo "port $port is in use; stop the process listening on it" >&2
            exit 1
        fi
    done
}

serve() { # name, command...
    local name="$1"; shift
    "$@" >"$LOGS/server-$name.log" 2>&1 &
    track "$!"
    LAST_PID=$!
}

wait_for() { # url, pid: the server at url answers and is the process pid
    for _ in $(seq 1 100); do
        kill -0 "$2" 2>/dev/null || break
        if curl -s -o /dev/null -m 1 "$1"; then
            kill -0 "$2" 2>/dev/null && return 0
            break
        fi
        sleep 0.2
    done
    echo "server at $1 did not start (see $LOGS)" >&2
    exit 1
}

require_free 3101 3111 3201 3202 3211 3301 3311 3401 8000

serve swift "$BIN_SWIFT/mcp-everything-server" --port 3101
wait_for http://127.0.0.1:3101/mcp "$LAST_PID"
serve go-stateful "$BIN_GO/go-everything-server" -http 127.0.0.1:3201 -stateless=false
wait_for http://127.0.0.1:3201/ "$LAST_PID"
serve go-stateless "$BIN_GO/go-everything-server" -http 127.0.0.1:3202
wait_for http://127.0.0.1:3202/ "$LAST_PID"
serve ts "$NODE" "$TS/server.mjs" --port 3401
wait_for http://127.0.0.1:3401/mcp "$LAST_PID"
serve python "$VENV/bin/mcp-everything-server" --port 3301
wait_for http://127.0.0.1:3301/mcp "$LAST_PID"
serve python-quickstart "$PY" "$EXAMPLES/mcpserver_quickstart.py"
wait_for http://127.0.0.1:8000/mcp "$LAST_PID"

# MARK: Cells

# Runs a command with a wall-clock limit (exit status 142 when it expires).
# The command runs in its own process group, and on expiry the limit signals
# the group and every descendant, not just the command: the Go runtime ignores
# SIGALRM, and a stdio client's server must go too (Foundation's Process puts
# it in a group of its own). Group members left when the command exits are
# killed as well.
limit() {
    perl -MPOSIX=WNOHANG -e '
        my $seconds = shift;
        my $pid = fork() // die "cannot fork: $!\n";
        if ($pid == 0) {
            setpgrp(0, 0);
            exec @ARGV or die "cannot run $ARGV[0]: $!\n";
        }
        setpgrp($pid, $pid); # in both, so the group exists before any signal
        my $stop = sub { # TERM the group and the tree, KILL them after 5 s, and exit
            my %children;
            for (`ps -A -o pid= -o ppid=`) { my ($p, $pp) = split; push @{$children{$pp}}, $p; }
            my @tree = ($pid);
            for (my $i = 0; $i < @tree; $i++) { push @tree, @{$children{$tree[$i]} || []}; }
            kill "TERM", -$pid, @tree;
            for (1 .. 50) { last if waitpid($pid, WNOHANG) == $pid; select(undef, undef, undef, 0.1); }
            kill "KILL", -$pid, @tree;
            waitpid($pid, 0);
            exit shift;
        };
        $SIG{ALRM} = sub { $stop->(142) };
        for my $name (qw(HUP INT TERM)) { $SIG{$name} = sub { $stop->(128 + POSIX->can("SIG$name")->()) }; }
        alarm $seconds;
        waitpid($pid, 0);
        my $status = $?;
        alarm 0;
        kill "KILL", -$pid;
        exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
    ' "$@" </dev/null
}

# client, server, transport, era, then the server address: a URL or a command.
# PROFILE names the cell's profile (default: basic); PROFILE_ARGS go to the client.
run_cell() {
    local client="$1" server="$2" transport="$3" era="$4"; shift 4
    local cell="${client}__${server}__${transport}__${era}"
    [[ -n "${PROFILE:-}" ]] && cell="${cell}__$PROFILE"
    local out="$RESULTS/$cell.jsonl"
    local log="$LOGS/$cell.log"
    local target=()
    if [[ "$transport" == http ]]; then
        case "$client" in
            go*) target=(-url "$1") ;;
            *) target=(--url "$1") ;;
        esac
    else
        case "$client" in
            go*) target=(-- "$@") ;;
            *) target=(--stdio "$@") ;;
        esac
    fi
    local extra=()
    [[ -n "${PROFILE_ARGS+x}" ]] && extra=("${PROFILE_ARGS[@]}")
    info "$client -> $server ($transport, $era${PROFILE:+, $PROFILE})"
    local status=0
    case "$client" in
        swift*) limit 300 "$BIN_SWIFT/mcp-interop-client" --era "$era" ${extra[@]+"${extra[@]}"} "${target[@]}" ;;
        go*) limit 300 "$BIN_GO/go-interop-client" -era "$era" ${extra[@]+"${extra[@]}"} "${target[@]}" ;;
        python*) limit 300 "$PY" "$ROOT/interop/python-client/client.py" --era "$era" ${extra[@]+"${extra[@]}"} "${target[@]}" ;;
        ts*) limit 300 "$NODE" "$TS/client.mjs" --era "$era" ${extra[@]+"${extra[@]}"} "${target[@]}" ;;
    esac >"$out" 2>"$log" || status=$?
    echo "$status" >"$RESULTS/$cell.exit"
}

# Everything servers over HTTP.
for client in swift go python; do
    for era in handshake stateless; do
        run_cell "$client" swift http "$era" http://127.0.0.1:3101/mcp
        run_cell "$client" python http "$era" http://127.0.0.1:3301/mcp
        run_cell "$client" go-stateless http "$era" http://127.0.0.1:3202/
    done
    run_cell "$client" go-stateful http handshake http://127.0.0.1:3201/
done

# Everything servers over stdio (the Python everything-server is HTTP only).
for client in swift go python; do
    for era in handshake stateless; do
        run_cell "$client" swift stdio "$era" "$BIN_SWIFT/mcp-everything-server" --stdio
        run_cell "$client" go stdio "$era" "$BIN_GO/go-everything-server"
    done
done

# The SDKs' example servers: one tool call each, era negotiated by the client.
example_cell() { # client, server, transport, tool, args, expect, address...
    local client="$1" server="$2" transport="$3" tool="$4" args="$5" expect="$6"; shift 6
    if [[ "$client" == go ]]; then
        PROFILE_ARGS=(-profile tool -tool "$tool" -args "$args" -expect "$expect")
    else
        PROFILE_ARGS=(--profile tool --tool "$tool" --args "$args" --expect "$expect")
    fi
    run_cell "$client" "$server" "$transport" auto "$@"
    unset PROFILE_ARGS
}
for client in swift go python; do
    example_cell "$client" swift-hello stdio greet '{"name":"Interop"}' "Hello, Interop!" "$BIN_SWIFT/HelloServer"
    example_cell "$client" go-hello stdio greet '{"name":"Interop"}' "Hi Interop" "$BIN_GO/go-hello-server"
    example_cell "$client" python-direct-execution stdio hello '{"name":"Interop"}' "Hello, Interop!" \
        "$PY" "$WORK/python-examples/direct_execution.py"
    example_cell "$client" python-quickstart http add '{"a":2,"b":3}' "5" http://127.0.0.1:8000/mcp
done

# Advanced: concurrency, cancellation, notifications, subscriptions and
# transport edges. The Go everything-server is the only one that updates
# test://watched-resource; its stateless server cannot send server-to-client
# requests at 2025-11-25, so it runs only in the stateless era.
PROFILE=advanced
for client in swift go python; do
    for era in handshake stateless; do
        PROFILE_ARGS=(--profile advanced)
        run_cell "$client" swift http "$era" http://127.0.0.1:3101/mcp
        run_cell "$client" python http "$era" http://127.0.0.1:3301/mcp
        run_cell "$client" swift stdio "$era" "$BIN_SWIFT/mcp-everything-server" --stdio
        PROFILE_ARGS=(--profile advanced --watched-updates)
        run_cell "$client" go stdio "$era" "$BIN_GO/go-everything-server"
    done
    run_cell "$client" go-stateful http handshake http://127.0.0.1:3201/
    run_cell "$client" go-stateless http stateless http://127.0.0.1:3202/
done

# Connect: era negotiation. Each client picks the era against every server: the
# newest one both serve, so 2026-07-28 against the servers that serve both. The
# Go stateful server supports only 2025-11-25, so a client pinned to 2026-07-28
# must fail with an unsupported-version error.
PROFILE=connect
for client in swift go python; do
    PROFILE_ARGS=(--profile connect --expect-era stateless)
    run_cell "$client" swift http auto http://127.0.0.1:3101/mcp
    run_cell "$client" python http auto http://127.0.0.1:3301/mcp
    run_cell "$client" go-stateless http auto http://127.0.0.1:3202/
    PROFILE_ARGS=(--profile connect --expect-era handshake)
    run_cell "$client" go-stateful http auto http://127.0.0.1:3201/
    PROFILE_ARGS=(--profile connect --expect-era unsupported)
    run_cell "$client" go-stateful http stateless http://127.0.0.1:3201/
done

# Session: the server restarts between two calls, so the client holds a
# session ID that the new process does not know (a 404 in the 2025-11-25 era).
# Each cell gets its own server, killed with SIGKILL; the client pauses
# through a file.
session_cell() { # client, server, era, url, server command...
    local client="$1" server="$2" era="$3" url="$4"; shift 4
    local pause="$WORK/pause-${client}-${server}-${era}" pid
    rm -f "$pause"
    "$@" >>"$LOGS/server-session-$server.log" 2>&1 & pid=$!
    track "$pid"
    wait_for "$url" "$pid"
    PROFILE_ARGS=(--profile session --pause-file "$pause")
    run_cell "$client" "$server" http "$era" "$url" &
    local cell=$!
    track "$cell"
    for _ in $(seq 1 300); do
        grep -qs ready "$pause" && break
        sleep 0.1
    done
    # SIGKILL: a crash, and no graceful shutdown that waits for the client's
    # keep-alive connections.
    kill -9 "$pid" 2>/dev/null || true
    reap "$pid"
    "$@" >>"$LOGS/server-session-$server.log" 2>&1 & pid=$!
    track "$pid"
    wait_for "$url" "$pid"
    echo go >"$pause"
    reap "$cell"
    kill "$pid" 2>/dev/null || true
    reap "$pid"
}
PROFILE=session
for client in swift go python; do
    for era in handshake stateless; do
        session_cell "$client" swift "$era" http://127.0.0.1:3111/mcp "$BIN_SWIFT/mcp-everything-server" --port 3111
        session_cell "$client" python "$era" http://127.0.0.1:3311/mcp "$VENV/bin/mcp-everything-server" --port 3311
    done
    session_cell "$client" go-stateful handshake http://127.0.0.1:3211/ \
        "$BIN_GO/go-everything-server" -http 127.0.0.1:3211 -stateless=false
done

# Tasks: the task tools of the Swift everything-server and of the TypeScript
# task server (2025-11-25 only). The Swift and TypeScript clients run the task
# lifecycle; every client checks that a client without tasks can call them
# (the Go and Python SDKs have no tasks runtime).
PROFILE=tasks
PROFILE_ARGS=(--profile tasks)
for client in swift go python ts; do
    for era in handshake stateless; do
        [[ "$client" == ts && "$era" == stateless ]] && continue
        run_cell "$client" swift http "$era" http://127.0.0.1:3101/mcp
        run_cell "$client" swift stdio "$era" "$BIN_SWIFT/mcp-everything-server" --stdio
    done
    run_cell "$client" ts http handshake http://127.0.0.1:3401/mcp
    run_cell "$client" ts stdio handshake "$NODE" "$TS/server.mjs" --stdio
done
unset PROFILE PROFILE_ARGS

# MCP Apps: the view and tools of the Swift everything-server and of the
# TypeScript server, which serves them with the ext-apps server helpers
# (2025-11-25 only). Every client declares the extension and reads them as a
# host does.
PROFILE=apps
PROFILE_ARGS=(--profile apps)
for client in swift go python ts; do
    for era in handshake stateless; do
        [[ "$client" == ts && "$era" == stateless ]] && continue
        run_cell "$client" swift http "$era" http://127.0.0.1:3101/mcp
        run_cell "$client" swift stdio "$era" "$BIN_SWIFT/mcp-everything-server" --stdio
    done
    run_cell "$client" ts http handshake http://127.0.0.1:3401/mcp
    run_cell "$client" ts stdio handshake "$NODE" "$TS/server.mjs" --stdio
done
unset PROFILE PROFILE_ARGS

# The SDKs' own example clients against the other SDKs' servers.
example_client() { # name, command...
    local name="$1"; shift
    info "example client: $name"
    local status=0
    limit 120 "$@" >"$LOGS/example-$name.log" 2>&1 || status=$?
    echo "$status" >"$RESULTS/$name.status"
}
example_client "swift-HelloClient__go-hello" "$BIN_SWIFT/HelloClient" "$BIN_GO/go-hello-server"
example_client "go-listfeatures__swift-hello" "$BIN_GO/go-listfeatures" "$BIN_SWIFT/HelloServer"
example_client "go-listfeatures__swift-everything-http" "$BIN_GO/go-listfeatures" -http http://127.0.0.1:3101/mcp
example_client "go-listfeatures__python-quickstart-http" "$BIN_GO/go-listfeatures" -http http://127.0.0.1:8000/mcp

# MARK: Report

{
    echo "Generated by scripts/run-interop.sh on $(date -u +%Y-%m-%d)."
    echo "Swift SDK $(git -C "$ROOT" log -1 --format=%h -- Sources) (last change to Sources/), Go SDK $GO_SDK_VERSION, Python SDK $PY_SDK_TAG, TypeScript SDK $TS_SDK_VERSION with ext-apps $TS_APPS_VERSION."
    echo
    python3 "$ROOT/interop/report.py" "$RESULTS"
} >"$WORK/report.md"
info "report: $WORK/report.md"
if [[ $UPDATE == 1 ]]; then
    cp "$WORK/report.md" "$ROOT/interop/RESULTS.md"
    info "updated interop/RESULTS.md"
fi
if [[ $CHECK == 1 ]]; then
    python3 "$ROOT/interop/report.py" "$RESULTS" --expect "$ROOT/interop/RESULTS.md" >/dev/null
fi
