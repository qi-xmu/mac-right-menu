import Foundation

/// A command dispatched from the Finder Extension to the Container over RPC.
/// Mirrored on the wire by `RPCParams`.
public struct CommandRequest: Codable, Sendable {
    public enum Action: Int, Codable, Sendable {
        case newFile = 0
        case openWithApp = 1
        case copyPath = 2
        case copyFileName = 3
        case toggleHidden = 4
        case shell = 6
    }

    public let action: Action
    public let files: [String]
    public let command: String?
    public let extra: [String: String]?

    public init(action: Action, files: [String], command: String? = nil, extra: [String: String]? = nil) {
        self.action = action
        self.files = files
        self.command = command
        self.extra = extra
    }
}
