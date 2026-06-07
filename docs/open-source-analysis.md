# 开源方案调研报告

> 日期: 2026-06-03

## 项目概览

| 项目 | Stars | 语言 | 特性 | 通信方式 | 沙箱策略 |
|------|-------|------|------|---------|---------|
| [RClick](https://github.com/wflixu/RClick) | ⭐162 | Swift + SwiftUI + SwiftData | 打开App、复制路径、新建文件、隐藏文件、常用文件夹、文件类型选择 | DistributedNotificationCenter | App-Scope Bookmark |
| [MenuHelper](https://github.com/Kyle-Ye/MenuHelper) | — | Swift + SwiftUI | 打开App、复制路径、父目录、新建文件、子菜单支持 | DistributedNotificationCenter | Sandbox + 临时例外(根目录只读) |
| [FinderUtilities](https://github.com/suolapeikko/FinderUtilities) | ⭐186 | Swift | 打开终端、创建空文件、复制路径 | 无 IPC（直接操作） | 未使用沙箱 |
| [rightmenu-master](https://github.com/jaywcjlove/rightmenu-master) | ⭐322 | SwiftUI | 新建文件、桌面App集成 | — | — |
| [OpenInTerminal](https://github.com/Ji4n1ng/OpenInTerminal) | ⭐6600+ | Swift | 在终端/编辑器中打开当前目录 | — | — |

---

## 项目详细分析

### 1. RClick (wflixu/RClick)

**仓库**: https://github.com/wflixu/RClick ⭐162

最完整的 Finder 右键菜单增强项目，功能最丰富。

#### 项目结构

```
RClick.app
├── RClick/                          # Container App
│   ├── RClickApp.swift              # @main 入口
│   ├── AppState.swift               # 全局状态
│   ├── MenuBarView.swift            # 菜单栏视图
│   ├── Settings/                    # 设置界面（SwiftUI）
│   │   ├── SettingsView.swift
│   │   ├── GeneralSettingsTabView.swift
│   │   ├── AppsSettingsTabView.swift
│   │   ├── ActionSettingsTabView.swift
│   │   ├── NewFileSettingsTabView.swift
│   │   └── CommonDirsSettingTabView.swift
│   ├── Model/                       # 数据模型 + SwiftData
│   │   ├── Models.swift             # PermDir (安全域书签)
│   │   ├── ModelContainer.swift     # 共享 ModelContainer
│   │   └── RCBase.swift
│   └── Shared/                      # 共享工具
│       ├── Messager.swift           # IPC 通信核心 ← 关键
│       ├── Constants.swift
│       ├── Utils.swift
│       └── AppLogger.swift
└── FinderSyncExt/                   # Finder Sync Extension
    ├── FinderSyncExt.swift           # 主类 ← 关键
    ├── MenuItemClickable.swift       # 菜单点击处理
    ├── Info.plist
    └── FinderSyncExt.entitlements
```

#### 关键技术决策

| 方面 | 方案 |
|------|------|
| IPC 通信 | `DistributedNotificationCenter`（Extension ↔ Container） |
| 持久化 | **SwiftData** + App Group Container 共享 |
| 安全域 | App-Scope Security Bookmark（用户选择目录后持久化书签） |
| 菜单构建 | `NSMenuItem`（非 `FIMenuItem`），因为可设 target、tooltip 等 |
| 状态同步 | Extension 通过 IPC 发送心跳，Container 响应时更新目录列表 |
| 目录权限 | 不请求沙箱（entitlements 无 `app-sandbox`），仅使用 `app-scope bookmarks` |
| 文件创建 | Container App 内通过 `Process()` 调用 `touch` 或其他工具处理 |
| 日志 | `OSLog` + 自定义 `AppLog` 属性包装 |

#### `DistributedNotificationCenter` IPC 模式

**Extension → Container**（发送消息）:
```swift
// FinderSyncExt.swift
let center = DistributedNotificationCenter.default()
center.postNotificationName(NSNotification.Name("messageFromFinder"),
                            object: jsonString,
                            userInfo: nil,
                            deliverImmediately: true)
```

**Container → Extension**（接收消息）:
```swift
// Messager.swift
center.addObserver(self, selector: #selector(recievedMessage(_:)),
                   name: NSNotification.Name("running"), object: nil)
```

消息以 `MessagePayload`（JSON 字符串）编码：
```swift
struct MessagePayload: Codable {
    var action: String      // "open" | "create" | "copy" | "delete" | "heartbeat"
    var target: [String]    // URL 路径列表
    var rid: String         // 资源 ID
    var trigger: String     // "ctx-items" | "ctx-container" | "toolbar"
}
```

#### Info.plist 配置

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.FinderSync</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).FinderSyncExt</string>
</dict>
```

#### Entitlements

Container App & Extension 使用相同的 entitlements（无沙箱 + App Group）:
```xml
<key>com.apple.security.application-groups</key>
<array><string>group.cn.wflixu.RClick</string></array>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

### 2. MenuHelper (Kyle-Ye/MenuHelper)

**仓库**: https://github.com/Kyle-Ye/MenuHelper

架构最清晰的项目，有良好的 MVC 分层和协议设计。

#### 项目结构

```
MenuHelper.app
├── MenuHelper/                      # Container App (SwiftUI)
│   ├── MenuHelperApp.swift
│   ├── ContentView.swift
│   ├── View/
│   │   ├── AppMenuItemView.swift
│   │   └── SettingView/            # 多 Tab 设置
│   └── Store/                       # 应用内购买
├── MenuHelperExtension/             # Finder Sync Extension
│   ├── FinderSync.swift             # 主类 ← 关键
│   ├── MenuItemClickable.swift      # 菜单点击处理
│   └── Info.plist
├── Shared/                          # 双 target 共享
│   ├── Channel/
│   │   ├── FinderCommChannel.swift  # Extension 端通信
│   │   └── AppCommChannel.swift     # Container 端通信
│   ├── Model/
│   │   ├── AppMenuItem.swift        # 应用菜单项模型
│   │   ├── ActionMenuItem.swift     # 动作菜单项模型
│   │   ├── MenuItem.swift           # MenuItem 协议
│   │   └── FolderItemStore.swift
│   └── ViewModel/
```

#### 关键技术决策

| 方面 | 方案 |
|------|------|
| IPC 通信 | `DistributedNotificationCenter`（双向） |
| 持久化 | `UserDefaults` + App Group |
| 菜单构建 | `NSMenuItem`，支持子菜单分组 |
| 架构设计 | 协议化（`MenuItem` 协议 + `MenuItemClickable` 协议） |
| 沙箱策略 | **开启沙箱** + 根目录只读临时例外 |
| 文件创建 | Extension 内直接用 `FileManager.default.createFile()` |
| 应用打开 | `NSWorkspace.shared.open(urls, withApplicationAt: url)` |

#### 沙箱策略对比

MenuHelper 选择开启完整沙箱 + 临时例外读取根目录：
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<string>/</string>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

#### 菜单构建模式

```swift
override func menu(for menuKind: FIMenuKind) -> NSMenu {
    let menu = NSMenu(title: "MenuHelper")
    // 支持按 FIMenuKind 控制显示
    switch menuKind {
    case .contextualMenuForItems:
        if !UserDefaults.group.showContextualMenuForItem { return NSMenu() }
    // ...

    // 应用菜单（使用 submenu 分组）
    let applicationSubMenuItem = NSMenuItem(title: "Application Menus")
    menu.addItem(applicationSubMenuItem)
    // 或直接添加到主菜单
    for item in menuStore.appItems.filter(\.enabled) {
        let menuItem = NSMenuItem()
        menuItem.target = self
        menuItem.title = "Open in \(item.name)"
        menuItem.action = #selector(menuAction(_:))
        menuItem.tag = 0  // 用 tag 区分菜单类型
        applicationSubMenuItem.submenu?.addItem(menuItem)
    }
}
```

### 3. FinderUtilities (suolapeikko/FinderUtilities)

**仓库**: https://github.com/suolapeikko/FinderUtilities ⭐186

最简洁的实现，适合理解基础架构。

#### 项目结构

```
FinderUtilities
├── FinderUtilities/                 # Container App
│   ├── AppDelegate.swift
│   └── Info.plist
└── RightClickExtension/            # Finder Sync Extension
    ├── RightClickExtension.swift    # 主类 ← 核心文件仅 100 行
    ├── Info.plist
    └── RightClickExtension.entitlements
```

#### 特点

- **不包含 IPC**：所有操作在 Extension 内直接完成
- **不包含设置界面**：Container App 只负责安装 Extension
- **Direct 模式**：直接设置 `directoryURLs = [URL(fileURLWithPath: "/")]` 在所有路径生效
- **使用 NSMenu**（非常简单，直接 `menu.addItem(withTitle:)`）
- 使用 `FIFinderSyncController.default().selectedItemURLs()` 和 `targetedURL()` 获取目标

### 4. rightmenu-master (jaywcjlove/rightmenu-master) ⭐ 322

**仓库**: https://github.com/jaywcjlove/rightmenu-master

- 只包含 README（README.md / README.zh.md / i18n）
- SwiftUI 编写
- 实际代码可能在其他仓库或私有不公开

### 5. OpenInTerminal (Ji4n1ng/OpenInTerminal) ⭐ 6600+

**仓库**: https://github.com/Ji4n1ng/OpenInTerminal

- 最受欢迎的 Finder 扩展工具
- 主要作为 **Finder Toolbar** 而非右键菜单
- 支持多种终端和编辑器
- 通过 Homebrew 分发（`brew install --cask openinterminal`）

---

## 关键架构模式总结

### 1. 菜单构建方式

| 方式 | 使用项目 | 优点 | 缺点 |
|------|---------|------|------|
| `NSMenuItem` + target/action | RClick, MenuHelper, FinderUtilities | 灵活，支持 tag/tooltip/子菜单 | 略多代码量 |
| `FIMenuItem` 数组 | 官方示例 | 简单 | 功能受限 |

结论：**所有实际项目都使用 `NSMenuItem`**，而非 `FIMenuItem`。

### 2. IPC 通信模式

```
Extension                         Container App
   │                                   │
   │  DistributedNotificationCenter    │
   │  ───── heartbeat ────────────────>│
   │  <───── running + dirs ──────────│
   │  ───── menu action ─────────────>│
   │  <───── quit ────────────────────│
   │                                   │
   │  (action 在 Container 内         │
   │   用 Process/NSWorkspace 执行)    │
```

### 3. 目录权限策略

| 策略 | 项目 | 效果 | 审核风险 |
|------|------|------|---------|
| 无沙箱 + App-Scope Bookmark | RClick | 用户选择目录后持久化 | 可能无法上架 MAS |
| 沙箱 + 根目录只读临时例外 | MenuHelper | Extension 可读所有路径，但不可写 | MAS 可能被拒 |
| 沙箱 + User Selected R/W | 默认 | 只能操作用户交互的文件 | 安全但限制大 |
| 无沙箱（不开启） | FinderUtilities | 可访问任何路径 | 无法上架 MAS |

### 4. 用户选中文件获取策略

```swift
FIFinderSyncController.default().selectedItemURLs()  // 选中的文件列表
FIFinderSyncController.default().targetedURL()        // 右键点击的目标
```

| 菜单类型 | selectedItemURLs | targetedURL |
|---------|-----------------|-------------|
| `.contextualMenuForItems` | ✅ 选中的文件 | ✅ 点击的文件 |
| `.contextualMenuForContainer` | ❌ nil | ✅ 当前目录 |
| `.toolbarItemMenu` | ⚠️ 也可能 nil | ✅ 当前目录 |

### 5. `directoryURLs` 设置策略

```swift
// 策略1: 监听所有路径
FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

// 策略2: 监听用户目录
FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/Users/")]

// 策略3: Container 通过 IPC 动态下发目录列表
// Extension: messager.on("running") { payload in
//     FIFinderSyncController.default().directoryURLs = Set(payload.target.map { URL(fileURLWithPath: $0) })
// }
```

**注意**: `directoryURLs` 决定了菜单在哪些目录的右键菜单中出现。设置为 `/` 或用户目录的上级目录通常能覆盖大部分场景。

---

## 对 mac-right-menu 的参考意义

### 推荐方案

1. **菜单位置**: 使用 `directoryURLs = [URL(fileURLWithPath: "/")]`（全局生效）或通过设置动态控制
2. **菜单构建**: 使用 `NSMenuItem` + target/action，不用 `FIMenuItem`
3. **IPC**: 使用 `DistributedNotificationCenter` 实现 Extension → Container 通信
4. **架构**: 参考 MenuHelper 的 Shared/ 共享代码模式，用协议抽象
5. **持久化**: 参考 RClick 使用 SwiftData + App Group
6. **安全域**: 如果需要 MAC App Store 发布，使用沙箱 + `com.apple.security.files.bookmarks.app-scope`
7. **目录访问策略**: 参考 RClick 的 App-Scope Bookmark 模式（用户选择设置中的目录后持久化）

### 不推荐方案

1. ❌ 直接使用 `FIMenuItem`（功能受限）
2. ❌ Extension 内直接弹 NSAlert/NSOpenPanel（Sandbox 限制 + 体验差）
3. ❌ 使用 `keyEquivalent`（Finder 忽略）
4. ❌ Extension 内直接写文件系统（除非绝对必要，应在 Container 侧操作）
