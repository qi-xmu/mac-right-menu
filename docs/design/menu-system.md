# 菜单系统设计

> 日期: 2026-06-08（初版）
> 更新: 2026-06-23（同步菜单树重构：MenuConfiguration → AppConfig/MenuConfig + ActionDefMap；CommandRequest → MenuAction；MenuActionHandler 已移除）
> 状态: 已实现

## 概述

mac-right-menu 的右键菜单由 Container App（设置 UI）配置，Finder Extension 负责在 Finder 中渲染。两端 `UserDefaults.standard` 隔离（App Group 共享已否决），所以 Extension 不读自己的 store —— 配置经 RPC 同步：连接时 `getConfig` 拉取 `MenuConfig`，运行期间 `configDidChange` 推送，缓存到 Extension 内存。Container 持有完整 `AppConfig`（`MenuConfig` + `ActionDefMap`），只把 `menu` 半推给 Extension；`actions` 半始终在 Container 内，点击时按 `actionID` 查表执行。

## 架构

```
┌───────────────────────┐          ┌──────────────────────────────────────┐
│     Container App      │          │        Finder Extension              │
│                        │          │                                      │
│  Settings UI           │          │  cachedConfig: MenuConfig        │
│     │                  │ 持久化    │     │  (初始 .default)              │
│     ▼                  │ (各自     │     ├── rebuildCachedMenu()        │
│  saveConfiguration()   │  独立     │     │   → 构建完整 NSMenu 缓存       │
│     ├── SharedUser     │  store)  │     │   → 配置变更 / 外观切换时重建   │
│     │   Defaults       │          │     │                                │
│     └── broadcastConfig│ getConfig │     ├── menu(for:)                 │
│         (configDidChange)│ ←─────►│     │   → 读 cachedMenu (NSLock)    │
│         pushes MenuConfig │       │     │   → refreshSelectionState()    │
└───────────────────────┘          │     │   → refreshSelectionState()    │
                                   │     │   → 低成本按点击刷新选中状态     │
                                   │     │                                │
                                   │     └── handleMenuAction()          │
                                   │          → configLock 加锁读配置      │
                                   │          → MenuAction → RPC          │
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
│  cachedConfig: MenuConfig  ← 配置快照（configLock）         │
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

Container App 和 Extension 各自维护自己的 `UserDefaults.standard` store（**非 App Group 共享**）。`SharedUserDefaults` 封装了对该 store 的读写。Container 用它持久化 `AppConfig`（`menu` + `actions`）；Extension **不读自己的 store**（两端隔离，读到的不是 Container 的配置），配置完全经 RPC 获取 `MenuConfig`。

```swift
// Container App — 持久化到自己的 store
SharedUserDefaults.appConfig = config   // AppConfig (MenuConfig + ActionDefMap)

// Extension — cachedConfig 初始为 MenuConfig.default，RPC 连接后由 getConfig/configDidChange 刷新
private var cachedConfig: MenuConfig = .default   // 连接前临时值
private let configLock = NSLock()
```

### 同步策略：连接时拉取 + RPC 实时推送 + 菜单重建

Extension 不读自己的 store（两端 store 隔离，读到的不是 Container 的配置）。`MenuConfig` 完全经 RPC 同步，两条通道共用同一个 `onConfigChange` 处理器：

```
Extension: init()
    → cachedConfig = MenuConfig.default（临时值，连接前兜底）
    → rpcClient.setConfigChangeHandler { newConfig in
          configLock.lock(); cachedConfig = newConfig; configLock.unlock()
          rebuildCachedMenu()   // 配置变更后重建完整菜单缓存
      }
    → rpcClient.connect()
        → .ready → fetchConfig() → getConfig 请求 → Container 回当前 MenuConfig → onConfigChange → rebuildCachedMenu()

Container 改配置: saveConfiguration()
    → rpcServer.broadcastConfig(config.menu)  // 只推送 MenuConfig，ActionDefMap 不发 Extension
    → 已连接 Extension 收到 configDidChange → onConfigChange（NSLock 保护）→ rebuildCachedMenu()

