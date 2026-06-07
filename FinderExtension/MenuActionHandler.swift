import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "action-handler")

/// Handles menu item clicks from the Finder's right-click menu.
/// Used as a static dispatch router; the actual @objc entry point is on FinderSync.
enum MenuActionHandler {

    // MARK: - Single Action Entry Point

    static func handleMenuAction(_ sender: NSMenuItem, targetURL: URL, selectedURLs: [URL]) {
        let config = SharedUserDefaults.menuConfiguration
        let urls = selectedURLs.isEmpty ? [targetURL] : selectedURLs
        let tag = sender.tag

        switch tag {
        case Constants.TagBase.appItem.rawValue:
            handleAppOpen(urls: urls, menuItem: sender, config: config)
        case Constants.TagBase.copyPath.rawValue:
            handleCopyPath(urls: urls)
        case Constants.TagBase.copyFileName.rawValue:
            handleCopyFileName(urls: urls)
        case Constants.TagBase.moveToTrash.rawValue:
            handleMoveToTrash(urls: urls)
        case Constants.TagBase.toggleHidden.rawValue:
            handleToggleHidden(urls: urls)
        case Constants.TagBase.openParent.rawValue:
            handleOpenParent(urls: urls)
        case Constants.TagBase.testItem.rawValue:
            handlePing(urls: urls)
        default:
            // New File templates (2000+n)
            if tag >= Constants.TagBase.newFile.rawValue {
                let index = tag - Constants.TagBase.newFile.rawValue
                guard index >= 0, index < config.newFileTemplates.count else {
                    logger.warning("Invalid new file template index: \(index)")
                    return
                }
                handleNewFile(template: config.newFileTemplates[index], targetURL: targetURL)
            } else {
                logger.warning("Unknown tag: \(tag)")
            }
        }
    }

    // MARK: - App Open

    private static func handleAppOpen(urls: [URL], menuItem: NSMenuItem, config: MenuConfiguration) {
        let app: AppMenuItem?
        if let obj = menuItem.representedObject as? AppMenuItem {
            app = obj
        } else {
            // Fallback to first enabled app (for single-app direct menu item)
            app = config.appItems.first(where: { $0.isEnabled })
        }
        guard let app else {
            logger.warning("No app item found")
            return
        }
        Task {
            do {
                let openConfig = NSWorkspace.OpenConfiguration()
                openConfig.promptsUserIfNeeded = true
                openConfig.arguments = app.arguments
                openConfig.environment = app.environment
                let launchedApp = try await NSWorkspace.shared.open(urls, withApplicationAt: app.appURL, configuration: openConfig)
                logger.notice("Opened \(urls.count) file(s) with \(launchedApp.localizedName ?? app.displayName, privacy: .public)")
            } catch {
                logger.error("Failed to open with app: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Copy Path

    private static func handleCopyPath(urls: [URL]) {
        let paths = urls.map(\.path)
        let string = paths.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        logger.notice("Copied \(urls.count) path(s) to clipboard")
    }

    // MARK: - Copy File Name

    private static func handleCopyFileName(urls: [URL]) {
        let names = urls.map(\.lastPathComponent)
        let string = names.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        logger.notice("Copied \(urls.count) file name(s) to clipboard")
    }

    // MARK: - New File

    private static func handleNewFile(template: NewFileTemplate, targetURL: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let parentDir: URL
        if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
            parentDir = targetURL
        } else {
            parentDir = targetURL.deletingLastPathComponent()
        }

        let fileName = template.fileName
        let fileURL = parentDir.appendingPathComponent(fileName)

        var uniqueURL = fileURL
        var counter = 1
        while fm.fileExists(atPath: uniqueURL.path) {
            let nameWithoutExt = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let newName = "\(nameWithoutExt) \(counter).\(ext)"
            uniqueURL = parentDir.appendingPathComponent(newName)
            counter += 1
        }

        do {
            let data = template.defaultContent.data(using: .utf8) ?? Data()
            try data.write(to: uniqueURL)
            logger.notice("Created new file: \(uniqueURL.lastPathComponent, privacy: .public) in \(parentDir.path, privacy: .public)")
        } catch {
            logger.error("Failed to create file: \(error.localizedDescription)")
        }
    }

    // MARK: - Move to Trash

    private static func handleMoveToTrash(urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            do {
                var trashedURL: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                logger.notice("Moved to trash: \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to trash \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Toggle Hidden

    private static func handleToggleHidden(urls: [URL]) {
        for url in urls {
            do {
                var resourceValues = URLResourceValues()
                let currentValues = try url.resourceValues(forKeys: [.isHiddenKey])
                let isHidden = currentValues.isHidden ?? false
                resourceValues.isHidden = !isHidden
                var mutableURL = url
                try mutableURL.setResourceValues(resourceValues)
                logger.notice("Toggled hidden: \(url.lastPathComponent, privacy: .public) -> \(!isHidden)")
            } catch {
                logger.error("Failed to toggle hidden for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Open Parent

    private static func handleOpenParent(urls: [URL]) {
        let parentURLs = Set(urls.map { $0.deletingLastPathComponent() })
        for parent in parentURLs {
            NSWorkspace.shared.open(parent)
        }
    }

    // MARK: - Test (Ping)

    private static func handlePing(urls: [URL]) {
        logger.notice("Ping! \(urls.count) item(s) selected")
    }
}
