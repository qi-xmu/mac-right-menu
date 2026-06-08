# macOS 权限模型分析

> 日期: 2026-06-08

## 三层权限体系

```
┌─────────────────────────────────────────────┐
│ 第三层：TCC / 完全磁盘访问权限                │
│ 控制访问其他 App 的受保护数据                 │
│ (Mail, Messages, Safari 等)                  │
│ 用户在系统设置中手动授权                       │
├─────────────────────────────────────────────┤
│ 第二层：App Sandbox                          │
│ 限制 App 能访问的文件系统范围                  │
│ 通过 entitlements 逐项申请例外                │
│ Finder Extension 必须开启                     │
├─────────────────────────────────────────────┤
│ 第一层：Hardened Runtime + Notarization       │
│ 防止代码注入，Gatekeeper 放行                 │
│ Developer ID 分发必须                         │
└─────────────────────────────────────────────┘
```

## 沙盒关键 Entitlement

| Entitlement | 作用 | 用途 |
|---|---|---|
| `app-sandbox` | 开启沙盒 | Finder Extension 必须开启 |
| `files.user-selected.read-only` | 读 NSOpenPanel 选中的文件 | 受限场景 |
| `files.user-selected.read-write` | 读写 NSOpenPanel 选中的文件 | 受限场景 |
| `files.bookmarks.app-scope` | 安全作用域书签 | 持久化文件权限 |
| `temporary-exception.files.absolute-path.read-only` | 沙盒临时例外（只读） | 绕过沙盒，但可能被拒 |
| `temporary-exception.files.absolute-path.read-write` | 沙盒临时例外（读写） | 绕过沙盒，但可能被拒 |

## 安全作用域书签 (Security-Scoped Bookmark) 流程

```
用户通过 NSOpenPanel 选择目录
    ↓
Container App 创建 Bookmark Data（加密令牌）
    ↓
存入选定 App Group UserDefaults
    ↓
Extension 读取 Bookmark Data
    ↓
调用 startAccessingSecurityScopedResource()
    ↓
获得临时文件访问权限
    ↓
操作文件
    ↓
调用 stopAccessingSecurityScopedResource()
```

## 三种策略对比

| | 策略 A 无沙盒 | 策略 B 临时例外 | 策略 C IPC 转发 |
|---|---|---|---|
| Extension 沙盒 | ❌ 关闭 | ✅ 开启 | ✅ 开启 |
| 权限弹窗 | 无 | 多次 TCC 弹窗 | 无 |
| Extension 加载 | ⚠️ 可能失败 | ✅ 正常 | ✅ 正常 |
| 代码复杂度 | 低 | 低 | 中 |
| MAS 上架 | ❌ | ❌ | ✅ |

## 最终选择：策略 C

将文件操作通过 IPC 转发到无沙盒的 Container App 执行，彻底规避所有沙盒相关问题。

### 核心架构

```
Finder → Extension(沙盒) → 收集用户意图 → 发指令 → Container App(无沙盒) → 操作文件 ✅
```

Extension 只负责两件事：
1. 向 Finder 提供右键菜单（`menu(for:)` → `NSMenu`）
2. 收集用户点击意图（操作类型 + 文件路径）→ 通过通信协议发给 Container

Container App 负责所有文件操作，无沙盒限制，也无需 TCC 权限弹窗。

**选择策略 C 的直接原因**：
1. macOS 已知 bug：沙盒中 `startAccessingSecurityScopedResource()` 对 `selectedItemURLs()` 返回的 URL 返回 false
2. `temporary-exception` 方案触发多次 TCC 权限弹窗，且 MAS 上架必定被拒

### 最终 Entitlements

```xml
<!-- Container App（无沙盒） -->
com.apple.security.application-groups = true

<!-- Finder Extension（最简化沙盒） -->
com.apple.security.app-sandbox = true
com.apple.security.finder.sync = true
com.apple.security.application-groups = true
```

## 参考

- [App Sandbox 设计指南 (Apple)](https://developer.apple.com/documentation/security/app_sandbox)
- [Finder Sync Extension 已知沙盒 Bug](https://developer.apple.com/forums/thread/717098)
- RClick - 无沙盒 Finder Extension 实现
- MenuHelper - 沙盒 + 临时例外实现
