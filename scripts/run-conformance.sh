#!/bin/bash
# Runs the MCP conformance harness against the Swift conformance fixtures.
#
# Usage: scripts/run-conformance.sh [options]
#
#   --spec-version <rev>   Run '--suite all' at one revision's wire
#                          (2025-11-25 or 2026-07-28). Omit for the bare leg
#                          at the harness default wire.
#   --requirements <rev>   Score the frozen requirement set for <rev>, the
#                          set 'conformance tier-check' uses. No baseline
#                          is read or written; any scored failure fails.
#   --mode <m>             client, server or both (default: both).
#   --update-baseline      Regenerate the leg's baseline instead of checking it.
#   --bin-path <dir>       Use fixtures already built in <dir>; skip swift build.
#   --port <n>             Server fixture port (default: 3001).
#   --output-dir <dir>     Results directory (default: .build/conformance).
#   --solo-attempts <n>    Re-run each unexpected failure and stale baseline
#                          entry alone up to n times before failing
#                          (default: 1; 0 disables).
#
# Environment: CONFORMANCE_PKG runs another harness package with npx instead
# of the locked one in scripts/conformance-harness; npm_config_registry selects
# the npm registry.
set -euo pipefail

CONFORMANCE_PKG="${CONFORMANCE_PKG:-}"
CLIENT_EXEC="mcp-everything-client"
SERVER_EXEC="mcp-everything-server"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-60000}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_VERSION=""
REQUIREMENTS=""
MODE="both"
UPDATE_BASELINE=0
BIN_PATH=""
PORT=3001
OUTPUT_DIR="$ROOT/.build/conformance"
SOLO_ATTEMPTS=1
SERVER_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-version) SPEC_VERSION="$2"; shift 2 ;;
    --requirements) REQUIREMENTS="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    --bin-path) BIN_PATH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --solo-attempts) SOLO_ATTEMPTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [[ ! "$MODE" =~ ^(client|server|both)$ ]]; then
  log_error "Invalid mode: $MODE (expected client, server or both)"
  exit 2
fi
for rev in "$SPEC_VERSION" "$REQUIREMENTS"; do
  if [[ -n "$rev" && ! "$rev" =~ ^(2025-11-25|2026-07-28)$ ]]; then
    log_error "Unsupported revision: $rev (expected 2025-11-25 or 2026-07-28)"
    exit 2
  fi
done
if [[ -n "$REQUIREMENTS" && ( -n "$SPEC_VERSION" || "$UPDATE_BASELINE" -eq 1 ) ]]; then
  log_error "--requirements cannot be combined with --spec-version or --update-baseline"
  exit 2
fi

if [[ -n "$REQUIREMENTS" ]]; then
  LEG="requirements-$REQUIREMENTS"
  BASELINE_FILE=""
  HARNESS_SELECT=(--requirements "$REQUIREMENTS")
elif [[ -n "$SPEC_VERSION" ]]; then
  LEG="$SPEC_VERSION"
  BASELINE_FILE="$ROOT/conformance-baseline.$SPEC_VERSION.yml"
  HARNESS_SELECT=(--suite all --spec-version "$SPEC_VERSION")
else
  LEG="default"
  BASELINE_FILE="$ROOT/conformance-baseline.yml"
  HARNESS_SELECT=(--suite all)
fi
LEG_DIR="$OUTPUT_DIR/$LEG"

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# The harness and its dependency tree come from scripts/conformance-harness/
# package-lock.json, installed with 'npm ci' (integrity-checked) into
# .build/conformance-harness.
HARNESS_SRC="$ROOT/scripts/conformance-harness"
HARNESS_DIR="$ROOT/.build/conformance-harness"
install_harness() {
  if [[ -n "$CONFORMANCE_PKG" ]]; then return 0; fi
  if [[ -x "$HARNESS_DIR/node_modules/.bin/conformance" ]] \
    && cmp -s "$HARNESS_SRC/package-lock.json" "$HARNESS_DIR/package-lock.json"; then
    return 0
  fi
  log_info "Installing the conformance harness from its lockfile..."
  rm -rf "$HARNESS_DIR"
  mkdir -p "$HARNESS_DIR"
  cp "$HARNESS_SRC/package.json" "$HARNESS_SRC/package-lock.json" "$HARNESS_DIR/"
  if ! (cd "$HARNESS_DIR" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=warn); then
    log_error "npm ci failed for the conformance harness"
    exit 1
  fi
}
harness() {
  if [[ -n "$CONFORMANCE_PKG" ]]; then
    npx --yes "$CONFORMANCE_PKG" "$@"
  else
    "$HARNESS_DIR/node_modules/.bin/conformance" "$@"
  fi
}
install_harness

