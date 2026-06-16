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
    private let maxLogEntries = 100

    /// In-memory record of every RPC exchange and wake/lifecycle event the
    /// Container observes, surfaced in the Debug Log window. Cleared on relaunch;
    /// capped at `maxDebugEntries`. Heartbeats are folded into single entries by
    /// `appendDebugActivity` so 1s-interval ping/pong don't fill the cap.
    @Published private(set) var debugLog: [DebugLogEntry] = []
    private let maxDebugEntries = 100

    /// Pending delayed Con→Ext wake. On heartbeat-timeout we don't immediately
    /// `pluginkit -e use`; we schedule it `extWakeDelay` seconds out. If the
    /// Extension reconnects within that window (`onHeartbeat`), the wake is
    /// cancelled — avoiding spurious launches on transient Ext hiccups.
    private var pendingExtWake: DispatchWorkItem?
    private static let extWakeDelay: TimeInterval = 1

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
                // Ext is alive — cancel any pending delayed wake.
                if let pw = self.pendingExtWake {
                    pw.cancel()
                    self.pendingExtWake = nil
                    self.appendDebugEntry(.init(category: .lifecycle, method: "wake",
                                                summary: "Ext reconnected — pending wake cancelled"))
                }
            },
            onDisconnected: { [weak self] in
                guard let self else { return }
                if let index = self.extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                    self.extensions[index].isConnected = false
                    self.extensions[index].connectedPID = nil
                    self.extensions[index].connectedVersion = nil
                    logger.warning("[Con] Extension disconnected — heartbeat timeout")
                    if self.extensions[index].autoLaunch {
                        logger.notice("[Con] Delayed auto-launch of Extension (3s)")
                        self.appendDebugEntry(.init(category: .lifecycle, method: "wake",
                                                    summary: "Heartbeat timeout — scheduling delayed Ext wake (\(Self.extWakeDelay)s)"))
                        // Cancel any previously scheduled wake, then schedule one
                        // `extWakeDelay` seconds out. If Ext reconnects before the
                        // timer fires, `onHeartbeat` cancels it.
                        self.pendingExtWake?.cancel()
                        let work = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.pendingExtWake = nil
                            self.launchExtension(bundleID: Constants.extensionBundleID)
                        }
                        self.pendingExtWake = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extWakeDelay, execute: work)
                    }
                }
            },
            onActivity: { [weak self] activity in
                // RPCServer emits from background queues; hop to the main actor
                // to append (and heartbeat-fold) into `debugLog`.
                Task { @MainActor in self?.appendDebugActivity(activity) }
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
        // Registration check is async; it kicks off auto-launch once the
        // pluginkit status is known (see `checkExtensionRegistration`).
        // We must NOT call `autoLaunchExtensions()` here directly: at this
        // point every extension's `registrationStatus` is still the default
        // `.notInstalled`, so `isRegistered` is false and the launch filter
        // would drop everything.
        checkExtensionRegistration()
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
    /// Skips extensions that are already connected — `pluginkit -e use` is
    /// idempotent, but there's no point re-electing a plugin whose host is
    /// already running and heartbeating.
    private func autoLaunchExtensions() {
        let toLaunch = extensions.filter { $0.autoLaunch && $0.isRegistered && !$0.isConnected }
        guard !toLaunch.isEmpty else { return }
        for ext in toLaunch {
            logger.notice("[Con] Auto-launching extension: \(ext.displayName, privacy: .public)")
            appendDebugEntry(.init(category: .wake, method: "pluginkit",
                                   summary: "Auto-launch: \(ext.displayName)"))
            launchExtension(bundleID: ext.bundleID)
        }
    }

    /// Wake/launch a Finder Sync extension by bundleID.
    ///
    /// FinderSync extensions are `.appex` bundles hosted by the system's plugin
    /// daemon (pkd), NOT LaunchServices applications — so `NSWorkspace.open` /
    /// `open -b` cannot start them (`LSCopyApplicationURLsForBundleIdentifier`
    /// fails for appex bundle ids). The correct wake mechanism is
    /// `pluginkit -e use -i <bundleID>`, which elects the plug-in for use and
    /// lets the plugin host load it (verified: extension starts and connects).
    /// Used both at Container startup (`autoLaunchExtensions`) and after a
    /// heartbeat-timeout disconnect (`onDisconnected`).
    private func launchExtension(bundleID: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-e", "use", "-i", bundleID]
        do {
            try task.run()
            logger.notice("[Con] pluginkit -e use -i \(bundleID, privacy: .public) requested")
            appendDebugEntry(.init(category: .wake, method: "pluginkit",
                                   summary: "pluginkit -e use -i \(bundleID) requested"))
        } catch {
            logger.error("[Con] pluginkit wake failed: \(error.localizedDescription, privacy: .public)")
            appendDebugEntry(.init(category: .wake, method: "pluginkit",
                                   summary: "pluginkit wake failed: \(error.localizedDescription)"))
        }
    }

    func setAutoLaunch(bundleID: String, enabled: Bool) {
        if let index = extensions.firstIndex(where: { $0.bundleID == bundleID }) {
            extensions[index].autoLaunch = enabled
            SharedUserDefaults.setExtensionAutoLaunch(bundleID: bundleID, enabled: enabled)
        }
    }

    /// Check via pluginkit whether the extension is registered with the system,
    /// decoding the election-state flag (`+`/`-`/`!`/`=`) to distinguish
    /// Enabled / Disabled / Not Installed. Public so the Extensions tab's
    /// Refresh button can re-run it after the user toggles the extension in
    /// System Settings. Also drives the startup auto-launch: once the real
    /// registration status is known, registered+disconnected extensions with
    /// `autoLaunch == true` are woken (idempotent under `pluginkit -e use`).
    func checkExtensionRegistration() {
        Task {
            let status = await Self.extensionRegistrationStatus()
            if let index = extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                if extensions[index].registrationStatus != status {
                    extensions[index].registrationStatus = status
                    logger.notice("[Con] Extension registration status: \(status.rawValue, privacy: .public)")
                }
            }
            // Now that registration is known, wake any registered, disconnected
            // extension the user wants auto-launched. Safe to run on every
            // refresh: `pluginkit -e use` is idempotent and the `!isConnected`
            // guard skips extensions that are already alive.
            autoLaunchExtensions()
        }
    }

    /// Deep-link to System Settings → Extensions so the user can enable a
    /// disabled extension without hunting for the pane.
    func openSystemSettingsForExtensions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Probe `pluginkit -m -p com.apple.FinderSync` and decode the leading
    /// election-state flag of our extension's line into a `RegistrationStatus`.
    /// On any failure (pluginkit missing, parse error, exit non-zero) we
    /// conservatively report `.notInstalled` so the UI shows actionable guidance.
    nonisolated private static func extensionRegistrationStatus() async -> RegistrationStatus {
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
                    continuation.resume(returning: parseRegistrationStatus(from: output))
                } catch {
                    logger.error("pluginkit check failed: \(error.localizedDescription)")
                    continuation.resume(returning: .notInstalled)
                }
            }
        }
    }

    /// Decode the election-state flag from `pluginkit -m` output. Each line
    /// begins with a flag char (after optional leading whitespace); we locate
    /// our extension's line and read that flag. See `RegistrationStatus` docs
    /// and the `pluginkit` man page for the flag semantics.
    nonisolated private static func parseRegistrationStatus(from output: String) -> RegistrationStatus {
        guard let line = output
            .components(separatedBy: .newlines)
            // A line "contains" the bundle id only when it actually appears
            // (substring match; false positives are not a concern here since
            // bundle ids are unique reverse-DNS strings).
            .first(where: { $0.contains(Constants.extensionBundleID) })
        else { return .notInstalled }
        // The flag is the first non-whitespace character on the line.
        guard let flag = line.first(where: { !$0.isWhitespace }) else {
            return .notInstalled
        }
        switch flag {
        // Man page: `+` = "elected to use the plug-in";
        //           `!` = "elected to use the plug-in for debugger use".
        // Both are "elected to use", i.e. the extension is active — a
        // FinderSync extension flagged `!` runs normally (it just signals the
        // user enabled it for debugging), so it must not read as disabled.
        case "+", "!":  return .enabled
        // `-` = "elected to ignore"; `=` = "superseded by another plug-in".
        case "-", "=":  return .disabled
        default:        return .disabled   // `?` unknown → treat as actionable
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

    // MARK: - Debug Log

    func clearDebugLog() {
        debugLog.removeAll()
    }

    /// Append a pre-built entry on the main actor, trimming to the cap.
    /// Used for wake/lifecycle events generated directly on the main actor.
    /// No-op when the Debug Log is disabled (the toggle in General settings);
    /// gating here covers every recording path in one place.
    private func appendDebugEntry(_ entry: DebugLogEntry) {
        guard SharedUserDefaults.debugLogEnabled else { return }
        debugLog.append(entry)
        if debugLog.count > maxDebugEntries {
            debugLog.removeFirst(debugLog.count - maxDebugEntries)
        }
    }

    /// Append an activity reported by `RPCServer`. Heartbeat activities
    /// (ping/pong) are folded into the last entry if it is itself a heartbeat
    /// group, so the log isn't dominated by 1s-interval ping/pong traffic.
    private func appendDebugActivity(_ activity: RPCActivity) {
        // Fold consecutive heartbeats into the previous heartbeat entry.
        if activity.isHeartbeat,
           let last = debugLog.last,
           last.category == .rpc,
           (last.method == "ping" || last.method == "pong") {
            // Keep folding the same direction+method as the group leader so
            // a ping group doesn't absorb a pong (or vice-versa) of the other
            // direction — but we DO want consecutive same-method heartbeats
            // (e.g. repeated Con→Ext pings) to accumulate.
            debugLog[debugLog.count - 1].count += 1
            debugLog[debugLog.count - 1].endTimestamp = Date()
            return
        }
        let entry = DebugLogEntry(
            category: activity.kind,
            direction: activity.direction,
            method: activity.method,
            rpcID: activity.rpcID,
            summary: activity.summary
        )
        appendDebugEntry(entry)
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

    /// Release the single-instance lock so a relaunched Container can start
    /// without being killed by the duplicate guard. Call before restart.
    func releaseInstanceLock() {
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
        }
        removeLockFile()
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

    /// Master switch for the "Open With" section, surfaced in the Apps tab
    /// header. Mirrors how the New File section is gated by the `.newFile`
    /// action item below.
    var appsSectionEnabled: Bool {
        get { configuration.appsSectionEnabled }
        set {
            configuration.appsSectionEnabled = newValue
            saveConfiguration()
        }
    }

    /// The New File section's master switch lives in the `.newFile` action
    /// item (gated in MenuBuilder). Exposed here for the File tab header toggle.
    var newFileSectionEnabled: Bool {
        get {
            configuration.actionItems.first(where: { $0.actionType == .newFile })?.isEnabled ?? false
        }
        set {
            if let index = configuration.actionItems.firstIndex(where: { $0.actionType == .newFile }) {
                configuration.actionItems[index].isEnabled = newValue
                saveConfiguration()
            }
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

    // MARK: - Debug Log Settings

    /// Whether the Debug Log window records RPC/wake events. Off by default;
    /// when off, all append paths short-circuit so the bookkeeping is free.
    var debugLogEnabled: Bool {
        get { SharedUserDefaults.debugLogEnabled }
        set {
            SharedUserDefaults.debugLogEnabled = newValue
            // Clear any stale records when disabling so the window doesn't
            // show historical data the user no longer wants surfaced.
            if !newValue { debugLog.removeAll() }
        }
    }

    /// Whether the Execution Log window records command executions. On by
    /// default (the primary user-facing log). When off, `appendLog` no-ops.
    var executionLogEnabled: Bool {
        get { SharedUserDefaults.executionLogEnabled }
        set {
            SharedUserDefaults.executionLogEnabled = newValue
            if !newValue { executionLog.removeAll() }
        }
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
            // Match MenuBuilder: only enabled templates are listed, and the
            // incoming index is relative to that filtered list. Filter here
            // with the same predicate so the index resolves to the same template.
            let templates = SharedUserDefaults.menuConfiguration.newFileTemplates.filter(\.isEnabled)
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
            let fileName = template.resolvedFileName
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
        guard SharedUserDefaults.executionLogEnabled else { return }
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
