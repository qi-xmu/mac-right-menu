# 沙箱策略优劣对比

> 日期: 2026-06-03
> 适用范围: macOS 26 (Tahoe), Swift 6.3, Xcode 16+

## 快速结论

| 你的目标 | 推荐策略 |
|---------|---------|
| **仅 Mac App Store 分发** | ✅ 沙箱 + `user-selected.read-write` + App-Scope Bookmark |
| **仅 Developer ID 外部分发** | ✅ 无沙箱 + App-Scope Bookmark（最简单，如 RClick） |
| **两个渠道都要** | ⚠️ 沙箱 + `user-selected.read-write` + App Group + IPC 转发操作至 Container |
| **不发布，自用** | ✅ 无沙箱（Developer ID） |

---

## Finder Sync Extension 沙箱规则

### 核心事实：Extension 不一定需要沙箱

Apple 文档和历史版本说 Finder Sync Extension 必须开启沙箱（否则 `pkd` 会拒绝加载），但 **RClick 项目实际在 macOS 26 上以无沙箱方式运行**（Container App 和 Extension 均无 `com.apple.security.app-sandbox`）。这意味着：

- ✅ **macOS 26 已允许无沙箱的 Finder Sync Extension 加载**
- ✅ **Developer ID 外部分发完全可行**
- ❌ **Mac App Store 仍然要求沙箱**

### 三种可行方案

```
方案 A: 无沙箱 (RClick 方式)
─────────────────────────────────────
Container:   application-groups ✅
             files.bookmarks.app-scope ✅
             app-sandbox ❌ (不设置)
Extension:  application-groups ✅ (与 Container 同 group)
             files.bookmarks.app-scope ✅
             app-sandbox ❌ (不设置)

方案 B: 开沙箱 + 临时例外 (MenuHelper 方式)
─────────────────────────────────────
Container:   app-sandbox ✅
             files.user-selected.read-only ✅
Extension:  app-sandbox ✅
             temporary-exception.files.absolute-path.read-only = "/"
             files.user-selected.read-write ✅

方案 C: 开沙箱 + Bookmark (Apple 推荐方式)
─────────────────────────────────────
Container:   app-sandbox ✅
             files.bookmarks.app-scope ✅
             files.user-selected.read-write ✅
Extension:  app-sandbox ✅ (Finder Sync 强制要求)
             files.bookmarks.app-scope ✅
             files.user-selected.read-write ✅
             application-groups (共享 Bookmark)
```

---

## 详细对比

### 方案 A：无沙箱（RClick）

