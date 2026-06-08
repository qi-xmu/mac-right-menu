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
    public var iconData: Data?

    private enum CodingKeys: String, CodingKey {
        case id, title, iconName, isEnabled, appURL, displayName, arguments, environment, iconData
    }

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
        // Cache icon data so Extension doesn't need to read app bundle
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        self.iconData = icon.tiffRepresentation
    }

    public var icon: NSImage {
        if let data = iconData, let img = NSImage(data: data) {
            return img
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

    public static func == (lhs: AppMenuItem, rhs: AppMenuItem) -> Bool {
        lhs.id == rhs.id
    }
}
