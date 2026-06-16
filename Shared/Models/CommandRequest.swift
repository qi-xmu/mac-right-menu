import Foundation

@objc(CommandRequest)
public final class CommandRequest: NSObject, NSSecureCoding, @unchecked Sendable {

    public enum Action: Int {
        case newFile = 0
        case openWithApp = 1
        case copyPath = 2
        case copyFileName = 3
        case toggleHidden = 4
        case openParent = 5
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

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(action.rawValue, forKey: "action")
        coder.encode(files, forKey: "files")
        coder.encode(command, forKey: "command")
        coder.encode(extra, forKey: "extra")
    }

    public init?(coder: NSCoder) {
        guard let action = Action(rawValue: coder.decodeInteger(forKey: "action")) else { return nil }
        guard let files = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "files") as? [String] else { return nil }
        self.action = action
        self.files = files
        self.command = coder.decodeObject(of: NSString.self, forKey: "command") as String?
        self.extra = coder.decodeObject(of: [NSDictionary.self, NSString.self], forKey: "extra") as? [String: String]
    }
}
