# IPC 通信架构（JSON-RPC over TCP）

> 历史背景：本项目曾尝试 XPC（mach service / XPC Service / 匿名 listener + endpoint 文件）
> 三种方案，均经实测排除。详见 `BUG1.md` 排查历程。最终采用 JSON-RPC over TCP。

## 分层

```
┌─────────────────────────────────────────────────────┐
│  业务调用方                                          │
│  AppState.swift / FinderSync.swift                   │
│  ─────                                               │
│  rpcServer (Container)       rpcClient (Extension)   │
│  server.start()              client.connect()        │
│  server.stop()               client.executeCommand() │
└───────────┬──────────────────────┬──────────────────┘
            │                      │
┌───────────▼──────────────────────▼──────────────────┐
│  RPCSession.swift (Shared/XPC/)                      │
│  ─────                                               │
│  RPCServer                    RPCClient              │
│  • NWListener (TCP)           • NWConnection (TCP)   │
│  • 连接池 + 锁管理            • 自动重连（2s）       │
│  • JSON-RPC dispatch          • pending 请求管理     │
└───────────┬──────────────────────┬──────────────────┘
            │                      │
┌───────────▼──────────────────────▼──────────────────┐
│  传输层                                              │
│  ─────                                               │
│  TCP loopback: 127.0.0.1:57421                       │
│  消息格式: JSON-RPC 2.0，line-delimited（\n 分隔）   │
└─────────────────────────────────────────────────────┘
```

## JSON-RPC 协议

### 请求（Extension → Container）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "executeCommand",
  "params": {
    "action": 2,
    "files": ["/path/to/file"],
    "command": null,
    "extra": null
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

| JSON-RPC | Swift 类型 |
|----------|-----------|
| `params` | `RPCParams` ↔ `CommandRequest`（action 用 `CommandRequest.Action.rawValue`） |
| `result` | `RPCResult` ↔ `CommandResult` |

## 数据流

### 指令执行（Extension → Container）

```
Finder 右键菜单点击
  → MenuActionHandler.handleMenuAction(...)
    → RPCClient.executeCommand(command)
      → TCP 发送 JSON-RPC request
        → RPCServer.handleRequest()
          → RPCServer.onCommand(command)
            → AppState.executeCommand()
          → TCP 返回 JSON-RPC response
    → 回调打印 [RPC OK] / [RPC DOWN]
```

### 配置读取（RPC 同步，不读各自 store）

```
Container 修改设置
  → SharedUserDefaults.menuConfiguration = config
  → 写入 Container 自己的 UserDefaults
  → rpcServer.broadcastConfig(config)（configDidChange 推送）

Extension
  → cachedConfig 初始为 .default
  → RPC 连接 .ready → getConfig 拉取 Container 当前配置
  → 运行期间收到 configDidChange → 刷新 cachedConfig
```

> 注意：两个进程的 UserDefaults 是各自独立的（非 App Group 共享）。
> 配置同步完全走 RPC：连接时 `getConfig` 拉取 + 运行期间 `configDidChange` 推送（payload 携带完整 `MenuConfiguration`），详见 `communication-protocol.md`。

## Entitlements

| 组件 | 需要的 entitlement |
|------|-------------------|
| Container（非沙盒） | 无（非沙盒 App 可自由监听 TCP） |
| Extension（沙盒） | `com.apple.security.network.client` |

## 为什么不用 XPC

| XPC 方案 | 排除原因 |
|----------|----------|
| `NSXPCListener(machServiceName:)` + `NSMachServices` Info.plist | 非沙盒 Container 的 key 被 launchd 忽略，mach service 不注册 |
| `temporary-exception.mach-register.global-name` | 实测仍不注册（现代 macOS 废弃 runtime bootstrap_register） |
| XPC Service（`serviceName`） | Extension 跨进程不可达（XPC Service 运行在宿主 App 进程空间） |
| 匿名 listener + endpoint 文件 | `NSXPCListenerEndpoint` 无法用 `NSKeyedArchiver` 序列化（mach port send right 非可序列化字节） |

详见 `DENY.md`。

## 文件清单

| 文件 | 职责 |
|------|------|
| `Shared/XPC/RPCSession.swift` | IPC 通信模块（RPCServer + RPCClient + JSON-RPC wire types） |
| `Shared/XPC/CommandResult.swift` | RPC 返回结果模型（`NSSecureCoding`，RPC 层用 `RPCResult` Codable 包装） |
| `Shared/Models/CommandRequest.swift` | RPC 指令模型（`NSSecureCoding`，RPC 层用 `RPCParams` Codable 包装） |
| `Shared/Constants.swift` | `rpcHost` / `rpcPort` 常量 |
| `mac-right-menu/ViewModels/AppState.swift` | Container 调用方（持有 `RPCServer`） |
| `FinderExtension/FinderSync.swift` | Extension 调用方（持有 `RPCClient`） |
| `FinderExtension/MenuActionHandler.swift` | 菜单动作 → `RPCClient.executeCommand` |
