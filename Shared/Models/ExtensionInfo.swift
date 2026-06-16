import Foundation

/// Represents a Finder Sync Extension with its runtime state and user preferences.
public struct ExtensionInfo: Identifiable, Codable {
    public var id: String { bundleID }

    /// Unique identifier (e.g. "com.qi-xmu.mac-right-menu.FinderExtension")
    public let bundleID: String

    /// Human-readable name for display (e.g. "Finder Extension")
    public let displayName: String

    /// System-level registration state (pluginkit). Set by the Container.
    public var isRegistered: Bool = false

    /// RPC connection state (heartbeat). Set by the Container.
    public var isConnected: Bool = false

    /// PID of the connected Extension process.
    public var connectedPID: Int? = nil

    /// Bundle version reported by the connected Extension.
    public var connectedVersion: String? = nil

    /// Timestamp of the last heartbeat received.
    public var lastHeartbeatAt: Date? = nil

    /// Whether the Container should auto-launch this extension on startup.
    public var autoLaunch: Bool = true

    public init(bundleID: String, displayName: String, autoLaunch: Bool = true) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.autoLaunch = autoLaunch
    }
}
