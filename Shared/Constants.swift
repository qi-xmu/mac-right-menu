import Foundation

public enum Constants {
    public static let appGroupID = "group.com.qi-xmu.mac-right-menu"

    public static let mainAppBundleID = "com.qi-xmu.mac-right-menu"
    public static let extensionBundleID = "com.qi-xmu.mac-right-menu.FinderExtension"

    /// The bundle id of the process actually running this code right now.
    /// Shared code (RPCSession, SharedUserDefaults) is compiled into BOTH
    /// targets, so a hardcoded subsystem would label Extension-side logs with
    /// the Container's id (or vice versa). Reading it at runtime keeps each
    /// process's logs under its own subsystem.
    public static var currentBundleID: String {
        Bundle.main.bundleIdentifier ?? mainAppBundleID
    }

    /// "Con" when running in the Container app, "Ext" when in the Finder
    /// Extension. Used as a log prefix so the origin of each line is obvious
    /// at a glance without filtering by subsystem.
    public static var currentProcessRole: String {
        currentBundleID == extensionBundleID ? "Ext" : "Con"
    }

    /// JSON-RPC over TCP: Container listens on 127.0.0.1 at this fixed port.
    public static let rpcHost = "127.0.0.1"
    public static let rpcPort: UInt16 = 57421

    /// Lock file written by the Container to indicate it is running.
    /// Extension checks this before attempting to launch a second instance.
    public static var containerLockURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("container.lock")
    }

    /// Heartbeat: the Extension sends a `ping` every `heartbeatInterval`
    /// seconds. If `heartbeatMaxMisses` consecutive pings go unanswered, the
    /// Extension treats the Container as dead and reconnects.
    public static let heartbeatInterval: TimeInterval = 15
    public static let heartbeatMaxMisses: Int = 3

    /// All known extensions bundled with this app. Used to populate the
    /// extension list in settings and for auto-launch on Container startup.
    public static let knownExtensions: [(bundleID: String, displayName: String)] = [
        (extensionBundleID, "Finder Extension"),
    ]

    public enum Defaults {
        public static let menuConfigKey = "menuConfiguration"
        public static let isExtensionEnabledKey = "isExtensionEnabled"
        public static let commandLogOnlyKey = "commandLogOnly"
    }

    public enum TagBase: Int {
        case newFile = 0        // 0–999: template index
        case appItem = 1000     // 1000–1999: app index
        case copyPath = 2000
        case copyFileName = 2001
        case toggleHidden = 2002
        case openParent = 2003
        case shell = 4000       // 4000–4999: shell index
    }
}
