# Shared by the CI job scripts in scripts/ci/. Sourced, not run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Makes sure each named tool (node, go, uv, ps) is available. On Linux a missing
# tool is installed with deps-linux.sh; elsewhere the job stops with a hint.
require_tools() {
    local missing=() tool
    for tool in "$@"; do
        case "$tool" in
            node) command -v npx >/dev/null || missing+=(node) ;;
            go) command -v go >/dev/null || missing+=(go) ;;
            uv) command -v uv >/dev/null || missing+=(uv) ;;
            ps) command -v ps >/dev/null || missing+=(ps) ;;
        esac
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    if [[ "$(uname -s)" == Linux ]]; then
        "$ROOT/scripts/ci/deps-linux.sh" "${missing[@]}"
    else
        echo "missing tools: ${missing[*]} (install them, e.g. with Homebrew)" >&2
        exit 2
    fi
}

ci_step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
