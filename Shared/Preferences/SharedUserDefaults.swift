import Foundation
import os

private let logger = Logger(subsystem: Constants.currentBundleID, category: "shared-defaults")

/// Each process has its own isolated UserDefaults store:
/// - Container: ~/Library/Preferences/com.qi-xmu.mac-right-menu.plist (unsandboxed)
/// - Extension: inside its own sandbox container (no TCC)
/// Config sync happens via RPC, not shared file I/O.
public enum SharedUserDefaults {

    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    // MARK: - App Configuration (menu tree + action definitions)

    /// The persisted `AppConfig` (menu tree + `ActionDefMap`). Each process
    /// keeps its own store; the Container pushes the `menu` half to the
    /// Extension over RPC via `configDidChange` / `getConfig`.
    public static var appConfig: AppConfig {
        get {
            guard let data = defaults.data(forKey: Constants.Defaults.appConfigKey) else {
                logger.notice("Config read: using default")
                return .default
            }
            let config = (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? .default
            logger.notice("Config read: enabled=\(config.menu.isEnabled) menus=\(config.menu.menus.count) actions=\(config.actions.count)")
            return config
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                logger.error("Config write: encode failed")
                return
            }
            // UserDefaults rejects values >= 4 MB per key silently. Detect and
            // log loudly so a regression (e.g. embedding icon data) is caught
            // instead of silently corrupting the config store.
            if data.count >= 4_000_000 {
                logger.error("Config write: \(data.count) bytes exceeds the 4 MB UserDefaults limit — refusing to write. Check for unintended large fields (e.g. icon bitmaps).")
                return
            }
            defaults.set(data, forKey: Constants.Defaults.appConfigKey)
        }
    }

    // MARK: - Command Log Only

    public static var commandLogOnly: Bool {
        get { defaults.bool(forKey: Constants.Defaults.commandLogOnlyKey) }
        set { defaults.set(newValue, forKey: Constants.Defaults.commandLogOnlyKey) }
    }

    // MARK: - Debug Log Enabled

    /// Whether the Debug Log window should record RPC/wake events. Off by
    /// default so the bookkeeping is skipped entirely in normal use.
    public static var debugLogEnabled: Bool {
        get { defaults.bool(forKey: Constants.Defaults.debugLogEnabledKey) }
        set { defaults.set(newValue, forKey: Constants.Defaults.debugLogEnabledKey) }
    }

    // MARK: - Execution Log Enabled

    /// Whether the Execution Log window records command executions.
    /// On by default since this is the primary user-facing activity log.
    public static var executionLogEnabled: Bool {
        get {
            if defaults.object(forKey: Constants.Defaults.executionLogEnabledKey) == nil {
                return true // default on
            }
            return defaults.bool(forKey: Constants.Defaults.executionLogEnabledKey)
        }
        set { defaults.set(newValue, forKey: Constants.Defaults.executionLogEnabledKey) }
    }

    // MARK: - Extension Preferences

    private static let extensionPrefsKey = "extensionPreferences"

    /// Per-extension user preferences (autoLaunch, etc.), keyed by bundleID.
    public static func extensionAutoLaunch(bundleID: String) -> Bool {
        let prefs = defaults.dictionary(forKey: extensionPrefsKey) as? [String: Bool] ?? [:]
        return prefs[bundleID] ?? true
    }

    public static func setExtensionAutoLaunch(bundleID: String, enabled: Bool) {
        var prefs = defaults.dictionary(forKey: extensionPrefsKey) as? [String: Bool] ?? [:]
        prefs[bundleID] = enabled
        defaults.set(prefs, forKey: extensionPrefsKey)
    }

}
