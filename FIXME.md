# FIXME.md

项目代码审查发现的问题清单，按优先级排列。

---

## 🔴 P0 — 关键问题（必须修复）

（无）

---

## 🔴 P1 — 高优先级（发布前修复）

### 1. `saveConfiguration()` 被双重调用

- **文件**: `mac-right-menu/ViewModels/AppState.swift:11-15, 67-128`
- **严重性**: Critical

**问题**: `configuration` 的 `didSet` 会调用 `saveConfiguration()`，但所有便捷访问器（`isEnabled`、`appItems` 等）又显式调用了一次。每次状态变更都触发**两次**序列化 + **两次**文件 I/O + **两次**通知扩展重新加载配置。视图中也存在同样问题（如 `ActionsSettingsTab.swift:30-31`、`NewFileSettingsTab.swift:51`）。

**修复建议**: 统一使用 `didSet` 自动保存，删除所有便捷访问器和视图中显式的 `saveConfiguration()` 调用。

---

### 2. `executeCommand` 标记为 `nonisolated` 导致线程安全问题

- **文件**: `mac-right-menu/ViewModels/AppState.swift:142`
- **严重性**: Critical

**问题**: `AppState` 是 `@MainActor` 类，但 `executeCommand` 被标记为 `nonisolated`，意味着任意线程都可以调用。方法内部访问了 `NSPasteboard.general`（需要主线程）和 `Process().waitUntilExit()`（阻塞线程）。虽然当前唯一调用方是 main queue 上的通知回调，但 `nonisolated` 移除了编译器的线程安全保障。

**修复建议**: 移除 `nonisolated`。通知回调中使用 `Task { @MainActor in self.executeCommand(command) }` 来保证主线程执行。

---

### 3. Shell 命令存在注入风险 + 阻塞主线程

- **文件**: `mac-right-menu/ViewModels/AppState.swift:244-251`
- **严重性**: High

