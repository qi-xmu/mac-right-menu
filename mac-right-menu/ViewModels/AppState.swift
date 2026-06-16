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

    /// All known extensions with their runtime state and user preferences.
    @Published var extensions: [ExtensionInfo] = []

    /// In-memory record of every command execution (newest appended at the end).
    /// Cleared on relaunch; capped at `maxLogEntries`.
    @Published private(set) var executionLog: [ExecutionLogEntry] = []
    private let maxLogEntries = 500

    /// File descriptor for the flock()-based single-instance guard.
    /// Kept open for the process lifetime; closing it releases the lock.
    private let lockFileDescriptor: Int32

    private lazy var rpcServer: RPCServer = {
        let server = RPCServer(
            onCommand: { [weak self] command in
                guard let self else {
                    return CommandResult(success: false, errorDescription: "AppState released")
                }
                return await self.executeCommand(command)
            },
            getConfig: { [weak self] in
                self?.configuration ?? SharedUserDefaults.menuConfiguration
            },
            onHeartbeat: { [weak self] meta in
                guard let self else { return }
                let pid = meta?["pid"].flatMap(Int.init)
                let version = meta?["version"]
                if let index = self.extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                    self.extensions[index].isConnected = true
                    self.extensions[index].connectedPID = pid
                    self.extensions[index].connectedVersion = version
                    self.extensions[index].lastHeartbeatAt = Date()
                }
            }
        )
        server.start()
        return server
    }()

    init() {
        // Fast path: check via NSRunningApplication.
        let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: Constants.mainAppBundleID
        )
        if existing.count > 1 {
            logger.warning("[Con] Another Container already running — exiting")
            self.lockFileDescriptor = -1
            exit(0)
        }

        // Atomic path: flock() prevents race conditions where two instances
        // start simultaneously and both pass the NSRunningApplication check.
        let fd = Self.acquireInstanceLock()
        self.lockFileDescriptor = fd
        if fd < 0 {
            logger.warning("[Con] Could not acquire instance lock — exiting")
            exit(0)
        }

        self.configuration = SharedUserDefaults.menuConfiguration
        loadExtensions()
        writeLockFile()
        _ = rpcServer
        checkExtensionRegistration()
        autoLaunchExtensions()
    }

    // MARK: - Extension Management

    private func loadExtensions() {
        extensions = Constants.knownExtensions.map { ext in
            var info = ExtensionInfo(
                bundleID: ext.bundleID,
                displayName: ext.displayName,
                autoLaunch: SharedUserDefaults.extensionAutoLaunch(bundleID: ext.bundleID)
            )
            return info
        }
    }

    /// Auto-launch extensions that have autoLaunch enabled.
    private func autoLaunchExtensions() {
        let toLaunch = extensions.filter { $0.autoLaunch && $0.isRegistered }
        guard !toLaunch.isEmpty else { return }
        for ext in toLaunch {
            logger.notice("[Con] Auto-launching extension: \(ext.displayName, privacy: .public)")
            launchExtension(bundleID: ext.bundleID)
        }
    }

    /// Launch an extension by bundleID using NSWorkspace or open -b fallback.
    private func launchExtension(bundleID: String) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                if let error {
                    logger.error("[Con] Extension launch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", bundleID, "--background"]
        do {
            try task.run()
        } catch {
            logger.error("[Con] open -b extension failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setAutoLaunch(bundleID: String, enabled: Bool) {
        if let index = extensions.firstIndex(where: { $0.bundleID == bundleID }) {
            extensions[index].autoLaunch = enabled
            SharedUserDefaults.setExtensionAutoLaunch(bundleID: bundleID, enabled: enabled)
        }
    }

    /// Check via pluginkit whether the extension is registered with the system.
    private func checkExtensionRegistration() {
        Task {
            let installed = await Self.isExtensionRegistered()
            if installed {
                if let index = extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                    if !extensions[index].isRegistered {
                        extensions[index].isRegistered = true
                        logger.notice("[Con] Extension registered via pluginkit")
                    }
                }
            }
        }
    }

    nonisolated private static func isExtensionRegistered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.launchPath = "/usr/bin/pluginkit"
                task.arguments = ["-m", "-p", "com.apple.FinderSync"]
                let pipe = Pipe()
                task.standardOutput = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let registered = output.contains(Constants.extensionBundleID)
                    continuation.resume(returning: registered)
                } catch {
                    logger.error("pluginkit check failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Config Sync

    func saveConfiguration() {
        SharedUserDefaults.menuConfiguration = configuration
        // Push the new config to any running Extension so its in-memory cache
        // refreshes immediately. Each process keeps its own UserDefaults, so
        // the full config travels in the notification payload.
        rpcServer.broadcastConfig(configuration)
    }

    func shutdownExtensions() {
        removeLockFile()
        rpcServer.broadcastShutdown()
        // Brief delay so connected Extensions can receive the shutdown
        // notification before the listener is torn down.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rpcServer.stop()
        }
    }

    func clearLog() {
        executionLog.removeAll()
    }

    // MARK: - Lock file (single-instance guard)

    /// Try to acquire an exclusive flock on `<AppGroup>/container.lock`.
    /// Returns the file descriptor on success, -1 on failure.
    /// The fd must be kept open for the process lifetime.
    nonisolated private static func acquireInstanceLock() -> Int32 {
        guard let url = Constants.containerLockURL else { return -1 }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return -1 }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func writeLockFile() {
        guard let url = Constants.containerLockURL else { return }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        try? pid.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeLockFile() {
        guard let url = Constants.containerLockURL else { return }
        try? FileManager.default.removeItem(at: url)
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

    /// Execute a command received from the Extension.
    /// Returns the real outcome so the RPC response reflects success/failure
    /// and so the Execution Log records the same result the caller observed.
    nonisolated func executeCommand(_ command: CommandRequest) async -> CommandResult {
        let actionName = Self.actionName(command.action)

        // commandLogOnly: record receipt but skip execution.
        if SharedUserDefaults.commandLogOnly {
            logger.notice("""
                [Con][RPC RECV→DISPATCH] action=\(command.action.rawValue, privacy: .public) \
                files=\(command.files, privacy: .public) \
                cmd=\(command.command ?? "nil", privacy: .public) \
                extra=\(command.extra?.description ?? "nil", privacy: .public)
                """)
            let result = CommandResult(success: true)
            await appendLog(command: command, actionName: actionName,
                            result: result, shellCommand: nil, logOnly: true)
            return result
        }

        let fileURLs = command.files.map { URL(fileURLWithPath: $0) }
        var result: CommandResult
        var shellCommand: String? = nil

        switch command.action {
        case .openWithApp:
            guard let appPath = command.extra?["appPath"] else {
                logger.warning("openWithApp: missing appPath")
                result = CommandResult(success: false, errorDescription: "openWithApp: missing appPath")
                break
            }
            let appURL = URL(fileURLWithPath: appPath)
            do {
                let config = NSWorkspace.OpenConfiguration()
                config.promptsUserIfNeeded = true
                let launched = try await NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config)
                logger.notice("Opened \(fileURLs.count) file(s) with \(launched.localizedName ?? command.extra?["appDisplayName"] ?? "", privacy: .public)")
                result = CommandResult(success: true)
            } catch {
                logger.error("openWithApp failed: \(error.localizedDescription)")
                result = CommandResult(success: false, errorDescription: "openWithApp failed: \(error.localizedDescription)")
            }

        case .copyPath:
            let paths = fileURLs.map(\.path).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths, forType: .string)
            logger.notice("Copied \(fileURLs.count) path(s)")
            result = CommandResult(success: true)

        case .copyFileName:
            let names = fileURLs.map(\.lastPathComponent).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(names, forType: .string)
            logger.notice("Copied \(fileURLs.count) file name(s)")
            result = CommandResult(success: true)

        case .newFile:
            guard let indexStr = command.extra?["templateIndex"],
                  let index = Int(indexStr),
                  let targetURL = fileURLs.first
            else {
                logger.warning("newFile: invalid payload")
                result = CommandResult(success: false, errorDescription: "newFile: invalid payload")
                break
            }
            let templates = SharedUserDefaults.menuConfiguration.newFileTemplates
            guard index >= 0, index < templates.count else {
                logger.warning("newFile: template index \(index) out of range")
                result = CommandResult(success: false, errorDescription: "newFile: template index \(index) out of range")
                break
            }
            let template = templates[index]
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
                result = CommandResult(success: true)
            } catch {
                logger.error("newFile failed: \(error.localizedDescription)")
                result = CommandResult(success: false, errorDescription: "newFile failed: \(error.localizedDescription)")
            }

        case .toggleHidden:
            var failed: String?
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
                    failed = error.localizedDescription
                    break
                }
            }
            result = failed.map { CommandResult(success: false, errorDescription: "toggleHidden failed: \($0)") }
                ?? CommandResult(success: true)

        case .openParent:
            let parents = Set(fileURLs.map { $0.deletingLastPathComponent() })
            for parent in parents {
                NSWorkspace.shared.open(parent)
            }
            logger.notice("Opened \(parents.count) parent folder(s)")
            result = CommandResult(success: true)

        case .shell:
            guard let cmd = command.command else {
                logger.warning("shell: missing command")
                result = CommandResult(success: false, errorDescription: "shell: missing command")
                break
            }
            let task = Process()
            task.launchPath = "/bin/bash"
            let substituted = cmd.replacingOccurrences(of: "{}", with: command.files.joined(separator: " "))
            shellCommand = substituted
            let errPipe = Pipe()
            task.standardError = errPipe
            task.arguments = ["-c", substituted]
            do {
                try task.run()
                task.waitUntilExit()
                let status = task.terminationStatus
                if status == 0 {
                    logger.notice("Shell executed: \(substituted, privacy: .public)")
                    result = CommandResult(success: true)
                } else {
                    let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
                    let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let desc = stderr.isEmpty ? "exit \(status)" : "exit \(status): \(stderr)"
                    logger.error("Shell failed: \(desc, privacy: .public)")
                    result = CommandResult(success: false, errorDescription: "shell \(desc)")
                }
            } catch {
                logger.error("Shell launch failed: \(error.localizedDescription)")
                result = CommandResult(success: false, errorDescription: "shell launch failed: \(error.localizedDescription)")
            }
        }

        await appendLog(command: command, actionName: actionName,
                        result: result, shellCommand: shellCommand, logOnly: false)
        return result
    }

    // MARK: - Execution Log

    /// Human-readable name for an action, used in log entries.
    nonisolated private static func actionName(_ action: CommandRequest.Action) -> String {
        switch action {
        case .newFile:      return "newFile"
        case .openWithApp:  return "openWithApp"
        case .copyPath:     return "copyPath"
        case .copyFileName: return "copyFileName"
        case .toggleHidden: return "toggleHidden"
        case .openParent:   return "openParent"
        case .shell:        return "shell"
        }
    }

    /// Append a single execution record on the main actor, trimming to the cap.
    private func appendLog(
        command: CommandRequest,
        actionName: String,
        result: CommandResult,
        shellCommand: String?,
        logOnly: Bool
    ) async {
        let entry = ExecutionLogEntry(
            timestamp: Date(),
            action: actionName,
            success: result.success,
            errorDescription: result.errorDescription,
            files: command.files,
            shellCommand: shellCommand,
            extra: command.extra,
            logOnly: logOnly
        )
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.executionLog.append(entry)
            if self.executionLog.count > self.maxLogEntries {
                self.executionLog.removeFirst(self.executionLog.count - self.maxLogEntries)
            }
        }
    }
}
