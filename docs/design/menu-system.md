# 菜单系统设计

> 日期: 2026-06-08（初版）
> 更新: 2026-06-16（配置同步：连接时 getConfig 拉取 + RPC configDidChange 实时推送；不再读各自 store）
> 状态: 已实现

## 概述

mac-right-menu 的右键菜单由 Container App（设置 UI）配置，Finder Extension 负责在 Finder 中渲染。两端 `UserDefaults.standard` 隔离（App Group 共享已否决），所以 Extension 不读自己的 store —— 配置经 RPC 同步：连接时 `getConfig` 拉取，运行期间 `configDidChange` 推送，缓存到 Extension 内存。

## 架构

```
┌───────────────────────┐          ┌─────────────────────────────────┐
│     Container App      │          │        Finder Extension         │
│                        │          │                                 │
│  Settings UI           │          │                                 │
│     │                  │ 持久化    │                                 │
│     ▼                  │ (各自     │  cachedConfig: MenuConfiguration│
│  saveConfiguration()   │  独立     │     │  (初始 .default)          │
│     ├── SharedUser     │  store)  │     ├── menu(for:) → 纯内存读取  │
│     │   Defaults       │          │     └── handleMenuAction()      │
│     └── broadcastConfig│ getConfig │          → CommandRequest → RPC │
│         (configDidChange)│ ←─────►│     onConfigChange → 更新缓存   │
└───────────────────────┘          └─────────────────────────────────┘
```

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

### 同步策略：连接时拉取 + RPC 实时推送

Extension 不读自己的 store（两端 store 隔离，读到的不是 Container 的配置）。配置完全经 RPC 同步，两条通道共用同一个 `onConfigChange` 处理器：

```
Extension: init()
    → cachedConfig = .default（临时值，连接前兜底）
    → rpcClient.setConfigChangeHandler { newConfig in
          configLock.lock(); cachedConfig = newConfig; configLock.unlock()
      }
    → rpcClient.connect()
        → .ready → fetchConfig() → getConfig 请求 → Container 回当前配置 → onConfigChange

Container 改配置: saveConfiguration()
    → rpcServer.broadcastConfig(config)
    → 已连接 Extension 收到 configDidChange → onConfigChange（NSLock 保护，因 menu(for:) 在 Finder 线程读）

menu(for:): 加锁读 cachedConfig 快照    // 零 I/O
```

> **实时性**：Extension 一旦 RPC 连上，立即经 `getConfig` 拿到 Container 当前配置；之后 Container 运行期间的变更由 `configDidChange` 实时推送，下次右键即生效。
> **边界**：RPC 连接建立前 `cachedConfig` 是 `.default`（此时右键只会显示默认菜单）。连接建立后立即刷新为真实配置。

### Extension 端使用

```swift
// FinderSync.swift
private var cachedConfig: MenuConfiguration = .default

override init() {
    super.init()
    cachedConfig = SharedUserDefaults.menuConfiguration   // 读一次
    // ...
}

override func menu(for menuKind: FIMenuKind) -> NSMenu {
    guard cachedConfig.isEnabled else { return NSMenu() }  // 纯内存读取
    return MenuBuilder.buildMenu(configuration: cachedConfig, ...)
}

@objc func handleMenuAction(_ sender: NSMenuItem) {
    MenuActionHandler.handleMenuAction(sender, ..., config: cachedConfig, client: rpcClient)
}
```

## 菜单结构

```
mac-right-menu
├─ 新建文件 (New File)          ← 子菜单，列出模板
│   ├─ newfile.txt
│   ├─ newfile.md
│   └─ ...
├─ Open With                    ← 单 item 或子菜单
│   ├─ VS Code
│   ├─ Zed
│   └─ ...
└─ 操作
    ├─ 复制路径 (Copy Path)
    ├─ 复制文件名 (Copy File Name)
    ├─ 切换隐藏 (Toggle Hidden)
    └─ 打开父目录 (Open Parent)
```

分组顺序固定：新建文件 → Open With → 通用操作。每组的显隐由配置中的 `isEnabled` 控制。

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
              ├─ 2002  toggleHidden
              └─ 2003  openParent
4000–4999     自定义命令 (shell)         tag = 4000 + shellIndex
```

### 编码原则

1. **按菜单顺序排列**：tag 范围顺序 = 菜单分组顺序
2. **同组紧凑**：操作标签连续编码，不做千位跳跃
3. **区间判断**：`MenuActionHandler` 对每个 tag 做上下界检查，防止无限吞 tag

## 配置读取策略：连接时拉取 + 内存缓存 + RPC 推送

Extension 不读自己的 store（两端隔离），`cachedConfig` 初始为 `.default`，RPC 连接 `.ready` 时经 `getConfig` 拉取 Container 当前配置，运行期间经 `configDidChange` 推送刷新。`menu(for:)` 纯内存读取（加锁）。

```
Extension: init()
    → cachedConfig = .default（临时值）
    → rpcClient.setConfigChangeHandler { 更新 cachedConfig（NSLock） }
    → rpcClient.connect() → .ready → fetchConfig() → 刷新 cachedConfig

menu(for:): 加锁读 cachedConfig    // 零 I/O、零解码
```

| 维度 | 评价 |
|------|------|
| 每次右键开销 | 0（纯内存读取，仅一次 NSLock 加解锁） |
| 同步延迟 | 连接时立即拉取 + 运行期间 configDidChange 实时推送 |
| 冷启动 | cachedConfig 暂为 `.default`，RPC 连上后立即刷新为真实配置 |
| 缓存失效 | getConfig（连接时）+ configDidChange（变更时）双通道刷新 |
| 线程安全 | configLock（NSLock）保护 cachedConfig 读写（RPC 回调在后台线程，menu(for:) 在 Finder 线程） |
| 内存 | 配置常驻 Extension 内存（< 3KB） |

## 涉及文件

| 文件 | 职责 |
|------|------|
| `Shared/Preferences/MenuConfiguration.swift` | 菜单配置数据模型 |
| `Shared/Preferences/SharedUserDefaults.swift` | UserDefaults 读写封装（各自独立 store） |
| `Shared/Constants.swift` | tag 编码常量 + RPC 端口常量 |
| `FinderExtension/FinderSync.swift` | Extension 入口，init 时缓存配置，实现 `menu(for:)` |
| `FinderExtension/MenuBuilder.swift` | NSMenu 构造 |
| `FinderExtension/MenuActionHandler.swift` | 菜单点击 → CommandRequest，通过 `RPCClient` 发送 |
| `Shared/Models/CommandRequest.swift` | RPC 指令结构（NSSecureCoding，RPC 层用 `RPCParams` 包装） |
| `Shared/RPC/RPCSession.swift` | JSON-RPC over TCP（RPCServer + RPCClient） |
| `mac-right-menu/ViewModels/AppState.swift` | Container App 状态管理，持有 `RPCServer`，实现 `executeCommand` |