FIXTURES=()
[[ "$MODE" == "server" ]] || FIXTURES+=("$CLIENT_EXEC")
[[ "$MODE" == "client" ]] || FIXTURES+=("$SERVER_EXEC")
if [[ -z "$BIN_PATH" ]]; then
  log_info "Building conformance fixtures..."
  for exe in "${FIXTURES[@]}"; do
    (cd "$ROOT" && swift build --product "$exe")
  done
  BIN_PATH="$(cd "$ROOT" && swift build --show-bin-path)"
fi
CLIENT_PATH="$BIN_PATH/$CLIENT_EXEC"
SERVER_PATH="$BIN_PATH/$SERVER_EXEC"
for exe in "${FIXTURES[@]}"; do
  [[ -x "$BIN_PATH/$exe" ]] || { log_error "Fixture not found: $BIN_PATH/$exe"; exit 1; }
done

start_server() {
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" 2>/dev/null; then
    log_error "Port $PORT is already in use"
    exit 1
  fi
  mkdir -p "$LEG_DIR"
  # The harness writes $LEG_DIR/server.log; the fixture gets its own log.
  "$SERVER_PATH" --port "$PORT" >"$LEG_DIR/server-fixture.log" 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log_error "Server exited during startup; see $LEG_DIR/server-fixture.log"
      SERVER_PID=""
      exit 1
    fi
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/mcp" 2>/dev/null; then
      log_info "Server ready on port $PORT (PID $SERVER_PID)"
      return
    fi
    sleep 0.5
  done
  log_error "Server did not become ready within 30s"
  exit 1
}

# Runs the harness for one role. Arguments: role, results dir, harness args.
run_role() {
  local role="$1" results="$2"; shift 2
  rm -rf "$results"
  if [[ "$role" == "client" ]]; then
    harness client --command "$CLIENT_PATH" --timeout "$CLIENT_TIMEOUT_MS" "$@" -o "$results"
  else
    harness server --url "http://localhost:$PORT/mcp" "$@" -o "$results"
  fi
}