menu(for:): 加锁读 cachedMenu 快照    // 零 I/O、零图像解码
    → refreshSelectionState()          // 仅更新 isHidden / isEnabled
```

> **实时性**：Extension 一旦 RPC 连上，立即经 `getConfig` 拿到 Container 当前 `MenuConfig` 并重建菜单缓存；之后 Container 运行期间的变更由 `configDidChange` 实时推送，下次右键即生效。
> **边界**：RPC 连接建立前 `cachedConfig` 是 `MenuConfig.default`（空菜单）。连接建立后立即刷新为真实配置并重建缓存。
> **动作执行**：Extension 不持有 `ActionDefMap`，点击时只发 `actionID` 给 Container；Container 按 `ActionDefMap[actionID]` 查表执行。configDidChange 推送的也是 `MenuConfig`（菜单树），不含动作定义。

### Extension 端使用

```swift
// FinderSync.swift
private var cachedConfig: MenuConfig = .default
private var cachedMenu: NSMenu?
private let menuLock = NSLock()

override func menu(for menuKind: FIMenuKind) -> NSMenu {
    // 支持两种上下文：选中文件的右键 / 文件夹空白区域的右键
    guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer
    else { return NSMenu() }

    menuLock.lock()
    let menu = cachedMenu
    menuLock.unlock()

    guard let menu else {
        // 兜底：缓存未就绪（等待首次 getConfig），用默认配置构建
        return MenuBuilder.buildMenu(config: .default, ...)
    }

    // 低成本按点击刷新：仅更新选中相关菜单项的显隐/启用状态
    let context = /* classify selection as .file or .dir */
    MenuBuilder.refreshSelectionState(menu, context: context, selectedCount: ...)
    return menu
}

