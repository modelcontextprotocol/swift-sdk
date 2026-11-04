#!/usr/bin/env bash
# CI job: builds every target of the package (the MCP library, the examples,
# the conformance fixtures, the interop client and the test bundles) for an
# Apple platform other than macOS, then runs the test bundles (MCPTests,
# SnippetTests) on a simulator of that platform.
#
# Usage: scripts/ci/apple-platform.sh <platform> [<destination id>]
#
#   <platform>        iOS, tvOS, watchOS, visionOS or macCatalyst: one of the
#                     platforms of Package.swift.
#   <destination id>  The simulator to test on (`xcrun simctl list devices`).
#                     Default: the first one xcodebuild offers for the
#                     scheme. Mac Catalyst tests on this Mac.
#
# Conformance and interop do not run here: their harnesses start the
# fixtures as processes on the host. On iOS, tvOS, watchOS and visionOS the
# executables only compile (Process does not exist there; --stdio fails at
# run time).
#
# macOS only (xcodebuild). Elsewhere the job passes and says so. The result
# bundle is .build/apple/<platform>/Tests.xcresult.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PLATFORM="${1:?usage: scripts/ci/apple-platform.sh <iOS|tvOS|watchOS|visionOS|macCatalyst> [<destination id>]}"
DESTINATION_ID="${2:-}"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "apple-platform: needs Xcode; skipped on $(uname -s)"
    exit 0
fi

# The device SDK, to fail early with a hint when this Xcode lacks it.
case "$PLATFORM" in
    iOS) SDK=iphoneos ;;
    tvOS) SDK=appletvos ;;
    watchOS) SDK=watchos ;;
    visionOS) SDK=xros ;;
    macCatalyst) SDK=macosx ;;
    *)
        echo "apple-platform: unknown platform $PLATFORM (iOS, tvOS, watchOS, visionOS or macCatalyst)" >&2
        exit 2
        ;;
esac
if [[ "$PLATFORM" == macCatalyst ]]; then
    BUILD_DESTINATION="generic/platform=macOS,variant=Mac Catalyst"
    TEST_PLATFORM=macOS
    VARIANT="Mac Catalyst"
else
    BUILD_DESTINATION="generic/platform=$PLATFORM"
    TEST_PLATFORM="$PLATFORM Simulator"
    VARIANT=""
fi

if ! xcrun --sdk "$SDK" --show-sdk-path >/dev/null 2>&1; then
    echo "apple-platform: this Xcode has no $PLATFORM SDK ($SDK);" \
        "install it with xcodebuild -downloadPlatform $PLATFORM" >&2
    exit 1
fi

SCHEME=mcp-swift-sdk-Package
OUT="$ROOT/.build/apple/$PLATFORM"
XCODEBUILD=(xcodebuild -scheme "$SCHEME" -derivedDataPath "$ROOT/.build/xcode" -skipPackagePluginValidation)
mkdir -p "$OUT"

ci_step "xcodebuild -version"
xcodebuild -version

# The device SDK: no device needed, and no signing (nothing is installed).
ci_step "xcodebuild build-for-testing ($BUILD_DESTINATION)"
"${XCODEBUILD[@]}" build-for-testing -destination "$BUILD_DESTINATION" CODE_SIGNING_ALLOWED=NO

if [[ -z "$DESTINATION_ID" ]]; then
    # Lines such as `{ platform:iOS Simulator, arch:arm64, id:<UDID>, OS:27.0, name:iPhone 17 }`
    # or `{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:<id>, name:My Mac }`. The
    # "Any ... Device" placeholders have a placeholder id or none; plain macOS has no variant.
    DESTINATION_ID="$("${XCODEBUILD[@]}" -showdestinations 2>/dev/null |
        grep -F "{ platform:$TEST_PLATFORM," | grep -v placeholder |
        { if [[ -n "$VARIANT" ]]; then grep -F "variant:$VARIANT,"; else grep -v 'variant:'; fi } |
        sed -n 's/.* id:\([^,]*\),.*/\1/p' | head -1 || true)"
    if [[ -z "$DESTINATION_ID" ]]; then
        echo "apple-platform: no $TEST_PLATFORM to test on;" \
            "install a runtime (xcodebuild -downloadPlatform $PLATFORM) or pass a simulator id" >&2
        exit 1
    fi
fi
TEST_DESTINATION="platform=$TEST_PLATFORM,${VARIANT:+variant=$VARIANT,}id=$DESTINATION_ID"

ci_step "xcodebuild test ($TEST_DESTINATION)"
rm -rf "$OUT/Tests.xcresult"
"${XCODEBUILD[@]}" test -destination "$TEST_DESTINATION" -resultBundlePath "$OUT/Tests.xcresult"
