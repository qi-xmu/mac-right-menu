# 通信协议设计

> 日期: 2026-06-08
> 状态: 设计中

## 概述

将 Extension 和 Container App 之间的所有通信统一为 NSXPCConnection 双向通道，替代现有的 DNC + UserDefaults + 文件心跳三套机制。

## 当前 vs 目标

```
当前 (3 套机制)                         目标 (1 套机制)
─────────────                         ───────────
指令:   Extension ──DNC──► Container    ──┐
      └──UserDefaults──pendingCmd──►     │
                                         │   Extension ◄─NSXPCConnection─► Container
配置同步: Extension ◄──DNC── Container   │       (双向 RPC, mach port)
                                         │
心跳: Extension ──文件── Container       │
      Container ──文件── Extension     ──┘
```

**可以移除的旧代码**：
- `SharedUserDefaults.pendingCommand` 读写
- `Constants.Notifications.executeCommand` DNC 通知
- `Constants.Notifications.shutdownRequested` DNC 通知
- `Shared/IPC/Heartbeat.swift` 整文件
- `SharedUSERDefaults` 中的 heartbeat 相关 key
- `FinderSync.startHeartbeat()` + Timer
- `AppState.startHeartbeat()` + Timer

---

## 协议定义

```swift
import Foundation

// ── Extension 调用 Container ──

@objc protocol ContainerXPCProtocol {
    /// Extension 请求 Container 执行文件操作
    func executeCommand(_ command: CommandRequest, completion: @escaping (CommandResult) -> Void)
}

// ── Container 调用 Extension ──

@objc protocol ExtensionXPCProtocol {
    /// Container 通知 Extension 配置已变更，下次 menu(for:) 时重新读取
    func settingsDidChange()
    /// Container 即将退出，Extension 停止心跳、注销监听
    func shutdownImminent()
}
```

### CommandRequest（NSSecureCoding 版）

```swift
final class CommandRequest: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    enum Action: Int {
        case copyPath      = 2000
        case copyFileName  = 2001
        case toggleHidden  = 2002
        case openParent    = 2003
        case newFile       = 0     // tag = 0 + templateIndex
        case openWithApp   = 1000  // tag = 1000 + appIndex
        case shell         = 4000  // tag = 4000 + shellIndex
    }

    let action: Action
    let files: [String]
    let command: String?          // shell 命令模板
    let extra: [String: String]?  // 附带参数

    // NSSecureCoding ...
}
```

### CommandResult（返回值）

```swift
final class CommandResult: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let success: Bool
    let errorDescription: String?

    init(success: Bool, errorDescription: String? = nil) {
        self.success = success
        self.errorDescription = errorDescription
    }
}
```

---

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                         Container App                       │
│  ┌─────────────────────┐      ┌──────────────────────────┐ │
│  │ NSXPCListener       │      │ AppState                 │ │
│  │ service: "com..menu"│─────►│ + executeCommand()       │ │
│  │                     │      │ + settingsDidChange()    │ │
│  │ exportedObject:     │      │ + shutdownImminent()     │ │
│  │   ContainerXPC      │      └──────────────────────────┘ │
│  └─────────────────────┘                                    │
└──────────────────────┬─────────────────────────────────────┘
                       │  mach port
┌──────────────────────┴─────────────────────────────────────┐
│                      Finder Extension                      │
│  ┌─────────────────────┐      ┌──────────────────────────┐ │
│  │ NSXPCConnection     │      │ FinderSync               │ │
│  │ endpoint: "com..menu"│     │ + menu(for:)             │ │
│  │                     │      │ + handleMenuAction()     │ │
│  │ remoteObjectProxy:  │─────►│                          │ │
│  │   ContainerXPC      │      │ exportedObject:          │ │
│  │                     │      │   ExtensionXPC           │ │
│  │ invalidationHandler │      └──────────────────────────┘ │
│  └─────────────────────┘                                    │
└────────────────────────────────────────────────────────────┘
```

### 角色

| 角色 | 组件 | 说明 |
|------|------|------|
| XPC Server | Container App | 注册 `NSXPCListener`，接收 Extension 连接 |
| XPC Client | Extension | 创建 `NSXPCConnection`，连接 Container |
| 导出接口 (Extension→Container) | `ContainerXPCProtocol` | executeCommand |
| 导出接口 (Container→Extension) | `ExtensionXPCProtocol` | settingsDidChange, shutdownImminent |

Container 做 Server 的理由：
- Container 生命周期由用户控制（随登录启动或手动打开）→ 一直在线
- Extension 由 Finder 按需启动 → 连接断开不影响 Container
- Mach service 注册在 Container App bundle 中更自然

---

## 生命周期

### 1. 启动

```
Container App 启动
    → 创建 NSXPCListener(machServiceName: "com.qi-xmu.mac-right-menu.command")
    → 设置 delegate，接受 incoming connections

Extension 被 Finder 唤醒 (init)
    → 创建 NSXPCConnection(machServiceName: "com.qi-xmu.mac-right-menu.command")
    → 设置 exportedObject = ExtensionXPC 实例
    → 设置 invalidationHandler（检测 Container 死亡）
    → connection.resume()
    → 获取 remoteObjectProxy → 可调用 executeCommand
```

### 2. 执行指令

```
用户右键 → handleMenuAction(sender, targetURL, selectedURLs)
    → 根据 tag 构造 CommandRequest
    → remoteObjectProxy.executeCommand(command) { result in
            logger.notice("Command \(result.success ? "succeeded" : "failed")")
        }
    （同步/异步均可，XPC 自动串行化调用）
