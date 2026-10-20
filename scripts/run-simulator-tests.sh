#!/usr/bin/env bash
# ==============================================================================
# run-simulator-tests.sh
#
# Runs QuarkTheater unit and integration tests against a tvOS Simulator instance,
# streams execution logs to the console, and captures both xcodebuild/xctest output
# and sandbox diagnostics.jsonl into the git-ignored .build/logs directory.
#
# USAGE:
#   ./scripts/run-simulator-tests.sh [OPTIONS]
#
# OPTIONS:
#   -u, --udid <UDID>       Simulator UDID to target (default: booted Apple TV simulator)
#   -t, --test <TARGET>     Specific test class or method (e.g. FocusNavigationTests)
#   -s, --skip-build        Skip xcodebuild build-for-testing step
#   -b, --build-only        Only build the test bundle without running tests
#   -h, --help              Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="$REPO_ROOT/.build/logs"
TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"

TARGET_UDID=""
TEST_TARGET=""
SKIP_BUILD=false
BUILD_ONLY=false

# Print usage information
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run QuarkTheater tests on a tvOS Simulator and collect sanitized diagnostics.

Options:
  -u, --udid <UDID>     Simulator UDID (default: auto-detect booted tvOS simulator)
  -t, --test <TARGET>   Specific test suite or test case (e.g. FocusNavigationTests)
  -s, --skip-build      Skip compilation and run tests using existing build
  -b, --build-only      Only compile the test bundle, do not execute tests
  -h, --help            Show this help documentation

Outputs:
  Build log:        .build/logs/xcodebuild-<timestamp>.log
  Test runner log:  .build/logs/xctest-<timestamp>.log
  Diagnostics log:  .build/logs/diagnostics-<timestamp>.jsonl
EOF
    exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--udid)
            TARGET_UDID="$2"
            shift 2
            ;;
        -t|--test)
            TEST_TARGET="$2"
            shift 2
            ;;
        -s|--skip-build)
            SKIP_BUILD=true
            shift
            ;;
        -b|--build-only)
            BUILD_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Ensure DEVELOPER_DIR points to Xcode 27 if available
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode_27_beta_6.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode_27_beta_6.app/Contents/Developer"
    elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

# Ensure log directory exists
mkdir -p "$LOGS_DIR"

echo "=== Quark Theater Simulator Test Runner ==="
echo "Repo Root:     $REPO_ROOT"
echo "Logs Directory: $LOGS_DIR"
echo "Timestamp:     $TIMESTAMP"
echo "Developer Dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"

# Auto-detect booted simulator UDID if not specified
if [[ -z "$TARGET_UDID" ]]; then
    TARGET_UDID="$(xcrun simctl list devices | grep -E "Apple TV.*\(Booted\)" | head -n 1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' || true)"
    if [[ -z "$TARGET_UDID" ]]; then
        TARGET_UDID="$(xcrun simctl list devices | grep -E "\(Booted\)" | head -n 1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' || true)"
    fi
fi

if [[ -z "$TARGET_UDID" && "$BUILD_ONLY" = false ]]; then
    echo "ERROR: No booted simulator found. Please boot a tvOS simulator first." >&2
    exit 1
fi

if [[ -n "$TARGET_UDID" ]]; then
    echo "Target UDID:   $TARGET_UDID"
fi

BUILD_LOG="$LOGS_DIR/xcodebuild-$TIMESTAMP.log"
TEST_LOG="$LOGS_DIR/xctest-$TIMESTAMP.log"
DIAG_LOG="$LOGS_DIR/diagnostics-$TIMESTAMP.log"

DERIVED_DATA_DIR="$REPO_ROOT/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug-appletvsimulator/QuarkTheater.app"
TEST_BUNDLE="$APP_BUNDLE/PlugIns/QuarkTheaterTests.xctest"

# Step 1: Build for testing
if [[ "$SKIP_BUILD" = false ]]; then
    echo "--- Building test bundle for tvOS Simulator ---"
    set +e
    xcodebuild build-for-testing \
        -project "$REPO_ROOT/QuarkTheater.xcodeproj" \
        -scheme QuarkTheater \
        -destination "generic/platform=tvOS Simulator" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1
    BUILD_STATUS=$?
    set -e

    if [[ $BUILD_STATUS -ne 0 ]]; then
        echo "ERROR: Build failed with exit code $BUILD_STATUS. See $BUILD_LOG for details." >&2
        tail -n 30 "$BUILD_LOG" >&2
        exit $BUILD_STATUS
    fi
    echo "Build succeeded. Log saved to: $BUILD_LOG"
fi

if [[ "$BUILD_ONLY" = true ]]; then
    echo "Build-only mode requested. Done."
    exit 0
fi

# Step 2: Run tests via simctl spawn
echo "--- Running tests on simulator ($TARGET_UDID) ---"
XCTEST_AGENT="$DEVELOPER_DIR/Platforms/AppleTVSimulator.platform/Developer/Library/Xcode/Agents/xctest"

TEST_ARGS=()
if [[ -n "$TEST_TARGET" ]]; then
    TEST_ARGS+=("-XCTest" "$TEST_TARGET")
fi
TEST_ARGS+=("$TEST_BUNDLE")

set +e
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$APP_BUNDLE/Frameworks:$APP_BUNDLE" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$APP_BUNDLE" \
xcrun simctl spawn "$TARGET_UDID" "$XCTEST_AGENT" "${TEST_ARGS[@]}" 2>&1 | tee "$TEST_LOG"
TEST_STATUS=${PIPESTATUS[0]}
set -e

echo "Test runner finished with exit code $TEST_STATUS. Log saved to: $TEST_LOG"

# Step 3: Collect and sanitize diagnostics.jsonl from simulator container
echo "--- Collecting and sanitizing simulator diagnostics ---"
SIM_DATA_ROOT="$HOME/Library/Developer/CoreSimulator/Devices/$TARGET_UDID/data"
LATEST_DIAG_FILE="$(find "$SIM_DATA_ROOT" -name "diagnostics.jsonl" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1 || true)"

if [[ -n "$LATEST_DIAG_FILE" && -f "$LATEST_DIAG_FILE" ]]; then
    echo "Found sandbox diagnostics: $LATEST_DIAG_FILE"
    # Copy and ensure sensitive tokens / auth fields are redacted
    sed -E \
        -e 's/"(authorization|token|cookie|password|secret|key|access_token|refresh_token|ticket)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"<REDACTED>"/gI' \
        "$LATEST_DIAG_FILE" > "$DIAG_LOG"
    echo "Diagnostics collected and sanitized to: $DIAG_LOG"
else
    echo "Notice: No diagnostics.jsonl file found in simulator data directory."
fi

echo "=== Complete ==="
exit $TEST_STATUS
