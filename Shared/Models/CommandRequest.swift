import Foundation

public struct CommandRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case copyPath
        case copyFileName
        case newFile
        case toggleHidden
        case openParent
        case openWithApp
        case shell
    }

    public let action: Action
    public let files: [String]
    public var command: String?
    public var extra: [String: String]?
}
