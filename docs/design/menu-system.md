# 菜单系统设计

> 日期: 2026-06-08（初版）
> 更新: 2026-06-17（菜单缓存 + 图标缓存 + 容器上下文支持 + 外观切换感知；配置同步：连接时 getConfig 拉取 + RPC configDidChange 实时推送；不再读各自 store）
> 状态: 已实现

## 概述

mac-right-menu 的右键菜单由 Container App（设置 UI）配置，Finder Extension 负责在 Finder 中渲染。两端 `UserDefaults.standard` 隔离（App Group 共享已否决），所以 Extension 不读自己的 store —— 配置经 RPC 同步：连接时 `getConfig` 拉取，运行期间 `configDidChange` 推送，缓存到 Extension 内存。

## 架构

```
┌───────────────────────┐          ┌──────────────────────────────────────┐
│     Container App      │          │        Finder Extension              │
│                        │          │                                      │
│  Settings UI           │          │  cachedConfig: MenuConfiguration     │
│     │                  │ 持久化    │     │  (初始 .default)              │
│     ▼                  │ (各自     │     ├── rebuildCachedMenu()        │
│  saveConfiguration()   │  独立     │     │   → 构建完整 NSMenu 缓存       │
│     ├── SharedUser     │  store)  │     │   → 配置变更 / 外观切换时重建   │
│     │   Defaults       │          │     │                                │
│     └── broadcastConfig│ getConfig │     ├── menu(for:)                 │
│         (configDidChange)│ ←─────►│     │   → 读 cachedMenu (NSLock)    │
└───────────────────────┘          │     │   → refreshSelectionState()    │
                                   │     │   → 低成本按点击刷新选中状态     │
                                   │     │                                │
                                   │     └── handleMenuAction()          │
                                   │          → configLock 加锁读配置      │
                                   │          → CommandRequest → RPC      │
                                   └──────────────────────────────────────┘
```

## 菜单缓存机制

### 设计动机

`menu(for:)` 由 Finder 在**每次右键**时调用。菜单构建的开销主要在图像生成（SF Symbol 着色 + 应用图标光栅化），而非 NSMenuItem 分配。这些图像在同一配置下是不变的纯函数输出，所以：

- **菜单结构缓存**：`cachedMenu` 在配置变更 / 外观切换时构建一次，后续右键复用同一 NSMenu 对象
- **图标缓存**：`symbolCache` 和 `appIconCache` 缓存已渲染的位图，跳过重复的 `lockFocus` 光栅化
- **按点击刷新**：`refreshSelectionState()` 只更新选中相关菜单项的 `isHidden`/`isEnabled`，是低成本的属性写入

### 缓存层级

```
┌─────────────────────────────────────────────────────────────┐
│ FinderSync.swift                                            │
│                                                             │
│  cachedMenu: NSMenu?    ← 完整菜单对象（配置变更时重建）     │
│  menuLock: NSLock       ← 保护 cachedMenu 读写              │
│  cachedConfig: MenuConfiguration  ← 配置快照（configLock）   │
│  configLock: NSLock     ← 保护 cachedConfig 读写            │
└─────────────────────────┬───────────────────────────────────┘
                          │ rebuildCachedMenu()
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ MenuBuilder.swift                                           │
│                                                             │
│  symbolCache: [String: NSImage]  ← SF Symbol 着色位图缓存  │
│  appIconCache: [String: NSImage] ← 应用图标缓存             │
│  invalidateSymbolCache()         ← 外观切换时清除 symbol    │
│  refreshSelectionState()         ← 按点击刷新选中状态       │
└─────────────────────────────────────────────────────────────┘
```

### 线程模型

两个并发源访问缓存：

| 缓存 | 写入方 | 读取方 | 保护方式 |
|------|--------|--------|----------|
| `cachedMenu` | `rebuildCachedMenu()`（config 回调 / 外观切换，RPC 后台线程） | `menu(for:)`（Finder 线程） | `menuLock`（NSLock） |
| `cachedConfig` | `onConfigChange`（RPC 后台线程） | `menu(for:)`、`handleMenuAction()`（Finder 线程） | `configLock`（NSLock） |
| `symbolCache` | `icon()` / `invalidateSymbolCache()`（Finder 线程 / .main） | `icon()`（Finder 线程） | 单线程访问保证（`nonisolated(unsafe)`） |
| `appIconCache` | `appIcon(forPath:)`（Finder 线程） | `appIcon(forPath:)`（Finder 线程） | 单线程访问保证（`nonisolated(unsafe)`） |

