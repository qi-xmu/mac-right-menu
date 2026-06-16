# DENY: 被否决的技术方案

> 本文档记录所有经过实测验证失败的 IPC / 存储 / 通信方案及其根因，
> 避免重复踩坑。最终采用方案见文末。

---

## 一、XPC 通信方案（全部否决）

| 方案 | 机制 | 拒绝原因（实测） | 证据 |
|------|------|-----------------|------|
| `NSXPCListener(machServiceName:)` + `NSMachServices` Info.plist | 命名 mach service，通过 launchd 注册 | 非沙盒 Container App 的 `NSMachServices` key 被 launchd 忽略，mach service 从未注册 | `launchctl print pid/<container>` 的 `services = {}` 列表里没有该 service；Extension 报 `xpc_error=[3: No such process]` |
| `temporary-exception.mach-register.global-name` | 给非沙盒 Container 加 entitlement 期望注册 mach service | 加了 entitlement 仍不注册；现代 macOS（10.15+）废弃了 runtime `bootstrap_register`，要求通过 LaunchAgent/LaunchDaemon plist 预注册 | `codesign -d` 确认 entitlement 已签名进 App，但 `launchctl print` 仍显示 service 未注册 |
| XPC Service（`NSXPCConnection(serviceName:)` + `.xpc` bundle） | 嵌入主 App 的 XPC Service bundle，按需启动 | XPC Service 运行在宿主 App 进程空间内（作为子进程）；FinderSync Extension 是独立进程，不在宿主 App 的 bootstrap namespace 内，`serviceName` 查找失败 | Apple 工程师在 Stack Overflow 确认此限制，建议改用 LoginItem |
| 匿名 listener + endpoint 文件 | `NSXPCListener.anonymous()` + `NSKeyedArchiver` 序列化 endpoint 到 App Group 文件 | `NSXPCListenerEndpoint` 虽声明遵循 `NSSecureCoding`，但只能通过 `NSXPCCoder` 在**已存在的 XPC 连接上**编码；它内部包装 mach port send right（内核资源），无法用 `NSKeyedArchiver` 扁平化到文件 | 实测报错："未能写入数据，因为它的格式不正确。"（endpoint 序列化失败）|

### XPC 方案否决的根因总结

1. **mach service 注册**：现代 macOS 要求通过 launchd plist 预注册，非沙盒 App 的运行时注册（`NSMachServices` Info.plist key / `bootstrap_register`）均不可靠
2. **XPC Service 隔离**：`.xpc` bundle 是宿主 App 内部的进程隔离机制，Extension 作为独立进程无法访问
3. **endpoint 序列化**：`NSXPCListenerEndpoint` 包含内核 mach port right，本质不可序列化（这是 Apple 的设计）

---

## 二、网络通信方案（部分否决）

| 方案 | 机制 | 拒绝原因 | 证据 |
|------|------|----------|------|
| Unix domain socket | Container 创建 Unix socket，Extension connect | Extension 沙盒中 `connect()` 返回 `EPERM`（Operation Not Permitted），即使 socket 由 Container 创建 | Stack Overflow 报告 + 沙盒 profile 限制 |

### TCP loopback（✅ 最终采用）

| 方案 | 机制 | 可行性 | 证据 |
|------|------|--------|------|
| TCP `127.0.0.1:57421` + JSON-RPC 2.0 | Container `NWListener` 监听，Extension `NWConnection` 出站连接（需 `network.client`） | ✅ 可行 | 实测 `lsof` 显示 ESTABLISHED；nc 模拟端到端成功 |

> 用 `127.0.0.1` 而非 `localhost`：沙盒内 `/etc/hosts` 解析可能失败。

---

## 三、共享存储方案（全部否决）

| 方案 | 机制 | 拒绝原因 | 证据 |
|------|------|----------|------|
| `UserDefaults(suiteName:)`（App Group） | App Group 共享 UserDefaults | `cfprefsd` 报 `detaching from cfprefsd` 警告；Extension 沙盒报 `user-preference-read or file-read-data sandbox access` | 运行时日志 |
| `NSDictionary(contentsOf:)` | 读 App Group 容器 plist 文件 | Extension 沙盒拦截，触发 TCC 弹窗 | 运行时 |
| `Data(contentsOf:)` | 读 App Group 容器裸文件 | Extension 沙盒拦截，触发 TCC 弹窗 | 运行时 |
| `FileManager.attributesOfItem(atPath:)` | 读 App Group 容器文件属性 | Extension 沙盒拦截，触发 TCC 弹窗 | 运行时 |
| `URL.resourceValues(forKeys:)` | 读 App Group 容器文件元数据 | Extension 沙盒拦截，触发 TCC 弹窗 | 运行时 |
| Container 写 Extension 沙盒容器 | Container（非沙盒）写 `~/Library/Containers/<ext-bundle-id>/Data/Documents/` | `~/Library/Containers/<bundle-id>/` 受系统 TCC 保护，非该 bundle-id 的进程无法写入（即使非沙盒） | shell `touch` 报 `Operation not permitted`；目录权限 700 但跨进程被拦 |

### 存储方案否决的根因总结

1. **App Group entitlement 不豁免裸文件 I/O** — `application-groups` 只对 `UserDefaults(suiteName:)` 提供理论豁免，但 cfprefsd 断开后 fallback 到直接文件访问仍触发沙盒检查
2. **Container ↔ Extension 无法共享文件** — Container 无沙盒但写 Extension 容器被 TCC 拦；Extension 有沙盒，读任何外部路径触发 TCC

### 当前存储方案（✅ 各自独立）

Container 与 Extension 各自维护 `UserDefaults.standard`（非共享）。配置同步策略见 `docs/design/storage-migration.md`。

---

## 四、最终方案

| 组件 | 实现 |
|------|------|
| **IPC 通道** | JSON-RPC 2.0 over TCP loopback（`127.0.0.1:57421`） |
| Container（非沙盒） | `RPCServer` 用 `NWListener` 监听，无需 entitlement |
| Extension（沙盒） | `RPCClient` 用 `NWConnection` 连接，需 `com.apple.security.network.client` |
| 配置存储 | 各进程独立的 `UserDefaults.standard`（非 App Group 共享） |
| 配置同步 | Extension 连接时 `getConfig` 拉取 + 运行期间 `configDidChange` 推送（不读各自 store；连接前 cachedConfig 为 `.default`） |

详见 `docs/design/communication-protocol.md`、`docs/design/xpc-architecture.md`、`BUG1.md`。
