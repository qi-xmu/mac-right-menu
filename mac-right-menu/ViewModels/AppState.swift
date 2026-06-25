import SwiftUI
import os.log

private let logger = Logger(subsystem: Constants.mainAppBundleID, category: "app-state")

/// One editable app row surfaced to the Apps settings tab: the app target
/// plus its enabled state (which lives on the menu leaf, not the payload).
struct AppRow: Identifiable, Equatable {
    let id: String        // == app.id (appURL.path)
    let app: AppTarget
    var isEnabled: Bool
}

/// One editable New File template row surfaced to the File settings tab.
struct TemplateRow: Identifiable, Equatable {
    let id: String        // == template.id (resolved file name)
    let template: NewFileTemplate
    var isEnabled: Bool
}

enum UpdateCheckResult {
    case upToDate
    case updateAvailable(_ version: String, downloadURL: String)
    case error(_ message: String)
}

private struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Codable {
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case browserDownloadURL = "browser_download_url"
    }
}

@MainActor
class AppState: ObservableObject {
    /// The sole source of truth: menu tree (`menu`) + action definitions
    /// (`actions`). Edits mutate this in place; the `didSet` persists and
    /// pushes the `menu` half to the Extension.
    @Published var appConfig: AppConfig {
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

    @Published var isCheckingUpdate = false
    @Published var isDownloading = false

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
            onAction: { [weak self] action in
                guard let self else {
                    return RPCResult(success: false, errorDescription: String(localized: "App released"))
                }
                return await self.executeAction(action)
            },
            getConfig: { [weak self] in
                guard let self else { return .default }
                var menu = self.appConfig.menu
                menu.menus.sort { Self.menuSortKey($0) < Self.menuSortKey($1) }
                return menu
            },
            onHeartbeat: { [weak self] meta in
                guard let self else { return }
                let pid = meta?["pid"].flatMap(Int.init)
                let version = meta?["version"]
                let build = meta?["build"]
                let displayName = meta?["displayName"]
                if let index = self.extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                    self.extensions[index].isConnected = true
                    self.extensions[index].connectedPID = pid
                    if let ver = version {
                        self.extensions[index].connectedVersion = build.map { "\(ver) (\($0))" } ?? ver
                    }
                    if let name = displayName, !name.isEmpty {
                        self.extensions[index].displayName = name
                    }
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
        // Filter out (a) ourselves (runningApplications includes the caller)
        // and (b) any instance already in `.terminating` — a terminating app
        // lingers in the list and would otherwise make a freshly-launched
        // replacement (e.g. Restart) see count > 1 and exit immediately.
        let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: Constants.mainAppBundleID
        ).filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        if existing.count > 0 {
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

        self.appConfig = SharedUserDefaults.appConfig
        loadExtensions()
        _ = rpcServer
        // Registration check is async; it kicks off auto-launch once the
        // pluginkit status is known (see `checkExtensionRegistration`).
        checkExtensionRegistration()
        // Probe Full Disk Access so the General settings tab shows a real
        // status on first open instead of "not checked".
        checkFullDiskAccess()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdownExtensions()
        }
    }

    // MARK: - Extension Management

