import Foundation

/// Result of a command execution, mirrored over RPC by `RPCResult`.
public struct CommandResult: Codable, Sendable {
    public let success: Bool
    public let errorDescription: String?

    public init(success: Bool, errorDescription: String? = nil) {
        self.success = success
        self.errorDescription = errorDescription
    }
}
