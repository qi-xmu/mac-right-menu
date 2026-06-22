<p align="center">
  <img src="https://img.shields.io/badge/macOS-26+-blue?logo=apple" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/Swift-6.3-FA7343?logo=swift&logoColor=white" alt="Swift 6.3" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License" />
  <a href="https://github.com/qi-xmu/mac-right-menu/releases"><img src="https://img.shields.io/github/v/release/qi-xmu/mac-right-menu" alt="Release" /></a>
</p>

<h1 align="center">mac-right-menu</h1>

<p align="center">
macOS Finder 右键菜单扩展<br/>
用任意应用打开文件 · 从模板新建文件 · 复制路径 · 切换隐藏 · 执行 Shell 命令<br/>
<sub>macOS Finder extension for custom right-click context menus</sub>
</p>

---

## ✨ Features

| 功能 | 说明 |
|------|------|
| 🔓 **用任意应用打开** | 选择文件后右键 → 用指定应用打开（不依赖"始终以此方式打开"） |
| 📄 **新建文件** | 从模板快速创建文件（.txt / .md / 自定义…），支持自定义默认内容 |
| 📋 **复制路径 / 文件名** | 一键复制完整路径或仅文件名到剪贴板 |
| 👁 **切换隐藏** | 显示或隐藏文件（Finder 的隐藏/显示切换） |
| 🐚 **Shell 命令** | 通过配置执行自定义 Shell 命令 |
| 🎨 **菜单图标** | 支持 SF Symbol 图标，可独立控制操作项 / 应用图标显示 |
| ⚡ **性能优化** | 图标预缓存 + SF Symbol 矢量渲染，右键无感知延迟 |
| 🌐 **多语言** | 完整中英双语支持（120+ 翻译条目） |
| 🔐 **全磁盘访问** | 自动检测 FDA 状态并引导用户配置 |

## 🖼 界面预览

设置窗口采用 macOS 原生 `NavigationSplitView` 侧栏导航：

| 通用 (General) | 应用 (Apps) | 文件 (File) | 操作 (Actions) |
|:---:|:---:|:---:|:---:|
| 启用/禁用菜单 | 配置"用应用打开"列表 | 管理文件模板 | 勾选显示的操作项 |
| 指令执行开关 | 独立的应用图标开关 | 自定义默认文件内容 | 图标/标题/描述 |
| 菜单图标开关 | 拖拽排序 | 模板开关 | |
| 调试/执行日志 | 从磁盘添加 `.app` | | |

## 🏗 Architecture

```
┌──────────────────────────────┐     JSON-RPC 2.0         ┌──────────────────────┐
│       Container App          │   ◄────── TCP ──────►    │   Finder Extension   │
│   (Settings + Command Exec)  │    127.0.0.1:57421       │  (Menu + UI Render)  │
│                              │                          │                      │
│  AppState (MainActor)        │   heartbeat ping/pong    │  FIFinderSync        │
│  RPCServer                   │  ◄────────────────────►  │  RPCClient           │
│  MenuConfiguration           │   configDidChange push   │  MenuBuilder         │
│  SharedUserDefaults          │   getConfig pull         │  MenuActionHandler   │
└──────────────────────────────┘                          └──────────────────────┘
```

### 通信模型

- **Extension → Container**: 右键点击 → `MenuActionHandler` 序列化为 `CommandRequest` → RPC 调用 → Container 执行
- **Container → Extension**: 设置变更 → `broadcastConfig()` 推送 `configDidChange` → Extension 重建菜单
- **心跳**: Container 周期性 ping → Extension 回 pong → 超时检测断连 → 自动重连/唤醒
- **自动拉起**: Extension 检测到 Container 未运行时自动后台启动；Container 启动时通过 `pluginkit` 唤醒 Extension

### 菜单构建流程

