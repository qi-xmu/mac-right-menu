import SwiftUI
import os.log

private let logger = Logger(subsystem: Constants.mainAppBundleID, category: "app-state")

@MainActor
class AppState: ObservableObject {
    @Published var configuration: MenuConfiguration {
        didSet {
            saveConfiguration()
        }
    }

    @Published var isExtensionActive: Bool = false

    private var xpcListener: NSXPCListener?
    private var commandHandler: XPCCommandHandler?
    private var xpcDelegate: XPCServerDelegate?

    init() {
        self.configuration = SharedUserDefaults.menuConfiguration
        setupXPCListener()
    }

    // MARK: - XPC

    private func setupXPCListener() {
        let listener = NSXPCListener(machServiceName: "com.qi-xmu.mac-right-menu.command")
        let handler = XPCCommandHandler()
        let delegate = XPCServerDelegate() { [weak self] added in
            self?.isExtensionActive = added
        }
        handler.onCommand = { [weak self] command in
            Task { @MainActor in
                self?.executeCommand(command)
            }
        }
        listener.delegate = delegate
        listener.resume()
        self.xpcListener = listener
        self.commandHandler = handler
        self.xpcDelegate = delegate
    }

    func saveConfiguration() {
        SharedUserDefaults.menuConfiguration = configuration
        xpcDelegate?.notifySettingsChanged()
    }

    func shutdownExtensions() {
        xpcDelegate?.notifyShutdown()
    }

    // MARK: - Convenience accessors

    var isEnabled: Bool {
        get { configuration.isEnabled }
        set {
            configuration.isEnabled = newValue
            saveConfiguration()
        }
    }

    var appItems: [AppMenuItem] {
        get { configuration.appItems }
        set {
            configuration.appItems = newValue
            saveConfiguration()
        }
    }

    var actionItems: [ActionMenuItem] {
        get { configuration.actionItems }
        set {
            configuration.actionItems = newValue
            saveConfiguration()
        }
    }

    var newFileTemplates: [NewFileTemplate] {
        get { configuration.newFileTemplates }
        set {
            configuration.newFileTemplates = newValue
            saveConfiguration()
        }
    }

    // MARK: - Actions

    func addApp(_ appURL: URL) {
        let newItem = AppMenuItem(appURL: appURL, isEnabled: true)
        if !configuration.appItems.contains(where: { $0.id == newItem.id }) {
            configuration.appItems.append(newItem)
            saveConfiguration()
        }
    }

    func removeApp(at offsets: IndexSet) {
        configuration.appItems.remove(atOffsets: offsets)
        saveConfiguration()
    }

    func moveApp(from source: IndexSet, to destination: Int) {
        configuration.appItems.move(fromOffsets: source, toOffset: destination)
        saveConfiguration()
    }

    func toggleAction(_ actionType: ActionType) {
        guard let index = configuration.actionItems.firstIndex(where: { $0.actionType == actionType }) else { return }
        configuration.actionItems[index].isEnabled.toggle()
        saveConfiguration()
    }

    func resetToDefaults() {
        configuration = .default
        saveConfiguration()
    }

    // MARK: - Command Execution

    var commandExecutionEnabled: Bool {
        get { !SharedUserDefaults.commandLogOnly }
        set { SharedUserDefaults.commandLogOnly = !newValue }
    }

    nonisolated func executeCommand(_ command: CommandRequest) {
        if SharedUserDefaults.commandLogOnly {
            logger.notice("""
                [IPC RECEIVED] action=\(command.action.rawValue, privacy: .public) \
                files=\(command.files, privacy: .public) \
                cmd=\(command.command ?? "nil", privacy: .public) \
                extra=\(command.extra?.description ?? "nil", privacy: .public)
                """)
            return
        }
        let fileURLs = command.files.map { URL(fileURLWithPath: $0) }

        switch command.action {
        case .openWithApp:
            guard let appPath = command.extra?["appPath"] else {
                logger.warning("openWithApp: missing appPath")
                return
            }
            let appURL = URL(fileURLWithPath: appPath)
            Task {
                do {
                    let config = NSWorkspace.OpenConfiguration()
                    config.promptsUserIfNeeded = true
                    let launched = try await NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config)
                    logger.notice("Opened \(fileURLs.count) file(s) with \(launched.localizedName ?? command.extra?["appDisplayName"] ?? "", privacy: .public)")
                } catch {
                    logger.error("openWithApp failed: \(error.localizedDescription)")
                }
            }

        case .copyPath:
            let paths = fileURLs.map(\.path).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths, forType: .string)
            logger.notice("Copied \(fileURLs.count) path(s)")