# Succeeds, and reports it, when the role is server and the fixture has
# exited. Scenarios that fail because the fixture crashed are neither flakes
# to re-run nor known failures to record.
server_exited() {
  local role="$1"
  if [[ "$role" == "server" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log_error "Server fixture exited during the run; see $LEG_DIR/server-fixture.log"
    return 0
  fi
  return 1
}

# Re-runs each unexpected failure and each stale baseline entry alone with the
# baseline; succeeds only if every one of them matches the baseline in at least
# one solo run. A stale entry that passes every solo run is really stale.
rescue_flakes() {
  local role="$1" log="$2"
  local unexpected stale
  unexpected="$(sed -n '/Unexpected failures (not in baseline):/,/^$/p' "$log" \
    | sed -n 's/^ *✗ \([^:]*\).*/\1/p' | sort -u)"
  stale="$(sed -n '/Stale baseline entries/,/^$/p' "$log" \
    | sed -n 's/^ *✓ \([^:]*\).*/\1/p' | sort -u)"
  local scenarios
  scenarios="$(printf '%s\n%s\n' "$unexpected" "$stale" | sed '/^$/d' | sort -u)"
  if [[ -z "$scenarios" || "$SOLO_ATTEMPTS" -eq 0 ]]; then
    if [[ -n "$stale" ]]; then
      log_error "Baseline has stale entries; regenerate with --update-baseline"
    fi
    return 1
  fi
  local scenario attempt passed
  for scenario in $scenarios; do
    if [[ ! "$scenario" =~ ^[A-Za-z0-9/_-]+$ ]]; then
      log_error "Unexpected scenario name: $scenario"
      return 1
    fi
    passed=0
    for attempt in $(seq 1 "$SOLO_ATTEMPTS"); do
      log_warn "Re-running $role scenario '$scenario' alone (attempt $attempt)"
      local select=(--scenario "$scenario")
      if [[ -n "$SPEC_VERSION" ]]; then select+=(--spec-version "$SPEC_VERSION"); fi
      if run_role "$role" "$LEG_DIR/$role-solo" "${select[@]}" \
        --expected-failures "$BASELINE_FILE" >"$LEG_DIR/$role-solo.log" 2>&1; then
        passed=1
        break
      fi
    done
    if [[ "$passed" -eq 0 ]]; then
      if grep -q "Stale baseline entries" "$LEG_DIR/$role-solo.log"; then
        log_error "$role scenario '$scenario' passes alone: its baseline entry is stale; regenerate with --update-baseline"
      else
        log_error "$role scenario '$scenario' also fails alone; see $LEG_DIR/$role-solo.log"
      fi
      return 1
    fi
  done
  log_warn "Every unexpected $role result matched the baseline when re-run alone (flaky)"
  return 0
}

# Runs one role of the leg. It is called as 'run_leg_role ... || STATUS=1', where
# bash ignores 'set -e', so every step checks its own status.
run_leg_role() {
  local role="$1"
  local log="$LEG_DIR/$role.log"
  mkdir -p "$LEG_DIR" || return 1
  log_info "Running $role conformance ($LEG leg)..."

  if [[ "$UPDATE_BASELINE" -eq 1 ]]; then
    # Failures are expected here; the generator records them.
    run_role "$role" "$LEG_DIR/$role" "${HARNESS_SELECT[@]}" >"$log" 2>&1 || true
    if ! grep -q "SUMMARY ===" "$log"; then
      log_error "The $role harness run did not finish ($LEG leg); harness log: $log"
      return 1
    fi
    if server_exited "$role"; then return 1; fi
    if ! node "$ROOT/scripts/conformance-baseline.mjs" --leg "$LEG" --out "$BASELINE_FILE" \
      "--$role" "$LEG_DIR/$role" "--$role-log" "$log"; then
      log_error "Baseline generation failed for $role ($LEG leg); harness log: $log"
      return 1
    fi
    return 0
  fi

  local args=("${HARNESS_SELECT[@]}")
  if [[ -n "$BASELINE_FILE" ]]; then args+=(--expected-failures "$BASELINE_FILE"); fi
  local rc=0
  run_role "$role" "$LEG_DIR/$role" "${args[@]}" >"$log" 2>&1 || rc=$?
  sed -n '/SUMMARY ===/,$p' "$log"
  if [[ -n "$REQUIREMENTS" ]]; then
    if ! harness list --requirements "$REQUIREMENTS" >"$LEG_DIR/requirements.txt"; then
      log_error "Could not list the $REQUIREMENTS requirement set"
      return 1
    fi
    # The tier rule also fails scored scenarios that produced no results.
    if ! node "$ROOT/scripts/conformance-score.mjs" --list "$LEG_DIR/requirements.txt" \
      --role "$role" --results "$LEG_DIR/$role"; then
      [[ "$rc" -ne 0 ]] || rc=1
    fi
  fi
  if [[ "$rc" -eq 0 ]]; then
    log_info "$role conformance passed ($LEG leg)"
    return 0
  fi
  if [[ -n "$BASELINE_FILE" ]] && ! server_exited "$role" && rescue_flakes "$role" "$log"; then
    return 0
  fi
  log_error "$role conformance failed ($LEG leg); full log: $log"
  return 1
}

STATUS=0
if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  run_leg_role client || STATUS=1
fi
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  start_server
  run_leg_role server || STATUS=1
fi
exit "$STATUS"
