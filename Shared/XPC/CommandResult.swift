import Foundation

public struct CommandResult: Codable, Sendable {
    public let success: Bool
    public let errorDescription: String?

    public init(success: Bool, errorDescription: String? = nil) {
        self.success = success
        self.errorDescription = errorDescription
    }
}