```
menu(for:)                    ← Finder 每次右键调用
  ├─ 有缓存? → refreshSelectionState (轻量: 仅切换 isHidden/isEnabled)
  └─ 无缓存 → buildMenu() (构建完整 NSMenu)
                ├─ New File 子菜单 (tag 0–999)
                ├─ Open With 子菜单 (tag 1000–1999)
                └─ 操作项 (tag 2000–2999)
```

### 图标渲染优化

| 方案 | 旧版 | 当前 |
|------|------|------|
| SF Symbol | `lockFocus()` CPU 栅格化 (~200ms) | `SymbolConfiguration` 矢量延迟渲染 (GPU) |
| App 图标 | 每次右键调用 `NSWorkspace.icon` | `appIconCache` 按路径缓存 |
| 外观切换 | 无处理 | `invalidateSymbolCache()` 丢弃 → 异步重建 |

## 📋 Requirements

- macOS 26 (Tahoe) 或更高
- Xcode 26+（Swift 6.3）
- 需要 **完全磁盘访问** 权限以支持所有路径下的文件操作

## 🚀 安装 & 运行

```bash
# 克隆仓库
git clone https://github.com/qi-xmu/mac-right-menu.git
cd mac-right-menu

# 打开 Xcode
xed .

# Build & Run
# Xcode → Product → Run (⌘R)

# 或通过命令行构建
xcodebuild -scheme "mac-right-menu" -project mac-right-menu.xcodeproj build
```

构建后：

1. 启动 Container App → 菜单栏出现图标
2. 打开 **系统设置 → 隐私与安全性 → 扩展 → Finder 扩展** → 启用 `mac-right-menu`
3. 在 Finder 中右键即可看到自定义菜单

## 🛠 Development

### 项目结构

```
mac-right-menu/
├── Shared/                          # Container & Extension 共享代码
│   ├── Constants.swift              # Bundle IDs, RPC 端口, Tag 定义
│   ├── Models/                      # MenuItem, CommandRequest, ExtensionInfo…
│   ├── Preferences/                 # MenuConfiguration, SharedUserDefaults
│   ├── Permissions/                 # FullDiskAccess 检测
│   └── RPC/                         # RPCSession (Server + Client)
├── mac-right-menu/                  # Container App
│   ├── ViewModels/AppState.swift    # 核心状态管理 (MainActor)
│   └── Views/                       # 设置窗口 (NavigationSplitView)
│       ├── SettingsView.swift       # 侧栏导航入口
│       ├── GeneralSettingsTab.swift
│       ├── ExtensionsSettingsTab.swift
│       ├── AppsSettingsTab.swift
│       ├── NewFileSettingsTab.swift
│       ├── ActionsSettingsTab.swift
│       ├── ExecutionLogView.swift
│       └── DebugLogView.swift
├── FinderExtension/                 # Finder Sync Extension
│   ├── FinderSync.swift             # FIFinderSync 入口 + 菜单缓存
│   ├── MenuBuilder.swift            # NSMenu 构建 + 图标缓存
│   └── MenuActionHandler.swift      # 点击分发 → RPC 调用
└── docs/                            # 设计文档
```

### 调试

```bash
# 实时查看 Extension 日志
log stream --predicate 'subsystem == "com.qi-xmu.mac-right-menu.FinderExtension"'

# 查看 Container 日志
log stream --predicate 'subsystem == "com.qi-xmu.mac-right-menu"'

# 查看所有相关日志
log stream --predicate 'subsystem == "com.qi-xmu.mac-right-menu" OR subsystem == "com.qi-xmu.mac-right-menu.FinderExtension"'

# 重启 Finder 重新加载扩展
killall Finder
```

### 设计文档

| 文档 | 说明 |
|------|------|
| [Communication Protocol](docs/design/communication-protocol.md) | JSON-RPC over TCP 通信协议设计 |
| [Menu System](docs/design/menu-system.md) | 菜单构建与图标缓存架构 |
| [Permission Model](docs/design/permission-model.md) | 权限模型与沙盒策略 |
| [Storage Migration](docs/design/storage-migration.md) | 配置存储方案演进 |

## 📜 License

[MIT](LICENSE)