    private func loadExtensions() {
        extensions = Constants.knownExtensions.map { bundleID in
            ExtensionInfo(
                bundleID: bundleID,
                displayName: bundleID,
                autoLaunch: SharedUserDefaults.extensionAutoLaunch(bundleID: bundleID)
            )
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
    /// `open -b` cannot start them. The correct wake mechanism is
    /// `pluginkit -e use -i <bundleID>`, which elects the plug-in for use and
    /// lets the plugin host load it.
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

    /// Check via pluginkit whether the extension is registered with the system.
    /// Public so the Extensions tab's Refresh button can re-run it after the
    /// user toggles the extension in System Settings.
    func checkExtensionRegistration() {
        Task {
            let status = await Self.extensionRegistrationStatus()
            if let index = extensions.firstIndex(where: { $0.bundleID == Constants.extensionBundleID }) {
                if extensions[index].registrationStatus != status {
                    extensions[index].registrationStatus = status
                    logger.notice("[Con] Extension registration status: \(status.rawValue, privacy: .public)")
                }
            }
            autoLaunchExtensions()
        }
    }

    func openSystemSettingsForExtensions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Full Disk Access

    /// Cached Full Disk Access status for the running Container.
    @Published var fullDiskAccessGranted: Bool?

    func checkFullDiskAccess() {
        DispatchQueue.global(qos: .utility).async {
            let granted = FullDiskAccess.isGranted()
            DispatchQueue.main.async {
                self.fullDiskAccessGranted = granted
            }
        }
    }

    func openSystemSettingsForFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Probe `pluginkit -m -p com.apple.FinderSync` and decode the leading
    /// election-state flag of our extension's line into a `RegistrationStatus`.
    nonisolated private static func extensionRegistrationStatus() async -> RegistrationStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
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

    nonisolated private static func parseRegistrationStatus(from output: String) -> RegistrationStatus {
        guard let line = output
            .components(separatedBy: .newlines)
            .first(where: { $0.contains(Constants.extensionBundleID) })
        else { return .notInstalled }
        guard let flag = line.first(where: { !$0.isWhitespace }) else {
            return .notInstalled
        }
        switch flag {
        case "+", "!":  return .enabled
        case "-", "=":  return .disabled
        default:        return .disabled
        }
    }

    // MARK: - Config Sync

    /// Stable sort key for a top-level menu item so that the `menus` array is
    /// transmitted (and persisted) in actionID order: New File (0…), Open With
    /// (1000…), general operations (2000…), shell (4000…). Leaf nodes use
    /// their own actionID; section headers use the first leaf's actionID (or
    /// zero if the section is empty).
    private static func menuSortKey(_ item: MenuItem) -> Int {
        item.subMenus.first?.actionID ?? item.actionID
    }

    func saveConfiguration() {
        var sorted = appConfig
        sorted.menu.menus.sort { Self.menuSortKey($0) < Self.menuSortKey($1) }
        SharedUserDefaults.appConfig = sorted
        // Push the menu tree to any running Extension so its in-memory cache
        // refreshes immediately. Each process keeps its own UserDefaults, so
        // the full tree travels in the notification payload.
        rpcServer.broadcastConfig(sorted.menu)
    }

    func shutdownExtensions() {
        rpcServer.broadcastShutdown()
        let server = rpcServer
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            server.stop()
        }
    }

    func quit() {
        shutdownExtensions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.terminate(nil)
        }
    }

    func checkForUpdate(completion: @escaping @MainActor (UpdateCheckResult) -> Void) {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task.detached {
            let result: UpdateCheckResult
            do {
                let url = URL(string: "https://api.github.com/repos/qi-xmu/mac-right-menu/releases/latest")!
                var req = URLRequest(url: url)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tagName.replacingOccurrences(of: "v", with: "")
                let current = Constants.version
                if latest.compare(current, options: .numeric) == .orderedDescending {
                    let dmgURL = release.assets.first?.browserDownloadURL ?? ""
                    result = .updateAvailable(latest, downloadURL: dmgURL)
                } else {
                    result = .upToDate
                }
            } catch {
                result = .error(error.localizedDescription)
            }
            await MainActor.run {
                self.isCheckingUpdate = false
                completion(result)
            }
        }
    }

