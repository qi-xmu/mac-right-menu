import AppKit
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "menu-builder")

/// Generic, structure-agnostic menu renderer.
///
/// Given a `MenuConfig` (a recursive `MenuItem` tree owned by the Container),
/// `buildMenu` renders it into an `NSMenu` without knowing anything about what
/// the items *do* — leaf clicks carry only an `actionID` (stored as the
/// `NSMenuItem.tag`) which the Container resolves via its `ActionDefMap`.
///
/// Selection-dependent visibility is driven purely by per-node metadata
/// (`showCondition` + `multiItemSupport`), stashed in each item's
/// `representedObject` as a `NodeMeta`. `refreshSelectionState` re-applies that
/// metadata in place on every right-click — cheap property writes, no rebuild.
enum MenuBuilder {

    /// Per-item visibility metadata, attached to every `NSMenuItem` this
    /// builder creates (leaves AND submenu headers) so `refreshSelectionState`
    /// can hide/disable nodes without rebuilding the menu.
    final class NodeMeta {
        let showCondition: ShowCondition
        let multiItemSupport: Bool
        init(showCondition: ShowCondition, multiItemSupport: Bool) {
            self.showCondition = showCondition
            self.multiItemSupport = multiItemSupport
        }
    }

    /// The right-click target's type, classified by the Extension on each click.
    /// Empty space (no selection) counts as `.dir` (the containing folder), so
    /// folder-oriented items such as New File can appear there.
    enum TargetContext {
        case file   // at least one selected item is a file
        case dir    // folder(s) selected, or empty space
    }

    // MARK: - Icon caches

    private static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Cache of resolved SF Symbol images keyed by symbol name. Rebuilt only on
    /// appearance flip. Mutated only from `resolveIcon`, reached solely via
    /// `buildMenu`; since `menu(for:)` no longer builds menus, `buildMenu` runs
    /// only on the main thread (via `rebuildCachedMenu`). `warmupCaches` and
    /// `invalidateSymbolCache` are also main-dispatched. Main-only access makes
    /// `nonisolated(unsafe)` sound without a lock.
    nonisolated(unsafe) private static var symbolCache: [String: NSImage] = [:]

    /// Cache of per-file app icons from `NSWorkspace.shared.icon(forFile:)`,
    /// keyed by absolute path. Same main-only access guarantee as `symbolCache`.
    nonisolated(unsafe) private static var appIconCache: [String: NSImage] = [:]

    /// Resolve an SF Symbol to an NSImage sized/tinted for the menu. The symbol
    /// stays a lazily-rendered vector (color applied via SymbolConfiguration),
    /// which is far cheaper than a CPU-side `lockFocus` rasterization.
    private static func symbolIcon(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let color: NSColor = isDarkMode ? .white : .black
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        let resolved = symbol.withSymbolConfiguration(config) ?? symbol
        symbolCache[name] = resolved
        return resolved
    }

