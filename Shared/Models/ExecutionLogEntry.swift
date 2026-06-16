import Foundation

/// A single recorded command execution, surfaced in the Execution Log window.
///
/// In-memory only (not persisted); cleared on app relaunch. Capped by
/// `AppState.maxLogEntries` to bound memory growth.
public struct ExecutionLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: String          // "newFile" / "copyPath" / "shell" ...
    public let success: Bool
    public let errorDescription: String?
    public let files: [String]
    public let shellCommand: String?   // shell only: actual executed string ({ } substituted)
    public let extra: [String: String]?
    public let logOnly: Bool           // true when commandLogOnly short-circuited execution

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        action: String,
        success: Bool,
        errorDescription: String? = nil,
        files: [String],
        shellCommand: String? = nil,
        extra: [String: String]? = nil,
        logOnly: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.success = success
        self.errorDescription = errorDescription
        self.files = files
        self.shellCommand = shellCommand
        self.extra = extra
        self.logOnly = logOnly
    }
}
