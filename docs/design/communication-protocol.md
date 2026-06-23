# 通信协议设计

> 日期: 2026-06-08（初版）
> 更新: 2026-06-17（双向心跳 Con→Ext + Ext→Con；自动拉起 Container/Extension；单实例 flock 锁）
> 状态: 已实现

## 概述

Extension 和 Container App 之间采用 **JSON-RPC 2.0 over TCP loopback** 通信。Extension（沙盒）通过 `RPCClient` 连接 Container（非沙盒）监听的 `127.0.0.1:57421`，将用户右键意图（`MenuAction`：actionID + Finder 选中文件）发送给 Container 按 `ActionDefMap` 查表执行。

### 为什么不用 XPC

本项目先后实测了三种 XPC 方案（mach service / XPC Service / 匿名 listener + endpoint 文件），均不可行，最终改用 TCP。完整否决表与排查历程见 `docs/design/xpc-architecture.md`（单一权威出处，不在各文档重复维护）。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                         Container App                       │
│  ┌─────────────────────┐      ┌──────────────────────────┐ │
│  │ RPCServer           │      │ AppState                 │ │
│  │ NWListener          │─────►│ + executeAction()        │ │
│  │ 127.0.0.1:57421     │      │   (文件操作，无沙盒)      │ │
│  │                     │      └──────────────────────────┘ │
│  │ onCommand 处理请求   │                                    │
│  └─────────┬───────────┘                                    │
└────────────┼────────────────────────────────────────────────┘
             │  TCP (JSON-RPC over \n-delimited JSON)
┌────────────┼────────────────────────────────────────────────┐
│            │              Finder Extension                   │
│  ┌─────────▼───────────┐      ┌──────────────────────────┐ │
│  │ RPCClient           │      │ FinderSync               │ │
│  │ NWConnection        │      │ + menu(for:)             │ │
│  │ → 127.0.0.1:57421   │      │ + handleMenuAction()     │ │
│  │                     │─────►│ + rebuildCachedMenu()    │ │
│  │ executeAction()     │      │                          │ │
│  │ 自动重连（2s）       │      │ cachedConfig (内存)       │ │
│  └─────────────────────┘      │ cachedMenu (NSMenu 缓存) │ │
│                               └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 角色

| 角色 | 组件 | 说明 |
|------|------|------|
| RPC Server | Container App | `RPCServer` 用 `NWListener` 监听 TCP，非沙盒无需额外 entitlement |
| RPC Client | Extension | `RPCClient` 用 `NWConnection` 连接，需 `network.client` entitlement |
| 调用方向（请求） | Extension → Container | `executeAction`（执行动作）、`getConfig`（连接时拉取配置）、`ping`（心跳保活） |
| 推送方向（通知） | Container → Extension | Container 改配置后广播 `configDidChange` notification（payload 携带 `MenuConfig`） |

Container 做 Server 的理由：
- Container 生命周期由用户控制（一直在线）→ 监听稳定
- Extension 由 Finder 按需启动 → 作为 client 连接/断开不影响 Container
- Container 非沙盒可自由监听端口；Extension 沙盒只需出站连接权限
- Container 持有 flock 锁保证单实例；Extension 通过 `kill(pid, 0)` 校验 Container 存活

## JSON-RPC 2.0 协议

### 请求（Extension → Container）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "executeAction",
  "params": {
    "actionID": 2,
    "targetURL": "file:///Users/qi/Documents",
    "selectedURLs": ["file:///Users/qi/Documents/test.txt"]
  }
}
```

### 响应（Container → Extension）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "success": true, "errorDescription": null }
}
```

### 字段映射

| JSON-RPC | Swift 类型 | 说明 |
|----------|-----------|------|
| `params` | `RPCActionParams` ↔ `MenuAction` | `actionID` 为整数，Container 通过 `ActionDefMap[actionID]` 查表派发 |
| `result` | `RPCResult` ↔ `CommandResult` | success + errorDescription |

