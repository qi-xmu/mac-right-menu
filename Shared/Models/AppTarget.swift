import Foundation

/// The target application for an `.openWith` action (the app payload; replaces
/// the former `AppMenuItem`). Pure data: exactly what's needed to open files
/// with this app. The display icon is derived from `appURL` via NSWorkspace and
/// carried by the menu item's `icon: .appIcon(path:)`; the enable state lives
/// on the `MenuItem`, not here.
public struct AppTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String { appURL.path }
    public var appURL: URL
    public var displayName: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(
        appURL: URL,
        displayName: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.appURL = appURL
        self.displayName = displayName
            ?? FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
        self.arguments = arguments
        self.environment = environment
    }

    // Identity by path: two targets pointing at the same app are equal. This
    // mirrors the former AppMenuItem and is what dedup in the apps list relies
    // on (an app is added at most once per path).
    public static func == (lhs: AppTarget, rhs: AppTarget) -> Bool {
        lhs.id == rhs.id
    }
}