### 缓存重建触发

| 触发条件 | 触发者 | 重建范围 |
|----------|--------|----------|
| 配置变更（`configDidChange` / `getConfig`） | `onConfigChange` 回调 | `rebuildCachedMenu()` → 完整 NSMenu 重建 |
| 外观切换（Dark↔Light） | `DistributedNotificationCenter` 监听 `AppleInterfaceThemeChangedNotification` | `rebuildCachedMenu()` → NSMenu 重建（图标着色随主题变化） |
| 首次右键（缓存未就绪） | `menu(for:)` 兜底 | 直接调用 `MenuBuilder.buildMenu(.default, ...)` 返回 |

### 外观切换感知

Extension 注册 `DistributedNotificationCenter` 监听 `AppleInterfaceThemeChangedNotification`：

```swift
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.rebuildCachedMenu()
}
```

外观切换改变 SF Symbol 的着色颜色（Dark→白色, Light→黑色）。由于着色位图烘焙在缓存的 NSMenuItem 中，切换时必须重建整个菜单对象。应用图标（`NSWorkspace.shared.icon(forFile:)`）与外观无关，仅清除 `symbolCache`。

## 配置传递

### 存储：各自独立的 UserDefaults

Container App 和 Extension 各自维护自己的 `UserDefaults.standard` store（**非 App Group 共享**）。`SharedUserDefaults` 封装了对该 store 的读写。Container 用它持久化配置；Extension **不读自己的 store**（两端隔离，读到的不是 Container 的配置），配置完全经 RPC 获取。

```swift
// Container App — 持久化到自己的 store
SharedUserDefaults.menuConfiguration = config

// Extension — cachedConfig 初始为 .default，RPC 连接后由 getConfig/configDidChange 刷新
private var cachedConfig: MenuConfiguration = .default   // 连接前临时值
private let configLock = NSLock()
```

### 同步策略：连接时拉取 + RPC 实时推送 + 菜单重建

Extension 不读自己的 store（两端 store 隔离，读到的不是 Container 的配置）。配置完全经 RPC 同步，两条通道共用同一个 `onConfigChange` 处理器：

```
Extension: init()
    → cachedConfig = .default（临时值，连接前兜底）
    → rpcClient.setConfigChangeHandler { newConfig in
          configLock.lock(); cachedConfig = newConfig; configLock.unlock()
          rebuildCachedMenu()   // 配置变更后重建完整菜单缓存
      }
    → rpcClient.connect()
        → .ready → fetchConfig() → getConfig 请求 → Container 回当前配置 → onConfigChange → rebuildCachedMenu()

Container 改配置: saveConfiguration()
    → rpcServer.broadcastConfig(config)
    → 已连接 Extension 收到 configDidChange → onConfigChange（NSLock 保护）→ rebuildCachedMenu()

menu(for:): 加锁读 cachedMenu 快照    // 零 I/O、零图像解码
    → refreshSelectionState()          // 仅更新 isHidden / isEnabled
```

> **实时性**：Extension 一旦 RPC 连上，立即经 `getConfig` 拿到 Container 当前配置并重建菜单缓存；之后 Container 运行期间的变更由 `configDidChange` 实时推送，下次右键即生效。
> **边界**：RPC 连接建立前 `cachedConfig` 是 `.default`（此时右键只显示默认菜单）。连接建立后立即刷新为真实配置并重建缓存。

### Extension 端使用

```swift
// FinderSync.swift
private var cachedConfig: MenuConfiguration = .default
private var cachedMenu: NSMenu?
private let menuLock = NSLock()

override func menu(for menuKind: FIMenuKind) -> NSMenu {
    // 支持两种上下文：选中文件的右键 / 文件夹空白区域的右键
    guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer
    else { return NSMenu() }

    let hasSelection = FIFinderSyncController.default().selectedItemURLs()?.isEmpty == false

    menuLock.lock()
    let menu = cachedMenu
    menuLock.unlock()

    guard let menu else {
        // 兜底：缓存未就绪（等待首次 getConfig），用默认配置构建
        return MenuBuilder.buildMenu(configuration: .default, ...)
    }

    // 低成本按点击刷新：仅更新选中相关菜单项的显隐/启用状态
    MenuBuilder.refreshSelectionState(menu, hasSelection: hasSelection)
    return menu
}

@objc func handleMenuAction(_ sender: NSMenuItem) {
    // configLock 加锁读 cachedConfig 快照，确保线程安全
    configLock.lock()
    let config = cachedConfig
    configLock.unlock()
    MenuActionHandler.handleMenuAction(sender, ..., config: config, client: rpcClient)
}
```

