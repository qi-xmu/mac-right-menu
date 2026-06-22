# FIXME.md

项目代码审查发现的问题清单，按优先级排列。
更新: 2026-06-22（移除已修复项 #6/#7/#10/#11/#14/#15）

---

## 🔴 P0 — 关键问题（必须修复）

（无）

---

## 🔴 P1 — 高优先级（发布前修复）

### 1. `saveConfiguration()` 被双重调用

- **文件**: `mac-right-menu/ViewModels/AppState.swift:8-11, 296-349`
- **严重性**: Medium

**问题**: `configuration` 的 `didSet` 会调用 `saveConfiguration()`，但所有便捷访问器（`isEnabled`、`appItems` 等）又显式调用了一次。每次状态变更都触发**两次**序列化 + **两次** RPC 广播。视图中也存在同样问题（如 `ActionsSettingsTab.swift:43`、`NewFileSettingsTab.swift:84, 93`）。

**修复建议**: 统一使用 `didSet` 自动保存，删除所有便捷访问器和视图中显式的 `saveConfiguration()` 调用。

---

### 2. `executeCommand` 标记为 `nonisolated` 导致线程安全问题

- **文件**: `mac-right-menu/ViewModels/AppState.swift:394`
- **严重性**: Medium

**问题**: `AppState` 是 `@MainActor` 类，但 `executeCommand` 被标记为 `nonisolated`，意味着任意线程都可以调用。方法内部访问了 `NSPasteboard.general`（需要主线程）和 `Process().waitUntilExit()`（阻塞线程）。当前唯一调用方是 `RPCServer` 的后台队列回调。

**修复建议**: 移除 `nonisolated`。在 `RPCServer` 的 `onCommand` 回调中使用 `Task { @MainActor in }` 保证主线程执行。

---

### 3. Shell 命令存在注入风险

- **文件**: `mac-right-menu/ViewModels/AppState.swift:523`
- **严重性**: High

**问题**: 文件路径未做转义，含空格/特殊字符（`$`、`` ` ``、`;`）的路径会导致命令注入。

```swift
// 当前有问题的代码：
let substituted = cmd.replacingOccurrences(of: "{}", with: command.files.joined(separator: " "))
task.arguments = ["-c", substituted]
```

**修复建议**: 将文件路径用 `shellescape` 转义，或作为独立参数传递而非字符串拼接。

---

## 🟡 P2 — 中优先级（建议修复）

### 4. Tag 范围 shell 分支缺少上界

- **文件**: `FinderExtension/MenuActionHandler.swift:44`, `Shared/Constants.swift:61`
- **严重性**: Low

**问题**: `TagBase.shell = 4000`，`default` 分支中 `tag >= shellBase` 没有上界。虽然当前只有 4000 一个 shell tag，但若未来新增其他 tag 范围（如 5000+），会被误判为 shell。

**当前状态**: 比旧版改善很多 — `newFile`（0–999）、`appItem`（1000–1999）、操作（2000–2002）都已有范围检查，仅 shell 分支无上界。

---

### 5. 所有序列化错误被静默吞掉

- **文件**: `Shared/Preferences/SharedUserDefaults.swift:22, 28`
- **严重性**: Medium

**问题**: `menuConfiguration` 的 get/set 使用 `try?`，数据损坏时无任何日志。解码失败时返回 `.default` 但无错误记录；编码失败时记录了 error 日志（`SharedUserDefaults.swift:29`），但解码失败路径无日志。

**修复建议**: 解码失败时添加 `logger.error` 日志。

---

## 🟢 P3 — 低优先级（改善代码质量）

### 6. 模板扩展名无输入校验

- **文件**: `mac-right-menu/Views/NewFileSettingsTab.swift:128`
- **问题**: 扩展名输入接受空格、斜杠等特殊字符，可能生成无效文件名。
- **建议**: 校验扩展名不含路径分隔符和空白字符。

### 7. Cancel 按钮不重置表单状态

- **文件**: `mac-right-menu/Views/NewFileSettingsTab.swift:134`
- **问题**: 取消新建模板后再次打开 Sheet，残留上次的输入内容。
- **建议**: Cancel 操作中也添加 `newFileName = ""; newExtension = "txt"`。

### 8. MenuBuilder 缩进不一致

- **文件**: `FinderExtension/MenuBuilder.swift:9-11`
- **问题**: `isDarkMode` 和 `icon(_:)` 方法多出 4 空格缩进。
- **建议**: 统一为 4 空格缩进。

### 9. 通知名未统一到 Constants

- **文件**: `mac-right-menu/mac_right_menuApp.swift:37-38`
- **问题**: `"openSettingsWindow"` 使用 `Notification.Name` 扩展定义，而跨进程通知都通过 `Constants.Notifications.*`。
- **建议**: 添加到 `Constants.Notifications`（或作为进程内通知说明两者风格不同的原因）。

---

## ✅ 已修复的问题

| # | 问题 | 状态 | 说明 |
|---|------|------|------|
| — | IPC 竞态条件：pendingCommand 可被覆盖 | ✅ 已修复 | IPC 已重写为 JSON-RPC over TCP，不存在 pendingCommand |
| — | Tag 范围缺少上界检查 | ✅ 大幅改善 | TagBase 已重排为 0/1000/2000/2002/4000，新增范围检查 |
| — | PreferenceStore 持锁做文件 I/O | ✅ 已修复 | SharedUserDefaults 已改用 UserDefaults.standard，无自定义锁 |
| — | Heartbeat 使用系统时钟 | ✅ 已修复 | IPC 已重写，心跳机制全新实现 |
| — | Timer 未在 deinit 中 invalidate | ✅ 已修复 | 改用 DispatchSourceTimer + stopHeartbeat() |
| — | `@unchecked Sendable` 重复声明 | ✅ 已修复 | 注释说明 Sendable 在各模型定义处声明 |
| — | SettingsView frame 矛盾 | ✅ 已修复 | 外层与子视图 frame 对齐 |
| — | `restartFinder()` 使用已废弃 API | ✅ 已修复 | 方法已移除 |
| — | SettingsSync 未返回观察者 token | ✅ 已修复 | IPC 架构已重构，SettingsSync 不再存在 |
| — | `icon(_:)` 每次右键都重新创建 NSImage | ✅ 已修复 | 已实现 `symbolCache` + `appIconCache` 静态缓存 |
| — | `isProductionMode` 每次查询 runningApplications | ✅ 已修复 | 属性已移除 |
| — | `menu(for:)` 仅处理 `contextualMenuForItems` | ✅ 已修复 | 已支持 `.contextualMenuForItems` + `.contextualMenuForContainer` |
| — | `Process.launchPath` 使用已废弃 API | ✅ 已修复 | 3 处全部替换为 `executableURL = URL(fileURLWithPath:)` |

---

## ✅ 值得肯定的方面

- 清晰的职责分离：FinderSync / MenuBuilder / MenuActionHandler 各司其职
- JSON-RPC over TCP 架构巧妙绕过沙盒限制，Extension 不碰文件
- 心跳机制实现容器与扩展的双向存活检测（Ext→Con + Con→Ext）
- `os_log` 统一日志输出，带 `[Con]/[Ext]` 前缀方便调试
- `LSUIElement = true` 正确隐藏 Dock 图标
- `ContentUnavailableView` 空状态处理良好
- flock() 单实例锁 + NSRunningApplication 快速检查，防竞争
- 自动拉起机制：Ext 检测到 Con 不在时自动后台启动