### 传输约定

- **传输层**：TCP，`127.0.0.1:57421`（固定端口，定义在 `Constants.rpcPort`）
- **消息边界**：line-delimited JSON（每条消息以 `\n` 结尾）
- **用 `127.0.0.1` 而非 `localhost`**：避免沙盒内 `/etc/hosts` 解析问题

## 生命周期

### 1. 启动

```
Container App 启动
    → NSRunningApplication 快速检查（已有实例？）
    → flock() 原子锁（防竞争）
    → RPCServer.start()
    → NWListener(using: .tcp, on: 57421)
    → listener.start(queue: .global(qos: .utility))
    → startPingTimer()（Con→Ext 心跳）
    → 监听就绪，等待连接
    → checkExtensionRegistration()（异步 pluginkit 探测）
    → autoLaunchExtensions()（注册成功后自动拉起 autoLaunch 启用的 Extension）

Extension 被 Finder 唤醒 (init)
    → cachedConfig = MenuConfig.default（临时值，连接前兜底）
    → rpcClient.setConfigChangeHandler { 更新 cachedConfig（NSLock）}
    → RPCClient.connect()
    → NWConnection(to: 127.0.0.1:57421, using: .tcp)
    → conn.start()
    → 状态变为 .ready
        → receiveLoop() 开始
        → fetchConfig() → getConfig 请求 → Container 回当前 `MenuConfig` → 刷新 cachedConfig
        → sendHeartbeat()（立即首 ping）→ startHeartbeat()（1s 快速心跳 → 确认后 15s）
        → 可调用 executeAction
    → 若 Container 未运行，2 秒后自动重试（cachedConfig 暂留 .default）
    → 重试前自动后台拉起 Container（NSWorkspace.openApplication / open -b fallback）
```

### 2. 执行指令

```
用户右键 → handleMenuAction(sender, targetURL, selectedURLs)
    → 构造 MenuAction(actionID: sender.tag, targetURL:, selectedURLs:)
    → rpcClient.executeAction(action) { result in
          logger.notice("[RPC OK] ... → \(result.success ? "OK" : "FAIL")")
      }
```

RPCClient 内部：
1. 分配递增 id，记录 pending 回调
2. `RPCActionParams`（包装 `MenuAction`）编码为 JSON + `\n`，通过 TCP 发送
3. Container 的 `RPCServer.handleRequest` 收到后 dispatch → `onAction` 回调 → `AppState.executeAction` 按 `ActionDefMap[actionID]` 查表执行
4. Container 返回 `RPCResponse`，RPCClient 的 `receiveLoop` 匹配 id 调用回调

### 3. Container 不在时 Extension 被唤醒（自动拉起）

```
Finder 唤醒 Extension (init)
    → RPCClient.connect()
    → NWConnection 状态 .failed（Container 未运行，Connection refused）
        → resetAndRetry()
            → launchContainerIfNeeded()
                → NSWorkspace.urlForApplication(withBundleIdentifier:) 解析 Con URL
                → NSWorkspace.openApplication(at:configuration:) 后台拉起（activates:false）
                → containerLaunchRequested 置位节流（避免 2s 重试 spam）
            → 2 秒后重试 connect()
    → Con 启动 → RPCServer 监听就绪
    → 下次重试 connect() 成功 → .ready → getConfig（拉取 `MenuConfig`）+ 心跳
```