    /// Resolve an app icon, using the cached bitmap when the path was seen
    /// before. Falls back to a live `NSWorkspace.shared.icon(forFile:)` call
    /// (and caches it) on miss.
    private static func appIcon(forPath path: String) -> NSImage? {
        if let cached = appIconCache[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        appIconCache[path] = img
        return img
    }

    private static func resolveIcon(_ icon: MenuIcon) -> NSImage? {
        switch icon {
        case .none:               return nil
        case .sfSymbol(let name): return symbolIcon(name)
        case .appIcon(let path):  return appIcon(forPath: path)
        }
    }

    /// Drop cached SF Symbol images. Called when the appearance flips so symbol
    /// tinting is regenerated for the new mode. App icons are
    /// appearance-independent and kept.
    static func invalidateSymbolCache() {
        symbolCache.removeAll()
    }

    /// Eagerly populate both icon caches for the given config so the first
    /// right-click after process launch doesn't pay the rasterization cost on
    /// Finder's menu-critical path.
    ///
    /// Dispatched to the main thread because `NSWorkspace.icon(forFile:)` and
    /// SF Symbol resolution are main-thread APIs. Idempotent — both cache
    /// helpers early-return on a hit.
    static func warmupCaches(for config: MenuConfig) {
        DispatchQueue.main.async {
            var symbols = Set<String>()
            var paths = Set<String>()
            collectIcons(in: config.menus, symbols: &symbols, paths: &paths)
            for path in paths { _ = appIcon(forPath: path) }
            for name in symbols { _ = symbolIcon(name) }
            logger.notice("[Ext] MenuBuilder: icon caches warmed (\(paths.count) apps, \(symbols.count) symbols)")
        }
    }

    private static func collectIcons(in nodes: [MenuItem], symbols: inout Set<String>, paths: inout Set<String>) {
        for node in nodes {
            switch node.icon {
            case .sfSymbol(let name): symbols.insert(name)
            case .appIcon(let path):  paths.insert(path)
            case .none: break
            }
            collectIcons(in: node.subMenus, symbols: &symbols, paths: &paths)
        }
    }

    // MARK: - Build

    /// Build the full `NSMenu` for a config. `target`/`action` are wired onto
    /// every leaf; submenu headers get no action (their `actionID` is never
    /// dispatched). A node's icon shows only when both the global
    /// `config.showAppIcons` and the node's own `showAppIcons` are true.
    static func buildMenu(config: MenuConfig, target: AnyObject, action handlerSelector: Selector) -> NSMenu {
        let menu = NSMenu(title: String(localized: "mac-right-menu"))
        for node in config.menus {
            addNode(node, to: menu, target: target, action: handlerSelector, iconsShown: config.showAppIcons)
        }
        return menu
    }

    private static func addNode(_ node: MenuItem, to menu: NSMenu, target: AnyObject, action handlerSelector: Selector, iconsShown: Bool) {
        guard node.isEnabled else { return }
        let showImage = iconsShown && node.showAppIcons
        let meta = NodeMeta(showCondition: node.showCondition, multiItemSupport: node.multiItemSupport)

        if node.subMenus.isEmpty {
            // Leaf: carries the actionID the Container will resolve.
            let item = NSMenuItem(title: node.name, action: handlerSelector, keyEquivalent: "")
            item.target = target
            item.tag = node.actionID
            item.representedObject = meta
            if showImage { item.image = resolveIcon(node.icon) }
            menu.addItem(item)
        } else {
            // Submenu header: no action; its visibility drives the whole
            // section (hiding the header hides its submenu too).
            let header = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
            header.representedObject = meta
            if showImage { header.image = resolveIcon(node.icon) }
            let submenu = NSMenu(title: node.name)
            for child in node.subMenus {
                // Pass the original iconsShown (global toggle) — NOT showImage
                // (which incorporates the parent's per-node setting). Each node
                // independently evaluates iconsShown && itsOwnShowAppIcons, so
                // a section header's ikon preference doesn't leak into its
                // children (e.g. "Show App Icons" toggle in the Apps tab should
                // only gate the section header's SF Symbol, not the individual
                // app leaf icons).
                addNode(child, to: submenu, target: target, action: handlerSelector, iconsShown: iconsShown)
            }
            menu.setSubmenu(submenu, for: header)
            menu.addItem(header)
        }
    }

    // MARK: - Per-click refresh

    /// Re-apply each item's `showCondition` / `multiItemSupport` against the
    /// current click context, in place. The only thing that changes between
    /// clicks for a fixed config is the selection, so this is cheap property
    /// writes — no menu rebuild.
    static func refreshSelectionState(_ menu: NSMenu, context: TargetContext, selectedCount: Int) {
        for item in menu.items {
            let meta = item.representedObject as? NodeMeta
            let condOK: Bool
            switch meta?.showCondition ?? .both {
            case .isFile: condOK = (context == .file)
            case .isDir:  condOK = (context == .dir)
            case .both:   condOK = true
            }
            let multiOK = (meta?.multiItemSupport ?? true) || selectedCount <= 1
            var visible = condOK && multiOK
            // Refresh children first, then collapse a section header whose
            // submenu has no visible leaves — an empty "Open With ▸" is just
            // clutter. (Recursing before writing this item is safe: they touch
            // different NSMenuItem objects.)
            if let submenu = item.submenu {
                refreshSelectionState(submenu, context: context, selectedCount: selectedCount)
                if !submenu.items.contains(where: { !$0.isHidden }) { visible = false }
            }
            item.isHidden = !visible
            item.isEnabled = visible
        }
    }
}
