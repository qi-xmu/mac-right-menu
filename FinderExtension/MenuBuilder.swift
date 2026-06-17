import AppKit
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "menu-builder")

/// Builds the NSMenu hierarchy from MenuConfiguration.
///
/// Performance: `menu(for:)` is invoked by Finder on EVERY right-click, and the
/// cost of building a menu is dominated by image generation — not NSMenuItem
/// allocation. Two paths are expensive:
///   1. `NSWorkspace.shared.icon(forFile:)` — reads the app bundle off disk
///      and rasterizes its icon.
///   2. `icon(_:)` below — `NSImage(systemSymbolName:)` + `lockFocus` to bake a
///      tinted bitmap. Each call re-decodes the symbol and re-renders pixels.
/// Both are pure functions of their input (file path / symbol name) and never
/// change within a process lifetime unless the source file changes, so they are
/// memoized here. NSMenuItem construction itself is cheap pointer wiring and is
/// left to run each call — that keeps menu(for:) free of any cross-thread menu
/// object reuse concerns.
enum MenuBuilder {

        private static var isDarkMode: Bool {
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }

        /// Cache of tinted SF Symbol bitmaps keyed by symbol name. Values are
        /// rebuilt only on appearance (dark/light) flip; in steady state every
        /// right-click hits the cache and skips `lockFocus` rasterization.
        /// Only ever touched from the Finder thread (menu(for:) is serialized
        /// by Finder, and invalidateSymbolCache() is dispatched on .main), so
        /// `nonisolated(unsafe)` is sound here without a lock.
        nonisolated(unsafe) private static var symbolCache: [String: NSImage] = [:]

        /// Cache of per-file icons from `NSWorkspace.shared.icon(forFile:)`,
        /// keyed by absolute path. App icons live in bundles on disk; their
        /// icon never changes while the app is installed, so caching avoids a
        /// disk read + rasterization on every right-click. Same single-thread
        /// access guarantee as `symbolCache`.
        nonisolated(unsafe) private static var appIconCache: [String: NSImage] = [:]

