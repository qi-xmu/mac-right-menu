import AppKit
import Foundation

public struct AppMenuItem: MenuItem, @unchecked Sendable {
    public var id: String
    public var title: String
    public var iconName: String?
    public var isEnabled: Bool

    public var appURL: URL
    public var displayName: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(appURL: URL, isEnabled: Bool = true, arguments: [String] = [], environment: [String: String] = [:]) {
        self.id = appURL.path
        self.appURL = appURL
        self.displayName = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
        self.title = self.displayName
        self.iconName = nil
        self.isEnabled = isEnabled
        self.arguments = arguments
        self.environment = environment
    }

    public var icon: NSImage {
        NSWorkspace.shared.icon(forFile: appURL.path)
    }

    public static func == (lhs: AppMenuItem, rhs: AppMenuItem) -> Bool {
        lhs.id == rhs.id
    }
}
