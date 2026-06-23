# NEXT.md

> 待办与设计差异，按优先级排列。
> 更新: 2026-06-23（同步菜单树重构：类型名/文件路径已更新）

---

## 🟡 P1 — 待完善（功能性缺口）

### 1. Shell 命令菜单项未接入（半成品状态）

当前 shell（`.custom`）动作仅有 reserved stub，端到端不通：

| 环节 | 状态 |
|---|---|
| `ActionDef.custom(command:)` | ✅ 已定义（`ActionDef.swift`） |
| `Constants.TagBase.shell = 4000` | ✅ 已定义（`Constants.swift:63`） |
| `AppState.executeAction` 分发 `.custom` | ⚠️ 仅 log + 返回 "not implemented"（`AppState.swift:812-816`） |
| `AppConfig.default` 种子包含 shell 项 | ❌ 无（默认 `ActionDefMap` 不含 `.custom`） |
| Settings UI 管理 shell 项 | ❌ 无对应 tab |
| `MenuItem` 树中 shell 叶子 | ❌ 无（需用户在 UI 添加） |

**待办**：
1. Container UI 增加 shell 项管理入口（新增 tab 或在 Actions tab 中扩展）
2. `AppState.executeAction` 的 `.custom` 分支实现 shell 执行（`/bin/bash -c`，`{}` 占位符替换为 `selectedURLs`）
3. 添加 shell 项时同步写入 `appConfig.menu.menus`（叶子 `MenuItem`）和 `appConfig.actions`（`ActionDef.custom(command:)`）
4. shell 路径需转义（空格、`$`、`` ` ``、`;`），防止命令注入

**涉及文件**：`mac-right-menu/ViewModels/AppState.swift`（`.custom` 分支）、`mac-right-menu/Views/`（新增/扩展 UI）、`Shared/Models/ActionDef.swift`（无需改）

### 2. 固定端口 57421 的冲突处理缺失

`RPCServer.start()` 监听失败仅 `logger.error`（`RPCSession.swift`），不尝试备用端口，也不通知 UI。

**可选方案**：
- A. ~~监听失败后尝试 +1/+2 端口~~ → 带外通道不可用，方案废弃（原 `docs/design/plan/port-conflict-resolution.md` 已删除）
- B. 监听失败后 UI 显示红 banner + 占用者探测（`lsof -i :57421`），引导用户释放端口
- C. 改用 Bonjour 服务发现（较重，长期方案）

---

## 🔵 P2 — 长期优化 / 打磨

### 3. 新建文件模板：从模板文件载入内容

当前每个模板（由「文件名 + 后缀」定义，如 `untitled.md`）都创建**空内容**文件，用户无法预设模板内容（如 Markdown 的 `# 标题\n`、JSON 的 `{}` 骨架）。

**现状**：

| 环节 | 状态 |
|---|---|
| `NewFileTemplate.defaultContent: String` | ✅ 字段存在，但内置默认模板全部为空（`""`） |
| `NewFileSettingsTab` Add Template sheet | ❌ 仅可填 fileName / extension，**无内容输入** |
| `AppState.performNewFile` 写文件 | ✅ 已用 `template.defaultContent`（`AppState.swift`），但永远写空 |
| 用户自定义模板内容 | ❌ 无任何 UI 入口 |

**待办**：
1. `NewFileSettingsTab` 列表行/编辑入口：新增「选择模板文件…」按钮（`NSOpenPanel`），按模板后缀过滤，读取内容写入 `template.defaultContent`。
2. 预览：列表行点击展开 / 二级 sheet 展示当前模板内容（只读多行文本预览）。
3. 持久化：`defaultContent` 已随 `AppConfig` 存入 `UserDefaults.standard`，通过 RPC 的 `MenuConfig` 同步给 Extension；注意大文件会让配置体积膨胀，需评估上限（建议限制 < 1MB，超限提示）。

**涉及文件**：`mac-right-menu/Views/NewFileSettingsTab.swift`、`Shared/Models/NewFileTemplate.swift`（无需改字段）。

---

## 📌 优先级建议

1. **P1.1 Shell 菜单项**（功能完整性，最直接的用户价值）
2. **P1.2 端口冲突**（开发期偶发，可低优先级）
3. **P2.3 模板文件载入内容**（提升新建文件实用性，与 P1.1 并列推进）
