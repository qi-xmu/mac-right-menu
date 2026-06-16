import Foundation

@objc(CommandResult)
public final class CommandResult: NSObject, NSSecureCoding, @unchecked Sendable {

    public let success: Bool
    public let errorDescription: String?

    public init(success: Bool, errorDescription: String? = nil) {
        self.success = success
        self.errorDescription = errorDescription
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(success, forKey: "success")
        coder.encode(errorDescription, forKey: "errorDescription")
    }

    public init?(coder: NSCoder) {
        self.success = coder.decodeBool(forKey: "success")
        self.errorDescription = coder.decodeObject(of: NSString.self, forKey: "errorDescription") as String?
    }
}
