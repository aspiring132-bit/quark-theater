#!/usr/bin/env bash
# ==============================================================================
# setup_vlc.sh
#
# Downloads, verifies, and installs the TVVLCKit XCFramework into Frameworks/
# for Quark Theater tvOS builds.
#
# Requirements:
#   - Official TVVLCKit 3.7.2
#   - SHA256 verification
#   - At least 1 GiB free disk space
#   - Temporary directory with trap cleanup on exit/signal
#   - Extracts only TVVLCKit.xcframework into Frameworks/ (no dSYMs)
#   - Preserves existing valid framework unless --force is specified
# ==============================================================================

set -euo pipefail

TVVLCKIT_VERSION="3.7.2"
TVVLCKIT_URL="https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz"
EXPECTED_SHA256="fa264c2eb17d648669d9d12b51e76e5b6769828354517d09b340387b30825f58"
REQUIRED_FREE_KB=1048576 # 1 GiB in KiB (1024 * 1024)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"
TARGET_FRAMEWORK="$FRAMEWORKS_DIR/TVVLCKit.xcframework"

FORCE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Download and set up TVVLCKit.xcframework for Quark Theater.

Options:
  --force       Overwrite existing TVVLCKit.xcframework if already present
  -h, --help    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Check if TVVLCKit.xcframework is already validly installed
if [[ -d "$TARGET_FRAMEWORK" ]]; then
    if [[ -f "$TARGET_FRAMEWORK/Info.plist" ]]; then
        if [[ "$FORCE" == false ]]; then
            echo "TVVLCKit.xcframework already exists at $TARGET_FRAMEWORK."
            echo "Use --force to re-download and overwrite."
            exit 0
        else
            echo "Overwriting existing TVVLCKit.xcframework (--force specified)."
        fi
    fi
fi

# Ensure Frameworks directory exists
mkdir -p "$FRAMEWORKS_DIR"

# Check free disk space (at least 1 GiB)
check_free_space() {
    local target_dir="$1"
    local free_kb
    # On macOS (and POSIX df -k), available space is column 4 (Filesystem, 1024-blocks, Used, Available, Capacity, ...)
    free_kb="$(df -k "$target_dir" | awk 'NR>1 {print $4}' | head -n 1)"
    if ! [[ "$free_kb" =~ ^[0-9]+$ ]] || [[ "$free_kb" -lt "$REQUIRED_FREE_KB" ]]; then
        echo "Error: Insufficient disk space on $(dirname "$target_dir")." >&2
        echo "Required: at least 1048576 KiB (1 GiB), Available: ${free_kb:-unknown} KiB." >&2
        exit 1
    fi
}

check_free_space "$FRAMEWORKS_DIR"

# Create a temporary directory with trap cleanup
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tvvlckit_setup.XXXXXX")"
STAGE_DIR="$(mktemp -d "$FRAMEWORKS_DIR/.tvvlckit_stage.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR" "$STAGE_DIR"
}
trap cleanup EXIT INT TERM HUP

check_free_space "$TMP_DIR"
check_free_space "$FRAMEWORKS_DIR"

ARCHIVE_PATH="$TMP_DIR/TVVLCKit-$TVVLCKIT_VERSION.tar.xz"

echo "Downloading TVVLCKit $TVVLCKIT_VERSION..."
curl -fL --progress-bar "$TVVLCKIT_URL" -o "$ARCHIVE_PATH"

echo "Verifying SHA256 checksum..."
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "Error: Checksum mismatch for $ARCHIVE_PATH." >&2
    echo "Expected: $EXPECTED_SHA256" >&2
    echo "Actual:   $ACTUAL_SHA256" >&2
    exit 1
fi
echo "Checksum verified successfully."

echo "Inspecting archive layout..."
MEMBERS="$(tar -tf "$ARCHIVE_PATH")"

# Find paths matching */TVVLCKit.xcframework/Info.plist or TVVLCKit.xcframework/Info.plist
MATCHING_PLISTS="$(echo "$MEMBERS" | grep -E '(^|/)TVVLCKit\.xcframework/Info\.plist$' || true)"
PLIST_COUNT="$(echo "$MATCHING_PLISTS" | grep -c . || true)"

if [[ "$PLIST_COUNT" -ne 1 ]]; then
    echo "Error: Unexpected archive layout. Expected exactly one TVVLCKit.xcframework/Info.plist, found $PLIST_COUNT." >&2
    exit 1
fi

FRAMEWORK_ARCHIVE_PATH="${MATCHING_PLISTS%/Info.plist}"

echo "Extracting TVVLCKit.xcframework members from archive..."
EXTRACT_DIR="$TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

# Extract only the selected TVVLCKit.xcframework member paths without nested dSYMs
tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" \
    --exclude '*/dSYMs' \
    --exclude '*/dSYMs/*' \
    "$FRAMEWORK_ARCHIVE_PATH"

FOUND_FRAMEWORK="$EXTRACT_DIR/$FRAMEWORK_ARCHIVE_PATH"

if [[ ! -d "$FOUND_FRAMEWORK" || ! -f "$FOUND_FRAMEWORK/Info.plist" ]]; then
    echo "Error: Failed to find valid TVVLCKit.xcframework in extracted content." >&2
    exit 1
fi

# Stage to sibling temporary directory within Frameworks/
echo "Staging framework in sibling temporary directory..."
STAGED_FRAMEWORK="$STAGE_DIR/TVVLCKit.xcframework"
mv "$FOUND_FRAMEWORK" "$STAGED_FRAMEWORK"

if [[ ! -f "$STAGED_FRAMEWORK/Info.plist" ]]; then
    echo "Error: Staged framework validation failed (missing Info.plist)." >&2
    exit 1
fi

# Info.plist declares a dSYMs path for each slice. The symbol payload is
# intentionally excluded to keep the install small, but Xcode still requires
# the declared directory to exist while resolving the XCFramework.
while IFS= read -r slice_dir; do
    [[ -d "$slice_dir/TVVLCKit.framework" ]] || continue
    mkdir -p "$slice_dir/dSYMs"
done < <(find "$STAGED_FRAMEWORK" -mindepth 1 -maxdepth 1 -type d -name 'tvos-*' -print)

echo "Installing TVVLCKit.xcframework into $FRAMEWORKS_DIR..."
BACKUP_FRAMEWORK=""
if [[ -e "$TARGET_FRAMEWORK" ]]; then
    BACKUP_FRAMEWORK="$(mktemp -d "$FRAMEWORKS_DIR/.tvvlckit_backup.XXXXXX")"
    rmdir "$BACKUP_FRAMEWORK"
    mv "$TARGET_FRAMEWORK" "$BACKUP_FRAMEWORK"
fi

if ! mv "$STAGED_FRAMEWORK" "$TARGET_FRAMEWORK"; then
    echo "Error: Failed to move staged framework into place. Restoring backup..." >&2
    if [[ -n "$BACKUP_FRAMEWORK" && -e "$BACKUP_FRAMEWORK" ]]; then
        mv "$BACKUP_FRAMEWORK" "$TARGET_FRAMEWORK"
    fi
    exit 1
fi

if [[ -n "$BACKUP_FRAMEWORK" && -e "$BACKUP_FRAMEWORK" ]]; then
    rm -rf "$BACKUP_FRAMEWORK"
fi

echo "Successfully installed TVVLCKit.xcframework to $TARGET_FRAMEWORK."
