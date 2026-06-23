# 存储方案

> 日期: 2026-06-08（初版）
> 更新: 2026-06-23（MenuConfiguration → AppConfig；SharedUserDefaults.appConfig）
> 状态: 已实现

## 目标

为 Container App 和 Extension 提供配置（`AppConfig` = `MenuConfig` + `ActionDefMap`）的持久化存储。

## 当前实现：各自独立的 UserDefaults

Container App 和 Extension 各自维护自己的 `UserDefaults.standard` store（**非 App Group 共享**）。`SharedUserDefaults` 封装了对该 store 的读写。

```
Container App: ~/Library/Preferences/com.qi-xmu.mac-right-menu.plist
Extension:     ~/Library/Containers/.../Data/Library/Preferences/...plist
                        ▲              ▲
        Container App ──┤              ├── Extension
        (各自独立 store)                (各自独立 store)

        UserDefaults.standard:
        - 各进程读写自己的偏好
        - 非跨进程共享
```

### 配置同步

存储层**不跨进程共享**（App Group 共享 UserDefaults 已实测否决，见下方）。配置同步完全由 RPC 层承担，Extension 不读自己的 store：

- Container App：用户在设置 UI 修改配置 → 写入自己的 store → `saveConfiguration()` 调 `rpcServer.broadcastConfig(config.menu)`（推送 `MenuConfig`，`ActionDefMap` 不发 Extension）
- Extension：`cachedConfig` 初始为 `MenuConfig.default`；RPC 连接 `.ready` 时经 `getConfig` 主动向 Container 拉取当前 `MenuConfig`；运行期间经 `configDidChange` notification 接收 Container 推送的 `MenuConfig`。两条通道共用 `onConfigChange` 处理器更新内存缓存。

> **设计要点**：因为各进程 store 独立，`getConfig` 响应与 `configDidChange` 的 payload 携带 `MenuConfig`（菜单树），`ActionDefMap` 始终保留在 Container 内部（Extension 不需要执行定义）。
> **边界**：RPC 连接建立前 `cachedConfig` 是 `MenuConfig.default`；连接一建立立即刷新为真实配置。

## 被否决的方案

### App Group 共享 UserDefaults（已否决）

最初设想用 `UserDefaults(suiteName: group.com.qi-xmu.mac-right-menu)` 实现跨进程共享，但实测发现：
- `cfprefsd` 报 `detaching from cfprefsd` 警告
- Extension 沙盒报 `user-preference-read or file-read-data sandbox access` 拒绝

详见 `DENY.md`。

### 用户级目录共享文件（已否决）

更早的方案用 `~/Library/Application Support/mac-right-menu/SharedData.plist` + 自定义 `PreferenceStore`（NSLock + modificationDate 跨进程变更检测）。问题：
- Extension 沙盒无法访问该路径
- 绝对路径访问触发 TCC

## 当前代码

**文件**：`Shared/Preferences/SharedUserDefaults.swift`

```swift
public enum SharedUserDefaults {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static var appConfig: AppConfig {
        get { /* 从 defaults 读 Data，JSONDecoder 解码 */ }
        set { /* JSONEncoder 编码为 Data，写入 defaults */ }
    }
    // ...
}
```

## 影响

| 维度 | 说明 |
|------|------|
| 代码量 | 简洁，无自定义锁/变更检测逻辑 |
| 存储路径 | 各进程自己的偏好目录 |
| 跨进程同步 | **经 RPC**（连接时 `getConfig` 拉取 + 运行期间 `configDidChange` 推送 `MenuConfig`；`ActionDefMap` 不发 Extension；存储层本身不共享） |
| Extension 沙箱 | 无权限问题（读自己的容器内偏好） |
| 实时性 | RPC 连接建立即拉取最新 `MenuConfig`；Container 运行期间变更实时推送 |