        private static func icon(_ name: String) -> NSImage {
            if let cached = symbolCache[name] { return cached }
            let size = NSSize(width: 18, height: 18)
            let img = NSImage(size: size)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                symbolCache[name] = img
                return img
            }
            let color: NSColor = isDarkMode ? .white : .black
            let tinted = symbol.withSymbolConfiguration(
                .init(hierarchicalColor: color)
            )
            img.lockFocus()
            (tinted ?? symbol).draw(in: NSRect(origin: .zero, size: size))
            img.unlockFocus()
            symbolCache[name] = img
            return img
        }

        /// Resolve an app icon, using the cached bitmap when the path was seen
        /// before. Falls back to a live `NSWorkspace.shared.icon(forFile:)`
        /// call (and caches it) on miss.
        private static func appIcon(forPath path: String) -> NSImage {
            if let cached = appIconCache[path] { return cached }
            let img = NSWorkspace.shared.icon(forFile: path)
            appIconCache[path] = img
            return img
        }

        /// Drop all cached images. Called when the appearance flips (dark/light)
        /// so symbol tinting is regenerated for the new mode. App icons are
        /// appearance-independent and kept.
        static func invalidateSymbolCache() {
            symbolCache.removeAll()
        }

    static func buildMenu(
        configuration: MenuConfiguration,
        hasSelection: Bool,
        targetURL: URL?,
        target: AnyObject,
        action handlerSelector: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: String(localized: "mac-right-menu"))

        let enabledApps = configuration.appItems.filter(\.isEnabled)
        let enabledActions = configuration.actionItems.filter(\.isEnabled)

        // ── Section: New File (tag: 0–999) ──
        // Available in BOTH selection and container (empty-space) contexts:
        // creating a new file is the primary action users want when they
        // right-click in an empty folder. The handler falls back to
        // `targetURL` (the folder itself) when nothing is selected.
        if enabledActions.contains(where: { $0.actionType == .newFile }) {
            // Only enabled templates appear, and their tags are numbered
            // consecutively over this filtered list (matching AppState, which
            // resolves the index against the same filter).
            let templates = configuration.newFileTemplates.filter(\.isEnabled)
            if !templates.isEmpty {
                // Uses a dedicated "New File" key (not the shared "File" key,
                // which is also the Settings tab label / action-row title) so
                // the Finder submenu can read "新建文件" without touching those.
                let submenuItem = NSMenuItem(title: String(localized: "New File"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("doc.badge.plus")
                let submenu = NSMenu(title: String(localized: "New File"))
                for (index, template) in templates.enumerated() {
                    let item = NSMenuItem(title: template.resolvedFileName, action: handlerSelector, keyEquivalent: "")
                    item.target = target
                    item.tag = Constants.TagBase.newFile.rawValue + index
                    item.representedObject = template
                    submenu.addItem(item)
                }
                menu.setSubmenu(submenu, for: submenuItem)
                menu.addItem(submenuItem)
            }
        }

        // ── Section: Open With (tag: 1000–1999) ──
        // Gated by the section master switch in addition to per-app enabled.
        // Built into the cached menu unconditionally (so config changes don't
        // require a rebuild per click); `refreshSelectionState` hides the whole
        // section when there's no selection, since opening a file with an app
        // requires a target file.
        if configuration.appsSectionEnabled, !enabledApps.isEmpty {
            if enabledApps.count == 1, let app = enabledApps.first {
                let item = NSMenuItem(
                    title: String(localized: "Open in \(app.displayName)"),
                    action: handlerSelector,
                    keyEquivalent: ""
                )
                item.target = target
                item.tag = Constants.TagBase.appItem.rawValue
                item.image = appIcon(forPath: app.appURL.path)
                item.isEnabled = hasSelection
                item.representedObject = app
                menu.addItem(item)
            } else {
                let submenuItem = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("menubar.dock.rectangle")
                let submenu = NSMenu(title: String(localized: "Open With"))
                for (index, app) in enabledApps.enumerated() {
                    let appItem = NSMenuItem(title: app.displayName, action: handlerSelector, keyEquivalent: "")
                    appItem.target = target
                    appItem.tag = Constants.TagBase.appItem.rawValue + index
                    appItem.image = appIcon(forPath: app.appURL.path)
                    appItem.representedObject = app
                    appItem.isEnabled = hasSelection
                    submenu.addItem(appItem)
                }
                menu.setSubmenu(submenu, for: submenuItem)
                menu.addItem(submenuItem)
            }
        }

        // ── Section: 操作 (tag: 2000–2999) ──
        // Same rationale as Open With: built unconditionally into the cached
        // menu; `refreshSelectionState` hides each item when nothing is picked,
        // since Copy Path / Copy Name / Toggle Hidden all need a target file.
        let operationActions: [ActionType] = [.copyPath, .copyFileName, .toggleHidden]
        let hasOps = enabledActions.contains(where: { operationActions.contains($0.actionType) })
        if hasOps {
            for actionItem in enabledActions where operationActions.contains(actionItem.actionType) {
                let tag: Int
                switch actionItem.actionType {
                case .copyPath:     tag = Constants.TagBase.copyPath.rawValue
                case .copyFileName: tag = Constants.TagBase.copyFileName.rawValue
                case .toggleHidden: tag = Constants.TagBase.toggleHidden.rawValue
                default:            continue
                }
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = tag
                item.image = actionItem.iconName.flatMap { icon($0) } ?? icon("gearshape")
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        return menu
    }

    /// Refresh the selection-dependent state of a cached NSMenu in place.
    /// Called from `menu(for:)` on every right-click — the only thing that
    /// changes between clicks for a fixed config is whether a file is picked.
    ///
    /// - Top-level file-dependent items (Open With section header, the single-app
    ///   "Open in X" item, and each operation action) are hidden when there's no
    ///   selection. Hiding the header hides its submenu too.
    /// - Leaf items under a visible section get `isEnabled` toggled so they look
    ///   live vs. disabled-grayed without rebuilding.
    ///
    /// Tag ranges (see Constants.TagBase) identify which items are file-dependent:
    /// New File (0–999) is always shown; Open With (1000–1999) and the operation
    /// actions (2000–2999) depend on a selection.
    static func refreshSelectionState(_ menu: NSMenu, hasSelection: Bool) {
        for item in menu.items {
            let tag = item.tag
            if tag >= Constants.TagBase.appItem.rawValue && tag < Constants.TagBase.shell.rawValue {
                // Open With section (1000–1999) — header or single-app leaf.
                item.isHidden = !hasSelection
                item.isEnabled = hasSelection
            } else if tag >= Constants.TagBase.copyPath.rawValue && tag < Constants.TagBase.shell.rawValue {
                // Operation actions (2000–2999): copyPath / copyFileName / toggleHidden.
                item.isHidden = !hasSelection
                item.isEnabled = hasSelection
            }
            // New File (0–999) and anything else: leave as-is.
        }
    }
}