    func quickCheckUpdate() {
        checkForUpdate { result in
            let alert = NSAlert()
            switch result {
            case .upToDate:
                alert.messageText = String(localized: "You're up to date!")
                alert.alertStyle = .informational
                alert.addButton(withTitle: String(localized: "OK"))
            case .updateAvailable(let version, let url):
                alert.messageText = String(localized: "New version v\(version) available!")
                alert.informativeText = String(localized: "Download and install now? The app will quit after downloading.")
                alert.alertStyle = .informational
                alert.addButton(withTitle: String(localized: "Download & Install"))
                alert.addButton(withTitle: String(localized: "Later"))
                if alert.runModal() == .alertFirstButtonReturn {
                    self.downloadAndInstall(from: url) { _ in }
                }
                return
            case .error(let msg):
                alert.messageText = String(localized: "Update check failed")
                alert.informativeText = msg
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "OK"))
            }
            alert.runModal()
        }
    }

    func downloadAndInstall(from urlString: String, completion: @escaping @MainActor (String?) -> Void) {
        guard !isDownloading, let url = URL(string: urlString) else { return }
        isDownloading = true
        Task.detached {
            let msg: String?
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let dmgURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mac-right-menu-update.dmg")
                try data.write(to: dmgURL)
                await NSWorkspace.shared.open(dmgURL)
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                msg = nil
            } catch {
                msg = error.localizedDescription
            }
            await MainActor.run {
                self.isDownloading = false
                completion(msg)
            }
        }
    }

    func clearLog() {
        executionLog.removeAll()
    }

    // MARK: - Debug Log

    func clearDebugLog() {
        debugLog.removeAll()
    }

    /// Export the current debug log to a plain-text file the user picks via
    /// NSSavePanel. Returns the written URL on success, nil on cancel/error.
    @discardableResult
    func exportDebugLog() -> URL? {
        guard !debugLog.isEmpty else { return nil }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Debug Log")
        let stamp = Self.exportDateFormatter.string(from: Date())
        panel.nameFieldStringValue = "mac-right-menu-debug-\(stamp).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let text = renderDebugLogText()
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("[Con] exportDebugLog write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func renderDebugLogText() -> String {
        let tsFmt = DateFormatter()
        tsFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        tsFmt.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = []
        lines.append("# mac-right-menu Debug Log")
        lines.append("# Exported: \(tsFmt.string(from: Date()))")
        lines.append("# Entries: \(debugLog.count)")
        lines.append("")

        for entry in debugLog.reversed() {
            var header = "[\(tsFmt.string(from: entry.timestamp))]"
            if let end = entry.endTimestamp {
                header += " – [\(tsFmt.string(from: end))]"
            }
            let dir = entry.direction.map { $0 == .send ? "↑" : "↓" } ?? "·"
            let method = entry.method ?? "—"
            var badge: String
            switch entry.category {
            case .rpc:        badge = "rpc \(dir) \(method)"
            case .wake:       badge = "wake \(method)"
            case .connection: badge = "conn \(method)"
            case .lifecycle:  badge = "life \(method)"
            }
            if let id = entry.rpcID { badge += " #\(id)" }
            if entry.count > 1 { badge += " ×\(entry.count)" }
            lines.append("\(header) \(badge)")
            lines.append("  \(entry.summary)")
            if let detail = entry.detail, !detail.isEmpty {
                detail.split(separator: "\n").forEach { lines.append("    \($0)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Append a pre-built entry on the main actor, trimming to the cap.
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
        if activity.isHeartbeat,
           let last = debugLog.last,
           last.category == .rpc,
           (last.method == "ping" || last.method == "pong") {
            debugLog[debugLog.count - 1].count += 1
            debugLog[debugLog.count - 1].endTimestamp = Date()
            return
        }
        let entry = DebugLogEntry(
            category: activity.kind,
            direction: activity.direction,
            method: activity.method,
            rpcID: activity.rpcID,
            summary: activity.summary,
            detail: activity.detail,
            rawPayload: activity.rawPayload
        )
        appendDebugEntry(entry)
    }

    // MARK: - Lock file (single-instance guard via flock)

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

    /// Release the single-instance lock so a relaunched Container can start
    /// without being killed by the duplicate guard. Call before restart.
    func releaseInstanceLock() {
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
        }
    }

    // MARK: - Menu editing (tree + ActionDefMap, surfaced as typed rows)

    /// Stable node IDs for the two managed sections. AppState owns these
    /// sections' layout; operations are loose top-level leaves with id
    /// "op.<rawValue>".
    private static let appsSectionID = "section.apps"
    private static let newFileSectionID = "section.newFile"

    // ── Global toggles ──

    /// Master switch for the whole menu.
    var isEnabled: Bool {
        get { appConfig.menu.isEnabled }
        set { appConfig.menu.isEnabled = newValue }
    }

    /// Global icon toggle (applies to every node whose own `showAppIcons` is
    /// also true).
    var showIcons: Bool {
        get { appConfig.menu.showAppIcons }
        set { appConfig.menu.showAppIcons = newValue }
    }

    // ── New File section ──

    var newFileSectionEnabled: Bool {
        get { appConfig.menu.menus.first(where: { $0.id == Self.newFileSectionID })?.isEnabled ?? true }
        set { ensureSection(Self.newFileSectionID, title: String(localized: "New File"), icon: .sfSymbol("doc.badge.plus"), showCondition: .isDir, multiItemSupport: false, isEnabled: newValue) }
    }

    var templateRows: [TemplateRow] {
        guard let section = appConfig.menu.menus.first(where: { $0.id == Self.newFileSectionID }) else { return [] }
        return section.subMenus.compactMap { leaf in
            guard case .newFile(let template) = appConfig.actions[leaf.actionID] else { return nil }
            return TemplateRow(id: template.id, template: template, isEnabled: leaf.isEnabled)
        }
    }

    func addTemplate(fileName: String, fileExtension: String) {
        let template = NewFileTemplate(fileName: fileName, fileExtension: fileExtension)
        var list = templateRows.map { (template: $0.template, isEnabled: $0.isEnabled) }
        guard !list.contains(where: { $0.template.id == template.id }) else { return }
        list.append((template: template, isEnabled: true))
        Self.rebuildNewFileSection(in: &appConfig, templates: list, sectionEnabled: newFileSectionEnabled)
    }

    func removeTemplate(at offsets: IndexSet) {
        var list = templateRows.map { (template: $0.template, isEnabled: $0.isEnabled) }
        list.remove(atOffsets: offsets)
        Self.rebuildNewFileSection(in: &appConfig, templates: list, sectionEnabled: newFileSectionEnabled)
    }

    private func setLeafEnabled(sectionID: String, leafPrefix: String, id: String, enabled: Bool) {
        guard let sIdx = appConfig.menu.menus.firstIndex(where: { $0.id == sectionID }),
              let leafIdx = appConfig.menu.menus[sIdx].subMenus.firstIndex(where: { $0.id == "\(leafPrefix)\(id)" })
        else { return }
        appConfig.menu.menus[sIdx].subMenus[leafIdx].isEnabled = enabled
    }

    func setTemplateEnabled(id: String, enabled: Bool) {
        setLeafEnabled(sectionID: Self.newFileSectionID, leafPrefix: "newFile.", id: id, enabled: enabled)
    }

    func setAppEnabled(id: String, enabled: Bool) {
        setLeafEnabled(sectionID: Self.appsSectionID, leafPrefix: "app.", id: id, enabled: enabled)
    }

    // ── Open With section ──

    var appsSectionEnabled: Bool {
        get { appConfig.menu.menus.first(where: { $0.id == Self.appsSectionID })?.isEnabled ?? true }
        set { ensureSection(Self.appsSectionID, title: String(localized: "Open With"), icon: .sfSymbol("menubar.dock.rectangle"), showCondition: .both, multiItemSupport: true, isEnabled: newValue) }
    }

    /// Whether app icons are shown in the Open With submenu. Controls only the
    /// individual app leaf items — the section header's SF Symbol icon is
    /// always gated by the global `showIcons` toggle.
    var appsShowAppIcons: Bool {
        get {
            guard let section = appConfig.menu.menus.first(where: { $0.id == Self.appsSectionID }),
                  let firstLeaf = section.subMenus.first
            else { return false }
            return firstLeaf.showAppIcons
        }
        set {
            guard let idx = appConfig.menu.menus.firstIndex(where: { $0.id == Self.appsSectionID }) else { return }
            var updated = appConfig.menu.menus
            for leafIdx in updated[idx].subMenus.indices {
                updated[idx].subMenus[leafIdx].showAppIcons = newValue
            }
            appConfig.menu.menus = updated
        }
    }

    var appRows: [AppRow] {
        guard let section = appConfig.menu.menus.first(where: { $0.id == Self.appsSectionID }) else { return [] }
        return section.subMenus.compactMap { leaf in
            guard case .openWith(let app) = appConfig.actions[leaf.actionID] else { return nil }
            return AppRow(id: app.id, app: app, isEnabled: leaf.isEnabled)
        }
    }

    func addApp(_ appURL: URL) {
        let target = AppTarget(appURL: appURL)
        var list = appRows.map { (app: $0.app, isEnabled: $0.isEnabled) }
        guard !list.contains(where: { $0.app.id == target.id }) else { return }
        list.append((app: target, isEnabled: true))
        let showIcons = appsShowAppIcons
        Self.rebuildAppsSection(in: &appConfig, apps: list, sectionEnabled: appsSectionEnabled, showAppIcons: showIcons)
    }

    func removeApp(at offsets: IndexSet) {
        var list = appRows.map { (app: $0.app, isEnabled: $0.isEnabled) }
        let showIcons = appsShowAppIcons
        list.remove(atOffsets: offsets)
        Self.rebuildAppsSection(in: &appConfig, apps: list, sectionEnabled: appsSectionEnabled, showAppIcons: showIcons)
    }

    func moveApp(from source: IndexSet, to destination: Int) {
        var list = appRows.map { (app: $0.app, isEnabled: $0.isEnabled) }
        let showIcons = appsShowAppIcons
        list.move(fromOffsets: source, toOffset: destination)
        Self.rebuildAppsSection(in: &appConfig, apps: list, sectionEnabled: appsSectionEnabled, showAppIcons: showIcons)
    }

    // ── General operations ──

    func operationEnabled(_ op: GeneralOperation) -> Bool {
        appConfig.menu.menus.first { $0.id == "op.\(op.rawValue)" }?.isEnabled ?? false
    }

    func setOperation(_ op: GeneralOperation, enabled: Bool) {
        let id = Self.opActionID(op)
        if let idx = appConfig.menu.menus.firstIndex(where: { $0.id == "op.\(op.rawValue)" }) {
            // Batch both writes (menu + actions) into a single didSet trigger
            var updated = appConfig
            updated.menu.menus[idx].isEnabled = enabled
            updated.actions[id] = enabled ? .general(operation: op) : nil
            appConfig = updated
        } else if enabled {
            var updated = appConfig
            updated.actions[id] = .general(operation: op)
            updated.menu.menus.append(MenuItem(
                id: "op.\(op.rawValue)",
                showAppIcons: true,
                showCondition: .both,
                multiItemSupport: true,
                actionID: id,
                icon: .sfSymbol(op.systemIconName),
                name: op.displayTitle
            ))
            appConfig = updated
        }
    }

    func resetToDefaults() {
        appConfig = .default
    }

    // MARK: - Section surgery helpers

    /// Ensure a top-level section node exists with the given id/title/icon,
    /// creating it if missing, and set its enabled state. Used by the section
    /// master toggles so the user can flip a section off even before any items
    /// are added.
    private func ensureSection(_ id: String, title: String, icon: MenuIcon, showCondition: ShowCondition, multiItemSupport: Bool, isEnabled: Bool) {
        if let idx = appConfig.menu.menus.firstIndex(where: { $0.id == id }) {
            var updated = appConfig.menu.menus
            updated[idx].isEnabled = isEnabled
            updated[idx].showAppIcons = true
            appConfig.menu.menus = updated
        } else {
            appConfig.menu.menus.append(MenuItem(
                id: id,
                isEnabled: isEnabled,
                showAppIcons: true,
                showCondition: showCondition,
                multiItemSupport: multiItemSupport,
                actionID: 0,
                icon: icon,
                name: title
            ))
        }
    }

    /// Rebuild the New File section from a typed list: clear old template
    /// actions (0..<1000), then assign actionID = 0 + index for each template.
    private static func rebuildNewFileSection(in config: inout AppConfig, templates: [(template: NewFileTemplate, isEnabled: Bool)], sectionEnabled: Bool) {
        for key in config.actions.keys where key >= 0 && key < 1000 {
            config.actions[key] = nil
        }
        let leaves = templates.enumerated().map { index, pair -> MenuItem in
            let id = Constants.TagBase.newFile.rawValue + index
            config.actions[id] = .newFile(template: pair.template)
            return MenuItem(
                id: "newFile.\(pair.template.id)",
                isEnabled: pair.isEnabled,
                showAppIcons: false,
                showCondition: .isDir,
                multiItemSupport: false,
                actionID: id,
                icon: .none,
                name: pair.template.resolvedFileName
            )
        }
        if let idx = config.menu.menus.firstIndex(where: { $0.id == newFileSectionID }) {
            config.menu.menus[idx].isEnabled = sectionEnabled
            config.menu.menus[idx].showAppIcons = true
            config.menu.menus[idx].subMenus = leaves
        } else {
            config.menu.menus.append(MenuItem(
                id: newFileSectionID, isEnabled: sectionEnabled, showAppIcons: true,
                showCondition: .isDir, multiItemSupport: false, actionID: 0,
                icon: .sfSymbol("doc.badge.plus"), name: String(localized: "New File"),
                subMenus: leaves
            ))
        }
    }

    /// Rebuild the Open With section from a typed list: clear old app actions
    /// (1000..<2000), then assign actionID = 1000 + index for each app.
    /// `showAppIcons` is the current value of the "Show App Icons" toggle
    /// (snapped before rebuild so adding/removing an app preserves the user's
    /// preference).
    private static func rebuildAppsSection(in config: inout AppConfig, apps: [(app: AppTarget, isEnabled: Bool)], sectionEnabled: Bool, showAppIcons: Bool) {
        for key in config.actions.keys where key >= 1000 && key < 2000 {
            config.actions[key] = nil
        }
        let leaves = apps.enumerated().map { index, pair -> MenuItem in
            let id = Constants.TagBase.appItem.rawValue + index
            config.actions[id] = .openWith(app: pair.app)
            return MenuItem(
                id: "app.\(pair.app.id)",
                isEnabled: pair.isEnabled,
                showAppIcons: showAppIcons,
                showCondition: .both,
                multiItemSupport: true,
                actionID: id,
                icon: .appIcon(path: pair.app.appURL.path),
                name: pair.app.displayName
            )
        }
        if let idx = config.menu.menus.firstIndex(where: { $0.id == appsSectionID }) {
            config.menu.menus[idx].isEnabled = sectionEnabled
            config.menu.menus[idx].showAppIcons = true
            config.menu.menus[idx].subMenus = leaves
        } else {
            config.menu.menus.append(MenuItem(
                id: appsSectionID, isEnabled: sectionEnabled, showAppIcons: true,
                showCondition: .both, multiItemSupport: true, actionID: 0,
                icon: .sfSymbol("menubar.dock.rectangle"), name: String(localized: "Open With"),
                subMenus: leaves
            ))
        }
    }

    private static func opActionID(_ op: GeneralOperation) -> Int {
        switch op {
        case .copyPath:     return Constants.TagBase.copyPath.rawValue
        case .copyFileName: return Constants.TagBase.copyFileName.rawValue
        case .toggleHidden: return Constants.TagBase.toggleHidden.rawValue
        }
    }

    // MARK: - Command Execution

    var commandExecutionEnabled: Bool {
        get { !SharedUserDefaults.commandLogOnly }
        set { SharedUserDefaults.commandLogOnly = !newValue }
    }

    // MARK: - Debug Log Settings

    var debugLogEnabled: Bool {
        get { SharedUserDefaults.debugLogEnabled }
        set {
            SharedUserDefaults.debugLogEnabled = newValue
            if !newValue { debugLog.removeAll() }
        }
    }

    var executionLogEnabled: Bool {
        get { SharedUserDefaults.executionLogEnabled }
        set {
            SharedUserDefaults.executionLogEnabled = newValue
            if !newValue { executionLog.removeAll() }
        }
    }

    /// Execute an action received from the Extension. Resolves `actionID` via
    /// the current `ActionDefMap` and runs the matching `ActionDef`. Returns
    /// the real outcome so the RPC response reflects success/failure and the
    /// Execution Log records the same result the caller observed.
    nonisolated func executeAction(_ action: MenuAction) async -> RPCResult {
        let actionID = action.actionID

        // Snapshot the action definition on the main actor (AppState is
        // @MainActor). Execution itself runs off-actor.
        let def: ActionDef? = await MainActor.run { self.appConfig.actions[actionID] }
        guard let def else {
            logger.warning("[Con] executeAction: unknown actionID \(actionID)")
            let result = RPCResult(success: false, errorDescription: "操作失败: \(actionID)")
            await appendLog(actionName: "unknown(\(actionID))", files: [], result: result, shellCommand: nil, logOnly: false)
            return result
        }

        let actionName = Self.actionName(for: def)

        // Effective targets: the actual selection, or the containing folder
        // (targetURL) when right-clicking empty space.
        let effectiveURLs: [URL] = action.selectedURLs.isEmpty
            ? (action.targetURL.map { [$0] } ?? [])
            : action.selectedURLs

        // commandLogOnly: record receipt but skip execution.
        if SharedUserDefaults.commandLogOnly {
            logger.notice("""
                [Con][RPC RECV→DISPATCH] actionID=\(actionID, privacy: .public) \
                files=\(effectiveURLs.map(\.path), privacy: .public)
                """)
            let result = RPCResult(success: true)
            await appendLog(actionName: actionName, files: effectiveURLs.map(\.path), result: result, shellCommand: nil, logOnly: true)
            return result
        }

        var result: RPCResult
        var shellCommand: String? = nil

        switch def {
        case .newFile(let template):
            result = await Self.performNewFile(template: template,
                                               targetURL: action.targetURL,
                                               selectedURLs: action.selectedURLs)
        case .openWith(let app):
            result = await Self.performOpenWith(app: app, urls: effectiveURLs)
        case .general(let operation):
            result = Self.performGeneral(operation, urls: effectiveURLs)
        case .custom(let command):
            // Reserved (shell); not yet wired in the UI.
            shellCommand = command
            logger.notice("[Con] custom action (unimplemented): \(command, privacy: .public)")
            result = RPCResult(success: false, errorDescription: String(localized: "Custom command not implemented"))
        }

        await appendLog(actionName: actionName, files: effectiveURLs.map(\.path), result: result, shellCommand: shellCommand, logOnly: false)
        if !result.success {
            let errorDesc = result.errorDescription ?? "未知错误"
            let displayName = await MainActor.run { self.menuItemName(for: actionID) }
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = String(localized: "Execution Failed")
                alert.informativeText = "\(displayName)\n\(errorDesc)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "OK"))
                DispatchQueue.main.async {
                    alert.runModal()
                }
            }
        }
        return result
    }

    /// Human-readable name for an `ActionDef`, used in log entries.
    nonisolated private static func actionName(for def: ActionDef) -> String {
        switch def {
        case .newFile:           return "newFile"
        case .openWith:          return "openWith"
        case .general(let op):   return op.rawValue
        case .custom:            return "shell"
        }
    }

    /// Find the display name from the menu tree for a given actionID.
    /// For leaf items inside a section, returns the section name; otherwise
    /// returns the matching item's own name.
    private func menuItemName(for actionID: Int) -> String {
        for section in appConfig.menu.menus {
            if !section.subMenus.isEmpty {
                for leaf in section.subMenus {
                    if leaf.actionID == actionID { return section.name }
                }
            }
            if section.actionID == actionID { return section.name }
        }
        return "actionID \(actionID)"
    }

    /// Create a new file from a template. The directory is derived from the
    /// Finder context that the Extension forwarded (this logic used to live in
    /// the Extension; it's centralized here so the Container owns behavior):
    ///   - a selected folder → create inside it
    ///   - a selected file   → create in its parent
    ///   - empty space        → create in `targetURL` (the containing folder)
    nonisolated private static func performNewFile(template: NewFileTemplate, targetURL: URL?, selectedURLs: [URL]) async -> RPCResult {
        let dirURL: URL
        if let first = selectedURLs.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                dirURL = first
            } else {
                dirURL = first.deletingLastPathComponent()
            }
        } else if let target = targetURL {
            dirURL = target
        } else {
            return RPCResult(success: false, errorDescription: String(localized: "Cannot determine target folder"))
        }

        let fm = FileManager.default
        let baseName = template.resolvedFileName
        var fileURL = dirURL.appendingPathComponent(baseName)
        var counter = 1
        while fm.fileExists(atPath: fileURL.path) {
            guard counter < 1000 else {
                return RPCResult(success: false, errorDescription: "文件名冲突过多: \(baseName)")
            }
            let name = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            fileURL = dirURL.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        do {
            let content = template.defaultContent.data(using: .utf8) ?? Data()
            try content.write(to: fileURL)
            logger.notice("Created new file: \(fileURL.path)")
            return RPCResult(success: true)
        } catch {
            logger.error("newFile failed: \(error.localizedDescription)")
            return RPCResult(success: false, errorDescription: error.localizedDescription)
        }
    }

    /// Open the given URLs with an application.
    nonisolated private static func performOpenWith(app: AppTarget, urls: [URL]) async -> RPCResult {
        guard !urls.isEmpty else {
            return RPCResult(success: false, errorDescription: String(localized: "No files to open"))
        }
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.promptsUserIfNeeded = true
            let launched = try await NSWorkspace.shared.open(urls, withApplicationAt: app.appURL, configuration: config)
            logger.notice("Opened \(urls.count) item(s) with \(launched.localizedName ?? app.displayName)")
            return RPCResult(success: true)
        } catch {
            logger.error("openWith failed: \(error.localizedDescription)")
            return RPCResult(success: false, errorDescription: error.localizedDescription)
        }
    }

    /// Run a built-in general operation (copy path / copy name / toggle hidden).
    nonisolated private static func performGeneral(_ operation: GeneralOperation, urls: [URL]) -> RPCResult {
        switch operation {
        case .copyPath:
            let paths = urls.map(\.path).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths, forType: .string)
            logger.notice("Copied \(urls.count) path(s)")
            return RPCResult(success: true)
        case .copyFileName:
            let names = urls.map(\.lastPathComponent).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(names, forType: .string)
            logger.notice("Copied \(urls.count) file name(s)")
            return RPCResult(success: true)
        case .toggleHidden:
            var failed: String?
            for url in urls {
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
            return failed.map { RPCResult(success: false, errorDescription: $0) }
                ?? RPCResult(success: true)
        }
    }

    // MARK: - Execution Log

    /// Append a single execution record on the main actor, trimming to the cap.
    nonisolated private func appendLog(
        actionName: String,
        files: [String],
        result: RPCResult,
        shellCommand: String?,
        logOnly: Bool
    ) async {
        guard SharedUserDefaults.executionLogEnabled else { return }
        let entry = ExecutionLogEntry(
            timestamp: Date(),
            action: actionName,
            success: result.success,
            errorDescription: result.errorDescription,
            files: files,
            shellCommand: shellCommand,
            extra: nil,
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