```

### 3. 设置变更通知

```
Container: 用户修改配置 → saveConfiguration()
    → for connection in listener.connections:
          connection.remoteObjectProxy.settingsDidChange()

Extension: settingsDidChange() 回调
    → 标记下次 menu(for:) 重新读配置
```

### 4. Container 关机

```
Container: 用户退出 / 系统关机
    → for connection in listener.connections:
          connection.remoteObjectProxy.shutdownImminent()
    → listener.invalidate()

Extension: shutdownImminent() 回调
    → 停止 heartbeat（如有）
    → FIFinderSyncController.default().directoryURLs = []
```

### 5. 心跳（连接即心跳）

```
Extension:
    invalidationHandler = {
        // Container App 退出 / hung / 崩溃
        logger.warning("Container connection lost")
        connection.invalidate()
        // Finder 下次调用 menu(for:) 时重建连接
    }
```

不需要 Timer，不需要文件 I/O。NSXPCConnection 的 invalidation 由内核级 mach port 管理，即时可靠。

### 6. Container 不在时 Extension 被唤醒

```
Finder 唤醒 Extension (init)
    → 创建 NSXPCConnection → resume()
    → 连接失败（Container 未运行）
        → invalidationHandler 触发
        → 尝试 NSWorkspace.openApplication 启动 Container
        → 等待 Container 启动 + XPC 连接建立
        → 挂起 5s，重试
```

---

## Container App 注册 Mach Service

需要在 `mac-right-menu/Info.plist` 或 entitlements 中注册 XPC service：

```xml
<!-- Info.plist -->
<key>NSServices</key>
<array>
    <dict>
        <key>NSMachServiceName</key>
        <string>com.qi-xmu.mac-right-menu.command</string>
    </dict>
</array>
```

或者通过代码注册匿名 listener（无需 Info.plist）：

```swift
let listener = NSXPCListener.anonymous()
listener.activate()
// Extension 通过 endpoint 连接
```

匿名 listener 不依赖 Info.plist，Extension 可通过 App Group 传递 endpoint（仅建立连接时一次）。

---

## 与现有代码的衔接

### 可以删除的

| 文件/代码 | 说明 |
|-----------|------|
| `Shared/IPC/Heartbeat.swift` | 整文件删除 |
| `SharedUserDefaults.pendingCommand` | 改为 XPC 传输 |
| `Constants.Notifications.executeCommand` | DNC 通知 |
| `Constants.Notifications.shutdownRequested` | DNC 通知 |
| `Constants.Defaults.heartbeat*` | heartbeat key |
| `Constants.Defaults.shutdownFlagKey` | shutdown flag |
| `SettingsSync.post*` (部分) | executeCommand 通知不再需要 |
| `FinderSync.startHeartbeat()` | Timer 删除 |
| `AppState.startHeartbeat()` | Timer 删除 |
| `AppState.isExtensionActive` | 换为 connection.isValid |

### 保留的

| 代码 | 说明 |
|------|------|
| `SettingsSync.postSettingsChanged()` | 降级：发 DNC 通知 → 改为走 XPC `settingsDidChange()` |
| `SharedUserDefaults.menuConfiguration` | 配置数据仍在 App Group |
| `Constants.Notifications.settingsChanged` | 如果 DNC 全移除则删，否则保留兼容 |

### 需要新增的

| 文件 | 说明 |
|------|------|
| `Shared/XPC/XPCProtocol.swift` | 协议定义 |
| `Shared/XPC/CommandRequest+NSSecureCoding.swift` | NSSecureCoding 实现 |
| `Shared/XPC/CommandResult.swift` | 返回结果类型 |
| `Container/XPCListener.swift` | Container 侧 listener 管理 |
| `Extension/XPCConnection.swift` | Extension 侧连接管理 |

---

## 风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| Container 未运行，Extension 连接失败 | 中 | 自动启动 Container App，重试连接 |
| XPC 调用阻塞 menu(for:) 返回 | 低 | executeCommand 异步调用（不等待 result） |
| NSSecureCoding 序列化错误 | 低 | CommandRequest 字段简单，单元测试覆盖 |
| 匿名 listener 重建时 endpoint 失效 | 低 | Extension 重连逻辑 + App Group 传递新 endpoint |

---

## 考虑点

### DNC 是否完全移除？

settingsChanged 当前通过 DNC 通知，替换为 XPC 调用后可以完全移除 DNC。但保留 DNC 作为 failsafe（Extension 接收 XPC 通知失败时兜底读取最新配置）也是一个选择。

### 匿名 Listener vs 命名 Service

匿名 listener 不依赖 Info.plist，更灵活。Extension 每次被唤醒时读取 App Group 中的 listener endpoint 即可连接。

```swift
// Container 启动时
let listener = NSXPCListener.anonymous()
listener.activate()
let endpoint = listener.endpoint
// 将 endpoint 序列化存储到 App Group
let data = NSKeyedArchiver.archivedData(withRootObject: endpoint)
SharedUserDefaults.suite.set(data, forKey: "xpcEndpoint")

// Extension 连接时
let data = SharedUserDefaults.suite.data(forKey: "xpcEndpoint")
let endpoint = NSKeyedUnarchiver.unarchiveObject(with: data) as! NSXPCListenerEndpoint
let connection = NSXPCConnection(listenerEndpoint: endpoint)
```

一旦建立连接，后续 Extension 重连时 Container 可能已重建 listener，需要刷新 endpoint。

### 线程模型

- `executeCommand` 的调用可能不在主线程 → Container 侧实现需 `DispatchQueue.main.async` 处理 UI 相关操作
- `settingsDidChange` / `shutdownImminent` 在 Extension 侧 → 需确保 `FIFinderSyncController` 调用在主线程
