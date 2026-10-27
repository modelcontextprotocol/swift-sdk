#!/bin/bash
# Tests the exit status of scripts/run-conformance.sh and
# scripts/conformance-score.mjs, and the entries scripts/conformance-baseline.mjs
# writes, with a fake harness and fixtures.
# Needs Node.js; no network.
#
# Usage: scripts/tests/run-conformance-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $expected, got $actual"
    FAILED=1
  fi
}

mkdir -p "$WORK/repo/scripts" "$WORK/bin" "$WORK/fixtures"
cp "$ROOT/scripts/run-conformance.sh" "$ROOT/scripts/conformance-baseline.mjs" \
  "$ROOT/scripts/conformance-score.mjs" "$WORK/repo/scripts/"
for fixture in mcp-everything-client mcp-everything-server; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/fixtures/$fixture"
  chmod +x "$WORK/fixtures/$fixture"
done
NODE="$(command -v node)"

# A harness run that finishes with failures, and a baseline generator that fails.
printf '#!/bin/sh\nprintf "=== SUMMARY ===\\n"\nexit 1\n' >"$WORK/bin/npx"
cat >"$WORK/bin/node" <<EOF
#!/bin/sh
case "\$1" in *conformance-baseline.mjs) echo "generator failed" >&2; exit 3 ;; esac
exec "$NODE" "\$@"
EOF
chmod +x "$WORK/bin/npx" "$WORK/bin/node"

rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --update-baseline --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "--update-baseline fails when the generator fails" 1 "$rc"
rm "$WORK/bin/node"

# A harness that writes results and then dies before its summary: the
# generator would accept the partial results.
cat >"$WORK/bin/npx" <<'EOF2'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
mkdir -p "$out/a-2026-01-01T00-00-00Z"
echo '[{"id":"c1","status":"SUCCESS"}]' >"$out/a-2026-01-01T00-00-00Z/checks.json"
exit 1
EOF2
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --update-baseline --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "--update-baseline fails when the harness run does not finish" 1 "$rc"

# Only the fixture the mode needs is required.
mkdir -p "$WORK/client-fixture"
cp "$WORK/fixtures/mcp-everything-client" "$WORK/client-fixture/"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/npx"
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --bin-path "$WORK/client-fixture") >/dev/null 2>&1 || rc=$?
check "--mode client needs only the client fixture" 0 "$rc"

# A flaky baseline entry: it passes in the full run (stale) and fails, as
# listed, when re-run alone.
cat >"$WORK/bin/npx" <<'EOF2'
#!/bin/sh
case " $* " in *" --scenario "*) exit 0 ;; esac
printf '\nStale baseline entries (now passing - remove from baseline):\n  ✓ flaky-one\n\n'
exit 1
EOF2
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "a flaky baseline entry is re-run alone and accepted" 0 "$rc"

# A really stale entry: it also passes alone.
cat >"$WORK/bin/npx" <<'EOF2'
#!/bin/sh
printf '\nStale baseline entries (now passing - remove from baseline):\n  ✓ stale-one\n\n'
exit 1
EOF2
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "a stale baseline entry fails the leg" 1 "$rc"

# A flaky unexpected failure: it fails in the full run and matches the
# baseline when re-run alone.
cat >"$WORK/bin/npx" <<'EOF2'
#!/bin/sh
case " $* " in *" --scenario "*) exit 0 ;; esac
printf '\nUnexpected failures (not in baseline):\n  ✗ flaky-two:check-a\n\n'
exit 1
EOF2
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "a flaky unexpected failure is re-run alone and accepted" 0 "$rc"

# A real unexpected failure: it also fails alone.
cat >"$WORK/bin/npx" <<'EOF2'
#!/bin/sh
printf '\nUnexpected failures (not in baseline):\n  ✗ broken-one:check-a\n\n'
exit 1
EOF2
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode client \
  --bin-path "$WORK/fixtures") >/dev/null 2>&1 || rc=$?
check "an unexpected failure that also fails alone fails the leg" 1 "$rc"

