---
name: release-dmg
description: 构建 DMG 并发布到 GitHub Release
user-invocable: true
argument-hint: [version]
---

# Release DMG to GitHub

构建 Release 版本、创建 DMG、推送 tag 并发布到 GitHub Release。

## When to Use

- 发布新版本到 GitHub
- 创建可分发的 DMG 安装包

## Your Task

### 1. 确认版本号

如果未指定版本号，读取 `Config/Version.xcconfig` 中的 `MARKETING_VERSION`，提示用户确认或输入新版本。

### 2. 更新版本号

将 `Config/Version.xcconfig` 中 `MARKETING_VERSION` 更新为新版本号。

### 3. 提交变更

如果有未提交的文件，先提交。commit message 包含版本号。

### 4. 构建 Release

```bash
xcodebuild -scheme "mac-right-menu" -project mac-right-menu.xcodeproj \
  -configuration Release build
```

### 5. 创建 DMG

```bash
APP_PATH=~/Library/Developer/Xcode/DerivedData/Build/Products/Release/mac-right-menu.app
DMG_PATH=/tmp/mac-right-menu-VERSION.dmg
rm -f "$DMG_PATH"
mkdir -p /tmp/dmg
cp -R "$APP_PATH" /tmp/dmg/
ln -s /Applications /tmp/dmg/Applications
hdiutil create -volname "mac-right-menu" -srcfolder /tmp/dmg -ov -format UDZO "$DMG_PATH"
rm -rf /tmp/dmg
ls -lh "$DMG_PATH"
```

### 6. 推送并发布

```bash
git tag v{VERSION}
git push origin main
git push origin v{VERSION}
gh release create v{VERSION} "$DMG_PATH" --title "v{VERSION}" --notes "<release notes>" --draft=false
```

Release notes 只列用户可见的功能变更，最多 3 条。

### 7. 输出 Release URL

最终输出 Release 链接，如 `https://github.com/qi-xmu/mac-right-menu/releases/tag/v1.0.5`。

## Implementation Notes

- DMG 临时存放在 `/tmp/`
- 需要 `gh` CLI 已登录
- 需要 Xcode 和代码签名证书
- Build number 由构建脚本自动生成
