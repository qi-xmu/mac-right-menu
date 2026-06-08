# 菜单系统设计

> 日期: 2026-06-08
> 状态: 设计中

## 概述

mac-right-menu 的右键菜单由 Container App（设置 UI）配置，Finder Extension 负责在 Finder 中渲染。两者通过 App Group 共享配置数据。

## 架构

```
┌─────────────────┐         ┌──────────────────────────────────┐
│  Container App  │         │        Finder Extension           │
│                 │  写入    │                                  │
│  Settings UI ───┼────────►│  App Group UserDefaults          │
│                 │         │      │                            │
│  用户修改配置    │  通知    │      ├── menu(for:) 时读取配置     │
│      │          │────────►│      │     → MenuBuilder 构造 NSMenu│
│      ▼          │  DNC    │      │                            │
│  save()         │         │      └── 点击 → MenuActionHandler  │
└─────────────────┘         │              → CommandRequest → IPC│
                            └──────────────────────────────────┘
```

## 配置传递

### 数据通道：App Group UserDefaults

Container App 和 Extension 配置相同的 App Group ID（`group.com.qi-xmu.mac-right-menu`），通过 `UserDefaults(suiteName:)` 共享同一份存储。

```swift
// 写（Container App）
SharedUserDefaults.menuConfiguration = config  // JSON 编码 → plist

// 读（Extension）
let config = SharedUserDefaults.menuConfiguration  // plist → JSON 解码
```

### 信号通道：DistributedNotificationCenter

Container App 修改配置后发送通知，Extension 收到通知后在下一次 Finder 调用 `menu(for:)` 时刷新。

```
用户修改配置
    → SharedUserDefaults.menuConfiguration = config
    → SettingsSync.postSettingsChanged()     // DNC 通知
                                          ↓
Extension: observeSettingsChanged { ... }    // 收到通知
    → 标记配置已过期 / 刷新缓存
    → 下次 menu(for:) 使用最新配置
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
3. **区间判断**：`MenuActionHandler` 对每个 tag 做上下界检查（如 `2000 <= tag < 3000`），防止无限吞 tag

## 配置读取策略

### 方案 A：每次实时读取（当前实现）

每次 Finder 调用 `menu(for:)` 时从 UserDefaults 实时解码配置：

```
menu(for:) 被调用
    → SharedUserDefaults.menuConfiguration
        → UserDefaults.data(forKey:)       // ~0.01ms，plist 已在内存
        → JSONDecoder().decode(...)        // ~0.1ms，结构体 < 3KB
    → MenuBuilder.buildMenu(config)
```

**耗时**：< 0.2ms，对右键菜单响应无感知。

| 维度 | 评价 |
|------|------|
| 每次右键开销 | ~0.1ms JSON 解码 |
| 状态管理 | 无状态，无缓存同步问题 |
| 线程安全 | 无需处理（每次本地读取） |
| 内存 | 配置不常驻 Extension 内存 |
| bug 风险 | 低 |

### 方案 B：Extension 缓存 + 通知刷新

Extension 在 `init` 时加载配置到内存，收到 DNC 设置变更通知时刷新缓存，`menu(for:)` 直接读缓存：

```
init():
    cachedConfig = SharedUserDefaults.menuConfiguration

observeSettingsChanged:
    cachedConfig = SharedUserDefaults.menuConfiguration   // 通知触发

menu(for:):
    直接使用 cachedConfig   // 零 I/O，零解码
```

| 维度 | 评价 |
|------|------|
| 每次右键开销 | 0（纯内存读取） |
| 状态管理 | 需维护缓存 + 失效逻辑 |
| 线程安全 | 需同步（DNC 回调线程 ≠ menu 调用线程） |
| 内存 | 配置常驻 Extension 内存 |
| bug 风险 | 中（缓存过期、竞态） |

**实现要点**：
1. `FinderSync` 持有 `cachedConfig: MenuConfiguration`
2. `init()` 中加载初始值
3. DNC 回调中刷新缓存（需处理线程同步）
4. Extension 被 Finder 唤醒时可能跳过 `init()`，需在 `menu(for:)` 首调用时惰性加载

### 方案选择

当前采用方案 A，理由：

- 配置体积极小（< 3KB），实时解码开销可忽略
- 零状态设计，不会出现缓存不同步
- Apple `FIFinderSync` 文档建议不在 `menu(for:)` 中执行重 I/O，但 UserDefaults 读取不属于重 I/O

未来若配置体量显著增长（如支持 50+ 模板、100+ App），可切换到方案 B。

## 涉及文件

| 文件 | 职责 |
|------|------|
| `Shared/Preferences/MenuConfiguration.swift` | 菜单配置数据模型 |
| `Shared/Preferences/SharedUserDefaults.swift` | App Group 读写封装 |
| `Shared/IPC/SettingsSync.swift` | DNC 通知发送/监听 |
| `Shared/Constants.swift` | tag 编码常量 |
| `FinderExtension/FinderSync.swift` | Extension 入口，实现 `menu(for:)` |
| `FinderExtension/MenuBuilder.swift` | NSMenu 构造 |
| `FinderExtension/MenuActionHandler.swift` | 菜单点击 → CommandRequest |
| `Shared/Models/CommandRequest.swift` | IPC 指令结构 |
| `mac-right-menu/ViewModels/AppState.swift` | Container App 状态管理 + 指令执行 |
