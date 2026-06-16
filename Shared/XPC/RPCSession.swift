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
    private let lock = NSLock()
    private var activeConnections: [NWConnection] = []

    public init(
        onCommand: @escaping @Sendable (CommandRequest) async -> (CommandResult),
        getConfig: @escaping @MainActor @Sendable () -> MenuConfiguration,
        onHeartbeat: @escaping @MainActor @Sendable ([String: String]?) -> Void
    ) {
        self.onCommand = onCommand
        self.getConfig = getConfig
        self.onHeartbeat = onHeartbeat
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
            logger.notice("[Con] RPCServer: listening on \(Constants.rpcHost, privacy: .public):\(Constants.rpcPort)")
        } catch {
            logger.error("RPCServer: failed to start listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let snapshot = activeConnections
        activeConnections.removeAll()
        lock.unlock()
        snapshot.forEach { $0.cancel() }
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
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        activeConnections.append(connection)
        lock.unlock()
        connection.start(queue: .global(qos: .utility))
        logger.notice("[Con] RPCServer: connection from pid (connection started)")

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.remove(connection)
            }
        }

        readLines(from: connection, handler: { [weak self] lineData in
            self?.handleRequest(lineData, connection: connection)
        }, onComplete: { [weak self] in
            self?.remove(connection)
        })
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        activeConnections.removeAll { $0 === connection }
        lock.unlock()
        connection.cancel()
    }

    private func handleRequest(_ lineData: Data, connection: NWConnection) {
        let payload = String(data: lineData, encoding: .utf8) ?? "<binary>"
        logger.debug("[\(Constants.currentProcessRole, privacy: .public)][RPC RECV] \(payload, privacy: .public)")
        let req: RPCRequest
        do {
            req = try JSONDecoder().decode(RPCRequest.self, from: lineData)
        } catch {
            logger.error("[Con] RPCServer: bad request line: \(error.localizedDescription, privacy: .public)")
            return
        }
        logger.notice("[Con] RPCServer: dispatch \(req.method, privacy: .public) id=\(req.id)")
        switch req.method {
        case "ping":
            // Heartbeat from the Extension. Reply with pong and surface the
            // Extension's metadata (pid/version) so AppState can update the
            // connection status shown in the UI.
            let meta = req.meta
            Task { @MainActor in onHeartbeat(meta) }
            let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                   result: RPCResult(CommandResult(success: true)), error: nil)
            sendJSON(resp, on: connection)
        case "getConfig":
            // Hand the full current config back to the Extension. Runs on the
            // main actor since AppState.configuration lives there.
            Task {
                let config = await getConfig()
                let resp = RPCResponse(jsonrpc: "2.0", id: req.id,
                                       result: RPCResult(config: config), error: nil)
                sendJSON(resp, on: connection)
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
            }
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

    // Heartbeat: a repeating timer fires every `heartbeatInterval`; each tick
    // sends a ping and bumps `consecutiveMisses`. Receiving a pong clears the
    // counter. Once it reaches `heartbeatMaxMisses`, the Container is presumed
    // dead and we reconnect.
    private var heartbeatTimer: DispatchSourceTimer?
    private var consecutiveMisses: Int = 0

    public init() {}

    /// Register a handler invoked when the Container pushes `configDidChange`,
    /// and also right after the initial `getConfig` pull on connect. Called on
    /// an arbitrary background queue.
    public func setConfigChangeHandler(_ handler: @escaping @Sendable (MenuConfiguration) -> Void) {
        lock.lock()
        onConfigChange = handler
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
                self?.receiveLoop()
                // Pull the current config from the Container immediately so the
                // Extension's cache reflects the latest state on connect (each
                // process keeps its own UserDefaults, so the init-time read is
                // unreliable).
                self?.fetchConfig()
                // Begin heartbeating so a dead Container is detected within
                // ~heartbeatInterval * heartbeatMaxMisses.
                self?.startHeartbeat()
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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Constants.heartbeatInterval,
                       repeating: Constants.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.sendHeartbeat() }
        timer.resume()
        lock.lock()
        heartbeatTimer = timer
        lock.unlock()
        logger.notice("[Ext] RPCClient: heartbeat started (interval=\(Constants.heartbeatInterval)s, maxMisses=\(Constants.heartbeatMaxMisses))")
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
            self?.lock.lock()
            self?.consecutiveMisses = 0
            self?.lock.unlock()
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
        lock.unlock()
        for (_, cb) in snapshot { cb(nil) }
        scheduleRetry()
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