        case .copyFileName:
            let names = fileURLs.map(\.lastPathComponent).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(names, forType: .string)
            logger.notice("Copied \(fileURLs.count) file name(s)")

        case .newFile:
            guard let templateJSON = command.extra?["templateJSON"],
                  let data = templateJSON.data(using: .utf8),
                  let template = try? JSONDecoder().decode(NewFileTemplate.self, from: data),
                  let targetURL = fileURLs.first
            else {
                logger.warning("newFile: invalid payload")
                return
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let parentDir: URL
            if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
                parentDir = targetURL
            } else {
                parentDir = targetURL.deletingLastPathComponent()
            }
            let fileName = template.fileName
            var fileURL = parentDir.appendingPathComponent(fileName)
            var counter = 1
            while fm.fileExists(atPath: fileURL.path) {
                let name = (fileName as NSString).deletingPathExtension
                let ext = (fileName as NSString).pathExtension
                fileURL = parentDir.appendingPathComponent("\(name) \(counter).\(ext)")
                counter += 1
            }
            do {
                let content = template.defaultContent.data(using: .utf8) ?? Data()
                try content.write(to: fileURL)
                logger.notice("Created new file: \(fileURL.lastPathComponent)")
            } catch {
                logger.error("newFile failed: \(error.localizedDescription)")
            }

        case .toggleHidden:
            for url in fileURLs {
                do {
                    var rv = URLResourceValues()
                    let cur = try url.resourceValues(forKeys: [.isHiddenKey])
                    rv.isHidden = !(cur.isHidden ?? false)
                    var mutable = url
                    try mutable.setResourceValues(rv)
                    logger.notice("Toggled hidden: \(url.lastPathComponent) -> \(rv.isHidden ?? false)")
                } catch {
                    logger.error("toggleHidden failed: \(error.localizedDescription)")
                }
            }

        case .openParent:
            let parents = Set(fileURLs.map { $0.deletingLastPathComponent() })
            for parent in parents {
                NSWorkspace.shared.open(parent)
            }

        case .shell:
            guard let cmd = command.command else {
                logger.warning("shell: missing command")
                return
            }
            let task = Process()
            task.launchPath = "/bin/bash"
            let substituted = cmd.replacingOccurrences(of: "{}", with: command.files.joined(separator: " "))
            task.arguments = ["-c", substituted]
            task.launch()
            task.waitUntilExit()
            logger.notice("Shell executed: \(substituted, privacy: .public)")
        }
    }
}

// MARK: - XPC Server Delegate

final class XPCServerDelegate: NSObject, NSXPCListenerDelegate, ExtensionXPCProtocol {
    private var activeConnections = Set<NSXPCConnection>()
    private let onConnectionChange: (Bool) -> Void

    init(onConnectionChange: @escaping (Bool) -> Void) {
        self.onConnectionChange = onConnectionChange
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: ContainerXPCProtocol.self)

        onConnectionChange(true)
        activeConnections.insert(newConnection)

        newConnection.invalidationHandler = { [weak self] in
            self?.activeConnections.remove(newConnection)
            if self?.activeConnections.isEmpty == true {
                self?.onConnectionChange(false)
            }
        }
        newConnection.resume()
        return true
    }

    func notifySettingsChanged() {
        for conn in activeConnections {
            (conn.remoteObjectProxy as? ExtensionXPCProtocol)?.settingsDidChange()
        }
    }

    func notifyShutdown() {
        for conn in activeConnections {
            (conn.remoteObjectProxy as? ExtensionXPCProtocol)?.shutdownImminent()
        }
    }

    func settingsDidChange() {}
    func shutdownImminent() {}
}