# A server fixture that exits during the run: its failures are not re-run
# alone, even when they would match the baseline.
mkdir -p "$WORK/server-fixture"
cp "$WORK/fixtures/mcp-everything-client" "$WORK/server-fixture/"
cat >"$WORK/server-fixture/mcp-everything-server" <<EOF
#!/bin/sh
while [ ! -e "$WORK/stop-server" ]; do sleep 0.1; done
EOF
chmod +x "$WORK/server-fixture/mcp-everything-server"
cat >"$WORK/bin/curl" <<'EOF2'
#!/bin/sh
case " $* " in *"/mcp "*) exit 0 ;; esac
exit 7
EOF2
cat >"$WORK/bin/npx" <<EOF2
#!/bin/sh
case " \$* " in *" --scenario "*) exit 0 ;; esac
touch "$WORK/stop-server"; sleep 1
printf '\nUnexpected failures (not in baseline):\n  ✗ crashed-one:check-a\n\n'
exit 1
EOF2
chmod +x "$WORK/bin/curl"
rc=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" CONFORMANCE_PKG=fake \
  scripts/run-conformance.sh --spec-version 2025-11-25 --mode server \
  --bin-path "$WORK/server-fixture") >/dev/null 2>&1 || rc=$?
check "a server fixture that exits during the run fails the leg" 1 "$rc"
rm "$WORK/bin/curl"

# The generator records failing checks per check, and a scenario the summary
# marks failed without a failing check in its results (a: only passing checks
# written; c: no results) as a bare entry.
mkdir -p "$WORK/gen/a-2026-01-01T00-00-00Z" "$WORK/gen/b-2026-01-01T00-00-00Z" \
  "$WORK/gen/auth/d-2026-01-01T00-00-00Z"
echo '[{"id":"a1","status":"SUCCESS"}]' >"$WORK/gen/a-2026-01-01T00-00-00Z/checks.json"
echo '[{"id":"b1","status":"SUCCESS"},{"id":"b2","status":"FAILURE"}]' \
  >"$WORK/gen/b-2026-01-01T00-00-00Z/checks.json"
echo '[{"id":"d1","status":"WARNING"}]' >"$WORK/gen/auth/d-2026-01-01T00-00-00Z/checks.json"
printf '%s\n' '=== SUITE SUMMARY ===' '✗ a: 1 passed, 1 failed' '✗ b: 1 passed, 1 failed' \
  '✗ c: 0 passed, 1 failed' '✗ auth/d: 0 passed, 0 failed, 1 warnings' >"$WORK/gen.log"
rc=0
"$NODE" "$ROOT/scripts/conformance-baseline.mjs" --leg 2025-11-25 --out "$WORK/gen.yml" \
  --client "$WORK/gen" --client-log "$WORK/gen.log" >/dev/null 2>&1 || rc=$?
check "the generator succeeds" 0 "$rc"
entries="$(sed -n '/^client:/,$s/^  - "\(.*\)"$/\1/p' "$WORK/gen.yml" | tr '\n' ' ')"
check "the generator records per-check and bare entries" "a auth/d:d1 b:b2 c " "$entries"

printf 'Server scenarios:\n  - a\n  - b\n' >"$WORK/list.txt"
rc=0
"$NODE" "$ROOT/scripts/conformance-score.mjs" --list "$WORK/list.txt" --role server \
  --results "$WORK/missing" >/dev/null 2>&1 || rc=$?
check "scorer fails scenarios without results" 1 "$rc"

mkdir -p "$WORK/results/server-a-2026-01-01T00-00-00Z" "$WORK/results/server-b-2026-01-01T00-00-00Z"
echo '[{"status":"SUCCESS"}]' >"$WORK/results/server-a-2026-01-01T00-00-00Z/checks.json"
echo '[{"status":"SUCCESS"}]' >"$WORK/results/server-b-2026-01-01T00-00-00Z/checks.json"
rc=0
"$NODE" "$ROOT/scripts/conformance-score.mjs" --list "$WORK/list.txt" --role server \
  --results "$WORK/results" >/dev/null 2>&1 || rc=$?
check "scorer passes when every scenario passes" 0 "$rc"

echo '[{"status":"SUCCESS"},{"status":"FAILURE"}]' >"$WORK/results/server-b-2026-01-01T00-00-00Z/checks.json"
rc=0
"$NODE" "$ROOT/scripts/conformance-score.mjs" --list "$WORK/list.txt" --role server \
  --results "$WORK/results" >/dev/null 2>&1 || rc=$?
check "scorer fails a scenario with a failed check" 1 "$rc"

printf 'Client scenarios:\n  - a\n' >"$WORK/client-only.txt"
rc=0
"$NODE" "$ROOT/scripts/conformance-score.mjs" --list "$WORK/client-only.txt" --role server \
  --results "$WORK/results" >/dev/null 2>&1 || rc=$?
check "scorer fails an empty scored set" 1 "$rc"

rc=0
"$NODE" "$ROOT/scripts/conformance-score.mjs" --list "$WORK/list.txt" --role both \
  --results "$WORK/results" >/dev/null 2>&1 || rc=$?
check "scorer rejects an unknown role" 2 "$rc"

exit "$FAILED"
