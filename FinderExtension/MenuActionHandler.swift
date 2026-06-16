import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "action-handler")

/// Handles menu item clicks from the Finder's right-click menu.
/// Serializes user intent into a CommandRequest, dispatches to Container App via IPC.
enum MenuActionHandler {

    // MARK: - Single Action Entry Point

    static func handleMenuAction(_ sender: NSMenuItem, targetURL: URL, selectedURLs: [URL], config: MenuConfiguration, client: RPCClient) {
        let urls = selectedURLs.isEmpty ? [targetURL] : selectedURLs
        let tag = sender.tag
        let paths = urls.map(\.path)

        let command: CommandRequest?

        switch tag {
        case Constants.TagBase.copyPath.rawValue:
            command = CommandRequest(action: .copyPath, files: paths)
        case Constants.TagBase.copyFileName.rawValue:
            command = CommandRequest(action: .copyFileName, files: paths)
        case Constants.TagBase.toggleHidden.rawValue:
            command = CommandRequest(action: .toggleHidden, files: paths)
        case Constants.TagBase.openParent.rawValue:
            command = CommandRequest(action: .openParent, files: paths)
        default:
            let nfBase = Constants.TagBase.newFile.rawValue
            let appBase = Constants.TagBase.appItem.rawValue
            let opBase = Constants.TagBase.copyPath.rawValue
            let shellBase = Constants.TagBase.shell.rawValue

            if tag >= nfBase && tag < appBase {
                // 0–999: New File
                let index = tag - nfBase
                guard index >= 0, index < config.newFileTemplates.count else { return }
                command = buildNewFileCommand(index: index, targetURL: targetURL, selectedURLs: selectedURLs)
            } else if tag >= appBase && tag < opBase {
                // 1000–1999: Open With App
                let index = tag - appBase
                let enabledApps = config.appItems.filter(\.isEnabled)
                guard index >= 0, index < enabledApps.count else { return }
                command = buildAppOpenCommand(urls: urls, app: enabledApps[index])
            } else if tag >= shellBase {
                // 4000+: Shell
                command = CommandRequest(action: .shell, files: paths)
            } else {
                command = nil
            }
        }

        if let command {
            dispatchCommand(command, tag: tag, client: client)
        }
    }

    // MARK: - IPC Dispatch

    private static func dispatchCommand(_ command: CommandRequest, tag: Int, client: RPCClient) {
        let filesStr = command.files.description
        let extraStr = command.extra?.description ?? "nil"
        client.executeCommand(command) { result in
            if let result {
                logger.notice("[RPC OK] \(tag, privacy: .public) \(String(describing: command.action), privacy: .public) \(filesStr, privacy: .public) \(extraStr, privacy: .public) → \(result.success ? "OK" : "FAIL", privacy: .public)")
            } else {
                logger.notice("[RPC DOWN] \(tag, privacy: .public) \(String(describing: command.action), privacy: .public) \(filesStr, privacy: .public) \(extraStr, privacy: .public)")
            }
        }
    }

    // MARK: - Command Builders

    private static func buildAppOpenCommand(urls: [URL], app: AppMenuItem) -> CommandRequest {
        CommandRequest(
            action: .openWithApp,
            files: urls.map(\.path),
            extra: ["appPath": app.appURL.path, "appDisplayName": app.displayName]
        )
    }

    private static func buildNewFileCommand(index: Int, targetURL: URL, selectedURLs: [URL]) -> CommandRequest {
        let dirURL: URL
        if let firstFile = selectedURLs.first {
            dirURL = firstFile.deletingLastPathComponent()
        } else {
            dirURL = targetURL
        }
        logger.notice("newFile index=\(index) dir=\(dirURL.path, privacy: .public)")
        return CommandRequest(
            action: .newFile,
            files: [dirURL.path],
            extra: ["templateIndex": "\(index)"]
        )
    }
}
