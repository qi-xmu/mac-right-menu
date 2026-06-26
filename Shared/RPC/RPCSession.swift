import AppKit
import Foundation
import Network
import os
import os.log

private let logger = Logger(subsystem: Constants.currentBundleID, category: "rpc-session")

/// JSON-RPC 2.0 over TCP (loopback).
///
/// Replaces the XPC transport. The Container App runs an `RPCServer` listening
/// on `Constants.rpcHost:Constants.rpcPort`; the FinderSync Extension uses
/// `RPCClient` to invoke `executeAction` on the Container and to receive
/// `configDidChange` pushes of the menu tree.
///
/// Messages are line-delimited JSON (one JSON-RPC object per `\n`).

// MARK: - JSON-RPC wire types

struct RPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: RPCActionParams?
    /// Out-of-band metadata for `ping` heartbeats (pid / version). Optional
    /// and ignored for other methods; defaults to nil so existing call sites
    /// and decoding of older peers stay backward compatible.
    let meta: [String: String]?

    init(id: Int, method: String, params: RPCActionParams) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.meta = nil
    }

    /// Request without params (e.g. `getConfig`).
    init(id: Int, method: String) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = nil
        self.meta = nil
    }

    /// Request carrying heartbeat metadata (e.g. `ping`).
    init(id: Int, method: String, meta: [String: String]) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = nil
        self.meta = meta
    }
}

struct RPCResponse: Codable {
    let jsonrpc: String
    let id: Int
    let result: RPCResult?
    let error: RPCError?

    struct RPCError: Codable {
        let code: Int
        let message: String
    }
}

/// Parameters for `executeAction` — mirrors `MenuAction` (an `actionID` plus
/// the Finder selection context). `actionID` resolves to an `ActionDef` in the
/// Container's `ActionDefMap`.
struct RPCActionParams: Codable {
    let actionID: Int
    let targetURL: String?
    let selectedURLs: [String]

    init(_ action: MenuAction) {
        self.actionID = action.actionID
        self.targetURL = action.targetURL?.path
        self.selectedURLs = action.selectedURLs.map(\.path)
    }

    func toMenuAction() -> MenuAction {
        MenuAction(
            actionID: actionID,
            targetURL: targetURL.map { URL(fileURLWithPath: $0) },
            selectedURLs: selectedURLs.map { URL(fileURLWithPath: $0) }
        )
    }
}

/// Result of `executeAction` / `getConfig` sent as the JSON-RPC response
/// payload. For action results `config` is nil; for `getConfig` it carries the
/// menu tree.
public struct RPCResult: Codable {
    public let success: Bool
    public let errorDescription: String?
    public let config: MenuConfig?

    public init(success: Bool, errorDescription: String? = nil) {
        self.success = success
        self.errorDescription = errorDescription
        self.config = nil
    }

    public init(config: MenuConfig) {
        self.success = true
        self.errorDescription = nil
        self.config = config
    }
}

/// JSON-RPC notification (no `id`, no response expected).
///
/// Used for server → client pushes such as `configDidChange`, which carries the
/// full `MenuConfig` (menu tree) so the Extension can update its in-memory
/// cache without relying on shared storage (each process keeps its own
/// `UserDefaults.standard`).
struct RPCNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: MenuConfig

    init(method: String, params: MenuConfig) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// JSON-RPC notification (no `id`, no params, no response expected).
/// Used for shutdown signals and pong replies.
struct RPCShutdownNotification: Codable {
    let jsonrpc: String
    let method: String

    init() {
        self.jsonrpc = "2.0"
        self.method = "shutdown"
    }

    init(method: String) {
        self.jsonrpc = "2.0"
        self.method = method
    }
}

// MARK: - Line-delimited JSON framing over NWConnection

private func readLines(from connection: NWConnection,
                        handler: @escaping @Sendable (Data) -> Void,
                        onComplete: @escaping @Sendable () -> Void) {
    LineReader(connection: connection, onHandler: handler, onComplete: onComplete).start()
}

private final class LineReader: @unchecked Sendable {
    private let connection: NWConnection
    private let buffer = OSAllocatedUnfairLock(initialState: Data())
    private let onHandler: @Sendable (Data) -> Void
    private let onComplete: @Sendable () -> Void

    init(connection: NWConnection,
         onHandler: @escaping @Sendable (Data) -> Void,
         onComplete: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onHandler = onHandler
        self.onComplete = onComplete
    }

    func start() { receiveNext() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            buffer.withLock { buf in
                if let data, !data.isEmpty {
                    buf.append(data)
                    while let nl = buf.firstIndex(of: 0x0A) {
                        let line = buf[buf.startIndex..<nl]
                        if !line.isEmpty { onHandler(Data(line)) }
                        buf = Data(buf[buf.index(after: nl)...])
                    }
                }
                if let err = error {
                    logger.error("RPCSession: receive error: \(err.localizedDescription, privacy: .public)")
                    onComplete()
                    return
                }
                if isComplete {
                    if !buf.isEmpty { onHandler(buf) }
                    onComplete()
                }
            }
            if error != nil || isComplete { return }
            receiveNext()
        }
    }
}

