import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "finder-sync")

class FinderSyncExtension: FIFinderSync, @unchecked Sendable {

    private let rpcClient = RPCClient()
    private var cachedConfig: MenuConfiguration = .default
    private let configLock = NSLock()

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

        // Refresh the in-memory cache from both channels:
        //  1. getConfig pull on connect (initial load)
        //  2. configDidChange push (live updates)
        // Both route through this handler. It runs on an RPC background queue;
        // cachedConfig is read in menu(for:) on the Finder thread, so guard the
        // write with a lock. MenuConfiguration is a value type, so the swap is safe.
        rpcClient.setConfigChangeHandler { [weak self] newConfig in
            guard let self else { return }
            self.configLock.lock()
            self.cachedConfig = newConfig
            self.configLock.unlock()
            let actions = newConfig.actionItems.map { "\($0.actionType):\($0.isEnabled ? "on" : "off")" }.joined(separator: " ")
            logger.notice("[Ext] Config applied: enabled=\(newConfig.isEnabled) apps=\(newConfig.appItems.count) actions=[\(actions, privacy: .public)] templates=\(newConfig.newFileTemplates.count)")
        }

        // Connect to the Container's JSON-RPC server. RPCClient handles retries
        // internally if the Container is not yet running. On .ready it auto-pulls
        // the current config via getConfig.
        rpcClient.connect()
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        guard menuKind == .contextualMenuForItems else { return NSMenu() }

        configLock.lock()
        let config = cachedConfig
        configLock.unlock()

        guard config.isEnabled else {
            logger.debug("menu: disabled, returning empty")
            return NSMenu()
        }

        let hasSelection = FIFinderSyncController.default().selectedItemURLs() != nil
        let targetURL = FIFinderSyncController.default().targetedURL()

        return MenuBuilder.buildMenu(
            configuration: config,
            hasSelection: hasSelection,
            targetURL: targetURL,
            target: self,
            action: #selector(handleMenuAction(_:))
        )
    }

    // MARK: - Action

    @objc func handleMenuAction(_ sender: NSMenuItem) {
        guard let targetURL = FIFinderSyncController.default().targetedURL() else {
            logger.warning("No target URL available")
            return
        }
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        MenuActionHandler.handleMenuAction(sender, targetURL: targetURL, selectedURLs: selectedURLs, config: cachedConfig, client: rpcClient)
    }
}