**Entitlements:**
```xml
<!-- Container & Extension 两者完全相同 -->
<key>com.apple.security.application-groups</key>
<array><string>group.cn.wflixu.RClick</string></array>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

| 维度 | 评价 |
|------|------|
| 文件访问 | ⭐ **完全访问**。Extension 和 Container 均可访问用户选择的带 bookmark 的目录，通过 `NSWorkspace`、`FileManager` 等 |
| IPC 通信 | ✅ `DistributedNotificationCenter` 正常工作 |
| 代码签名 | ✅ Developer ID + Hardened Runtime（非 MAS 不需要沙箱） |
| 上架 MAS | ❌ **无法上架**。无沙箱的 App 不被 MAS 接受 |
| 用户隐私 | ⚠️ 无 TCC 提示，用户需信任开发者 |
| 开发复杂度 | ⭐ **最低**。无需处理沙箱权限问题、无需 `startAccessingSecurityScopedResource()` |
| 实际项目 | **RClick** — 已发布，无沙箱正常运行 |

### 方案 B：开沙箱 + 临时例外（MenuHelper）

**Container App Entitlements:**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

**Extension Entitlements:**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<string>/</string>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

| 维度 | 评价 |
|------|------|
| 文件访问 | ⚠️ Extension 可读 `/` 下所有文件（通过临时例外），Container 只能读用户选择的文件 |
| IPC 通信 | ✅ `DistributedNotificationCenter` 正常工作 |
| 代码签名 | ✅ Developer ID + Hardened Runtime（MAS 也可能接受） |
| 上架 MAS | ⚠️ **极大概率被拒**。Apple 明确禁止 `temporary-exception` 类 entitlement 用于 MAS |
| 用户隐私 | ⚠️ 临时例外绕过 TCC，可能引起用户警觉 |
| 开发复杂度 | 中。需处理沙箱+例外，但比纯沙箱简单 |
| 实际项目 | **MenuHelper** — 但 MAS 未上架 |

### 方案 C：开沙箱 + Bookmark（Apple 推荐）

**Container App Entitlements:**
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

**Extension Entitlements:** 同 Container

| 维度 | 评价 |
|------|------|
| 文件访问 | ⚠️ 只能访问用户通过 `NSOpenPanel` 选择的目录（及其子目录）。有已知 bug: `selectedItemURLs()` 返回的 URL 即使调用 `startAccessingSecurityScopedResource()` 也可能被沙箱拒绝 |
| IPC 通信 | ✅ `DistributedNotificationCenter` |
| 代码签名 | ✅ Hardened Runtime（MAS 中非必需但推荐） |
| 上架 MAS | ✅ **可上架**。Apple 接受此模式 |
| 用户隐私 | ✅ 用户明确选择目录，TCC 授权 |
| 开发复杂度 | ⭐ **最高**。需处理：Container 创建 bookmark → 传给 Extension → Extension 创建自己的 bookmark → `startAccessingSecurityScopedResource()` → 文件操作 → `stopAccessingSecurityScopedResource()`。且需处理 bookmark stale 和已知 bug |
| 实际项目 | **FinderUtilities** — 但使用了临时例外来解决实际访问问题 |

---

## 文件访问能力矩阵

### Extension 内直接访问（menu action 回调内）

| 场景 | 无沙箱(A) | 沙箱+例外(B) | 沙箱+Bookmark(C) |
|------|:---------:|:------------:|:----------------:|
| 读取 `targetedURL()` 的文件 | ✅ | ✅ | ⚠️ 已知 bug |
| 写入 `selectedItemURLs()` 的文件 | ✅ | ⚠️ 只读例外 | ❌ 沙箱拒绝 |
| 创建新文件在右键目录 | ✅ | ⚠️ 临时例外允许 | ❌ 需要 bookmark |
| 删除/隐藏文件 | ✅ | ❌ 只读例外 | ❌ 需要 bookmark |
| 读取系统目录（/Library/等） | ✅ | ✅ (例外) | ❌ |
| 读取外置硬盘 | ✅ | ✅ (例外) | ❌ |
| 设置文件的隐藏属性 | ✅ | ❌ | ❌ |

### Container App 内操作（IPC 转发后）

| 场景 | 无沙箱(A) | 沙箱+例外(B) | 沙箱+Bookmark(C) |
|------|:---------:|:------------:|:----------------:|
| 读取 `targetedURL()` 的文件 | ✅ | ✅ (需 IPC 传 URL) | ⚠️ 需 bookmark |
| 创建新文件 | ✅ | ✅ (需 IPC 传路径) | ⚠️ 需 bookmark 父目录 |
| 删除文件 | ✅ | ⚠️ 只读 | ❌ |
| 通过 `NSWorkspace` 打开App | ✅ | ✅ | ✅ |
| 通过 `Process()` 执行命令 | ✅ | ⚠️ 沙箱限制 | ⚠️ 沙箱限制 |

---

## Distribution 渠道限制

| 渠道 | 沙箱 | Hardened Runtime | Notarization |
|------|:----:|:----------------:|:------------:|
| **Mac App Store** | ✅ 必须 | ⬜ 可选 | ❌ 不需要 |
| **Developer ID（外部）** | ⬜ 可选 | ✅ 必须 | ✅ 必须 |
| **Ad-hoc / 开发** | ⬜ 可选 | ⬜ 可选 | ❌ 不需要 |

**外部发布的组合限制：**
- 无沙箱 + Hardened Runtime + Notarization → 可发布，无需 MAS
- 有沙箱 + Hardened Runtime + Notarization → 可发布，也是 MAS 合规的

---

## Apple DTS 承认的沙箱 Bug

`selectedItemURLs()` 在沙箱环境中返回的 URL **即使调用了 `startAccessingSecurityScopedResource()` 也无法访问**。这是 macOS 已知问题，Apple DTS 工程师的官方回复是：「建议开启 DTS 技术支持工单」。

**影响：**
- 所有需要直接在 Extension 内读写用户选中文件的场景（方案 C 受影响最大）
- 解决方案（来自社区）：
  1. 将 URL 通过 IPC 发给 Container App，Container 用自己保存的 security-scoped bookmark 来操作 —— 前提是 Container 提前通过 `NSOpenPanel` 让用户选择过该目录
  2. 使用无沙箱模式避免此问题
  3. 使用临时例外绕过

---

## 推荐策略

### 方案优先级

```
需要 MAS 发布?
├─ 是 → 方案 C（沙箱+Bookmark）+ 所有操作通过 IPC 转发到 Container
│        Container 预先让用户选择目录 → 存 Bookmark → 通过 IPC 传给 Extension
│        Extension 只负责菜单展示，不直接做文件操作
│
├─ 否，但考虑未来 MAS
│     └─ 同方案 C（保持兼容）
│
└─ 否，仅外部发布
     └─ 方案 A（无沙箱，RClick 方式）
        最简单、功能最全、无已知 bug