private func sendJSON<T: Encodable>(_ value: T, on connection: NWConnection) {
    guard let payload = payloadJSON(value) else {
        logger.error("RPCSession: encode error")
        return
    }
    logger.debug("[\(Constants.currentProcessRole, privacy: .public)][RPC SEND] \(payload, privacy: .public)")
    var data = payload.data(using: .utf8) ?? Data()
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { error in
        if let error {
            logger.error("RPCSession: send error: \(error.localizedDescription, privacy: .public)")
        }
    })
}

/// Serialise a value to compact JSON (no newline), matching the wire format
/// used for RPC messages. Returns nil on encode failure so callers can skip
/// the raw-payload field rather than storing an error string.
private func payloadJSON<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - Server (Container side)

public final class RPCServer: @unchecked Sendable {
    private var listener: NWListener?
    private let onAction: @Sendable (MenuAction) async -> (RPCResult)
    private let getConfig: @MainActor @Sendable () -> MenuConfig
    private let onHeartbeat: @MainActor @Sendable ([String: String]?) -> Void
    private let onDisconnected: @MainActor @Sendable () -> Void
    /// Reports every RPC/wake/connection event the Container observes, for the
    /// Debug Log window. Defaults to a no-op so existing call sites keep working.
    private let onActivity: @Sendable (RPCActivity) -> Void
    private let lock = NSLock()
    private var activeConnections: [NWConnection] = []
    // Track last pong time per connection for Con→Ext heartbeat.
    private var lastPong: [ObjectIdentifier: Date] = [:]
    private var pingTimer: DispatchSourceTimer?

    public init(
        onAction: @escaping @Sendable (MenuAction) async -> (RPCResult),
        getConfig: @escaping @MainActor @Sendable () -> MenuConfig,
        onHeartbeat: @escaping @MainActor @Sendable ([String: String]?) -> Void,
        onDisconnected: @escaping @MainActor @Sendable () -> Void = {},
        onActivity: @escaping @Sendable (RPCActivity) -> Void = { _ in }
    ) {
        self.onAction = onAction
        self.getConfig = getConfig
        self.onHeartbeat = onHeartbeat
        self.onDisconnected = onDisconnected
        self.onActivity = onActivity
    }