**自动拉起要点**：
- **Ext→Con 拉起时机**：仅连接失败（`resetAndRetry`）时触发，不在 init 主动拉起，避免 Ext 被 Finder 频繁唤醒时冗余拉起。
- **Con→Ext 重新拉起**：Container 的 Con→Ext 心跳检测到 Ext 断连后，若该 Extension 的 `autoLaunch == true`，自动调用 `pluginkit -e use` 重新拉起。
- **后台拉起**：`NSWorkspace.OpenConfiguration.activates = false` 不抢焦点；Con 本身是 `LSUIElement`，无 Dock 图标、不弹窗口，只在菜单栏运行。
- **节流**：`containerLaunchRequested` 标志位，一次失败周期内只请求一次拉起；`.ready` 连接成功后清零，下次掉线可再请求；拉起失败则 10 秒冷却后允许重试。
- **依赖**：`urlForApplication(withBundleIdentifier:)` 需 Con 已在 LaunchServices 注册。若未注册（如全新环境），自动 fallback 到 `open -b <bundleID>` 通过命令行触发 LaunchServices 拉起。若两者均失败（app 未安装），日志报错，Ext 退化为纯重试直到用户手动启动 Con。
- **沙盒**：FinderSync 扩展用 `NSWorkspace.openApplication` 启动指定 bundle-id 的 App 不触发额外 TCC（启动应用是公开能力，非文件访问）。
- **单实例**：Container 启动时通过 `NSRunningApplication` 快速检查 + `flock()` 原子锁防止多实例竞争。Extension 通过读取 lock 文件中的 PID + `kill(pid, 0)` 校验 Container 是否存活。

### 4. 双向心跳保活（ping / pong）

TCP loopback 上，半开连接（一方崩溃但 `NWConnection` 未报 `.failed`）会导致消息发到已死对端。双向心跳让两端都能在有限时间内感知对方死亡并触发恢复。

#### 4.1 Ext → Con 心跳（Extension 检测 Container 存活）

```
Extension（.ready 后）
    → 立即 sendHeartbeat()（首 ping），然后 startHeartbeat()
    → startHeartbeat()：DispatchSource 定时器
        → 首次用 fastHeartbeatInterval(1s) 直到首个 pong 确认连接
        → 确认后切换到 heartbeatInterval(15s)
    → 每次 tick：consecutiveMisses += 1，发 ping（meta = { pid, version }）
    → 收到 pong：pending 回调清零 consecutiveMisses
    → consecutiveMisses >= heartbeatMaxMisses(3)
        → 判定 Container 死亡 → resetAndRetry()（断开 + 2s 重连）
```

#### 4.2 Con → Ext 心跳（Container 检测 Extension 存活）

```
Container（RPCServer.start 后）
    → startPingTimer()：DispatchSource 定时器，每 heartbeatInterval(15s) 触发
    → 每次 tick：checkConnections()
        → 遍历 activeConnections
        → 若 lastPong[id] 超时（> heartbeatInterval × heartbeatMaxMisses）
            → 标记为 dead，调用 remove(conn) → onDisconnected 回调
        → 否则发 ping 请求到 Ext
    → 收到 Ext 的 pong（RPCShutdownNotification(method: "pong")）
        → recordPong(conn)：记录 lastPong 时间戳
```

#### 4.3 报文格式

```json
// ping（Ext→Con，meta 携带元数据）
{ "jsonrpc": "2.0", "id": 5, "method": "ping", "params": null,
  "meta": { "pid": "219", "version": "1.0" } }

// pong（Ext→Con，RPCResponse 形式）
{ "jsonrpc": "2.0", "id": 5, "result": { "success": true }, "error": null }

// ping（Con→Ext，RPCRequest 形式）
{ "jsonrpc": "2.0", "id": 0, "method": "ping" }

// pong（Con→Ext，RPCShutdownNotification 形式）
{ "jsonrpc": "2.0", "method": "pong" }
```

#### 4.4 设计要点