@objc func handleMenuAction(_ sender: NSMenuItem) {
    // actionID 直接从 tag 获取，不再解析 tag 语义
    let action = MenuAction(actionID: sender.tag, targetURL: targetURL, selectedURLs: selectedURLs)
    rpcClient.executeAction(action) { result in ... }
}
```

## 菜单结构与上下文

### 上下文类型

| FIMenuKind | 场景 | context | 菜单行为 |
|------------|------|---------|----------|
| `.contextualMenuForItems` | 右键选中的文件/文件夹 | `.file` 或 `.dir`（取决于选中项类型） | 完整菜单（新建文件 + Open With + 操作） |
| `.contextualMenuForContainer` | 右键文件夹空白区域 | `.dir` | 仅显示 showCondition 为 `.isDir` 或 `.both` 的项 |
| 其他（sidebar/toolbar/window） | 不相关 | — | 返回空菜单 |

### 菜单结构

菜单结构完全由 `MenuConfig`（递归 `MenuItem` 树）驱动。`MenuBuilder` 是结构无关的通用渲染器——它不知道什么是"新建文件"或"打开方式"，只把树渲染成 `NSMenu`。每个叶子节点携带 `actionID`，Container 通过 `ActionDefMap[actionID]` 查表执行。

默认种子配置（`AppConfig.default`）的布局：

```
mac-right-menu
├─ 新建文件 (New File)          ← 子菜单头，showCondition=.isDir
│   ├─ 未命名.txt               ← actionID 0
│   ├─ 未命名.md                ← actionID 1
│   └─ ...
├─ Open With                    ← 子菜单头，showCondition=.both
│   ├─ Terminal                 ← actionID 1000
│   ├─ VS Code                  ← actionID 1001
│   └─ ...
├─ Copy Path                    ← 叶子，actionID 2000
├─ Copy File Name               ← 叶子，actionID 2001
└─ Toggle Hidden                ← 叶子，actionID 2002
```

每个 `MenuItem` 携带 `showCondition`（`.isFile`/`.isDir`/`.both`）和 `multiItemSupport` 元数据。`refreshSelectionState` 遍历顶层菜单项，根据当前 `TargetContext` 和选中数量，用这些元数据决定 `isHidden`/`isEnabled`。

- **showCondition `.isDir`**（如 New File）：仅在文件夹上下文（选中文件夹或空白处）显示
- **showCondition `.both`**（如 Open With、Copy Path）：文件和文件夹上下文都显示
- **showCondition `.isFile`**：仅在选中文件时显示

### refreshSelectionState 机制

`menu(for:)` 每次右键时调用 `MenuBuilder.refreshSelectionState(menu, context:, selectedCount:)`，仅更新依赖选中状态的属性：

```swift
static func refreshSelectionState(_ menu: NSMenu, context: TargetContext, selectedCount: Int) {
    for item in menu.items {
        guard let meta = item.representedObject as? NodeMeta else { continue }
        let condOK: Bool = switch meta.showCondition {
            case .isFile: context == .file
            case .isDir:  context == .dir
            case .both:   true
        }
        let multiOK = meta.multiItemSupport || selectedCount <= 1
        item.isHidden = !(condOK && multiOK)
        item.isEnabled = condOK && multiOK
    }
}
```

**开销**：仅遍历顶层菜单项（通常 < 10 项），每项读 `representedObject` 做两次属性写入。比每次重建整个 NSMenu 树（图像解码 + 位图光栅化）快 100x+。

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

菜单项点击通过 `NSMenuItem.tag` 携带 `actionID`。Extension 不解释 actionID 的语义——它直接把 tag 值通过 `MenuAction` 发给 Container，Container 按 `ActionDefMap[actionID]` 查表执行：

```
actionID 范围   ActionDef 类型              来源
───────────    ─────────────              ────
0–999          .newFile(template:)        AppConfig.default 种子 + 用户自定义
1000–1999      .openWith(app:)            用户在 Settings > Apps 添加
2000–2999      .general(operation:)       固定：2000=copyPath, 2001=copyFileName, 2002=toggleHidden
4000–4999      .custom(command:)          预留（未实现）
```

### 编码原则

1. **叶子节点携带真实 actionID**：子菜单头的 `actionID` 不被派发（渲染器不给非叶子节点设 action selector）
2. **按类型分段**：`Constants.TagBase` 定义区间起点，区间内递增
3. **Container 查表派发**：`ActionDefMap[actionID]` 一次字典查找，miss 记日志忽略

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

Extension 不读自己的 store（两端隔离），`cachedConfig` 初始为 `MenuConfig.default`（空菜单），RPC 连接 `.ready` 时经 `getConfig` 拉取 Container 当前 `MenuConfig`，运行期间经 `configDidChange` 推送刷新。每次配置变更触发 `rebuildCachedMenu()`。`menu(for:)` 读 `cachedMenu`（加锁）。

```
Extension: init()
    → cachedConfig = MenuConfig.default（临时值）
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
| `FinderExtension/FinderSync.swift` | Extension 入口：菜单缓存管理、configChangeHandler、rebuildCachedMenu()、menu(for:)、handleMenuAction() 构造 `MenuAction` 发送 |
| `FinderExtension/MenuBuilder.swift` | 结构无关的通用 NSMenu 构建器（递归 `MenuItem` 树）、图标缓存 (symbolCache/appIconCache)、refreshSelectionState() |
| `Shared/Models/MenuConfig.swift` | 菜单配置数据模型（`MenuConfig` + `MenuItem` 树 + `ShowCondition` + `MenuIcon`） |
| `Shared/Models/AppConfig.swift` | 持久化根（`AppConfig` = `MenuConfig` + `ActionDefMap`） |
| `Shared/Models/ActionDef.swift` | 动作定义（`ActionDef` 枚举 + `ActionDefMap` + `GeneralOperation`） |
| `Shared/Models/MenuAction.swift` | Extension → Container 的点击载荷（`actionID` + `targetURL` + `selectedURLs`） |
| `Shared/Preferences/SharedUserDefaults.swift` | UserDefaults 读写封装（各自独立 store，`appConfig` 键） |
| `Shared/Constants.swift` | actionID 编码常量 (`TagBase`) + RPC 端口常量 |
| `Shared/RPC/RPCSession.swift` | JSON-RPC over TCP（RPCServer + RPCClient） |
| `mac-right-menu/ViewModels/AppState.swift` | Container App 状态管理，持有 `RPCServer` + `ActionDefMap`，实现 `executeAction` 查表派发 |
