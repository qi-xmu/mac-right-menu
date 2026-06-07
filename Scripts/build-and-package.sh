#!/bin/bash
# build-and-package.sh
# Builds, signs, and notarizes mac-right-menu for Developer ID distribution.
#
# Prerequisites:
#   - Xcode 16+ installed
#   - Developer ID certificates in keychain
#   - App-specific password for notarytool in keychain (or use --apple-id)

set -euo pipefail

SCHEME="mac-right-menu"
PROJECT="mac-right-menu.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="build/DerivedData"
ARCHIVE_PATH="build/mac-right-menu.xcarchive"
EXPORT_PATH="build/export"
APP_NAME="mac-right-menu"

echo "==> Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE="Manual" \
    CODE_SIGN_IDENTITY="Developer ID Application"

echo "==> Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "Scripts/export-options.plist"

echo "==> Notarizing..."
ditto -c -k --keepParent "$EXPORT_PATH/$APP_NAME.app" "$EXPORT_PATH/$APP_NAME.zip"

xcrun notarytool submit "$EXPORT_PATH/$APP_NAME.zip" \
    --keychain-profile "NOTARIZATION" \
    --wait

echo "==> Stapling..."
xcrun stapler staple "$EXPORT_PATH/$APP_NAME.app"

echo "==> Done! App is at: $EXPORT_PATH/$APP_NAME.app"
