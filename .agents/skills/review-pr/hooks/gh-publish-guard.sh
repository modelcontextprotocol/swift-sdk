#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"

# Pull the Bash command string out of the hook payload.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
else
  cmd="$(printf '%s' "$payload" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))')"
fi

# `gh` followed by any global options (e.g. `--repo owner/repo`, `-R owner/repo`).
gh_re='gh([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'

# Commands that write to GitHub.
write_re="${gh_re}(pr|issue)[[:space:]]+(review|comment|merge|create|edit|close|reopen|ready)"
write_re+="|${gh_re}release[[:space:]]+(create|edit|delete)"
write_re+="|${gh_re}api[[:space:]].*(--method([[:space:]]+|=)|-X[[:space:]]*)(POST|PATCH|PUT|DELETE)"

# `gh api` defaults to GET, but switches to POST when it sends parameters
# (-f/--raw-field, -F/--field) or a body (--input), unless GET is set explicitly.
api_body_re="${gh_re}api[[:space:]].*[[:space:]](-[fF][^[:space:]]*|--(raw-)?field([[:space:]]|=)|--input([[:space:]]|=))"
api_get_re="(--method([[:space:]]+|=)|-X[[:space:]]*)GET([[:space:]]|$)"

# Join shell line continuations so options split across lines are matched, then
# put each chained command (`;`, `&&`, `||`) on its own line so the explicit-GET
# exemption only applies to the command that sets it.
line="${cmd//$'\\\n'/ }"
line="${line//&&/$'\n'}"
line="${line//||/$'\n'}"
line="${line//;/$'\n'}"

api_writes="$(grep -E "$api_body_re" <<<"$line" | grep -Eiv "$api_get_re" || true)"

if grep -Eiq "$write_re" <<<"$line" || [[ -n "$api_writes" ]]; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "This command publishes to GitHub. Confirm the draft review/comment was shown and approved before posting."
  }
}
JSON
fi

# Non-matching commands: emit nothing and exit 0 -> normal permission flow.
exit 0
