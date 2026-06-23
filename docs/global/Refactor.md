# 按 new_menu_design.md 重构 FinderExtension（v3）

## Context（为什么做这个改动）

当前架构里 **Extension 端对菜单结构硬编码**：`MenuBuilder` 写死三分区，靠 `Constants.TagBase` 的 tag 区分；点击时 `MenuActionHandler` 把 tag 反解成类型化 `CommandRequest`。Extension 与业务强耦合，且持久化用类型化列表 `MenuConfiguration`（`appItems`/`actionItems`/`newFileTemplates`）。

`new_menu_design.md` 要求：**菜单结构完全由 Config 驱动**。Extension 变成与业务无关的通用渲染器——只渲染递归 `MenuItem` 树，点击只回传 `Action { actionID, targetURL, selectedURLs }`；Container 按 `actionID` 查 `ActionDefMap` 执行。

**v3 方向（本次确定）**：弃用 `MenuConfiguration` 及其类型化列表；文档的 `Config`（菜单树）+ `ActionDefMap`（动作表）成为**唯一配置源**，一同持久化。`MenuItem.actionID` 引用 `ActionDefMap` 中的定义。不再有"类型化列表 → 树"的编译步骤——树+表就是被持久化、被（未来 UI）直接编辑的源。

---

## 关键设计决策

### 决策 1：弃用 MenuConfiguration，新模型为唯一源（已定）

- 持久化根 = `AppConfig { menu: MenuConfig, actions: ActionDefMap }`。
  - `menu`（文档 Config，菜单树）→ RPC 推给 Extension 渲染。
  - `actions`（文档 ActionDefMap）→ Container 查表执行，**不发** Extension。
- 旧模型清理：`MenuItem` 协议、`ActionMenuItem`、`AppMenuItem`、`CommandRequest` 移除。功能负载保留为：`NewFileTemplate`、`AppTarget`（替代 AppMenuItem）、`GeneralOperation`（替代 ActionType 的通用操作子集）。

### 决策 2：`showCondition` + `multiItemSupport`

- 约定：右键**空白处归为 `.isDir` 上下文**（否则 New File 无法在空白处出现）。
- 可见性（Extension 侧，存入 `representedObject`）：
  `condOK = (isFile∧ctx==file) ∨ (isDir∧ctx==dir) ∨ both`；`multiOK = multiItemSupport || selected.count<=1`；`isHidden = !(condOK∧multiOK)`。

| 节点 | showCondition | multiItemSupport |
|---|---|---|
| New File 头 + 模板 | `.isDir` | `false` |
| Open With 头 + 应用（含单项直显） | `.both` | `true` |
| copyPath / copyFileName / toggleHidden | `.both` | `true` |

相对当前 2 处微调：① Open With + Copy 类也会在空白处出现（作用于所在文件夹）；② New File 多选时隐藏。

### 决策 3：actionID 区间 = 现有 `Constants.TagBase`（不改）

`0–999` newFile、`1000–1999` apps、`2000` copyPath / `2001` copyFileName / `2002` toggleHidden、`4000–4999` shell（未实现）。叶子节点带真实 actionID；非叶子（子菜单头）`action:nil`，其 actionID 不被派发。

### 决策 4：`ActionDefMap` 派发

`ActionDef` 用**枚举带关联值**承载各类型负载（文档的 `...`），`actionID` 即字典 key（不重复存储）：

```swift
enum ActionDefType { case newFile, openWith, general, custom }   // 文档 NEW_FILE/OPEN_WITH/GENERAL/CUSTOM
enum ActionDef {
  case newFile(template: NewFileTemplate)
  case openWith(app: AppTarget)
  case general(operation: GeneralOperation)
  case custom(command: String)        // 预留 shell，未实现
  var actionType: ActionDefType { ... }
}
typealias ActionDefMap = [Int: ActionDef]   // key = actionID
```

点击到达 → `actionMap[actionID]` 一次查表；config 变更后陈旧 actionID 要么命中要么 miss（记日志忽略），不会错位。

