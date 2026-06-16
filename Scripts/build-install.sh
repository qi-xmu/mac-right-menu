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

# ── 1. 构建 ──────────────────────────────────────────────
echo "==> Building Release..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

# 找到构建产物
BUILD_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$BUILD_APP" ]; then
    echo "❌ Build failed: $BUILD_APP not found"
    exit 1
fi
echo "✅ Build succeeded: $BUILD_APP"

# ── 2. 安装 App ──────────────────────────────────────────
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
echo "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" "$INSTALL_APP"
echo "✅ Installed: $INSTALL_APP"

# ── 3. 安装 Finder 扩展 ─────────────────────────────────
EXTENSION_APPEX="$INSTALL_APP/Contents/PlugIns/FinderExtension.appex"
if [ -d "$EXTENSION_APPEX" ]; then
    echo "==> Installing Finder extension..."
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

# ── 4. 重启 Finder ──────────────────────────────────────
echo "==> Restarting Finder..."
killall Finder 2>/dev/null || true
echo "✅ Finder restarted"

# ── 5. 可选：启动 App ───────────────────────────────────
if [ "$AUTO_RUN" = true ]; then
    echo "==> Launching $APP_NAME..."
    open "$INSTALL_APP"
fi

echo ""
echo "🎉 Done! Right-click in Finder to test the extension."
echo "   Settings: open $INSTALL_APP"