- **双向检测**：Ext→Con 保护 Extension 不向死 Container 发命令；Con→Ext 让 Container 知道 Extension 是否存活，断开后可自动重新拉起。
- **快速首 ping**：连接建立后前几次 ping 用 1s 间隔，首个 pong 到达后切回 15s。这让连接状态在 1-2 秒内确认，而非等待首个 15s 周期。
- **计数法超时**：每发一次 ping 先自增 misses，pong 清零；达到阈值即重连。实现极简。
- **自动拉起**：Con 检测到 Ext 断连后，若该 Extension 的 `autoLaunch == true`，自动调用 `pluginkit -e use` 重新拉起。
- **`onDisconnected` 回调**：RPCServer 的所有断连路径（`.failed` 状态、读流结束、心跳超时）统一路由到 `remove()` → `onDisconnected`，确保 UI 和自动拉起逻辑只触发一次。
- **ping 日志用 debug 级**：15 秒一次，notice 会刷屏；需要时 `log stream --debug` 才可见。
- **UI 可见**：Extensions 设置页显示每个 Extension 的 Connected/Disconnected 状态 + PID + 版本 + 最后心跳相对时间（每秒刷新）。

## 与配置同步的关系

配置（`AppConfig`，包含 `MenuConfig` 菜单树 + `ActionDefMap` 动作表）的**持久化**仍是各自独立的 `UserDefaults.standard`（App Group 共享 UserDefaults 已实测否决，见 `storage-migration.md`）。两个进程的 store 互不可见，所以配置同步完全走 RPC。Extension 只接收 `menu` 半（`MenuConfig`），`actions` 半（`ActionDefMap`）始终保留在 Container 内，分两条通道：

### 1. 连接时拉取（getConfig，Extension → Container）

Extension 的 RPCClient 一旦进入 `.ready`，立即发 `getConfig` 请求向 Container 索取当前 `MenuConfig`。这是**首次加载**的唯一可靠来源 —— Extension 不再读自己的 store（那个 store 拿不到 Container 的写入）。

```
Extension: RPCClient.connect() → NWConnection .ready
    → fetchConfig()  → 发 getConfig 请求（有 id）
Container: handleRequest case "getConfig"
    → 返回 RPCResponse.result.config = 当前 MenuConfig（appConfig.menu）
Extension: pending 回调 → onConfigChange(config) → 更新 cachedConfig（NSLock）
```

### 2. 变更时推送（configDidChange，Container → Extension）

Container 修改配置后主动广播 `MenuConfig`（`appConfig.menu`），让**已连接**的 Extension 实时刷新：

```
Container: 用户修改配置
    → SharedUserDefaults.appConfig = config（写自己的 store）
    → saveConfiguration() → rpcServer.broadcastConfig(config.menu)
        → 向所有已连接 Extension 发 configDidChange notification（payload = MenuConfig）
Extension: RPCClient 收到 configDidChange
    → onConfigChange 回调 → 用 NSLock 保护地更新 cachedConfig
```

两条通道共用同一个 `onConfigChange` 处理器，`menu(for:)` 加锁读 `cachedMenu` 即可。

### configDidChange notification（Container → Extension）

JSON-RPC notification（无 `id`，无需响应），payload 携带 `MenuConfig`（菜单树，非完整 `AppConfig`——`ActionDefMap` 不发 Extension）：

```json
{
  "jsonrpc": "2.0",
  "method": "configDidChange",
  "params": {
    "isEnabled": true,
    "showAppIcons": true,
    "menus": [...]
  }
}
```

### getConfig 请求/响应（Extension → Container）

```json
// 请求
{ "jsonrpc": "2.0", "id": 1, "method": "getConfig" }
// 响应（result.config 携带 MenuConfig）
{ "jsonrpc": "2.0", "id": 1, "result": { "success": true, "errorDescription": null, "config": { "isEnabled": true, "showAppIcons": true, "menus": [...] } } }
```

RPCClient 的 `handleResponse` 先尝试按 notification 形态解码（有 `method` 无 `id`），命中则触发 config 回调；否则按 response（有 `id`）匹配 pending 请求。getConfig 的响应复用 `RPCResult`，新增可选 `config` 字段（类型为 `MenuConfig`）。

