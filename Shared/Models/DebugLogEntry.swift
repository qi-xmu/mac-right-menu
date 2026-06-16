import Foundation

/// A single recorded debug event, surfaced in the Debug Log window.
///
/// Records everything the Container can observe about RPC traffic and the
/// Ext wake/lifecycle: every JSON-RPC message sent to or received from the
/// Extension, plus `pluginkit` wake requests and connection state changes.
///
/// In-memory only (not persisted); cleared on app relaunch. Capped by
/// `AppState.maxDebugEntries` to bound memory growth.
public struct DebugLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    /// For collapsed heartbeat groups, the time of the last heartbeat in the
    /// group; nil for single events.
    public var endTimestamp: Date?
    public let category: Category
    /// RPC direction from the Container's viewpoint. Non-RPC entries are nil.
    public let direction: Direction?
    /// RPC method ("ping"/"pong"/"executeCommand"/"getConfig"/"configDidChange"/
    /// "shutdown"/"response") or a connection/wake descriptor. nil for lifecycle.
    public let method: String?
    public let rpcID: Int?
    public let summary: String
    /// > 1 means this entry collapses `count` consecutive heartbeats.
    public var count: Int

    public enum Category: String, Sendable {
        case rpc
        case wake
        case connection
        case lifecycle
    }

    public enum Direction: String, Sendable {
        /// Container → Extension.
        case send
        /// Extension → Container.
        case recv
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        endTimestamp: Date? = nil,
        category: Category,
        direction: Direction? = nil,
        method: String? = nil,
        rpcID: Int? = nil,
        summary: String,
        count: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.category = category
        self.direction = direction
        self.method = method
        self.rpcID = rpcID
        self.summary = summary
        self.count = count
    }
}

/// Activity descriptor emitted by `RPCServer` to the Container.
///
/// `RPCServer` runs on background queues; it hands each observed event to the
/// Container via the `onActivity` callback, which the Container then routes to
/// the main actor to append (and heart-beat-fold) into `debugLog`.
public struct RPCActivity: Sendable {
    public let kind: DebugLogEntry.Category
    public let direction: DebugLogEntry.Direction?
    public let method: String?
    public let rpcID: Int?
    public let summary: String
    /// When true, the Container collapses adjacent heartbeat activities into a
    /// single DebugLogEntry (avoids 1s-interval ping/pong flooding the log).
    public let isHeartbeat: Bool

    public init(
        kind: DebugLogEntry.Category,
        direction: DebugLogEntry.Direction? = nil,
        method: String? = nil,
        rpcID: Int? = nil,
        summary: String,
        isHeartbeat: Bool = false
    ) {
        self.kind = kind
        self.direction = direction
        self.method = method
        self.rpcID = rpcID
        self.summary = summary
        self.isHeartbeat = isHeartbeat
    }
}