    public func start() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: Constants.rpcPort))
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            startPingTimer()
            logger.notice("[Con] RPCServer: listening on \(Constants.rpcHost, privacy: .public):\(Constants.rpcPort)")
            onActivity(RPCActivity(kind: .lifecycle, method: "RPCServer", summary: "RPCServer listening on \(Constants.rpcHost):\(Constants.rpcPort)"))
        } catch {
            logger.error("RPCServer: failed to start listener: \(error.localizedDescription, privacy: .public)")
            onActivity(RPCActivity(kind: .lifecycle, method: "RPCServer", summary: "RPCServer start failed: \(error.localizedDescription)"))
        }
    }

    public func stop() {
        stopPingTimer()
        listener?.cancel()
        listener = nil
        lock.lock()
        let snapshot = activeConnections
        activeConnections.removeAll()
        lastPong.removeAll()
        lock.unlock()
        snapshot.forEach { $0.cancel() }
        onActivity(RPCActivity(kind: .lifecycle, method: "RPCServer", summary: "RPCServer stopped"))
    }

    // MARK: - Con→Ext Heartbeat

    /// Con sends periodic pings to Ext. If no pong arrives within
    /// `heartbeatInterval * heartbeatMaxMisses`, Ext is presumed dead.
    private func startPingTimer() {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Constants.heartbeatInterval,
                       repeating: Constants.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.checkConnections() }
        timer.resume()
        lock.lock()
        pingTimer = timer
        lock.unlock()
    }

    private func stopPingTimer() {
        lock.lock()
        let timer = pingTimer
        pingTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    func pausePingTimer() {
        stopPingTimer()
    }

    func resumePingTimer() {
        lock.lock()
        guard !activeConnections.isEmpty, pingTimer == nil else { lock.unlock(); return }
        lock.unlock()
        startPingTimer()
    }

    private func checkConnections() {
        lock.lock()
        let now = Date()
        var dead: [NWConnection] = []
        for conn in activeConnections {
            let id = ObjectIdentifier(conn)
            let last = lastPong[id] ?? .distantPast
            let elapsed = now.timeIntervalSince(last)
            if elapsed > Constants.heartbeatInterval * Double(Constants.heartbeatMaxMisses) {
                dead.append(conn)
            } else {
                // Send ping to keep the connection alive
                let ping = RPCRequest(id: 0, method: "ping")
                sendJSON(ping, on: conn)
                onActivity(RPCActivity(kind: .rpc, direction: .send, method: "ping", summary: "ping", isHeartbeat: true))
            }
        }
        lock.unlock()

        if !dead.isEmpty {
            logger.warning("[Con] RPCServer: \(dead.count) connection(s) timed out — marking disconnected")
            // remove() fires onDisconnected per connection; no separate call here.
            for conn in dead {
                remove(conn, reason: "heartbeat timeout")
            }
        }
    }

    /// Called when Ext responds to a ping (pong received).
    private func recordPong(_ connection: NWConnection) {
        lock.lock()
        lastPong[ObjectIdentifier(connection)] = Date()
        lock.unlock()
    }

    /// Push a `configDidChange` notification carrying the menu tree to every
    /// connected Extension. Because each process keeps its own
    /// `UserDefaults.standard`, the config payload must travel in-band so the
    /// Extension can refresh its in-memory cache without shared storage.
    public func broadcastConfig(_ config: MenuConfig) {
        let note = RPCNotification(method: "configDidChange", params: config)
        lock.lock()
        let snapshot = activeConnections
        lock.unlock()
        guard !snapshot.isEmpty else {
            // No Extension is connected right now. The push is dropped; the
            // Extension will fall back to its init-time snapshot. Logged so the
            // absence of a send is diagnosable rather than silent.
            logger.notice("[Con] RPCServer: configDidChange skipped — no connected Extension")
            return
        }
        logger.notice("[Con] RPCServer: broadcast configDidChange to \(snapshot.count) connection(s)")
        let rawPayload = payloadJSON(note)
        snapshot.forEach { sendJSON(note, on: $0) }
        onActivity(RPCActivity(
            kind: .rpc, direction: .send, method: "configDidChange",
            summary: "configDidChange → \(snapshot.count) conn(s)",
            detail: "topMenus=\(note.params.menus.count) enabled=\(note.params.isEnabled) showIcons=\(note.params.showAppIcons)",
            rawPayload: rawPayload
        ))
    }

    /// Push a `shutdown` notification to every connected Extension so they can
    /// exit cleanly. Called by the Container before terminating.
    public func broadcastShutdown() {
        let note = RPCShutdownNotification()
        lock.lock()
        let snapshot = activeConnections
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        logger.notice("[Con] RPCServer: broadcast shutdown to \(snapshot.count) connection(s)")
        let rawPayload = payloadJSON(note)
        snapshot.forEach { sendJSON(note, on: $0) }
        onActivity(RPCActivity(kind: .rpc, direction: .send, method: "shutdown", summary: "shutdown → \(snapshot.count) conn(s)", rawPayload: rawPayload))
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        activeConnections.append(connection)
        lastPong[ObjectIdentifier(connection)] = Date()
        lock.unlock()
        connection.start(queue: .global(qos: .utility))
        logger.notice("[Con] RPCServer: connection from pid (connection started)")
        onActivity(RPCActivity(kind: .connection, method: "connected", summary: "Ext connected"))

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.remove(connection, reason: "connection failed")
            }
        }

        readLines(from: connection, handler: { [weak self] lineData in
            self?.handleRequest(lineData, connection: connection)
        }, onComplete: { [weak self] in
            self?.remove(connection, reason: "read stream ended")
        })
    }

    /// Tear down a connection. Every loss-of-connection path (`.failed`
    /// state, read-stream end, heartbeat timeout) routes through here so the
    /// Extension wake-up fires uniformly. Idempotent: a connection already
    /// removed — e.g. when `cancel()` re-enters via a state update — won't
    /// fire `onDisconnected` twice.
    private func remove(_ connection: NWConnection, reason: String) {
        lock.lock()
        let wasActive = activeConnections.contains { $0 === connection }
        activeConnections.removeAll { $0 === connection }
        lastPong.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
        guard wasActive else { return }
        logger.notice("[Con] RPCServer: Extension connection lost (\(reason, privacy: .public))")
        onActivity(RPCActivity(kind: .connection, method: "disconnected", summary: "Ext disconnected (\(reason))"))
        Task { @MainActor in onDisconnected() }
    }

    private func handleRequest(_ lineData: Data, connection: NWConnection) {
        let payload = String(data: lineData, encoding: .utf8) ?? "<binary>"
        logger.debug("[\(Constants.currentProcessRole, privacy: .public)][RPC RECV] \(payload, privacy: .public)")
        let req: RPCRequest
        do {
            req = try JSONDecoder().decode(RPCRequest.self, from: lineData)
        } catch {
            // Not a request — try as a notification (e.g. "pong" from Ext).
            if let note = try? JSONDecoder().decode(RPCShutdownNotification.self, from: lineData) {
                if note.method == "pong" {
                    recordPong(connection)
                    logger.debug("[Con] RPCServer: pong received from Ext")
                    onActivity(RPCActivity(kind: .rpc, direction: .recv, method: "pong", summary: "pong", isHeartbeat: true))
                }
            }
            return
        }
        logger.notice("[Con] RPCServer: dispatch \(req.method, privacy: .public) id=\(req.id)")
        let (summary, detail) = recvSummary(for: req)
        onActivity(RPCActivity(kind: .rpc, direction: .recv, method: req.method, rpcID: req.id, summary: summary, detail: detail, rawPayload: payload))
        switch req.method {
        case "hello":
            // One-shot identity handshake from the Extension (sent right after
            // connect). Carries pid/version so the Container can update the
            // connection status UI and cancel any pending delayed Ext wake.
            // Replaces the old Ext→Con ping heartbeat: heartbeat direction is
            // now Con→Ext only.
            //
            // PID verification: confirm the reported PID actually belongs to a
            // running process with our Extension's bundle ID. This prevents a
            // malicious local process from connecting and sending forged commands.
            let meta = req.meta ?? [:]
            if let pidStr = meta["pid"], let pid = Int32(pidStr) {
                let extApps = NSRunningApplication.runningApplications(
                    withBundleIdentifier: Constants.extensionBundleID
                )
                let isKnownExtension = extApps.contains {
                    $0.processIdentifier == pid && !$0.isTerminated
                }
                guard isKnownExtension else {
                    logger.warning("[Con] RPCServer: rejected hello — PID \(pid) is not a registered Extension (bundleID=\(Constants.extensionBundleID))")
                    onActivity(RPCActivity(kind: .rpc, direction: .recv, method: "hello", rpcID: req.id,
                                           summary: "hello rejected — PID \(pid) not a registered Extension",
                                           rawPayload: payload))
                    connection.cancel()
                    return
                }
            }
            Task { @MainActor in onHeartbeat(meta) }
            recordPong(connection)
            let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                   result: RPCResult(success: true), error: nil)
            let respPayload = payloadJSON(resp)
            sendJSON(resp, on: connection)
            onActivity(RPCActivity(kind: .rpc, direction: .send, method: "response", rpcID: req.id, summary: "hello ack", detail: "  pid=\(meta["pid"] ?? "?") version=\(meta["version"] ?? "?")", rawPayload: respPayload))
        case "getConfig":
            // Hand the current menu tree back to the Extension. Runs on the
            // main actor since AppState's config lives there.
            Task {
                let config = await getConfig()
                let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                       result: RPCResult(config: config), error: nil)
                let respPayload = payloadJSON(resp)
                sendJSON(resp, on: connection)
                onActivity(RPCActivity(
                    kind: .rpc, direction: .send, method: "response", rpcID: req.id,
                    summary: "getConfig response",
                    detail: "topMenus=\(config.menus.count) enabled=\(config.isEnabled) showIcons=\(config.showAppIcons)",
                    rawPayload: respPayload
                ))
            }
        case "executeAction":
            guard let params = req.params else {
                logger.error("RPCServer: executeAction missing params id=\(req.id)")
                return
            }
            let action = params.toMenuAction()
            // Execute on a background task; the response is sent once execution
            // completes. JSON-RPC framing supports this deferred response.
            Task {
                let result = await onAction(action)
                let resp = RPCResponse(jsonrpc: "2.0", id: req.id, result: result, error: nil)
                let respPayload = payloadJSON(resp)
                sendJSON(resp, on: connection)
                let ok = result.success ? "ok" : "fail"
                onActivity(RPCActivity(
                    kind: .rpc, direction: .send, method: "response", rpcID: req.id,
                    summary: "executeAction response (\(ok))",
                    detail: result.errorDescription.map { "error: \($0)" },
                    rawPayload: respPayload
                ))
            }
        default:
            logger.warning("[Con] RPCServer: unknown method '\(req.method, privacy: .public)' id=\(req.id)")
            let resp = RPCResponse(jsonrpc: "2.0", id: req.id, result: nil,
                                   error: RPCResponse.RPCError(code: -32601, message: "Method not found: \(req.method)"))
            sendJSON(resp, on: connection)
        }
    }

    /// One-line summary + multi-line detail of a received request, for the
    /// Debug Log. The summary stays compact for the list row; the detail
    /// carries the full payload (file paths, command string) so it's visible
    /// on expand / hover / export without flooding the compact view.
    private func recvSummary(for req: RPCRequest) -> (summary: String, detail: String?) {
        switch req.method {
        case "executeAction":
            guard let p = req.params else { return ("executeAction (no params)", nil) }
            // Map the actionID to a readable name via its range so the log row
            // says "action=openWith" instead of "id=1000".
            let actionName = Self.actionName(for: p.actionID)
            let summary = "action=\(actionName) id=\(p.actionID) files=\(p.selectedURLs.count)"
            // Detail: list every selected path (not just the count) + the
            // target URL. These are the values that matter when debugging "why
            // did this action fail / open the wrong app".
            var lines = p.selectedURLs.enumerated().map { idx, path in
                "  [\(idx)] \(path)"
            }
            if let target = p.targetURL {
                lines.append("  target: \(target)")
            }
            return (summary, lines.joined(separator: "\n"))
        case "hello":
            // hello carries the Extension's pid/version (sent once on connect).
            if let meta = req.meta, !meta.isEmpty {
                let kv = meta.map { "\($0)=\($1)" }.joined(separator: ", ")
                return ("hello", "  meta: \(kv)")
            }
            return ("hello", nil)
        case "getConfig":
            return ("getConfig", nil)
        default:
            return (req.method, nil)
        }
    }

    /// Human-readable name for an `actionID`, based on its range
    /// (see `Constants.TagBase`). Used for Debug Log rows.
    private static func actionName(for actionID: Int) -> String {
        let nf = Constants.TagBase.newFile.rawValue
        let app = Constants.TagBase.appItem.rawValue
        let op = Constants.TagBase.copyPath.rawValue
        let shell = Constants.TagBase.shell.rawValue
        switch actionID {
        case Constants.TagBase.copyPath.rawValue:     return "copyPath"
        case Constants.TagBase.copyFileName.rawValue: return "copyFileName"
        case Constants.TagBase.toggleHidden.rawValue: return "toggleHidden"
        case nf..<app:        return "newFile"     // 0 + templateIndex
        case app..<op:        return "openWith"    // 1000 + appIndex
        case shell..<(shell + 1000): return "shell" // 4000 + shellIndex
        default:              return "unknown(\(actionID))"
        }
    }
}

