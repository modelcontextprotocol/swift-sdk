#!/usr/bin/env bash
# Installs the tools the CI jobs need on a Linux builder: Node 22 (the
# conformance harness), Go 1.25 or later, uv with Python 3.12 and ps (interop:
# the time limit stops a client's whole process tree). Swift, git, curl, perl
# and python3 come with the builder image.
#
# Usage: scripts/ci/deps-linux.sh [node] [go] [uv] [ps]   (default: all four)
#
# Tools already on PATH at a usable version are left alone. Supports dnf
# (swift:*-rhel-ubi9 and other RHEL-based images) and apt
# (swift:*-noble and other Debian/Ubuntu images). On dnf everything comes
# from the image's package mirrors; on apt Node, Go and uv come from their
# upstream download sites (the Node and Go tarballs checked against their
# published SHA-256). Runs as root, or through sudo.
set -euo pipefail

TOOLS=("$@")
[[ ${#TOOLS[@]} -eq 0 ]] && TOOLS=(node go uv ps)

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo -n"

info() { printf '\033[0;32m[deps]\033[0m %s\n' "$*"; }

case "$(uname -m)" in
    x86_64) ARCH=amd64 NODE_ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 NODE_ARCH=arm64 ;;
    *) echo "deps-linux.sh: unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac

if command -v dnf >/dev/null; then
    PM=dnf
elif command -v apt-get >/dev/null; then
    PM=apt
else
    echo "deps-linux.sh: needs dnf or apt-get" >&2
    exit 2
fi

APT_UPDATED=0
apt_install() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        $SUDO apt-get update -q
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -yq --no-install-recommends "$@"
}

# The major version of `node`, or 0.
node_major() { command -v node >/dev/null && node -p 'process.versions.node.split(".")[0]' || echo 0; }

# The minor version of a Go 1.x on PATH, or 0.
go_minor() { command -v go >/dev/null && go env GOVERSION | sed -nE 's/^go1\.([0-9]+).*/\1/p' || echo 0; }

# Downloads a tarball and extracts it into /usr/local after checking it
# against its published SHA-256.
install_tarball() { # url sha256 tar-options...
    local url="$1" sha="$2" tmp
    shift 2
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "deps-linux.sh: no SHA-256 published for $url" >&2; exit 1; }
    tmp="$(mktemp)"
    curl -fsSL -o "$tmp" "$url"
    if ! echo "$sha  $tmp" | sha256sum -c --quiet - >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "deps-linux.sh: $url does not match its published SHA-256" >&2
        exit 1
    fi
    $SUDO tar "$@" -f "$tmp" -C /usr/local
    rm -f "$tmp"
}

install_node() {
    if [[ "$(node_major)" -ge 22 ]]; then return; fi
    info "installing Node 22"
    if [[ $PM == dnf ]]; then
        # DEPS_NODE_DNF_PACKAGE names a Node 22 package from the image's own
        # repositories, tried first.
        if [[ -z "${DEPS_NODE_DNF_PACKAGE:-}" ]] || ! $SUDO dnf install -yq "$DEPS_NODE_DNF_PACKAGE"; then
            $SUDO dnf module enable -yq nodejs:22
            $SUDO dnf install -yq nodejs npm
        fi
    else
        apt_install ca-certificates curl xz-utils
        local base=https://nodejs.org/dist/latest-v22.x line
        line="$(curl -fsSL "$base/SHASUMS256.txt" | awk -v a="linux-$NODE_ARCH.tar.xz" '$2 ~ a"$" { print $1, $2; exit }')"
        install_tarball "$base/${line#* }" "${line%% *}" -xJ --strip-components=1
    fi
}

install_go() {
    if [[ "$(go_minor)" -ge 25 ]]; then return; fi
    info "installing Go"
    if [[ $PM == dnf ]]; then
        $SUDO dnf install -yq golang
    else
        apt_install ca-certificates curl python3
        # The newest stable release's archive and its SHA-256.
        local line
        line="$(curl -fsSL 'https://go.dev/dl/?mode=json' | python3 -c '
import json, sys
for release in json.load(sys.stdin):
    for f in release["files"]:
        if (f["os"], f["arch"], f["kind"]) == ("linux", sys.argv[1], "archive"):
            print(f["filename"], f["sha256"])
            sys.exit()
' "$ARCH")"
        $SUDO rm -rf /usr/local/go
        install_tarball "https://go.dev/dl/${line%% *}" "${line#* }" -xz
        $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
    fi
    [[ "$(go_minor)" -ge 25 ]] || { echo "deps-linux.sh: Go 1.25 or later is required" >&2; exit 1; }
}

install_uv() {
    if command -v uv >/dev/null; then return; fi
    info "installing Python 3.12 and uv"
    if [[ $PM == dnf ]]; then
        $SUDO dnf install -yq python3.12 python3.12-pip
        $SUDO python3.12 -m pip install --quiet --root-user-action=ignore uv
    else
        apt_install ca-certificates curl python3 python3-venv
        curl -fsSL https://astral.sh/uv/install.sh | $SUDO env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh -s -- --quiet
    fi
}

install_ps() {
    if command -v ps >/dev/null; then return; fi
    info "installing ps"
    if [[ $PM == dnf ]]; then
        $SUDO dnf install -yq procps-ng
    else
        apt_install procps
    fi
}

for tool in "${TOOLS[@]}"; do
    case "$tool" in
        node) install_node ;;
        go) install_go ;;
        uv) install_uv ;;
        ps) install_ps ;;
        *) echo "deps-linux.sh: unknown tool $tool (expected node, go, uv or ps)" >&2; exit 2 ;;
    esac
done
if [[ $PM == dnf ]]; then $SUDO dnf clean all -q >/dev/null 2>&1 || true; fi