### 决策 5：保留全部功能；`showAppIcons` 双层

`Config.showAppIcons`（全局）AND `MenuItem.showAppIcons`（单项）同为真才显示图标。

---

## 第 1 步（本次执行）：定义 `Shared/Models/`

仅定义模型类型 + 弃用 `MenuConfiguration`。**第 1 步后构建会故意中断**（RPC/AppState/Extension/UI 仍引用旧类型），由后续步骤修复。

**新增：**
- `Shared/Models/MenuConfig.swift`
  - `MenuConfig { isEnabled, showAppIcons, menus: [MenuItem] }`（文档 Config）
  - `MenuItem { id, isEnabled, showAppIcons, showCondition, multiItemSupport, actionID, icon: MenuIcon, name, subMenus: [MenuItem] }`（文档 MenuItem，递归树节点；`id` 为 SwiftUI/diff 增加）
  - `ShowCondition { isFile, isDir, both }`
  - `MenuIcon { none, sfSymbol(String), appIcon(path: String) }`
- `Shared/Models/MenuAction.swift` — `MenuAction { actionID, targetURL: URL?, selectedURLs: [URL] }`（文档 Action；targetURL 可空因 `targetedURL()` 可为 nil）
- `Shared/Models/ActionDef.swift` — `ActionDefType`、`ActionDef`（枚举）、`ActionDefMap`、`GeneralOperation { copyPath, copyFileName, toggleHidden }`（含 displayTitle/systemIconName/localizedDescription）
- `Shared/Models/AppTarget.swift` — `AppTarget { appURL, displayName, arguments, environment }`（替代 AppMenuItem；图标由 `appURL` 经 NSWorkspace 取，enable 态移到 MenuItem）
- `Shared/Models/AppConfig.swift` — `AppConfig { menu: MenuConfig, actions: ActionDefMap }`（持久化根，替代 MenuConfiguration）+ `AppConfig.default`（种子：New File txt/md + 三个通用操作，布局同旧默认菜单）

**改写：**
- `Shared/Models/NewFileTemplate.swift` — 去掉 `isEnabled`（移到 MenuItem）与旧版 Codable 迁移，仅留 `{ fileName, fileExtension, defaultContent }` + resolved 辅助 + `defaults`

**删除：**
- `Shared/Models/MenuItem.swift`（旧协议 + ActionType）
- `Shared/Models/ActionMenuItem.swift`
- `Shared/Models/AppMenuItem.swift`
- `Shared/Models/CommandRequest.swift`
- `Shared/Preferences/MenuConfiguration.swift`

**保留不动：** `DebugLogEntry`/`ExecutionLogEntry`/`ExtensionInfo`、`CommandResult`、`Constants`（`TagBase` 不变）。

---

## 后续步骤（待逐步指令）

2. **持久化**：`SharedUserDefaults` 由 `MenuConfiguration` 改读/写 `AppConfig`。
3. **RPC**：`RPCResult.config`/`RPCNotification.params` → `MenuConfig`；新增 `executeAction`（携带 `MenuAction`）替换 `executeCommand`。
4. **AppState**：持有 `ActionDefMap`，`executeAction(actionID)` 查表派发；newFile 目录推导迁入 Container。
5. **Extension**：`MenuBuilder` 改通用递归渲染器；`FinderSync` 用 `MenuConfig`；点击只发 `MenuAction`。
6. **UI**：Settings 直接编辑树+表（Apps/Actions/File 视图重写）。

---

## 不变性 / 风险

- 持久化形状整体替换（旧 `MenuConfiguration` 数据不迁移——属于开发期重构）。
- `ActionDefMap` miss → 记日志忽略，不错位。
- actionID 区间与现有 `TagBase` 一致。
- 第 1 步后构建中断是预期的，后续步骤逐层修复。

## 验证（最终，第 6 步后）

构建（Debug+Release）→ 安装重启 → 三场景实测（文件/文件夹/空白处）每项动作 → 实时改 Config 即时生效 → 日志确认 actionID 解析正确。