## 菜单结构与上下文

### 上下文类型

| FIMenuKind | 场景 | hasSelection | 菜单行为 |
|------------|------|-------------|----------|
| `.contextualMenuForItems` | 右键选中的文件/文件夹 | `true` | 完整菜单（新建文件 + Open With + 操作） |
| `.contextualMenuForContainer` | 右键文件夹空白区域 | `false` | 仅显示 New File（Open With 和操作被隐藏） |
| 其他（sidebar/toolbar/window） | 不相关 | — | 返回空菜单 |

### 菜单结构

```
mac-right-menu
├─ 新建文件 (New File)          ← 子菜单，列出模板（始终显示）
│   ├─ 未命名.txt
│   ├─ 未命名.md
│   └─ ...
├─ Open With                    ← 单 item 或子菜单（仅选中文件时显示）
│   ├─ VS Code
│   ├─ Zed
│   └─ ...
└─ 操作                         ← 仅选中文件时显示
    ├─ 复制路径 (Copy Path)
    ├─ 复制文件名 (Copy File Name)
    └─ 切换隐藏 (Toggle Hidden)
```

分组顺序固定：新建文件 → Open With → 通用操作。

- **New File**：在两种上下文都构建，`refreshSelectionState` 不改变其显隐
- **Open With**：构建时 `isEnabled = hasSelection`；容器上下文中 `refreshSelectionState` 将其隐藏
- **操作**：同 Open With，容器上下文中被隐藏

### refreshSelectionState 机制

`menu(for:)` 每次右键时调用 `refreshSelectionState(menu, hasSelection:)`，仅更新依赖选中状态的属性：

```swift
static func refreshSelectionState(_ menu: NSMenu, hasSelection: Bool) {
    for item in menu.items {
        let tag = item.tag
        if tag >= Constants.TagBase.appItem.rawValue && tag < Constants.TagBase.shell.rawValue {
            // Open With (1000–1999)
            item.isHidden = !hasSelection
            item.isEnabled = hasSelection
        } else if tag >= Constants.TagBase.copyPath.rawValue && tag < Constants.TagBase.shell.rawValue {
            // 操作 (2000–2999)
            item.isHidden = !hasSelection
            item.isEnabled = hasSelection
        }
        // New File (0–999) 不变
    }
}
```

**开销**：仅遍历顶层菜单项（通常 < 10 项），每项做两次属性写入。比每次重建整个 NSMenu 树（图像解码 + 位图光栅化）快 100x+。

## 图标缓存

### SF Symbol 缓存 (symbolCache)

```swift
nonisolated(unsafe) private static var symbolCache: [String: NSImage] = [:]
```

- Key: symbol name（如 `"doc.badge.plus"`）
- Value: 着色后的 18×18 位图（`lockFocus` + `draw(in:)` 渲染）
- 命中时直接返回，跳过 `NSImage(systemSymbolName:)` + 着色 + 光栅化
- 外观切换时调用 `invalidateSymbolCache()` 清除全部缓存（着色颜色随主题变化）

### 应用图标缓存 (appIconCache)

```swift
nonisolated(unsafe) private static var appIconCache: [String: NSImage] = [:]
```

- Key: 应用绝对路径（如 `"/Applications/Visual Studio Code.app"`）
- Value: `NSWorkspace.shared.icon(forFile:)` 返回的图标
- 命中时跳过磁盘读取 + 光栅化；应用安装期间图标不变，缓存安全

### 缓存失效

| 缓存 | 失效条件 | 失效方式 |
|------|----------|----------|
| `symbolCache` | 外观切换 (Dark↔Light) | `invalidateSymbolCache()` → `removeAll()` |
| `appIconCache` | 永不失效（进程生命周期内） | 不清除；应用卸载/重装后路径变化自然 miss |
| `cachedMenu` | 配置变更 / 外观切换 | `rebuildCachedMenu()` → 新 NSMenu 对象替换 |

## 分发编码

菜单项点击通过 `NSMenuItem.tag` 分发，避免字符串比较：