// MARK: - Client (Extension side)

public final class RPCClient: @unchecked Sendable {
    private var connection: NWConnection?
    private let lock = NSLock()
    private var nextID: Int = 1
    private var pending: [Int: (RPCResult?) -> Void] = [:]
    private var retryWork: DispatchWorkItem?
    private var onConfigChange: (@Sendable (MenuConfig) -> Void)?
    private var onShutdown: (@Sendable () -> Void)?

    // Heartbeat direction is Con→Ext only: the Container pings every
    // `heartbeatInterval` and the Extension replies `pong`. The Extension no
    // longer runs its own ping timer — a dead Container is detected by TCP
    // stream termination in `receiveLoop` (onComplete → resetAndRetry), which
    // is reliable without an application-layer poll. On connect the Extension
    // sends a one-shot `hello` carrying pid/version so the Container can update
    // the connection status UI; that replaces the meta that used to ride on the
    // Ext→Con ping.

    // Container auto-launch: when the connection fails we ask LaunchServices to
    // open the Container app. Throttled so repeated retries (every 2s) don't
    // re-issue the launch request; the flag is cleared on a successful connect.
    private var containerLaunchRequested = false
    private static let containerLaunchCooldown: TimeInterval = 10

    /// Pending delayed Ext→Con wake. On connection failure we don't immediately
    /// call LaunchServices; we schedule it `containerWakeDelay` seconds out. If
    /// a `shutdown` notification arrives or the Container reconnects within that
    /// window, the wake is cancelled — preventing the Container from being
    /// relaunched when the user intentionally quit it.
    private var pendingContainerWake: DispatchWorkItem?
    private static let containerWakeDelay: TimeInterval = 1