> **边界**：Extension 启动时（RPCClient 尚未连上 Container）`cachedConfig` 是 `MenuConfig.default`（空菜单）。一旦连接建立，getConfig 立即把它刷新为 Container 的真实 `MenuConfig`。之后 Container 运行期间的变更由 configDidChange 实时推送。

## 调试

每条日志以 **`[Con]`/`[Ext]`** 前缀标明来源进程，无需过滤 subsystem 即可一眼区分。共享代码（`RPCSession`/`SharedUserDefaults`）的 logger 用 `Constants.currentBundleID`（运行时 `Bundle.main.bundleIdentifier`）作 subsystem，确保 Con 进程的日志归 Con、Ext 进程的归 Ext（避免共享代码把 Ext 日志误标成 Con）。

| 日志点 | 标签 | 级别 | 位置 |
|---|---|---|---|
| Extension 发起调用 | `[Ext][RPC CALL]` | notice | `RPCClient.executeAction` / `fetchConfig` |
| 任意发送（两端共享） | `[Con/Ext][RPC SEND]` | debug | `sendJSON` |
| 任意接收（两端共享） | `[Con/Ext][RPC RECV]` | debug | `RPCServer.handleRequest` / `RPCClient.handleResponse` |
| Con 监听就绪 | `[Con] RPCServer: listening on ...` | notice | `RPCServer.start` |
| Con 收到 Ext 连接 | `[Con] RPCServer: connection from pid` | notice | `RPCServer.handle` |
| Con 派发请求 | `[Con] RPCServer: dispatch ...` | notice | `RPCServer.handleRequest` |
| Con 广播/跳过 configDidChange | `[Con] RPCServer: broadcast/skipped configDidChange` | notice | `RPCServer.broadcastConfig` |
| Ext 连上 Con | `[Ext] RPCClient: connected to ...` | notice | `RPCClient.connect` |
| Ext getConfig 拉到配置 | `[Ext] RPCClient: getConfig received config` | notice | `RPCClient.fetchConfig` 回调 |
| Ext 收到 configDidChange | `[Ext] RPCClient: received configDidChange` | notice | `RPCClient.handleResponse` |
| Ext 心跳启动 | `[Ext] RPCClient: heartbeat started ...` | notice | `RPCClient.startHeartbeat` |
| Ext 发 ping | `[Ext][RPC CALL] id=N method=ping misses=N` | debug | `RPCClient.sendHeartbeat` |
| Ext 心跳超时重连 | `[Ext] RPCClient: N heartbeats unanswered — ... reconnecting` | error | `RPCClient.sendHeartbeat` |
| Ext 拉起 Con | `[Ext] RPCClient: Container not reachable — requesting launch` / `Container launch requested` | notice | `RPCClient.launchContainerIfNeeded` |
| Ext 配置写入缓存 | `[Ext] Config applied:` | notice | `FinderSync`（onConfigChange 回调） |
| Ext 缓存菜单重建 | `[Ext] Cached menu rebuilt (N top-level items)` | notice | `FinderSync.rebuildCachedMenu` |
| Con 收到指令并派发执行 | `[Con][RPC RECV→DISPATCH]` | notice | `AppState.executeAction`（`onAction` 回调） |
| Con 检测到 Ext 注册 | `[Con] Extension registered via pluginkit (system-level; not yet RPC-connected)` | notice | `AppState.checkExtensionRegistration` |

> 注：`[RPC RECV→DISPATCH]` 标签与 `[RPC RECV]` 含义有区分：前者表示 Container 收到 RPC 请求后进入 dispatch/执行，后者是原始接收日志。

### 日志过滤

按内容过滤（同时看两端，推荐）：

```bash
log stream --debug --predicate 'eventMessage CONTAINS "[Con]" OR eventMessage CONTAINS "[Ext]"'
```

按进程 subsystem 过滤（只看某一端）：

