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

# Commands that write to GitHub. `gh api` is only flagged when it uses a
# write HTTP method, since it defaults to GET (read-only).
write_re="${gh_re}(pr|issue)[[:space:]]+(review|comment|merge|create|edit|close|reopen|ready)"
write_re+="|${gh_re}release[[:space:]]+(create|edit|delete)"
write_re+="|${gh_re}api[[:space:]].*(--method([[:space:]]+|=)|-X[[:space:]]*)(POST|PATCH|PUT|DELETE)"

# Join shell line continuations so options split across lines are matched.
if printf '%s' "${cmd//$'\\\n'/ }" | grep -Eiq "$write_re"; then
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
