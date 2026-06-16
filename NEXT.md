# NEXT.md

> 待办与设计差异，按优先级排列。
> 更新: 2026-06-16（XPC 方案废弃，改用 JSON-RPC over TCP；configDidChange 实时配置同步已实现并移出待办）

---

## 🟡 P1 — 待完善（功能性缺口）

### 1. Shell 命令菜单项未接入（半成品状态）

当前 shell 命令仅有一半实现，端到端不通：

| 环节 | 状态 |
|---|---|
| `CommandRequest.Action.shell` | ✅ 已定义 |
| `CommandRequest.command: String?` | ✅ 字段存在，但 **MenuActionHandler 从未填充** |
| `MenuActionHandler` `case >= shellBase` | ✅ 分发分支存在（tag 4000+） |
| `MenuBuilder` 构造 shell 菜单项 | ❌ 完全未实现 |
| `MenuConfiguration` 持有 shell 项 | ❌ 无对应字段（仅 `appItems`/`actionItems`/`newFileTemplates`） |
| `AppState.executeCommand(.shell)` | ✅ 已实现（`/bin/bash -c`，`{}` 占位符替换） |

**待办**：
1. 在 `MenuConfiguration` 增加 `shellItems: [ShellMenuItem]`（含 title、command、iconName、isEnabled、id）
2. `MenuBuilder` 增加 Shell Section，tag = `Constants.TagBase.shell.rawValue + index`
3. `MenuActionHandler` 的 `case >= shellBase` 改为 `CommandRequest(action: .shell, files: paths, command: shellItem.command)`
4. 新增 Container UI tab 管理 shell 项

**涉及文件**：`Shared/Preferences/MenuConfiguration.swift`、`Shared/Models/`（新建 `ShellMenuItem.swift`）、`FinderExtension/MenuBuilder.swift`、`FinderExtension/MenuActionHandler.swift`、`mac-right-menu/Views/`（新建 settings tab）

### 2. Container 未运行时 Extension 不自动拉起

`RPCClient.connect()` 失败时 `resetAndRetry()` 静默重试（默认 2 秒间隔），命令直接丢弃（`completion(nil)`），不主动启动 Container。

**可选方案**：`RPCClient` 在首次连接失败且命令排队时，通过 `NSExtensionContext.open(_:)` 拉起 Container；或在 Extension 启动时即拉起。

**设计参考**：`communication-protocol.md` → 生命周期。

### 3. 固定端口 57421 的冲突处理缺失

`RPCServer.start()` 监听失败仅 `logger.error`（`RPCSession.swift:148`），不尝试备用端口，也不通知 UI。

**可选方案**：
- A. 监听失败后尝试 +1/+2 端口，写入 App Group 文件供 Extension 读取（注意 App Group 文件 I/O 有 TCC 风险，见 `DENY.md`）
- B. 监听失败后弹 Toast 提示用户释放端口（开发期足够）
- C. 改用 `NWEndpoint` + Bonjour 服务发现（较重，长期方案）

---

## 🔵 P2 — 长期优化 / 打磨

### 4. Extension 注册/启用状态检测增强

`AppState.checkExtensionRegistration()` 用 `pluginkit -m -p com.apple.FinderSync` 检测注册，但不解析输出行首的状态标志（`!` 禁用 / `+` 启用 / `-` 用户禁用）。
开发期需手动 `pluginkit -e use -i com.qi-xmu.mac-right-menu.FinderExtension` 启用扩展。

**可选方案**：解析 `pluginkit -m` 输出行的首个字符判断启用状态；若为 `!`/`-`，在 App UI 引导用户到「系统设置 → 扩展 → 访达扩展」启用。

### 5. App Store 上架评估

Container 非沙盒（无法上架 MAS）。`network.client` entitlement 本身 MAS 兼容，但非沙盒 Container 需评估分发策略（Developer ID 签名 + 公证 + 官网/GitHub Releases 分发）。

### 6. 残留清理（小）

- `Shared/Constants.swift:14` 的 `endpointFileName = "xpc_endpoint.dat"` 已无任何引用（failed scheme C 遗留），可删除。

### 7. 日志命名一致性（小）

`AppState.swift:160` 的 `[IPC RECEIVED]` 命名沿用 XPC 时代，建议改为 `[RPC RECV→DISPATCH]` 以与 `[RPC SEND]`/`[RPC RECV]` 对齐。

---

## 📌 优先级建议

1. **P1.1 Shell 菜单项**（功能完整性，最直接的用户价值）
2. **P1.2 Container 自动拉起**（影响首次使用体验）
3. **P1.3 端口冲突**（开发期偶发，可低优先级）
4. P2.* 按需推进
