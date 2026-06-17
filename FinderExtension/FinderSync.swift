import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "finder-sync")

class FinderSyncExtension: FIFinderSync, @unchecked Sendable {

    private let rpcClient = RPCClient()
    private var cachedConfig: MenuConfiguration = .default
    private let configLock = NSLock()

    /// Pre-built NSMenu reused across right-clicks. `menu(for:)` builds NSMenu
    /// trees, resolves localized titles, decodes app icons, and renders SF
    /// Symbol bitmaps — none of that changes between clicks for a given config,
    /// so we build ONCE when config arrives and hand back the same object every
    /// time Finder asks. Only the `isEnabled`/`isHidden` flags that depend on
    /// the live selection are refreshed in `menu(for:)` (cheap property writes).
    ///
    /// Mutated from two threads: the config-change handler (RPC background
    /// queue) rebuilds it, and `menu(for:)` (Finder thread) reads + refreshes
    /// it. `menuLock` serializes rebuild vs. read/refresh. A rebuild swaps in a
    /// brand-new NSMenu so a Finder-render in flight on the old object is
    /// unaffected (it keeps its own reference).
    private var cachedMenu: NSMenu?
    private let menuLock = NSLock()

    var rpc: RPCClient { rpcClient }

    // MARK: - Initialization

    override init() {
        super.init()
        logger.notice("FinderSync initialized")

        // cachedConfig stays at .default until the RPC connection comes up,
        // at which point getConfig pulls the real config from the Container.
        // Reading our own UserDefaults here is unreliable — the two processes
        // keep separate stores, so it would only ever see a stale/default copy.
        logger.notice("[Ext] Config: awaiting initial getConfig from Container")

        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        // Appearance flips (Light↔Dark) change how MenuBuilder tints SF Symbol
        // icons. Since the cached menu bakes those bitmaps into its items, a
        // theme flip requires a rebuild (icons are embedded in the cached
        // NSMenu items, not regenerated per click).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildCachedMenu()
        }

        // Refresh the in-memory cache from both channels AND rebuild the cached
        // menu on every change. Both routes (getConfig pull on connect,
        // configDidChange push on live edits) come through here on an RPC
        // background queue; cachedConfig is read in menu(for:) on the Finder
        // thread, so the write is guarded. MenuConfiguration is a value type,
        // so the swap is safe.
        rpcClient.setConfigChangeHandler { [weak self] newConfig in
            guard let self else { return }
            self.configLock.lock()
            self.cachedConfig = newConfig
            self.configLock.unlock()
            let actions = newConfig.actionItems.map { "\($0.actionType):\($0.isEnabled ? "on" : "off")" }.joined(separator: " ")
            logger.notice("[Ext] Config applied: enabled=\(newConfig.isEnabled) apps=\(newConfig.appItems.count) actions=[\(actions, privacy: .public)] templates=\(newConfig.newFileTemplates.count)")
            // Rebuild the cached NSMenu so subsequent right-clicks reflect the
            // new structure (added/removed apps, toggled sections, ...).
            self.rebuildCachedMenu()
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
    /// (all sections) so a single object can serve both items and container
    //  contexts — `menu(for:)` hides the file-dependent sections when there's
    /// no selection.
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
            configuration: config,
            hasSelection: true,           // build full; visibility handled at serve time
            targetURL: nil,
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
        // Two contextual kinds we serve:
        //  - .contextualMenuForItems:     right-click on selected file(s)/folder(s)
        //  - .contextualMenuForContainer: right-click on a folder's empty space
        //    (this is the "open a folder, select nothing, right-click" case —
        //    the natural place to offer New File). Sidebar/window/toolbar kinds
        //    are not relevant and stay empty.
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer
        else { return NSMenu() }

        // hasSelection is true only in the .contextualMenuForItems case where
        // something is actually picked. In the container case selectedItemURLs
        // is nil → hasSelection false → file-dependent sections are hidden.
        let hasSelection = FIFinderSyncController.default().selectedItemURLs()?.isEmpty == false

        menuLock.lock()
        let menu = cachedMenu
        menuLock.unlock()

        guard let menu else {
            // No config yet (waiting for first getConfig). Fall back to a fresh
            // build off the default config so the very first right-click after
            // launch isn't blank; the cached one takes over once config lands.
            return MenuBuilder.buildMenu(
                configuration: .default,
                hasSelection: hasSelection,
                targetURL: nil,
                target: self,
                action: #selector(handleMenuAction(_:))
            )
        }

        // Cheap per-click refresh: only the selection-dependent visibility /
        // enabled state changes between clicks for a fixed config. The menu
        // structure, titles, icons, tags stay baked into the cached object.
        MenuBuilder.refreshSelectionState(menu, hasSelection: hasSelection)
        return menu
    }

    // MARK: - Action

    @objc func handleMenuAction(_ sender: NSMenuItem) {
        guard let targetURL = FIFinderSyncController.default().targetedURL() else {
            logger.warning("No target URL available")
            return
        }
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        configLock.lock()
        let config = cachedConfig
        configLock.unlock()
        MenuActionHandler.handleMenuAction(sender, targetURL: targetURL, selectedURLs: selectedURLs, config: config, client: rpcClient)
    }
}
