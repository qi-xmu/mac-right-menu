import AppKit
import Foundation
import Network
import os.log

private let logger = Logger(subsystem: Constants.currentBundleID, category: "rpc-session")

/// JSON-RPC 2.0 over TCP (loopback).
///
/// Replaces the XPC transport. The Container App runs an `RPCServer` listening
/// on `Constants.rpcHost:Constants.rpcPort`; the FinderSync Extension uses
/// `RPCClient` to invoke `executeCommand` on the Container.
///
/// Messages are line-delimited JSON (one JSON-RPC object per `\n`).

// MARK: - JSON-RPC wire types

struct RPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: RPCParams?
    /// Out-of-band metadata for `ping` heartbeats (pid / version). Optional
    /// and ignored for other methods; defaults to nil so existing call sites
    /// and decoding of older peers stay backward compatible.
    let meta: [String: String]?

    init(id: Int, method: String, params: RPCParams) {
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

/// Parameters for `executeCommand` — mirrors `CommandRequest` fields.
struct RPCParams: Codable {
    let action: Int
    let files: [String]
    let command: String?
    let extra: [String: String]?

    init(_ req: CommandRequest) {
        self.action = req.action.rawValue
        self.files = req.files
        self.command = req.command
        self.extra = req.extra
    }

    func toCommandRequest() -> CommandRequest {
        let action = CommandRequest.Action(rawValue: action) ?? .shell
        return CommandRequest(action: action, files: files, command: command, extra: extra)
    }
}

/// Result of `executeCommand` — mirrors `CommandResult`.
/// Also carries an optional `config` for `getConfig` responses.
public struct RPCResult: Codable {
    public let success: Bool
    public let errorDescription: String?
    public let config: MenuConfiguration?

    public init(_ res: CommandResult) {
        self.success = res.success
        self.errorDescription = res.errorDescription
        self.config = nil
    }

    public init(config: MenuConfiguration) {
        self.success = true
        self.errorDescription = nil
        self.config = config
    }
}

/// JSON-RPC notification (no `id`, no response expected).
///
/// Used for server → client pushes such as `configDidChange`, which carries the
/// full `MenuConfiguration` so the Extension can update its in-memory cache
/// without relying on shared storage (each process keeps its own
/// `UserDefaults.standard`).
struct RPCNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: MenuConfiguration

    init(method: String, params: MenuConfiguration) {
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

/// Reads complete newline-terminated JSON lines from an NWConnection.
/// Calls `handler` for each decoded line, then `onComplete` when the stream ends.
private func readLines(from connection: NWConnection,
                        handler: @escaping (Data) -> Void,
                        onComplete: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let data, !data.isEmpty {
            // Buffer handling: split on \n. Simple approach — assume messages fit in chunks.
            // For this app's payload sizes (small command descriptors) this is sufficient.
            var start = data.startIndex
            while let nl = data[start...].firstIndex(of: 0x0A) {
                let line = data[start..<nl]
                if !line.isEmpty { handler(Data(line)) }
                start = data.index(after: nl)
            }
            // Trailing partial line without newline (shouldn't happen for well-formed peers).
            if start < data.endIndex {
                handler(Data(data[start..<data.endIndex]))
            }
        }
        if let err = error {
            logger.error("RPCSession: receive error: \(err.localizedDescription, privacy: .public)")
            onComplete()
            return
        }
        if isComplete {
            onComplete()
            return
        }
        readLines(from: connection, handler: handler, onComplete: onComplete)
    }
}

private func sendJSON<T: Encodable>(_ value: T, on connection: NWConnection) {
    do {
        var data = try JSONEncoder().encode(value)
        let payload = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("[\(Constants.currentProcessRole, privacy: .public)][RPC SEND] \(payload, privacy: .public)")
        data.append(0x0A) // newline delimiter
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("RPCSession: send error: \(error.localizedDescription, privacy: .public)")
            }
        })
    } catch {
        logger.error("RPCSession: encode error: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Server (Container side)

public final class RPCServer: @unchecked Sendable {
    private var listener: NWListener?
    private let onCommand: @Sendable (CommandRequest) async -> (CommandResult)
    private let getConfig: @MainActor @Sendable () -> MenuConfiguration
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
        onCommand: @escaping @Sendable (CommandRequest) async -> (CommandResult),
        getConfig: @escaping @MainActor @Sendable () -> MenuConfiguration,
        onHeartbeat: @escaping @MainActor @Sendable ([String: String]?) -> Void,
        onDisconnected: @escaping @MainActor @Sendable () -> Void = {},
        onActivity: @escaping @Sendable (RPCActivity) -> Void = { _ in }
    ) {
        self.onCommand = onCommand
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

    /// Push a `configDidChange` notification carrying the full configuration
    /// to every connected Extension. Because each process keeps its own
    /// `UserDefaults.standard`, the config payload must travel in-band so the
    /// Extension can refresh its in-memory cache without shared storage.
    public func broadcastConfig(_ config: MenuConfiguration) {
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
        snapshot.forEach { sendJSON(note, on: $0) }
        onActivity(RPCActivity(kind: .rpc, direction: .send, method: "configDidChange", summary: "configDidChange → \(snapshot.count) conn(s)"))
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
        snapshot.forEach { sendJSON(note, on: $0) }
        onActivity(RPCActivity(kind: .rpc, direction: .send, method: "shutdown", summary: "shutdown → \(snapshot.count) conn(s)"))
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
        onActivity(RPCActivity(kind: .rpc, direction: .recv, method: req.method, rpcID: req.id, summary: recvSummary(for: req)))
        switch req.method {
        case "ping":
            // Heartbeat from the Extension. Reply with pong and surface the
            // Extension's metadata (pid/version) so AppState can update the
            // connection status shown in the UI.
            let meta = req.meta
            Task { @MainActor in onHeartbeat(meta) }
            recordPong(connection)
            let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                   result: RPCResult(CommandResult(success: true)), error: nil)
            sendJSON(resp, on: connection)
            onActivity(RPCActivity(kind: .rpc, direction: .send, method: "response", rpcID: req.id, summary: "ping response", isHeartbeat: true))
        case "getConfig":
            // Hand the full current config back to the Extension. Runs on the
            // main actor since AppState.configuration lives there.
            Task {
                let config = await getConfig()
                let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                       result: RPCResult(config: config), error: nil)
                sendJSON(resp, on: connection)
                onActivity(RPCActivity(kind: .rpc, direction: .send, method: "response", rpcID: req.id, summary: "getConfig response"))
            }
        default: // "executeCommand"
            guard let params = req.params else {
                logger.error("RPCServer: executeCommand missing params id=\(req.id)")
                return
            }
            let command = params.toCommandRequest()
            // Execute on a background task; the response is sent once execution
            // completes. JSON-RPC framing supports this deferred response.
            Task {
                let result = await onCommand(command)
                let resp = RPCResponse(jsonrpc: "2.0", id: req.id, result: RPCResult(result), error: nil)
                sendJSON(resp, on: connection)
                let ok = result.success ? "ok" : "fail"
                onActivity(RPCActivity(kind: .rpc, direction: .send, method: "response", rpcID: req.id, summary: "executeCommand response (\(ok))"))
            }
        }
    }

    /// One-line summary of a received request for the Debug Log.
    private func recvSummary(for req: RPCRequest) -> String {
        switch req.method {
        case "executeCommand":
            if let p = req.params {
                return "action=\(p.action) files=\(p.files.count)"
            }
            return "executeCommand (no params)"
        case "ping":
            return "ping"
        case "getConfig":
            return "getConfig"
        default:
            return req.method
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
    private var onConfigChange: (@Sendable (MenuConfiguration) -> Void)?
    private var onShutdown: (@Sendable () -> Void)?

    // Heartbeat: a repeating timer fires every `heartbeatInterval`; each tick
    // sends a ping and bumps `consecutiveMisses`. Receiving a pong clears the
    // counter. Once it reaches `heartbeatMaxMisses`, the Container is presumed
    // dead and we reconnect.
    private var heartbeatTimer: DispatchSourceTimer?
    private var consecutiveMisses: Int = 0
    // Fast heartbeat mode: on first connect we ping every 1s until the first
    // pong arrives, then switch to the normal interval.
    private var heartbeatConfirmed: Bool = false
    private static let fastHeartbeatInterval: TimeInterval = 1

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
    private var failedRetries: Int = 0
    static let maxFailedRetries = 3

    public init() {}

    /// Register a handler invoked when the Container pushes `configDidChange`,
    /// and also right after the initial `getConfig` pull on connect. Called on
    /// an arbitrary background queue.
    public func setConfigChangeHandler(_ handler: @escaping @Sendable (MenuConfiguration) -> Void) {
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
        let alreadyConnected = connection != nil
        lock.unlock()
        guard !alreadyConnected else { return }

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
                self.heartbeatConfirmed = false
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
                // Send an immediate heartbeat so Con knows we're alive right away,
                // then start fast heartbeat (1s) until first pong confirms the
                // connection, at which point we switch to normal interval (15s).
                self.sendHeartbeat()
                self.startHeartbeat()
            case .waiting(let err):
                // NWConnection stays in .waiting for connection-refused instead
                // of transitioning to .failed. Cancel and retry manually so the
                // auto-launch mechanism can kick in.
                logger.warning("[Ext] RPCClient: connection waiting — \(err.localizedDescription, privacy: .public)")
                self?.stopHeartbeat()
                self?.resetAndRetry()
                conn.cancel()
            case .failed, .cancelled:
                logger.warning("RPCClient: connection \(String(describing: state))")
                self?.stopHeartbeat()
                self?.resetAndRetry()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        lock.lock()
        connection = conn
        lock.unlock()
    }

    /// Invoke `executeCommand` on the Container. Completion is called on an
    /// arbitrary queue; returns false if no connection is available.
    @discardableResult
    public func executeCommand(_ command: CommandRequest,
                                completion: @escaping (RPCResult?) -> Void) -> Bool {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            logger.warning("RPCClient: not connected — command dropped")
            completion(nil)
            return false
        }
        let id = nextID
        nextID += 1
        pending[id] = completion
        lock.unlock()

        let req = RPCRequest(id: id, method: "executeCommand", params: RPCParams(command))
        logger.notice("[Ext][RPC CALL] id=\(id) action=\(command.action.rawValue) files=\(command.files, privacy: .public)")
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

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        consecutiveMisses = 0
        lock.lock()
        let confirmed = heartbeatConfirmed
        lock.unlock()
        let interval = confirmed ? Constants.heartbeatInterval : Self.fastHeartbeatInterval
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sendHeartbeat() }
        timer.resume()
        lock.lock()
        heartbeatTimer = timer
        lock.unlock()
        logger.notice("[Ext] RPCClient: heartbeat started (interval=\(interval)s, maxMisses=\(Constants.heartbeatMaxMisses))")
    }

    private func stopHeartbeat() {
        lock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func sendHeartbeat() {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            return
        }
        let misses = consecutiveMisses + 1
        consecutiveMisses = misses
        let id = nextID
        nextID += 1
        // Clearing the miss counter on pong is all the callback does; the
        // timeout decision is the "N consecutive unanswered pings" count above.
        pending[id] = { [weak self] result in
            guard result != nil else { return }
            guard let self else { return }
            self.lock.lock()
            self.consecutiveMisses = 0
            let wasUnconfirmed = !self.heartbeatConfirmed
            self.heartbeatConfirmed = true
            self.lock.unlock()
            if wasUnconfirmed {
                logger.notice("[Ext] RPCClient: first pong received — switching to normal heartbeat interval")
                self.startHeartbeat()
            }
        }
        lock.unlock()

        if misses >= Constants.heartbeatMaxMisses {
            // Container is presumed dead: tear down and reconnect. The current
            // ping is not sent since we're abandoning this connection.
            logger.error("[Ext] RPCClient: \(misses) heartbeats unanswered — Container presumed dead, reconnecting")
            resetAndRetry()
            return
        }

        let meta: [String: String] = [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]
        let req = RPCRequest(id: id, method: "ping", meta: meta)
        logger.debug("[Ext][RPC CALL] id=\(id) method=ping misses=\(misses)")
        sendJSON(req, on: conn)
    }

    public func disconnect() {
        stopHeartbeat()
        retryWork?.cancel()
        lock.lock()
        let conn = connection
        connection = nil
        let snapshot = pending
        pending.removeAll()
        lock.unlock()
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

        if attempts >= Self.maxFailedRetries {
            logger.error("[Ext] RPCClient: \(attempts) consecutive connection failures — giving up")
            onShutdown?()
            return
        }

        // Connection failed — most likely the Container isn't running. Ask
        // LaunchServices to open it so subsequent retries can succeed.
        launchContainerIfNeeded()
        scheduleRetry()
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

    /// Check if the Container process is alive by reading its PID from the lock
    /// file and sending signal 0 ( existence check only ).
    private func isContainerProcessAlive() -> Bool {
        guard let url = Constants.containerLockURL,
              let data = try? Data(contentsOf: url),
              let pidStr = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr)
        else { return false }
        // kill -0: check if process exists (no signal sent)
        return kill(pid, 0) == 0
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: work)
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