```
tag 范围       操作                      示例
───────       ────                      ────
0–999         新建文件模板               tag = 0 + templateIndex
1000–1999     Open With App             tag = 1000 + appIndex
2000–2999     通用操作                   tag = 2000 + offset
              ├─ 2000  copyPath
              ├─ 2001  copyFileName
              └─ 2002  toggleHidden
4000–4999     自定义命令 (shell)         tag = 4000 + shellIndex（未实现）
```

### 编码原则

1. **按菜单顺序排列**：tag 范围顺序 = 菜单分组顺序
2. **同组紧凑**：操作标签连续编码，不做千位跳跃
3. **区间判断**：`MenuActionHandler` 对每个 tag 做上下界检查，防止无限吞 tag

## 性能分析

| 维度 | 优化前 | 优化后 |
|------|--------|--------|
| 每次右键开销 | 构建完整 NSMenu + 图像解码 + 光栅化 | 读 cachedMenu 引用 + refreshSelectionState（< 10 项属性写入） |
| SF Symbol 渲染 | 每次右键重新 `lockFocus` + `draw(in:)` | 命中 symbolCache 直接返回缓存位图 |
| 应用图标读取 | 每次右键 `NSWorkspace.shared.icon(forFile:)` | 命中 appIconCache 跳过磁盘 I/O |
| 容器上下文 | 不支持 | 支持 `.contextualMenuForContainer`，New File 可在空白区域使用 |
| 外观切换 | 无感知，着色过时 | 监听主题变更通知，自动重建缓存菜单 |
| 配置同步延迟 | 每次右键重新构建 | 配置变更时重建缓存，后续右键零开销 |
| 内存 | 无缓存 | cachedMenu + symbolCache + appIconCache（估算 < 50KB） |

## 配置读取策略：连接时拉取 + 内存缓存 + RPC 推送

Extension 不读自己的 store（两端隔离），`cachedConfig` 初始为 `.default`，RPC 连接 `.ready` 时经 `getConfig` 拉取 Container 当前配置，运行期间经 `configDidChange` 推送刷新。每次配置变更触发 `rebuildCachedMenu()`。`menu(for:)` 读 `cachedMenu`（加锁）。

```
Extension: init()
    → cachedConfig = .default（临时值）
    → rpcClient.setConfigChangeHandler { 更新 cachedConfig（NSLock）→ rebuildCachedMenu() }
    → rpcClient.connect() → .ready → fetchConfig() → 刷新 cachedConfig → rebuildCachedMenu()

menu(for:): 加锁读 cachedMenu    // 零 I/O、零解码、零图像渲染
    → refreshSelectionState()      // 仅 isHidden / isEnabled 属性写入
```

| 维度 | 评价 |
|------|------|
| 每次右键开销 | 极低（读 NSMenu 引用 + < 10 项属性写入） |
| 同步延迟 | 连接时立即拉取 + 运行期间 configDidChange 实时推送 |
| 冷启动 | cachedMenu 暂为 nil，menu(for:) 兜底构建默认菜单；RPC 连上后重建缓存 |
| 缓存失效 | getConfig（连接时）+ configDidChange（变更时）+ 外观切换 → rebuildCachedMenu() |
| 线程安全 | configLock 保护 cachedConfig，menuLock 保护 cachedMenu（RPC 后台线程 vs Finder 线程） |
| 内存 | 配置 < 3KB + 菜单/图标缓存 < 50KB |

## 涉及文件

| 文件 | 职责 |
|------|------|
| `FinderExtension/FinderSync.swift` | Extension 入口：菜单缓存管理、configChangeHandler、rebuildCachedMenu()、menu(for:) |
| `FinderExtension/MenuBuilder.swift` | NSMenu 构建、图标缓存 (symbolCache/appIconCache)、refreshSelectionState() |
| `FinderExtension/MenuActionHandler.swift` | 菜单点击 → CommandRequest，通过 `RPCClient` 发送 |
| `Shared/Preferences/MenuConfiguration.swift` | 菜单配置数据模型 |
| `Shared/Preferences/SharedUserDefaults.swift` | UserDefaults 读写封装（各自独立 store） |
| `Shared/Constants.swift` | tag 编码常量 + RPC 端口常量 |
| `Shared/Models/CommandRequest.swift` | RPC 指令结构（Codable，RPC 层用 `RPCParams` 包装） |
| `Shared/RPC/RPCSession.swift` | JSON-RPC over TCP（RPCServer + RPCClient） |
| `mac-right-menu/ViewModels/AppState.swift` | Container App 状态管理，持有 `RPCServer`，实现 `executeCommand` |
