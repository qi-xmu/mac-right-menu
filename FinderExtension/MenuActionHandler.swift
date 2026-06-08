import AppKit
import FinderSync
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "action-handler")

/// Handles menu item clicks from the Finder's right-click menu.
/// Serializes user intent into a CommandRequest, dispatches to Container App via IPC.
enum MenuActionHandler {

    // MARK: - Single Action Entry Point

    static func handleMenuAction(_ sender: NSMenuItem, targetURL: URL, selectedURLs: [URL], proxy: ContainerXPCProtocol?) {
        let config = SharedUserDefaults.menuConfiguration
        let urls = selectedURLs.isEmpty ? [targetURL] : selectedURLs
        let tag = sender.tag
        let paths = urls.map(\.path)

        let command: CommandRequest?

        switch tag {
        case Constants.TagBase.appItem.rawValue:
            command = buildAppOpenCommand(urls: urls, menuItem: sender, config: config)
        case Constants.TagBase.copyPath.rawValue:
            command = CommandRequest(action: .copyPath, files: paths)
        case Constants.TagBase.copyFileName.rawValue:
            command = CommandRequest(action: .copyFileName, files: paths)
        case Constants.TagBase.toggleHidden.rawValue:
            command = CommandRequest(action: .toggleHidden, files: paths)
        case Constants.TagBase.openParent.rawValue:
            command = CommandRequest(action: .openParent, files: paths)
        default:
            if tag >= Constants.TagBase.newFile.rawValue {
                let index = tag - Constants.TagBase.newFile.rawValue
                guard index >= 0, index < config.newFileTemplates.count else { return }
                command = buildNewFileCommand(template: config.newFileTemplates[index], targetURL: targetURL)
            } else {
                command = nil
            }
        }

        if let command {
            dispatchCommand(command, proxy: proxy)
        }
    }

    // MARK: - IPC Dispatch

    private static func dispatchCommand(_ command: CommandRequest, proxy: ContainerXPCProtocol?) {
        guard let proxy else {
            logger.notice("[XPC DOWN] action=\(command.action.rawValue, privacy: .public) files=\(command.files, privacy: .public)")
            return
        }
        guard let data = try? JSONEncoder().encode(command) else {
            logger.error("Failed to encode command")
            return
        }
        proxy.executeCommand(data) { resultData in
            let result = (try? JSONDecoder().decode(CommandResult.self, from: resultData)).map { $0.success } ?? false
            logger.notice("Dispatched \(command.action.rawValue, privacy: .public): \(result ? "OK" : "FAIL")")
        }
    }

    // MARK: - Command Builders

    private static func buildAppOpenCommand(
        urls: [URL],
        menuItem: NSMenuItem,
        config: MenuConfiguration
    ) -> CommandRequest? {
        let app: AppMenuItem?
        if let obj = menuItem.representedObject as? AppMenuItem {
            app = obj
        } else {
            app = config.appItems.first(where: { $0.isEnabled })
        }
        guard let app else { return nil }
        return CommandRequest(
            action: .openWithApp,
            files: urls.map(\.path),
            extra: ["appPath": app.appURL.path, "appDisplayName": app.displayName]
        )
    }

    private static func buildNewFileCommand(
        template: NewFileTemplate,
        targetURL: URL
    ) -> CommandRequest? {
        guard let jsonData = try? JSONEncoder().encode(template),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return nil }
        return CommandRequest(
            action: .newFile,
            files: [targetURL.path],
            extra: ["templateJSON": jsonString]
        )
    }
}
