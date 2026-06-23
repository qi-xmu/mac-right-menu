# FIXME.md

项目代码审查发现的问题清单，按优先级排列。
更新: 2026-06-23（移除已修复/已过时项 #1/#3/#4/#8；因菜单重构更新引用）

---

## 🔴 P0 — 关键问题（必须修复）

（无）

---

## 🔴 P1 — 高优先级（发布前修复）

### 1. `executeAction` 标记为 `nonisolated` 导致线程安全问题

- **文件**: `mac-right-menu/ViewModels/AppState.swift:768`
- **严重性**: Medium

**问题**: `AppState` 是 `@MainActor` 类，但 `executeAction` 被标记为 `nonisolated`，意味着任意线程都可以调用。方法内部通过 `await MainActor.run` 安全读取 `appConfig`，但 `performGeneral()` 内部直接访问 `NSPasteboard.general`（line 900-909）仍可能有线程问题。当前唯一调用方是 `RPCServer` 的后台队列回调。

**修复建议**: 移除 `nonisolated`。在 `RPCServer` 的回调中使用 `Task { @MainActor in }` 保证主线程执行，或将 `performGeneral` 的 Pasteboard 操作 dispatch 到主线程。

---

## 🟡 P2 — 中优先级（建议修复）

### 2. 所有序列化错误被静默吞掉

- **文件**: `Shared/Preferences/SharedUserDefaults.swift:25, 30`
- **严重性**: Medium

**问题**: `appConfig` 的 get/set 使用 `try?`，数据损坏时无日志。解码失败（line 25）静默回退到 `.default`，无错误记录；编码失败（line 30）直接 return，也无日志。成功读取时有 `logger.notice`，但失败路径全无。

**修复建议**: 解码/编码失败时添加 `logger.error` 日志。

---

## 🟢 P3 — 低优先级（改善代码质量）

### 3. Cancel 按钮不重置表单状态

- **文件**: `mac-right-menu/Views/NewFileSettingsTab.swift:146`
- **问题**: 取消新建模板后再次打开 Sheet，残留上次的输入内容。Cancel 操作仅 `showingAddTemplate = false`，未重置 `newFileName` / `newExtension`。
- **建议**: Cancel 操作中也添加 `newFileName = ""; newExtension = "txt"`。

### 4. 通知名未统一到 Constants

- **文件**: `mac-right-menu/mac_right_menuApp.swift:37-38`
- **问题**: `"openSettingsWindow"` 使用 `Notification.Name` 扩展定义，而跨进程通知都通过 `Constants.Notifications.*`。
- **建议**: 添加到 `Constants.Notifications`（或作为进程内通知说明两者风格不同的原因）。

---

## ✅ 已修复的问题

| # | 问题 | 状态 | 说明 |
|---|------|------|------|
| — | IPC 竞态条件：pendingCommand 可被覆盖 | ✅ 已修复 | IPC 已重写为 JSON-RPC over TCP，不存在 pendingCommand |
| — | Tag 范围缺少上界检查 | ✅ 已改善 | TagBase 已重排为 0/1000/2000/2002/4000，新增范围检查 |
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
| — | `saveConfiguration()` 被双重调用 | ✅ 已修复 | 菜单重构后仅 `appConfig.didSet` 调用一次，无重复 |
| — | Shell 命令存在注入风险 | ✅ 已不适用 | `.custom` 动作已改为 reserved stub，未实现 shell 执行 |
| — | Tag 范围 shell 分支缺少上界 | ✅ 已不适用 | Extension 不再解析 tag 语义，Container 通过 `ActionDefMap` 查表派发 |
| — | MenuBuilder 缩进不一致 | ✅ 已修复 | 菜单重构后 MenuBuilder 全部重写，缩进统一 |

---

## ✅ 值得肯定的方面

- 清晰的职责分离：FinderSync / MenuBuilder 各司其职
- JSON-RPC over TCP 架构巧妙绕过沙盒限制，Extension 不碰文件
- 心跳机制实现容器与扩展的双向存活检测（Ext→Con + Con→Ext）
- `os_log` 统一日志输出，带 `[Con]/[Ext]` 前缀方便调试
- `LSUIElement = true` 正确隐藏 Dock 图标
- `ContentUnavailableView` 空状态处理良好
- flock() 单实例锁 + NSRunningApplication 快速检查，防竞争
- 自动拉起机制：Ext 检测到 Con 不在时自动后台启动
- 菜单树配置驱动：Extension 成为与业务无关的通用渲染器，只回传 actionID
