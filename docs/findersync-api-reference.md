# FinderSync Framework API 参考

> 来源: Apple Developer Documentation
> 日期: 2026-06-03
> 适用: macOS 26 (Tahoe) + Swift 6.3

## FIFinderSyncProtocol

```swift
protocol FIFinderSyncProtocol : NSObjectProtocol
```

由 Finder Sync Extension 的主类实现。在 Swift 实现中，主类通常继承自 `FIFinderSyncController`。

### 必需方法

```swift
func beginObservingDirectory(at url: URL)
```
开始观察指定目录的文件变化。

```swift
func endObservingDirectory(at url: URL)
```
停止观察指定目录。

```swift
func requestBadgeIdentifier(for url: URL)
```
获取文件/目录的 badge 标识字符串（用于在 Finder 中显示角标）。

### 可选方法

```swift
func menu(for menuKind: FIMenuKind) -> NSMenu?
```
提供自定义右键菜单。核心方法。

```swift
func lastUsedDate(for url: URL) -> Date?
func setLastUsedDate(_: Date?, for url: URL)
func tagNames(for url: URL) -> Set<String>
func setTagNames(_: Set<String>, for url: URL)
func url(forItemWithPersistentIdentifier: Any) -> URL?
func persistentIdentifierForItem(at url: URL) -> Any?
```

## FIFinderSyncController

单例控制器，Finder Sync Extension 的主类必须继承自它。

```swift
class FIFinderSyncController : NSObject, FIFinderSyncProtocol
```

### 关键属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `shared` | `class var` | 单例 |
| `directoryURLs` | `Set<URL>` | 观察的目录（决定菜单在哪显示） |
| `menuItems` | `[FIMenuItem]` | 菜单项数组 |

### 关键方法

```swift
// 注册 badge 图片
func setBadgeImage(_ image: NSImage, label: String, forBadgeIdentifier identifier: String)

// 为特定菜单类型设置菜单项
func setMenuItem(_ menuItem: FIMenuItem?, for menu: FIMenuKind)

// 获取用户选中的文件 URL（仅在菜单回调中有效！）
func selectedItemURLs() -> [URL]?
```

### 重要限制 — `selectedItemURLs()`

`selectedItemURLs()` **只在以下情况返回有效值**：
1. `menu(for:)` 方法调用期间
2. 菜单项 action 被用户点击时（同步回调）

**以下情况返回 `nil`：**
- 通过 IPC / 全局快捷键 / Timer 等非菜单路径调用
- 用户点击的是 toolbar button 而非右键菜单项
- 选中的文件不在 extension 管理的目录内

## FIMenuItem

```swift
class FIMenuItem : NSObject, NSCopying
```

### Initializer

```swift
init(title: String, image: NSImage?, action: Selector?, keyEquivalent charCode: String)
```

### 属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `title` | `String` | 菜单标题 |
| `image` | `NSImage?` | 图标 |
| `action` | `Selector?` | action 选择器（必须在主类上实现） |
| `keyEquivalent` | `String` | 键盘快捷键（**实际被忽略**） |
| `tag` | `Int` | 标识 tag |
| `state` | `NSControl.StateValue` | 勾选状态 |
| `submenu` | `[FIMenuItem]?` | 子菜单 |
| `toolTip` | `String?` | 提示文字 |
| `isAlternate` | `Bool` | 是否是 Option 键备选项 |
| `indentationLevel` | `Int` | 缩进层级 |

### 重要限制
- ❌ 不支持自定义 `view`（NSView-based menu item）
- ❌ 不支持自定义 target（action 必须在 `FIFinderSyncController` 子类上实现）
- ❌ `keyEquivalent` 实际被 Finder 忽略，不显示也不生效
- ✅ 支持 `title`, `image`, `action`, `enabled`, `tag`, `state`, `indentationLevel`, `submenu`

## FIMenuKind

```swift
struct FIMenuKind : RawRepresentable, Equatable, Hashable
```

| 常量 | Raw Value | 说明 |
|------|-----------|------|
| `.contextualMenuForItems` | 1 | 右键点击文件/文件夹 |
| `.contextualMenuForContainer` | 2 | 右键点击 Finder 窗口空白处 |
| `.contextualMenuForSidebar` | 3 | 右键点击侧边栏 |
| `.toolbarItemMenu` | 4 | 点击 toolbar 按钮 |

## Info.plist 配置

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict/>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.FinderSync</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).FinderSync</string>
</dict>
```

**注意**: Swift 项目必须在类名前加模块名（`$(PRODUCT_MODULE_NAME).FinderSync`），Objective-C 可以直接用类名。
