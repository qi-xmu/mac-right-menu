#!/bin/bash
# build-and-package.sh
# 构建 Release 版本并打包为 DMG（开源分发，无需 Apple Developer 账号）
#
# 用法: ./Scripts/build-and-package.sh
#
# 前置条件:
#   - Xcode 16+ installed
#   - Config/Local.xcconfig with your Team ID (free Apple ID works)
#
# 生成的 DMG 使用构建者的个人签名，在其他 Mac 上会被 Gatekeeper 拦截，
# 用户需要右键 → 打开 来首次运行。这是开源 macOS 应用的通用做法。

set -euo pipefail

SCHEME="mac-right-menu"
PROJECT="mac-right-menu.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="build/DerivedData"
APP_NAME="mac-right-menu"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="build/${DMG_NAME}"

# ── 0. 签名前置检查 ────────────────────────────────────
# Finder Sync 扩展必须由带 Team ID 的开发证书签名，pkd 才会加载它。
# 免费 Apple ID 的 Personal Team 同样可用，不需要付费账号。
# 参见 build-install.sh 中的详细说明。
XCCONFIG="Config/Local.xcconfig"
if [ ! -f "$XCCONFIG" ]; then
    echo "❌ Missing $XCCONFIG."
    echo "   cp Config/Local.example.xcconfig $XCCONFIG"
    echo "   then set DEVELOPMENT_TEAM to your Apple ID Team ID."
    echo "   (Free Apple ID works — find your Team ID at https://developer.apple.com/account)"
    exit 1
fi
if ! grep -qE "^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]+$" "$XCCONFIG"; then
    echo "❌ DEVELOPMENT_TEAM is not set in $XCCONFIG."
    echo "   Finder Sync extension requires a real signing identity; ad-hoc /"
    echo "   linker-signed bundles are rejected by pkd and never register."
    echo "   (Free Apple ID Personal Team is sufficient — no paid account needed.)"
    exit 1
fi

# ── 1. 构建 ──────────────────────────────────────────────
echo "==> Cleaning derived data..."
rm -rf "$DERIVED_DATA"

echo "==> Building Release (Automatic signing)..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA"

BUILD_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$BUILD_APP" ]; then
    echo "❌ Build failed: $BUILD_APP not found"
    exit 1
fi
echo "✅ Built: $BUILD_APP"

# ── 2. 创建 DMG ──────────────────────────────────────────
echo "==> Creating DMG..."
DMG_TMP="build/dmg_temp"
rm -rf "$DMG_TMP" "$DMG_PATH"
mkdir -p "$DMG_TMP"

# 拷贝 App
cp -R "$BUILD_APP" "$DMG_TMP/"

# 创建 /Applications 快捷方式
ln -s /Applications "$DMG_TMP/Applications"

# 用 hdiutil 创建压缩只读 DMG
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

rm -rf "$DMG_TMP"
echo "✅ DMG created: $DMG_PATH"

# ── 3. 完成 ─────────────────────────────────────────────────
echo ""
echo "🎉 Done!"
echo "   DMG: $DMG_PATH"
echo ""
echo "   Note: This DMG is signed with your personal Team ID."
echo "   When shared with others, they'll need to right-click → Open"
echo "   the first time to bypass Gatekeeper."
echo ""
echo "   To test locally:  open $DMG_PATH"
