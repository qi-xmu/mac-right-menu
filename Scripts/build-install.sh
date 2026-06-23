#!/bin/bash
# build-install.sh
# 构建 Release 版本并安装到系统（本地开发用，不需要公证）
#
# 用法: ./Scripts/build-install.sh [--run]
#   --run    安装后自动启动 App

set -euo pipefail

SCHEME="mac-right-menu"
PROJECT="mac-right-menu.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="build/DerivedData"
APP_NAME="mac-right-menu"
INSTALL_DIR="/Applications"
BUNDLE_ID="com.qi-xmu.mac-right-menu"
EXTENSION_BUNDLE_ID="com.qi-xmu.mac-right-menu.FinderExtension"
AUTO_RUN=false

for arg in "$@"; do
    case "$arg" in
        --run) AUTO_RUN=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── 0. 签名前置检查 ────────────────────────────────────
# Finder Sync 扩展必须由带 Team ID 的开发证书签名 + 嵌入
# com.apple.security.finder.sync entitlement，pkd 才会加载它。
# 历史上这里曾用 CODE_SIGN_IDENTITY="-" + CODE_SIGNING_ALLOWED=NO
# 走 ad-hoc / linker-signed，结果 Release 扩展根本进不了 pluginkit
# 注册表，Finder 右键菜单也就永远空着。强制要求 Local.xcconfig 提供
# DEVELOPMENT_TEAM，从根上杜绝再次回退到 ad-hoc。
XCCONFIG="Config/Local.xcconfig"
if [ ! -f "$XCCONFIG" ]; then
    echo "❌ Missing $XCCONFIG."
    echo "   cp Config/Local.example.xcconfig $XCCONFIG"
    echo "   then set DEVELOPMENT_TEAM to your Apple Developer Team ID."
    exit 1
fi
if ! grep -qE "^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]+$" "$XCCONFIG"; then
    echo "❌ DEVELOPMENT_TEAM is not set in $XCCONFIG."
    echo "   Finder Sync extension requires a real signing identity; ad-hoc /"
    echo "   linker-signed bundles are rejected by pkd and never register."
    exit 1
fi

# ── 1. 构建 ──────────────────────────────────────────────
# Automatic signing driven by Config/Local.xcconfig (DEVELOPMENT_TEAM +
# CODE_SIGN_STYLE). The Xcode project already declares entitlements for both
# the Container and FinderExtension targets; Automatic signing embeds them.
echo "==> Building Release (Automatic signing)..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA"

# 找到构建产物
BUILD_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$BUILD_APP" ]; then
    echo "❌ Build failed: $BUILD_APP not found"
    exit 1
fi
echo "✅ Build succeeded: $BUILD_APP"

# ── 2. 杀掉运行中的旧 Container（释放单实例锁 + 端口）──
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
echo "==> Stopping running Container..."
killall "$APP_NAME" 2>/dev/null || true

# ── 3. 安装 App ──────────────────────────────────────────
echo "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" "$INSTALL_APP"
echo "✅ Installed: $INSTALL_APP"


# ── 4. 安装 Finder 扩展 ─────────────────────────────────
EXTENSION_APPEX="$INSTALL_APP/Contents/PlugIns/FinderExtension.appex"
if [ -d "$EXTENSION_APPEX" ]; then
    echo "==> Installing Finder extension..."
    # Kill any already-loaded FinderExtension process BEFORE re-registering.
    # pkd caches a loaded extension's process image in memory; once an ext has
    # been instantiated it gets reused on the next right-click and the on-disk
    # .appex is NOT re-read. So a fresh build silently runs as the OLD binary
    # until the host process is torn down. Killing it here forces pkd to reload
    # the new binary on the next invocation.
    killall "FinderExtension" 2>/dev/null || true
    # 先移除旧注册
    pluginkit -e ignore -i "$EXTENSION_BUNDLE_ID" 2>/dev/null || true
    # 注册新扩展
    pluginkit -a "$EXTENSION_APPEX"
    # 启用扩展
    pluginkit -e use -i "$EXTENSION_BUNDLE_ID"
    echo "✅ Finder extension installed and enabled"
else
    echo "⚠️  Extension not found at $EXTENSION_APPEX"
fi

# ── 5. 重启 Finder ──────────────────────────────────────
echo "==> Restarting Finder..."
killall Finder 2>/dev/null || true
echo "✅ Finder restarted"

# ── 6. 可选：启动 App ───────────────────────────────────
if [ "$AUTO_RUN" = true ]; then
    echo "==> Launching $APP_NAME..."
    open "$INSTALL_APP"
fi

echo ""
echo "🎉 Done! Right-click in Finder to test the extension."
echo "   Settings: open $INSTALL_APP"
