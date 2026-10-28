#!/usr/bin/env bash
# CI job: runs each fuzz target in fuzz/ for a while. A crash, a failed
# precondition or a sanitizer report fails the job, after the other targets
# have run; the input that caused it is in .build/fuzz/artifacts/.
#
# Usage: scripts/ci/fuzz.sh [<seconds per target>]   (default: 60)
#
# Linux only: libFuzzer is not part of the Xcode toolchain. Elsewhere the job
# passes and says so.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SECONDS_PER_TARGET="${1:-60}"
TARGETS=(FuzzDecode FuzzSSE FuzzStatelessHTTP FuzzStatefulHTTP FuzzFrontmatter)

if [[ "$(uname -s)" != Linux ]]; then
    echo "fuzz: needs a Linux toolchain with libFuzzer; skipped"
    exit 0
fi

OUT="$ROOT/.build/fuzz"
mkdir -p "$OUT/artifacts"
ci_step "swift build (fuzz/, -sanitize=fuzzer,address)"
# A cached build manifest misses source files added to the MCP package,
# which this package depends on by path.
FLAGS=(-c debug --package-path "$ROOT/fuzz" --scratch-path "$OUT/build" --disable-build-manifest-caching
    -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library -Xswiftc -enable-testing)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

failed=()
for target in "${TARGETS[@]}"; do
    corpus="$OUT/corpus/$target"
    mkdir -p "$corpus"
    [[ -d "$ROOT/fuzz/corpus/$target" ]] && cp -n "$ROOT/fuzz/corpus/$target"/* "$corpus"/ 2>/dev/null || true
    ci_step "$target for ${SECONDS_PER_TARGET}s"
    # No LeakSanitizer: Swift keeps pointers inside enum payloads (Data, for
    # one) with spare bits set, so it reports reachable globals. The HTTP
    # targets check instead that each input's server is released.
    ASAN_OPTIONS=detect_leaks=0 "$BIN/$target" "$corpus" -max_total_time="$SECONDS_PER_TARGET" -max_len=65536 \
        -detect_leaks=0 -artifact_prefix="$OUT/artifacts/$target-" -print_final_stats=1 ||
        failed+=("$target")
done
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "fuzz: failed: ${failed[*]} (inputs in $OUT/artifacts/)" >&2
    exit 1
fi
