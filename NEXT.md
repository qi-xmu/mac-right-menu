# NEXT.md

> 待办与设计差异，按优先级排列。
> 更新: 2026-06-22（Debug Log 已集成；RPCActivity 编译警告已修复）

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

### 2. 固定端口 57421 的冲突处理缺失

`RPCServer.start()` 监听失败仅 `logger.error`（`RPCSession.swift:237-238`），不尝试备用端口，也不通知 UI。

**可选方案**：
- A. 监听失败后尝试 +1/+2 端口，写入 App Group 文件供 Extension 读取（注意 App Group 文件 I/O 有 TCC 风险，见 `DENY.md`）
- B. 监听失败后弹 Toast 提示用户释放端口（开发期足够）
- C. 改用 `NWEndpoint` + Bonjour 服务发现（较重，长期方案）

---

## 🔵 P2 — 长期优化 / 打磨

### 3. 新建文件模板：从模板文件载入内容

当前每个模板（由「文件名 + 后缀」定义，如 未命名.md）都创建**空内容**文件，用户无法预设模板内容（如 Markdown 的 `# 标题\n`、JSON 的 `{}` 骨架）。

**现状**：

| 环节 | 状态 |
|---|---|
| `NewFileTemplate.defaultContent: String` | ✅ 字段存在，但内置默认模板全部为空（`""`） |
| `NewFileSettingsTab` Add Template sheet | ❌ 仅可填 fileName / extension，**无内容输入** |
| `AppState.executeCommand(.newFile)` 写文件 | ✅ 已用 `template.defaultContent`（`AppState.swift:477`），但永远写空 |
| 用户自定义模板内容 | ❌ 无任何 UI 入口 |

**待办**：
1. `NewFileSettingsTab` 列表行/编辑入口：新增「选择模板文件…」按钮（`NSOpenPanel`），按模板后缀过滤（仅允许选该后缀文件），读取内容写入 `template.defaultContent`。
2. 预览：列表行点击展开 / 二级 sheet 展示当前模板内容（只读多行文本预览）。
3. （可选）内置模板恢复常用骨架：md→`# \n`、json→`{\n  \n}\n`，并提供「恢复内置内容」按钮。
4. 持久化：`defaultContent` 已随 `MenuConfiguration` 存入各进程独立 `UserDefaults.standard`，通过 RPC 同步；注意大文件会让配置体积膨胀，需评估上限（建议限制 < 1MB，超限提示）。

**涉及文件**：`mac-right-menu/Views/NewFileSettingsTab.swift`（`NSOpenPanel` + 预览）、`Shared/Models/NewFileTemplate.swift`（无需改字段）。

**不在本期范围**：模板内容的版本管理 / 多版本、模板内容用文件路径引用而非内联（架构级改动）。

---

## 📌 优先级建议

1. **P1.1 Shell 菜单项**（功能完整性，最直接的用户价值）
2. **P1.2 端口冲突**（开发期偶发，可低优先级）
3. **P2.3 模板文件载入内容**（提升新建文件实用性，与 P1.1 并列推进）
4. P2.* 按需推进