    // Retry limit: after `maxFailedRetries` consecutive failures the Extension
    // gives up and exits. Counter resets on successful connect.
    // BUT giving up also requires `maxFailedRetryWindow` seconds to have
    // elapsed since the first failure (see `giveUpGuard`): a slow Container
    // launch shouldn't be misclassified as fatal just because each
    // connection-refused during startup bumps the counter.
    private var failedRetries: Int = 0
    static let maxFailedRetries = 5
    /// Wall-clock grace window during which retry-cap exhaustion does NOT cause
    /// a give-up. Tuned to comfortably exceed a cold Container launch + RPC
    //  port bind (typically 2–4s on modern macOS; 30s allows for heavy load).
    static let maxFailedRetryWindow: TimeInterval = 30
    /// Timestamp of the first failure in the current streak; nil once a
    /// successful connect resets the streak.
    private var firstFailureTime: Date?

    // Retry cadence. `postLaunchRetryInterval` is used right after we've asked
    // LaunchServices to bring the Container up — long enough for Con to start
    // and bind its port. `retryInterval` is used otherwise (e.g. transient
    // drops when Con is presumably already running).
    static let postLaunchRetryInterval: TimeInterval = 3
    static let retryInterval: TimeInterval = 3

    public init() {}

    /// Register a handler invoked when the Container pushes `configDidChange`,
    /// and also right after the initial `getConfig` pull on connect. Called on
    /// an arbitrary background queue.
    public func setConfigChangeHandler(_ handler: @escaping @Sendable (MenuConfig) -> Void) {
        lock.lock()
        onConfigChange = handler
        lock.unlock()
    }