```bash
# 只看 Container
log stream --debug --predicate 'subsystem == "com.qi-xmu.mac-right-menu"'
# 只看 Extension
log stream --debug --predicate 'subsystem == "com.qi-xmu.mac-right-menu.FinderExtension"'
```

## 涉及文件

| 文件 | 职责 |
|------|------|
| `Shared/RPC/RPCSession.swift` | `RPCServer` + `RPCClient` + JSON-RPC wire types |
| `Shared/Constants.swift` | `rpcHost` / `rpcPort` / 心跳参数 / `knownExtensions` / `containerLockURL` |
| `Shared/Models/MenuAction.swift` | Extension → Container 的点击载荷（`actionID` + `targetURL` + `selectedURLs`） |
| `Shared/RPC/CommandResult.swift` | 返回结果模型 |
| `Shared/Models/ExtensionInfo.swift` | Extension 状态模型（enabled/connected/autoLaunch） |
| `Shared/Models/DebugLogEntry.swift` | 调试日志条目 + `RPCActivity` 描述符 |
| `Shared/Preferences/SharedUserDefaults.swift` | 各进程独立 UserDefaults 存储 + Extension 偏好 |
| `mac-right-menu/ViewModels/AppState.swift` | Container 持有 `RPCServer`，实现 `executeAction`（按 `ActionDefMap` 查表），自动拉起 Extension |
| `FinderExtension/FinderSync.swift` | Extension 持有 `RPCClient`，`handleMenuAction` 构造 `MenuAction` 发送，自动拉起 Container |
| `FinderExtension/MenuBuilder.swift` | 结构无关的通用菜单渲染器（递归 `MenuItem` 树 → `NSMenu`） |

## 风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| Container 未运行/崩溃，Extension 连接失败 | 低 | RPCClient 内置 2 秒自动重连；连接失败时自动后台拉起 Container（NSWorkspace.openApplication，节流）；Ext→Con 心跳在 ≤45 秒内感知半开连接并触发重连 |
| Extension 崩溃/被杀，Container 未感知 | 低 | Con→Ext 心跳定时检测每个连接的 lastPong；超时后自动标记断连并调用 `pluginkit -e use` 重新拉起（autoLaunch 启用时） |
| 固定端口 57421 被占用 | 低 | 当前未处理；可后续改为动态端口 + 文件传递 |
| TCP 传输无加密 | 低 | loopback 流量不出本机，风险可接受 |
| Container 改配置时 Extension 未连上 → 推送丢失 | 低 | Extension 下次 RPC 连接 `.ready` 时经 `getConfig` 拉取最新 `MenuConfig`；连接前 `cachedConfig` 暂为 `.default` |
| flock 锁文件残留（Container 异常退出） | 低 | flock(fd) 在进程退出时自动释放；`isContainerProcessAlive()` 通过 `kill(pid, 0)` 校验 PID 存活再判断 |

## 考虑点

### 端口策略

当前用固定端口 `57421`。若担心冲突，可改为：Container 启动时随机选端口，写入 App Group 文件，Extension 读文件获取端口。但这又依赖 App Group 文件 I/O（`DENY.md` 记录有 TCC 风险），目前固定端口更简单可靠。

### 性能

- RPC 调用本身异步，不阻塞 Extension 的 `menu(for:)` 返回（菜单渲染与命令执行解耦）。
- `executeAction` 为 `async`，返回**真实执行结果**（`CommandResult`，含成功/失败 + `errorDescription`）。RPC 响应延迟到执行完成后才发送 —— 这是相对早期 "fire-and-forget" 行为的演进，使 Extension 能感知命令失败，且 Container 端 Execution Log 记录的结果与 Extension 收到的响应一致。
- `executeAction` 是 `nonisolated` 的，通过 `await MainActor.run` 安全读取 `appConfig`（`ActionDefMap` 查表），执行本身在 RPC 后台队列（**不阻塞主线程 / UI**）。
