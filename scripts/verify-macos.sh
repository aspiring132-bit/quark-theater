#!/usr/bin/env bash
# Run on macOS with Xcode selected. No Apple TV model is assumed.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script requires macOS and Xcode; no build or test was performed." >&2
  exit 1
fi
if [[ "$#" -gt 1 ]]; then
  echo "Usage: bash scripts/verify-macos.sh [Apple-TV-Simulator-UDID]" >&2
  exit 2
fi
command -v xcodebuild >/dev/null
python3 scripts/validate_project.py
plutil -lint QuarkTheater.xcodeproj/project.pbxproj
xcodebuild -version
xcodebuild -list -project QuarkTheater.xcodeproj
xcodebuild -project QuarkTheater.xcodeproj -scheme QuarkTheater \
  -configuration Debug -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
if [[ "$#" -eq 1 ]]; then
  simulator_udid="$1"
  if [[ ! "$simulator_udid" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
    echo "Supply an actual tvOS Simulator UDID from xcrun simctl list devices available." >&2
    exit 2
  fi
  xcodebuild -project QuarkTheater.xcodeproj -scheme QuarkTheater \
    -configuration Debug -destination "platform=tvOS Simulator,id=$simulator_udid" \
    -derivedDataPath .build/DerivedData \
    -resultBundlePath ".build/TestResults-$(date +%Y%m%d-%H%M%S).xcresult" \
    CODE_SIGNING_ALLOWED=NO test
else
  echo "Build completed. Tests were not run: select an available tvOS Simulator UDID."
  echo "List devices: xcrun simctl list devices available"
  echo "Then: bash scripts/verify-macos.sh <UDID>"
fi
echo "Device signing, installation and real Quark account validation remain separate checks."