    /// Register a handler invoked when the Container sends a `shutdown`
    /// notification before terminating. Called on an arbitrary background queue.
    public func setShutdownHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onShutdown = handler
        lock.unlock()
    }

    public func connect() {
        lock.lock()
        guard connection == nil else { lock.unlock(); return }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Constants.rpcHost),
            port: NWEndpoint.Port(integerLiteral: Constants.rpcPort)
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.notice("[Ext] RPCClient: connected to \(Constants.rpcHost, privacy: .public):\(Constants.rpcPort)")
                guard let self else { return }
                // Connected: clear the launch-throttle flag and reset the
                // failed-retry counter so a future drop starts fresh.
                self.lock.lock()
                self.containerLaunchRequested = false
                self.failedRetries = 0
                self.firstFailureTime = nil
                let wake = self.pendingContainerWake
                self.pendingContainerWake = nil
                self.lock.unlock()
                wake?.cancel()
                self.receiveLoop()
                // Pull the current config from the Container immediately so the
                // Extension's cache reflects the latest state on connect (each
                // process keeps its own UserDefaults, so the init-time read is
                // unreliable).
                self.fetchConfig()
                // One-shot identity handshake: tell the Container our pid/version
                // so it can update the connection status UI and cancel any pending
                // delayed Ext wake. This replaces the old Ext→Con ping heartbeat:
                // the heartbeat direction is now Con→Ext only (Con pings, Ext
                // pongs), so Ext no longer needs a repeating timer — a dead Con
                // is detected by TCP stream termination in receiveLoop instead.
                self.sendHello()
            case .waiting(let err):
                // NWConnection parks in .waiting for connection-refused instead
                // of transitioning to .failed. We just cancel here and let the
                // `.cancelled` case below handle exactly ONE resetAndRetry —
                // doing resetAndRetry here AND again in .cancelled doubled the
                // failure count per attempt and short-circuited the Container
                // launch (the 2nd pass saw containerLaunchRequested=true and
                // skipped it, so Con was never actually woken).
                logger.warning("[Ext] RPCClient: connection waiting — \(err.localizedDescription, privacy: .public)")
                conn.cancel()
            case .failed:
                logger.warning("RPCClient: connection failed")
                self?.resetAndRetry()
            case .cancelled:
                // Triggered by our `conn.cancel()` in the .waiting branch above
                // (or by teardown). Treat it as the single failure event and run
                // resetAndRetry once here — not also in .waiting.
                logger.warning("RPCClient: connection cancelled")
                self?.resetAndRetry()
            default:
                break
            }
        }
        // Assign inside the lock (together with the guard above) so that a
        // concurrent resetAndRetry from an old connection's state handler can't
        // slip in between the check and the assignment.
        connection = conn
        lock.unlock()
        conn.start(queue: .global(qos: .userInitiated))
    }

    /// Invoke `executeAction` on the Container, forwarding the clicked menu
    /// item's `actionID` plus the current Finder selection context. Completion
    /// is called on an arbitrary queue; returns false if no connection is
    /// available.
    @discardableResult
    public func executeAction(_ action: MenuAction,
                              completion: @escaping (RPCResult?) -> Void) -> Bool {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            logger.warning("RPCClient: not connected — action dropped")
            completion(nil)
            return false
        }
        let id = nextID
        nextID += 1
        pending[id] = completion
        lock.unlock()

        let req = RPCRequest(id: id, method: "executeAction", params: RPCActionParams(action))
        logger.notice("[Ext][RPC CALL] id=\(id) actionID=\(action.actionID) selected=\(action.selectedURLs.map(\.path), privacy: .public)")
        sendJSON(req, on: conn)
        return true
    }

    /// Pull the current config from the Container (`getConfig`). On success
    /// the `onConfigChange` handler is invoked, so the Extension refreshes its
    /// cache via the same path used for `configDidChange` pushes.
    public func fetchConfig() {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            logger.warning("RPCClient: getConfig skipped — not connected")
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = { [weak self] result in
            guard let config = result?.config else {
                logger.error("RPCClient: getConfig returned no config")
                return
            }
            logger.notice("[Ext] RPCClient: getConfig received config")
            guard let self else { return }
            self.lock.lock()
            let handler = self.onConfigChange
            self.lock.unlock()
            handler?(config)
        }
        lock.unlock()

        let req = RPCRequest(id: id, method: "getConfig")
        logger.notice("[Ext][RPC CALL] id=\(id) method=getConfig")
        sendJSON(req, on: conn)
    }

    // MARK: - Identity handshake

    /// One-shot `hello` sent right after connect. Carries the Extension's
    /// pid/version so the Container can populate the connection status UI and
    /// cancel any pending delayed Ext wake. Fire-and-forget: we don't register
    /// a `pending[id]` callback because Con's reply (a plain RPCResponse with
    /// `success: true`) carries no information Ext needs — Con already pings Ext
    /// for liveness, and a dropped `hello` simply means Con keeps showing the
    /// Extension as "last seen" until its own ping elicits a pong.
    private func sendHello() {
        lock.lock()
        guard let conn = connection else { lock.unlock(); return }
        let id = nextID
        nextID += 1
        lock.unlock()
        let extDisplayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        let meta: [String: String] = [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "version": Constants.version,
            "build": Constants.build,
            "displayName": extDisplayName
        ]
        let req = RPCRequest(id: id, method: "hello", meta: meta)
        logger.debug("[Ext][RPC CALL] id=\(id) method=hello")
        sendJSON(req, on: conn)
    }

    public func disconnect() {
        lock.lock()
        let work = retryWork
        retryWork = nil
        let conn = connection
        connection = nil
        let snapshot = pending
        pending.removeAll()
        lock.unlock()
        work?.cancel()
        conn?.cancel()
        // Fail any pending calls.
        for (_, cb) in snapshot { cb(nil) }
    }

    private func resetAndRetry() {
        lock.lock()
        connection = nil
        let snapshot = pending
        pending.removeAll()
        failedRetries += 1
        let attempts = failedRetries
        lock.unlock()
        for (_, cb) in snapshot { cb(nil) }

        // Give up only after we've genuinely exhausted both retries AND given
        // the Container enough wall-clock time to come up. The old logic
        // (`attempts >= 3`, retrying every 2s) gave up after ~6s — too early,
        // because a freshly-launched Container can take several seconds to bind
        // its RPC port, and each connection-refused during that window bumped
        // the counter. See giveUpGuard below.
        if attempts >= Self.maxFailedRetries, giveUpGuard() {
            logger.error("[Ext] RPCClient: \(attempts) consecutive connection failures — giving up")
            onShutdown?()
            return
        }

        // Connection failed — most likely the Container isn't running (yet).
        // Ask LaunchServices to open it, THEN schedule a retry after enough of
        // a delay for Con to actually start and bind its port. The two used to
        // run on independent timers (wake@1s, retry@2s), which raced: the
        // retry fired before Con was listening and burned through `maxRetries`.
        launchContainerIfNeeded()
        // After a launch, retry on a generous interval so Con has time to come
        // up; retries that find Con already running use a short interval.
        scheduleRetry(postLaunch: true)
    }

    /// Decide whether the Extension should truly give up. We only give up if
    /// we've hit the retry cap AND enough wall-clock time has elapsed since the
    /// first failure that the Container has had a fair chance to start. This
    /// stops slow Con launches from being misclassified as fatal.
    private func giveUpGuard() -> Bool {
        lock.lock()
        let first = firstFailureTime
        lock.unlock()
        guard let first else { return true }
        return Date().timeIntervalSince(first) >= Self.maxFailedRetryWindow
    }

    /// Ask LaunchServices to open the Container app in the background. The
    /// Container is `LSUIElement`, so it comes up without a Dock icon or a
    /// stealing focus.
    ///
    /// Delayed by `containerWakeDelay` seconds: on connection failure we don't
    /// immediately open Con; we schedule a short grace period. If a `shutdown`
    /// notification arrives or the Container reconnects within that window,
    /// the wake is cancelled. This prevents the user's intentional Quit from
    /// being immediately undone by a stale disconnect detection.
    ///
    /// Throttled: only one launch request per cooldown window (repeated 2s
    /// retries must not spam the request), and the flag clears on a successful
    /// connect.
    private func launchContainerIfNeeded() {
        lock.lock()
        // Cancel any previously scheduled launch (e.g. from a prior failure
        // before the delay expired). The new schedule replaces it.
        pendingContainerWake?.cancel()
        pendingContainerWake = nil

        if containerLaunchRequested {
            lock.unlock()
            return
        }
        containerLaunchRequested = true
        let bundleID = Constants.mainAppBundleID
        lock.unlock()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Double-check: the Container might already be alive by now
            // (user manually restarted, system re-opened, or a late connect).
            if self.isContainerProcessAlive() {
                logger.notice("[Ext] RPCClient: Container already running — skipping delayed launch")
                self.lock.lock()
                self.pendingContainerWake = nil
                self.lock.unlock()
                self.scheduleCooldownReset()
                return
            }

            logger.notice("[Ext] RPCClient: Container not reachable — requesting launch (\(bundleID, privacy: .public))")

            // Tier 1: Resolve app URL via LaunchServices, then open in background.
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false   // background: don't steal focus (Con is LSUIElement anyway)
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] runningApp, error in
                    if let error {
                        logger.error("[Ext] RPCClient: Container launch failed: \(error.localizedDescription, privacy: .public)")
                        self?.scheduleCooldownReset()
                    } else if runningApp != nil {
                        logger.notice("[Ext] RPCClient: Container launch requested")
                    }
                }
                self.lock.lock()
                self.pendingContainerWake = nil
                self.lock.unlock()
                return
            }

            // Tier 2: App not in LaunchServices (e.g. never launched after install).
            // Try `open -b <bundleID>` as fallback — uses a different LaunchServices
            // code path that may succeed even when urlForApplication returns nil.
            logger.notice("[Ext] RPCClient: Container not in LaunchServices — trying open -b fallback")
            self.launchViaOpenB(bundleID: bundleID)
            self.lock.lock()
            self.pendingContainerWake = nil
            self.lock.unlock()
        }

        lock.lock()
        pendingContainerWake = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.containerWakeDelay, execute: work)
        logger.notice("[Ext] RPCClient: scheduling delayed Container launch (\(Self.containerWakeDelay)s)")
    }

    private func launchViaOpenB(bundleID: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", bundleID, "--background"]
        do {
            try task.run()
            task.waitUntilExit()
            let status = task.terminationStatus
            if status == 0 {
                logger.notice("[Ext] RPCClient: open -b launch succeeded (status=0)")
            } else {
                logger.error("[Ext] RPCClient: open -b failed (exit \(status)) — Container may not be installed")
                scheduleCooldownReset()
            }
        } catch {
            logger.error("[Ext] RPCClient: open -b exception: \(error.localizedDescription, privacy: .public)")
            scheduleCooldownReset()
        }
    }

    private func scheduleCooldownReset() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.containerLaunchCooldown) { [weak self] in
            self?.lock.lock(); self?.containerLaunchRequested = false; self?.lock.unlock()
        }
    }

    /// Check if the Container process is alive.
    private func isContainerProcessAlive() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Constants.mainAppBundleID
        ).filter { !$0.isTerminated }.isEmpty
    }

    /// Schedule the next `connect()` attempt.
    /// - Parameter postLaunch: when true, use the longer `postLaunchRetryInterval`
    ///   so a freshly-launched Container has time to start and bind its RPC port
    ///   before we poke it again. Previously the retry fired on a fixed 2s timer
    ///   independent of the launch, racing it and burning through `maxRetries`.
    private func scheduleRetry(postLaunch: Bool = false) {
        lock.lock()
        retryWork?.cancel()
        if firstFailureTime == nil { firstFailureTime = Date() }
        let interval = postLaunch ? Self.postLaunchRetryInterval : Self.retryInterval
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: work)
        if postLaunch {
            logger.notice("[Ext] RPCClient: retry scheduled in \(interval)s (waiting for Container to come up)")
        } else {
            logger.notice("[Ext] RPCClient: retry scheduled in \(interval)s")
        }
    }

    private func receiveLoop() {
        lock.lock()
        guard let conn = connection else { lock.unlock(); return }
        lock.unlock()
        readLines(from: conn, handler: { [weak self] lineData in
            self?.handleResponse(lineData)
        }, onComplete: { [weak self] in
            logger.notice("RPCClient: receive stream ended")
            self?.resetAndRetry()
        })
    }

    private func handleResponse(_ lineData: Data) {
        let payload = String(data: lineData, encoding: .utf8) ?? "<binary>"
        logger.debug("[\(Constants.currentProcessRole, privacy: .public)][RPC RECV] \(payload, privacy: .public)")

        // Try shutdown notification first (no params, just method "shutdown").
        // RPCShutdownNotification decodes ANY JSON with {jsonrpc, method}, so
        // we only `return` when we actually handled a "shutdown"; otherwise
        // fall through so configDidChange / pong can be matched by later blocks.
        if let shutdown = try? JSONDecoder().decode(RPCShutdownNotification.self, from: lineData) {
            if shutdown.method == "shutdown" {
                logger.notice("[Ext] RPCClient: received shutdown from Container")
                lock.lock()
                let handler = onShutdown
                let wake = pendingContainerWake
                pendingContainerWake = nil
                lock.unlock()
                wake?.cancel()  // User quit Con intentionally — don't re-launch.
                handler?()
                return
            }
            // pong or other short notification — fall through to try RPCNotification / RPCResponse
        }

        // Check if this is a ping request from Con (Con→Ext heartbeat).
        // A request has "method" and "id" fields; notifications have "method" but no "id".
        if let req = try? JSONDecoder().decode(RPCRequest.self, from: lineData) {
            if req.method == "ping" {
                logger.debug("[Ext] RPCClient: received ping from Con, replying pong")
                lock.lock()
                guard let conn = connection else { lock.unlock(); return }
                lock.unlock()
                let pong = RPCShutdownNotification(method: "pong")
                sendJSON(pong, on: conn)
            }
            return
        }

        // A server-pushed notification has `method` and no `id`; a response has
        // `id` and no `method`. Try the notification shape first.
        if let note = try? JSONDecoder().decode(RPCNotification.self, from: lineData) {
            if note.method == "configDidChange" {
                logger.notice("[Ext] RPCClient: received configDidChange")
                lock.lock()
                let handler = onConfigChange
                lock.unlock()
                handler?(note.params)
            }
            return
        }

        let resp: RPCResponse
        do {
            resp = try JSONDecoder().decode(RPCResponse.self, from: lineData)
        } catch {
            logger.error("RPCClient: bad response line: \(error.localizedDescription, privacy: .public)")
            return
        }
        lock.lock()
        let cb = pending.removeValue(forKey: resp.id)
        lock.unlock()
        if resp.error != nil {
            logger.error("RPCClient: server error id=\(resp.id)")
        }
        cb?(resp.result)
    }
}
