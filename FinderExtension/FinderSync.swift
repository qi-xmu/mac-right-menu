import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "finder-sync")

class FinderSyncExtension: FIFinderSync, @unchecked Sendable {

    private let rpcClient = RPCClient()
    private var cachedConfig: MenuConfig = .default
    private let configLock = NSLock()

    /// Pre-built NSMenu reused across right-clicks. Built once when config
    /// arrives; `menu(for:)` only refreshes selection-dependent visibility in
    /// place (cheap property writes via `refreshSelectionState`).
    ///
    /// Mutated from two threads: the config-change handler (RPC background
    /// queue) rebuilds it, and `menu(for:)` (Finder thread) reads + refreshes
    /// it. `menuLock` serializes rebuild vs. read/refresh. A rebuild swaps in a
    /// brand-new NSMenu so a Finder-render in flight on the old object is
    /// unaffected (it keeps its own reference).
    private var cachedMenu: NSMenu?
    private let menuLock = NSLock()

    // MARK: - Initialization

    override init() {
        super.init()
        logger.notice("FinderSync initialized — v\(Constants.version) (\(Constants.build))")

        // cachedConfig stays at .default until the RPC connection comes up,
        // at which point getConfig pulls the real menu tree from the Container.
        logger.notice("[Ext] Config: awaiting initial getConfig from Container")

        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        // Appearance flips (Light↔Dark) change how SF Symbol icons are tinted.
        // Since the cached menu bakes resolved symbol images into its items, a
        // theme flip requires dropping the symbol cache and rebuilding. Both
        // run on the main thread (icon APIs are main-thread-only).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MenuBuilder.invalidateSymbolCache()
            DispatchQueue.main.async { self?.rebuildCachedMenu() }
        }

        // Refresh the in-memory cache from both channels AND rebuild the cached
        // menu on every change. Both routes (getConfig pull on connect,
        // configDidChange push on live edits) arrive on an RPC background queue.
        rpcClient.setConfigChangeHandler { [weak self] newConfig in
            guard let self else { return }
            self.configLock.lock()
            self.cachedConfig = newConfig
            self.configLock.unlock()
            logger.notice("[Ext] Config applied: enabled=\(newConfig.isEnabled, privacy: .public) menus=\(newConfig.menus.count) showIcons=\(newConfig.showAppIcons)")
            // Warm icon caches on the main thread, THEN rebuild the menu so
            // buildMenu's icon lookups hit the cache. Warmup is idempotent.
            DispatchQueue.main.async {
                MenuBuilder.warmupCaches(for: newConfig)
                self.rebuildCachedMenu()
            }
        }

        // Handle Container shutdown or max-retry exhaustion: exit the process.
        rpcClient.setShutdownHandler {
            logger.notice("[Ext] Shutting down (Container exit or max retries reached)")
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        // Connect to the Container's JSON-RPC server. RPCClient handles retries
        // internally if the Container is not yet running. On .ready it auto-pulls
        // the current config via getConfig.
        rpcClient.connect()
    }

    // MARK: - Cached Menu

    /// Build (or rebuild) the cached NSMenu from the current cachedConfig.
    /// Called when config changes or the appearance flips. Builds the FULL menu
    /// tree; `menu(for:)` hides per-node selection-dependent items at serve time.
    ///
    /// - Important: must be called on the main thread. Use `rebuildOnMain()`
    ///   from non-main contexts.
    private func rebuildCachedMenu() {
        configLock.lock()
        let config = cachedConfig
        configLock.unlock()

        guard config.isEnabled else {
            // Disabled: keep an empty menu so menu(for:) returns something
            // valid, but it renders nothing.
            menuLock.lock()
            cachedMenu = NSMenu()
            menuLock.unlock()
            return
        }

        let menu = MenuBuilder.buildMenu(
            config: config,
            target: self,
            action: #selector(handleMenuAction(_:))
        )
        menuLock.lock()
        cachedMenu = menu
        menuLock.unlock()
        logger.notice("[Ext] Cached menu rebuilt (\(menu.numberOfItems) top-level items)")
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let targetURL = FIFinderSyncController.default().targetedURL()

        // Classify the click target. A selection containing any file counts as
        // `.file`; folders-only or empty space count as `.dir` (the containing
        // folder), which keeps folder-oriented items (e.g. New File) visible
        // when right-clicking empty space.
        let anyFile = selectedURLs.contains { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        let context: MenuBuilder.TargetContext = (selectedURLs.isEmpty || !anyFile) ? .dir : .file
        logger.info("[Ext] menu(for:) menuKind=\(menuKind.rawValue) target=\(targetURL?.path ?? "nil", privacy: .public) selected=\(selectedURLs.count) context=\(context == .file ? "file" : "dir", privacy: .public)")

        menuLock.lock()
        let menu = cachedMenu
        menuLock.unlock()

        // No config yet (waiting for first getConfig): serve an empty menu.
        // We deliberately do NOT call MenuBuilder.buildMenu here — it resolves
        // icons via main-thread-only AppKit APIs, and menu(for:) runs on the
        // Finder thread, so building off-main would race the icon caches.
        // MenuConfig.default carries no items anyway, so an empty NSMenu is the
        // exact equivalent. The cached menu takes over once config lands.
        let resolved = menu ?? NSMenu()
        MenuBuilder.refreshSelectionState(resolved, context: context, selectedCount: selectedURLs.count)
        return resolved
    }

    // MARK: - Action

    /// A leaf menu item was clicked. Forward its `actionID` plus the current
    /// Finder selection context to the Container, which resolves the actionID
    /// via its `ActionDefMap`. The Extension no longer interprets tags or
    /// builds commands — it is a pure forwarder.
    @objc func handleMenuAction(_ sender: NSMenuItem) {
        let targetURL = FIFinderSyncController.default().targetedURL()
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let actionID = sender.tag
        logger.notice("[Ext] handleMenuAction actionID=\(actionID) target=\(targetURL?.path ?? "nil", privacy: .public) selected=\(selectedURLs.map(\.path), privacy: .public)")
        rpcClient.executeAction(
            MenuAction(actionID: actionID, targetURL: targetURL, selectedURLs: selectedURLs)
        ) { result in
            if let result {
                logger.notice("[RPC OK] actionID=\(actionID, privacy: .public) → \(result.success ? "OK" : "FAIL", privacy: .public)")
            } else {
                logger.notice("[RPC DOWN] actionID=\(actionID, privacy: .public)")
            }
        }
    }
}
