#!/bin/bash
# Generate Config/BuildNumber.xcconfig (takes effect on next build).
# Also patch the built product's Info.plist so this build gets the right version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    BUILD_NUMBER=$(git -C "$PROJECT_DIR" rev-list --count HEAD)
else
    BUILD_NUMBER=1
fi

# 1. Generate xcconfig for the next build (read by xcconfig processing at build start).
echo "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" > "$PROJECT_DIR/Config/BuildNumber.xcconfig"

# 2. Patch the built product's Info.plist (takes effect on this build).
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${INFOPLIST_PATH:-}" ]; then
    PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
    if [ -f "$PLIST" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
    fi
fi

echo "Build number: $BUILD_NUMBER"
