# 技术选型文档

> 日期: 2026-06-03

## 架构方案

mac-right-menu 采用 **Container App + Finder Sync Extension** 双层架构：

```
mac-right-menu.app
├── Contents/
│   ├── MacOS/
│   │   └── mac-right-menu              # 容器应用（偏好设置 UI）
│   └── PlugIns/
│       └── FinderExtension.appex       # Finder Sync Extension
│           └── Contents/
│               └─ MacOS/
│                  └─ FinderExtension    # XPC 服务进程
```

### 各组件职责

| 组件 | 职责 | 运行方式 |
|------|------|----------|
| Container App | 设置界面、启用/禁用 Extension、代码签名宿主 | 用户手动打开 |
| Finder Sync Extension | 提供右键菜单、处理菜单项点击 | Finder 按需启动（XPC） |

## 框架选择

### 选型结论: **FinderSync 框架**

| 方案 | 可行性 | 说明 |
|------|--------|------|
| ✅ **FinderSync 框架** | 可用 | 原生 API，简单稳定，但不支持复杂 UI |
| ❌ Replicated File Provider | 不适用 | 针对文件同步场景，不是右键菜单方案 |
| ❌ 纯 AppleEvents | 过度复杂 | 需监听 Finder 事件，不稳定且繁琐 |
| ❌ Shortcuts 自动化 | 体验差 | 无法嵌入 Finder 右键菜单 |

### FinderSync 的优势
- 原生集成到 Finder 右键菜单
- 支持多种菜单类型（文件、空白处、侧边栏、toolbar）
- 支持图标、子菜单、状态
- 相对简单的 API

### FinderSync 的局限
- 不支持自定义 NSView 菜单项（2026 年仍未支持）
- `selectedItemURLs()` 仅在菜单回调中有效
- `keyEquivalent` 被忽略（无法设置键盘快捷键）
- 无法直接弹出 UI 对话框
- 沙箱限制严格
- Apple 未推出替代方案之前，FinderSync 仍可用（macOS 26 Tahoe 已验证）

## 通信方案

### Extension → Container App

| 方案 | 复杂度 | 延迟 | 推荐 |
|------|--------|------|------|
| `NSXPCConnection` | 高 | 低 | ⭐ 主推 |
| Darwin Notification Center | 低 | 中 | 简单通知场景 |
| Local Socket/文件 | 中 | 低 | 不推荐 |

### Extension → 外部命令/服务

| 方案 | 说明 |
|------|------|
| `Process()` | 调用 shell 命令（最常用） |
| URLSession | HTTP 请求 |
| AppleEvents | 控制其他 macOS 应用 |

## 开发工具链

| 工具 | 版本 | 说明 |
|------|------|------|
| **Xcode** | 16+ | 必需（构建/签名/运行） |
| **Swift** | 6.3+ | Swift 6 with strict concurrency checking |
| **pixi** | 0.66 | 包管理/环境管理 |
| **macOS Target** | 26+ (Tahoe) | 最低部署目标 |
| **Architecture** | arm64 | Apple Silicon 原生 |

## 代码签名

- Development Team: 需要配置 Apple Developer Team ID
- 容器 App bundle ID: `com.example.mac-right-menu`（待定）
- Extension bundle ID: `com.example.mac-right-menu.FinderExtension`（自动附加）
- 分发: 开发者 ID + 公测，或 Mac App Store

### 必要 Entitlements

```xml
<!-- Container App -->
com.apple.security.app-sandbox: YES
com.apple.security.files.user-selected.read-write  <!-- 读/写用户选中的文件 -->

<!-- Finder Extension -->
com.apple.security.app-sandbox: YES
com.apple.security.finder.sync: YES
com.apple.security.files.user-selected.read-write
```

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| Apple 可能最终弃用 FinderSync | 文档中说已弃用但从未给出替代方案，持续关注 WWDC |
| 沙箱限制导致某些功能受限 | 使用 Security-Scoped Bookmarks，或请求临时例外 |
| MDM 策略阻止 Extension 加载 | 提示用户：联系 IT 管理员 |
| 调试困难（XPC 进程） | 使用 `os_log` + Console.app + `lldb -n finder-sync` |
