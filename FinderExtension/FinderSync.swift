import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "finder-sync")

class FinderSyncExtension: FIFinderSync {

    var xpcConnection: NSXPCConnection?
    var remoteProxy: ContainerXPCProtocol? {
        xpcConnection?.remoteObjectProxyWithErrorHandler { error in
            logger.error("XPC error: \(error.localizedDescription)")
        } as? ContainerXPCProtocol
    }

    // MARK: - Initialization

    override init() {
        super.init()
        logger.notice("FinderSync initialized")

        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        connectToContainer()
    }

    // MARK: - XPC Connection

    private func connectToContainer() {
        let conn = NSXPCConnection(machServiceName: "com.qi-xmu.mac-right-menu.command")
        conn.remoteObjectInterface = NSXPCInterface(with: ContainerXPCProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in
            logger.warning("XPC connection to Container lost")
            self?.xpcConnection = nil
        }
        conn.resume()
        xpcConnection = conn
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        guard menuKind == .contextualMenuForItems else { return NSMenu() }

        let config = SharedUserDefaults.menuConfiguration
        guard config.isEnabled else { return NSMenu() }

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
        MenuActionHandler.handleMenuAction(sender, targetURL: targetURL, selectedURLs: selectedURLs, proxy: remoteProxy)
    }
}

// MARK: - ExtensionXPCProtocol

extension FinderSyncExtension: ExtensionXPCProtocol {
    func settingsDidChange() {
        logger.notice("Container notified settings changed")
    }

    func shutdownImminent() {
        logger.notice("Container shutting down — Extension going dormant")
        FIFinderSyncController.default().directoryURLs = []
        xpcConnection?.invalidate()
        xpcConnection = nil
    }
}
