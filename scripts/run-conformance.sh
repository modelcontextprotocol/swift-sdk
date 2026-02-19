#!/bin/bash
set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Configuration
CONFORMANCE_PKG="@modelcontextprotocol/conformance"
CLIENT_EXEC="mcp-everything-client"
SERVER_EXEC="mcp-everything-server"
BASELINE_FILE="${BASELINE_FILE:-conformance-baseline.yml}"
MODE="${MODE:-both}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --baseline)
      BASELINE_FILE="$2"
      shift 2
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate mode
if [[ ! "$MODE" =~ ^(client|server|both)$ ]]; then
  log_error "Invalid mode: $MODE. Must be one of: client, server, both"
  exit 1
fi

# Build Swift executables
log_info "Building Swift executables..."
swift build --product "$CLIENT_EXEC" || {
  log_error "Failed to build client"
  exit 1
}
swift build --product "$SERVER_EXEC" || {
  log_error "Failed to build server"
  exit 1
}

CLIENT_PATH="$(swift build --show-bin-path)/$CLIENT_EXEC"
SERVER_PATH="$(swift build --show-bin-path)/$SERVER_EXEC"

log_info "Client executable: $CLIENT_PATH"
log_info "Server executable: $SERVER_PATH"

# Check for baseline file
BASELINE_ARG=""
if [[ -f "$BASELINE_FILE" ]]; then
  log_info "Using baseline file: $BASELINE_FILE"
  BASELINE_ARG="--expected-failures $BASELINE_FILE"
else
  log_warn "No baseline file found at $BASELINE_FILE"
fi

# Run client tests
if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  log_info "Running client conformance tests..."
  npx "$CONFORMANCE_PKG" client \
    --command "$CLIENT_PATH" \
    --suite core \
    $BASELINE_ARG || {
    log_error "Client conformance tests failed"
    exit 1
  }
  log_info "Client tests completed"
fi

# Run server tests
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  log_info "Starting server for conformance testing..."

  # Start server in background
  "$SERVER_PATH" &
  SERVER_PID=$!

  # Wait for server to be ready
  log_info "Waiting for server to start (PID: $SERVER_PID)..."
  sleep 3

  # Run server tests
  log_info "Running server conformance tests..."
  npx "$CONFORMANCE_PKG" server \
    --url http://localhost:3001/mcp \
    --suite all \
    $BASELINE_ARG || {
    log_error "Server conformance tests failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  }

  # Cleanup
  log_info "Stopping server..."
  kill $SERVER_PID 2>/dev/null || true
  log_info "Server tests completed"
fi

log_info "All conformance tests completed successfully"
