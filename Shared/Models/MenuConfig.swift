import Foundation

/// The menu configuration consumed by the Finder Extension (the `Config` from
/// `new_menu_design.md`). The Container builds and persists this — as part of
/// `AppConfig` — and pushes it over RPC; the Extension renders `menus` into an
/// `NSMenu`. Execution data lives in `ActionDefMap`, not here: a leaf
/// `MenuItem.actionID` references an entry there.
public struct MenuConfig: Codable, Equatable, Sendable {
    /// Master switch. When false the Extension renders an empty menu.
    public var isEnabled: Bool
    /// Global icon toggle. A node's icon is shown only when this AND the node's
    /// own `showAppIcons` are both true.
    public var showAppIcons: Bool
    /// Top-level menu items. The tree is recursive via `MenuItem.subMenus`.
    public var menus: [MenuItem]

    public init(isEnabled: Bool = true, showAppIcons: Bool = true, menus: [MenuItem] = []) {
        self.isEnabled = isEnabled
        self.showAppIcons = showAppIcons
        self.menus = menus
    }

    /// Empty-but-enabled config, used as the baseline before the real config
    /// arrives from the Container over RPC.
    public static let `default` = MenuConfig()
}

/// A node in the menu tree (the `MenuItem` from `new_menu_design.md`).
///
/// Leaves (`subMenus` empty) carry an `actionID` that references an `ActionDef`
/// in the `ActionDefMap`; clicking them sends that `actionID` to the Container.
/// Non-leaf nodes are submenu headers — the renderer gives them no action
/// selector, so their `actionID` is never dispatched.
public struct MenuItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity for diffing / SwiftUI lists.
    public var id: String
    /// Per-node enable switch (false → the renderer skips this node).
    public var isEnabled: Bool
    /// Per-node icon switch (AND-ed with `MenuConfig.showAppIcons`).
    public var showAppIcons: Bool
    /// When to show this node based on the right-click target type.
    public var showCondition: ShowCondition
    /// When false, the node is hidden if more than one item is selected.
    public var multiItemSupport: Bool
    /// References an `ActionDef` by its actionID. Only meaningful for leaves.
    public var actionID: Int
    /// Icon source, resolved to `NSImage` by the Extension's renderer.
    public var icon: MenuIcon
    /// Display title.
    public var name: String
    /// Child nodes (empty ⇒ this node is a leaf).
    public var subMenus: [MenuItem]

    public init(
        id: String,
        isEnabled: Bool = true,
        showAppIcons: Bool = true,
        showCondition: ShowCondition = .both,
        multiItemSupport: Bool = true,
        actionID: Int = 0,
        icon: MenuIcon = .none,
        name: String,
        subMenus: [MenuItem] = []
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.showAppIcons = showAppIcons
        self.showCondition = showCondition
        self.multiItemSupport = multiItemSupport
        self.actionID = actionID
        self.icon = icon
        self.name = name
        self.subMenus = subMenus
    }
}

/// Visibility condition based on the right-click target (the
/// `IS_FILE | IS_DIR | BOTH` from the design doc). Right-clicking empty space
/// (no selection) counts as a directory context, so folder-oriented items such
/// as New File can appear there.
public enum ShowCondition: String, Codable, Sendable, CaseIterable {
    case isFile   // IS_FILE
    case isDir    // IS_DIR  (includes empty space)
    case both     // BOTH
}

/// Icon source for a menu item (the `Icon` from the design doc).
public enum MenuIcon: Codable, Equatable, Sendable {
    /// No icon.
    case none
    /// An SF Symbol name, rendered and tinted by the Extension.
    case sfSymbol(String)
    /// Absolute path to a `.app` bundle; resolved to its icon via NSWorkspace.
    case appIcon(path: String)
}
