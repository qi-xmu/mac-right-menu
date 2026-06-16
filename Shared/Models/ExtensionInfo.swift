import Foundation

/// System-level registration state derived from `pluginkit -m` output.
///
/// `pluginkit -m -p com.apple.FinderSync` lists one matching plugin per line;
/// each line begins with a flag indicating the user's election state
/// (`pluginkit` man page):
///
///   `+` elected to use            → `.enabled`
///   `!` elected to use (debugger) → `.enabled`  (active; "for debugger use")
///   `-` elected to ignore         → `.disabled`
///   `=` superseded                → `.disabled`
///   (line absent)                 → `.notInstalled`
///
/// The `-`/`!`/`=` cases all mean "present in pluginkit but not active", so they
/// share the same remediation (enable in System Settings) and collapse into a
/// single `.disabled` state.
public enum RegistrationStatus: String, Codable {
    case enabled
    case disabled
    case notInstalled
}

/// Represents a Finder Sync Extension with its runtime state and user preferences.
public struct ExtensionInfo: Identifiable, Codable {
    public var id: String { bundleID }

    /// Unique identifier (e.g. "com.qi-xmu.mac-right-menu.FinderExtension")
    public let bundleID: String

    /// Human-readable name for display (e.g. "Finder Extension")
    public let displayName: String

    /// System-level registration state (pluginkit). Set by the Container.
    public var registrationStatus: RegistrationStatus = .notInstalled

    /// Convenience: true when the extension is known to pluginkit in any state
    /// (enabled, disabled, superseded...). Used by `autoLaunchExtensions()` to
    /// decide whether a launch attempt is worthwhile.
    public var isRegistered: Bool { registrationStatus != .notInstalled }

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