```

### 决策树

```
你希望上架 Mac App Store 吗？
│
├─ ✅ 是
│   ├─ 你需要读写任意文件系统路径吗？
│   │   ├─ ✅ 是 → 无法 MAS，改用 Developer ID 分发
│   │   └─ ❌ 否 → 方案 C：沙箱 + Bookmark
│   │              + 所有文件操作在 Container 侧执行
│   │              + 使用 NSOpenPanel 让用户授权目录
│   │              + App-Scope Bookmark 持久化权限
│   │
│   └─ 注：MAS 下 MenuHelper 方式（临时例外）会被拒
│
└─ ❌ 否（Developer ID 外部发布）
    ├─ 方案 A：无沙箱（RClick 方式）✅ 推荐
    │   ├─ 不需要 NSOpenPanel
    │   ├─ 不需要 Security-Scoped Bookmark
    │   ├─ 不需要处理沙箱 bug
    │   └─ Hardened Runtime + Notarization 即可发布
    │
    └─ 方案 B：沙箱 + 临时例外
        适合特定场景，但不如方案 A 简单
```

---

## 实践指南

### 方案 A（无沙箱）必需步骤

1. **Hardened Runtime** 必须在 Xcode 中开启（用于 Notarization）
2. **Notarization** 每次发布前执行
3. Container 和 Extension 的 entitlements 同步（使用相同 App Group）
4. `DistributedNotificationCenter` 用于 IPC
5. App Group Container 用于共享数据

**Entitlements（Container & Extension 完全相同）:**
```xml
<key>com.apple.security.application-groups</key>
<array><string>group.com.example.mac-right-menu</string></array>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

### 方案 C（沙箱 + Bookmark）必需步骤

1. **Container App** 显示 `NSOpenPanel` 让用户选择要监视的目录
2. **Container** 创建 App-Scope Security-Scoped Bookmark：
   ```swift
   let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
       includingResourceValuesForKeys: nil, relativeTo: nil)
   ```
3. **Container** 通过 App Group UserDefaults 或 IPC 将 Bookmark Data 传给 Extension
4. **Extension** 需要创建 **自己的** Bookmark（App-Scope Bookmark 不能跨进程使用）
5. 每个进程各自 `startAccessingSecurityScopedResource()` 后操作文件
6. 操作完成后必须 `stopAccessingSecurityScopedResource()`（防内核泄漏）
7. Extension 不直接做文件操作，通过 IPC 转发到 Container 并由 Container 的 Bookmark 授权执行

---

## 各项目实际采用的策略

| 项目 | Container Sandbox | Extension Sandbox | 文件访问方式 | 可上架 MAS | 实际发布渠道 |
|-----|:-----------------:|:-----------------:|:-----------:|:----------:|:----------:|
| **RClick** | ❌ 无 | ❌ 无 | Bookmark + 直接文件操作 | ❌ 不可 | GitHub Releases |
| **MenuHelper** | ✅ 有 (read-only) | ✅ 有 + 临时例外(`/` 只读) | 临时例外 + IPC | ⚠️ 可能被拒 | — |
| **FinderUtilities** | ✅ 有 | ✅ 有 + 临时例外(`/` 读写) | 临时例外 | ❌ 被拒 | GitHub Releases |
| **OpenInTerminal** | — | — | Toolbar 模式 | ⚠️ | Homebrew Cask |

---

## 参考资源

- [App Sandbox 设计指南 (Apple)](https://developer.apple.com/documentation/security/app_sandbox)
- [Hardened Runtime 指南 (Apple)](https://developer.apple.com/documentation/security/hardened_runtime)
- [Security-Scoped Bookmarks (Apple)](https://developer.apple.com/documentation/foundation/nsurl/1417051-bookmarkdata)
- [Finder Sync Extension 已知 Sandbox Bug (Apple Forums)](https://developer.apple.com/forums/thread/717098)
- [RClick - 无沙箱 Finder Extension 实现](https://github.com/wflixu/RClick)
- [MenuHelper - 沙箱 + 临时例外实现](https://github.com/Kyle-Ye/MenuHelper)
