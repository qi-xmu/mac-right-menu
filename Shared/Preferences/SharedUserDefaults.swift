import Foundation
import os

private let logger = Logger(subsystem: Constants.currentBundleID, category: "shared-defaults")

/// Each process has its own isolated UserDefaults store:
/// - Container: ~/Library/Preferences/com.qi-xmu.mac-right-menu.plist (unsandboxed)
/// - Extension: inside its own sandbox container (no TCC)
/// Config sync happens via RPC, not shared file I/O.
public enum SharedUserDefaults {

    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    // MARK: - Menu Configuration

    public static var menuConfiguration: MenuConfiguration {
        get {
            guard let data = defaults.data(forKey: Constants.Defaults.menuConfigKey) else {
                logger.notice("Config read: using default")
                return .default
            }
            let config = (try? JSONDecoder().decode(MenuConfiguration.self, from: data)) ?? .default
            let actions = config.actionItems.map { "\($0.actionType):\($0.isEnabled ? "on" : "off")" }.joined(separator: " ")
            logger.notice("Config read: enabled=\(config.isEnabled) apps=\(config.appItems.count) actions=[\(actions, privacy: .public)] templates=\(config.newFileTemplates.count)")
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
            defaults.set(data, forKey: Constants.Defaults.menuConfigKey)
        }
    }

    // MARK: - Extension Enabled

    public static var isExtensionEnabled: Bool {
        get { defaults.bool(forKey: Constants.Defaults.isExtensionEnabledKey) }
        set { defaults.set(newValue, forKey: Constants.Defaults.isExtensionEnabledKey) }
    }

    // MARK: - Command Log Only

    public static var commandLogOnly: Bool {
        get { defaults.bool(forKey: Constants.Defaults.commandLogOnlyKey) }
        set { defaults.set(newValue, forKey: Constants.Defaults.commandLogOnlyKey) }
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

    public static func forceReload() {
        defaults.synchronize()
    }
}
