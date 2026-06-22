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

        /// Resolve an SF Symbol to an NSImage suitable for `NSMenuItem.image`.
        ///
        /// Implementation note: the old version created a blank bitmap NSImage
        /// and used `lockFocus()` + `draw()` to bake a tinted, fixed-size copy.
        /// `lockFocus()` forces the image to materialize a bitmap representation,
        /// which internally calls `representationOfImageRepsInArray:usingType:properties:`
        /// — that single call dominated the right-click flame graph at ~200ms /
        /// ~82% of `menu(for:)`. It also had to be re-run on every appearance
        /// flip (dark/light changes the tint).
        ///
        /// The replacement keeps the SF Symbol as a vector / lazily-rendered
        /// image: we apply a `SymbolConfiguration` carrying both the point size
        /// (so the image's `size` is 18pt) and the hierarchical color (black on
        /// Light, white on Dark). NSMenuItem renders the image on the GPU at
        /// draw time, which is dramatically cheaper than a CPU-side `lockFocus`
        /// rasterization and needs no pre-baked bitmap. Because the color is
        /// applied via configuration, an appearance flip still requires dropping
        /// the cache (see `invalidateSymbolCache`), but there's no expensive
        /// re-rasterization — just re-resolving the configuration.
        private static func icon(_ name: String) -> NSImage {
            if let cached = symbolCache[name] { return cached }
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                // Unknown symbol: return a tiny placeholder so the menu still
                // lays out correctly. Cached so we don't keep re-querying.
                let placeholder = NSImage(size: NSSize(width: 18, height: 18))
                symbolCache[name] = placeholder
                return placeholder
            }
            let color: NSColor = isDarkMode ? .white : .black
            let config = NSImage.SymbolConfiguration(
                pointSize: 18,
                weight: .regular
            ).applying(
                NSImage.SymbolConfiguration(hierarchicalColor: color)
            )
            // `withSymbolConfiguration` returns a lazily-resolved image; the
            // symbol stays a vector until actually drawn. Cache that resolved
            // image so repeated menu builds reuse the same instance.
            let resolved = symbol.withSymbolConfiguration(config) ?? symbol
            symbolCache[name] = resolved
            return resolved
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

        /// Eagerly populate both icon caches for the given configuration, so the
        /// first `menu(for:)` after process launch doesn't pay the full
        /// rasterization cost on Finder's menu-critical path.
        ///
        /// Background: the Extension process is NOT persistent — pkd reaps idle
        /// Finder Sync extension processes, so each right-click can relaunch Ext
        /// (new PID) with a cold cache. Without warmup, the first right-click's
        /// `rebuildCachedMenu` synchronously runs `NSWorkspace.icon(forFile:)`
        /// (reads each app's .icns, decodes TIFF) + SF Symbol `lockFocus` per
        /// item — exactly the TIFF IO the flame graph flagged.
        ///
        /// Warmup is dispatched to the main thread because
        /// `NSWorkspace.shared.icon(forFile:)` and `NSImage.lockFocus` are
        /// main-thread APIs; calling them from the RPC background thread (as
        /// rebuildCachedMenu used to) was a latent correctness bug. It's also
        /// idempotent — both `icon(_:)` and `appIcon(forPath:)` early-return on
        /// a cache hit, so repeated calls (config change, appearance flip) are
        /// cheap no-ops once the cache is warm.
        ///
        /// - Note: this returns immediately; the actual work happens async on
        ///   the main queue, overlapping with the 1-3s RPC connect/config-fetch
        ///   window so it costs the user no perceived latency.
        static func warmupCaches(for configuration: MenuConfiguration) {
            DispatchQueue.main.async {
                // App icons: every enabled app in the config. Keyed by path in
                // appIconCache, so this is what buildMenu will look up later.
                for app in configuration.appItems where app.isEnabled {
                    _ = appIcon(forPath: app.appURL.path)
                }
                // SF Symbols: the fixed set the menu can render — action icons
                // (from ActionType.systemIconName), the New File submenu header,
                // the Open With submenu header, and the fallback gear.
                var symbols = Set<String>([
                    "doc.badge.plus",            // New File header + section
                    "menubar.dock.rectangle",    // Open With header
                    "gearshape"                  // fallback for action w/o icon
                ])
                for actionType in ActionType.allCases {
                    symbols.insert(actionType.systemIconName)
                }
                for name in symbols {
                    _ = icon(name)
                }
                logger.notice("[Ext] MenuBuilder: icon caches warmed (\(configuration.appItems.count) apps, \(symbols.count) symbols)")
            }
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
                if configuration.showAppIcons {
                    item.image = appIcon(forPath: app.appURL.path)
                }
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
                    if configuration.showAppIcons {
                        appItem.image = appIcon(forPath: app.appURL.path)
                    }
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
