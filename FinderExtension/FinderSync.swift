import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "finder-sync")

class FinderSyncExtension: FIFinderSync {

    // MARK: - Initialization

    override init() {
        super.init()
        logger.notice("FinderSync initialized from \(Bundle.main.bundlePath, privacy: .public)")

        // Show menu across the entire filesystem
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        // Observe settings changes from Container App
        SettingsSync.observeSettingsChanged {
            logger.notice("Settings changed, will rebuild menu on next call")
        }
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // Only show custom menu for file/folder right-click
        guard menuKind == .contextualMenuForItems else {
            return NSMenu()
        }

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

    /// Single entry point for all menu item clicks.
    /// Tag-based dispatch to MenuActionHandler.
    @objc func handleMenuAction(_ sender: NSMenuItem) {
        guard let targetURL = FIFinderSyncController.default().targetedURL() else {
            logger.warning("No target URL available")
            return
        }
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        MenuActionHandler.handleMenuAction(sender, targetURL: targetURL, selectedURLs: selectedURLs)
    }
}
