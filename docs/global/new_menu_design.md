# 新菜单设计

目标 重构 FinderExtension 设计

## 菜单设计

菜单设计 完全依赖于 Container Config

Config 定义伪代码如下 

```
struct Config {
  isEnable: bool  # 是否启用菜单
  showAppIcons: bool  # 是否显示图标
  menus: [MenuItem]  # 菜单项配置
}

struct MenuItem {
  isEnable: bool  # 是否启用该菜单 
  showAppIcons: bool  # 是否显示该图标

  # 显示条件
  showCondition: IS_FILE, IS_DIR, BOTH # 根据文件或者文件夹
  multiItemSupport: bool # 是否支持多个选取
  
  actionID: Int # 标识符
  icon: Icon  # 图标
  name: String  # 菜单项显示名称
  subMenus: [MenuItem] # 子菜单项
}
```

## 动作发送

Finder Extension 激活时发送 给 Container 的内容。

Action 定义的伪代码如下：

```
struct Action {
  actionID: Int # 动作标示符
  targetURL: URL # FIFinderSyncController.default().targetedURL()
  selectedURLs: [URL] # FIFinderSyncController.default().selectedItemURLs()
}
```

Container 根据 actionID 区分不同的动作执行。


## Container 动作执行


actionID      操作                      示例
───────       ────                      ────
0–999         新建文件模板              tag = 0 + templateIndex
1000–1999     Open With App             tag = 1000 + appIndex
2000–2999     通用操作                  tag = 2000 + offset
              ├─ 2000  copyPath
              ├─ 2001  copyFileName
              └─ 2002  toggleHidden
4000–4999     自定义命令 (shell)         tag = 4000 + shellIndex（未实现）

ActionDefMap<Int, ActionDef> 伪代码为 
``` 
actionDef = actionMap[actionID]

struct ActionDef {
  actionID: Int 
  actionType: NEW_FILE, OPEN_WITH, GENERAL, CUSTIOM
  ...
}

```