**问题**: 文件路径未做转义，含空格/特殊字符（`$`、`` ` ``、`;`）的路径会导致命令注入。同时 `Process().launch()` + `waitUntilExit()` 阻塞当前线程。

```swift
// 当前有问题的代码：
let substituted = cmd.replacingOccurrences(of: "{}", with: command.files.joined(separator: " "))
task.arguments = ["-c", substituted]
task.launch()
task.waitUntilExit()
```

**修复建议**:
1. 将文件路径作为独立参数传递而非字符串拼接，或至少用 `shellescaped` 转义
2. 异步执行 `Process`，避免阻塞主线程

---

## 🟡 P2 — 中优先级（建议修复）

### 4. IPC 竞态条件：pendingCommand 可被覆盖

- **文件**: `FinderExtension/MenuActionHandler.swift:57-63`
- **严重性**: High

**问题**: `pendingCommand` 是单槽位，快速连续点击两个菜单项会丢失第一个命令。扩展写入 → 发通知 → 容器读取之间有竞态窗口。

**修复建议**: 改为队列式（数组存储），或使用 XPC 连接实现同步请求-响应 IPC。

---

### 5. Tag 范围缺少上界检查

- **文件**: `FinderExtension/MenuActionHandler.swift:32-35`, `Shared/Constants.swift:30-37`
- **严重性**: Medium

**问题**: `TagBase` 从 `newFile = 2000` 跳到 `toggleHidden = 4000`（间隔 2000）。`default` 分支捕获所有 `tag >= 2000`，未来添加 3000+ 的 tag 会被误判为 newFile 模板索引。当前虽有 `index < config.newFileTemplates.count` 的边界检查不会导致越界，但会静默忽略而不是报错。

**修复建议**: 添加上界检查 `tag >= TagBase.newFile.rawValue && tag < TagBase.newFile.rawValue + 1000`，或为每种动作类型添加独立的 enum case。

---

### 6. PreferenceStore 持锁做文件 I/O

- **文件**: `Shared/Preferences/SharedUserDefaults.swift:100-105`
- **严重性**: Medium

**问题**: `persist()` 在 `NSLock` 内执行文件写入，阻塞所有读操作。Finder 调用 `menu(for:)` 时若触发读取，可能被写入阻塞导致菜单卡顿。

**修复建议**: 在锁内拷贝字典快照，释放锁后再执行 I/O：

```swift
func set(_ value: Any?, forKey key: String) {
    lock.lock()
    if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    let snapshot = storage as NSDictionary
    lock.unlock()
    // 在锁外执行 I/O
    try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    snapshot.write(to: fileURL, atomically: true)
}
```

---

### 7. 所有序列化错误被静默吞掉

- **文件**: `Shared/Preferences/SharedUserDefaults.swift:24,27,44,48`
- **严重性**: Medium

**问题**: 全部使用 `try?`，数据损坏或迁移失败时无任何日志，用户配置静默丢失且无法诊断。

**修复建议**: 至少在解码失败时记录日志：

```swift
do {
    return try JSONDecoder().decode(MenuConfiguration.self, from: data)
} catch {
    logger.error("Failed to decode MenuConfiguration: \(error.localizedDescription)")
    return .default
}
```

---

### 8. NewFileTemplate.id 可能重复

- **文件**: `Shared/Models/NewFileTemplate.swift:4`
- **严重性**: Medium

**问题**: `id` 由 `"\(name).\(fileExtension)"` 计算，同名的两个模板会产生相同 `id`，导致 SwiftUI 列表异常（重复 section 错误、选中错误项）。

**修复建议**: 添加 UUID 字段作为唯一标识：

```swift
public struct NewFileTemplate: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    // ...
    public init(name: String, fileExtension: String, defaultContent: String = "", id: UUID = UUID()) {
        self.id = id
        // ...
    }
}
```

---

### 9. Heartbeat 使用系统时钟

- **文件**: `Shared/IPC/Heartbeat.swift:34-42`
- **严重性**: Medium

**问题**: 用 `Date()` 判断存活，系统休眠/时钟校准/NTP 调整会导致误判（误以为对方已死）。

**修复建议**: 改用 `ProcessInfo.processInfo.systemUptime` 做相对时间比较，或在唤醒通知后重置心跳时间戳。

---

### 10. Timer 未在 deinit 中 invalidate

- **文件**: `FinderExtension/FinderSync.swift:42-48`, `mac-right-menu/ViewModels/AppState.swift:41-51`
- **严重性**: Medium

**问题**: `heartbeatTimer` 只在 `handleShutdownNotification` 中 invalidate，扩展被 Finder 直接杀死时 Timer 泄漏。Finder 扩展使用 XPC run loop，`Timer.scheduledTimer` 可能不被正确触发。

**修复建议**: 添加 `deinit` 清理 Timer；扩展端考虑改用 `DispatchSourceTimer`（不依赖 RunLoop）。

---

### 11. 模板扩展名无输入校验

- **文件**: `mac-right-menu/Views/NewFileSettingsTab.swift:83`
- **严重性**: Medium

**问题**: 扩展名输入接受空格、斜杠等特殊字符，可能生成无效文件名（如 `my file/txt`）。

**修复建议**: 校验扩展名不含路径分隔符和空白字符，自动去除前导点号。

---

### 12. Cancel 按钮不重置表单状态

- **文件**: `mac-right-menu/Views/NewFileSettingsTab.swift:89`
- **严重性**: Medium

**问题**: 取消新建模板后再次打开 Sheet，残留上次的输入内容。Add 按钮会重置，Cancel 不会。

**修复建议**: Cancel 操作中也添加 `newName = ""; newExtension = "txt"`。

---

## 🟢 P3 — 低优先级（改善代码质量）

### 13. `icon(_:)` 每次右键都重新创建 NSImage

- **文件**: `FinderExtension/MenuBuilder.swift:13-27`
- **问题**: 每次调用 `icon(_:)` 都执行 `lockFocus()` / `unlockFocus()` / `draw(in:)`，每次右键为每个菜单项重复绘制。
- **建议**: 缓存图标到静态字典，在外观变化时失效。

### 14. `isProductionMode` 每次动作都查询 `runningApplications`

- **文件**: `FinderExtension/FinderSync.swift:13-15`
- **问题**: 计算属性每次访问都调用 `NSRunningApplication.runningApplications(withBundleIdentifier:)`。
- **建议**: 在 `init()` 中缓存，仅在 `settingsChanged` 通知时更新。

### 15. MenuBuilder 缩进不一致

- **文件**: `FinderExtension/MenuBuilder.swift:9-11`
- **问题**: `isDarkMode` 和 `icon(_:)` 方法多出 4 空格缩进。
- **建议**: 统一为 4 空格缩进。

### 16. `@unchecked Sendable` 重复声明

- **文件**: `Shared/Models/AppMenuItem.swift:4` vs `Shared/Preferences/MenuConfiguration.swift:47`
- **问题**: `AppMenuItem` 在类型定义（`@unchecked Sendable`）和 extension 中各声明了一次 `@unchecked Sendable`。`ActionMenuItem`、`NewFileTemplate` 同理。
- **建议**: 删除 `MenuConfiguration.swift:45-49` 中的重复声明。

### 17. SettingsView 与子视图 frame 矛盾

- **文件**: `mac-right-menu/Views/SettingsView.swift:27` vs `mac-right-menu/Views/ActionsSettingsTab.swift:59`
- **问题**: 外层 `frame(width: 500)`，子视图 `minWidth: 560`，外层宽度总是被覆盖。
- **建议**: 对齐内外层 frame 值，或移除子视图的尺寸约束。

### 18. 通知名未统一到 Constants

- **文件**: `mac-right-menu/mac_right_menuApp.swift:29-31`
- **问题**: `"openSettingsWindow"` 使用 `Notification.Name` 扩展定义，而跨进程通知都通过 `Constants.Notifications.*`。
- **建议**: 添加到 `Constants.Notifications`（或作为进程内通知说明两者风格不同的原因）。

### 19. `restartFinder()` 使用已废弃 API

- **文件**: `mac-right-menu/ViewModels/AppState.swift:53-58`
- **问题**: 使用 `Process.launchPath` / `Process.launch()`（已废弃），应改用 `executableURL` / `run()`。
- **建议**: 改为 `task.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); task.arguments = ["Finder"]; try task.run()`。

### 20. SettingsSync 未返回观察者 token

- **文件**: `Shared/IPC/SettingsSync.swift:26-36`
- **问题**: `addObserver` 返回的 token 被丢弃，无法取消订阅。
- **建议**: 返回 `NSObjectProtocol` token 给调用方管理。

### 21. `menu(for:)` 仅处理 `contextualMenuForItems`

- **文件**: `FinderExtension/FinderSync.swift:59`
- **问题**: `guard menuKind == .contextualMenuForItems else { return NSMenu() }` 忽略了 toolbar/sidebar/gear menu。
- **建议**: 添加注释说明这是有意为之的设计决定。

---

## ✅ 值得肯定的方面

- 清晰的职责分离：FinderSync / MenuBuilder / MenuActionHandler 各司其职
- IPC 转发架构（策略 C）巧妙绕过沙盒限制，Extension 不碰文件
- 直接读写 Extension 容器内 plist 实现跨进程数据共享，无需 App Group
- 心跳机制实现容器与扩展的双向存活检测
- `os_log` 统一日志输出，方便调试
- `LSUIElement = true` 正确隐藏 Dock 图标，适合菜单栏工具类应用
- `ContentUnavailableView` 空状态处理良好
