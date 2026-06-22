import Foundation

/// The full menu configuration that is persisted to App Group UserDefaults
/// and shared between Container App and Finder Extension.
public struct MenuConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var appItems: [AppMenuItem]
    public var actionItems: [ActionMenuItem]
    public var newFileTemplates: [NewFileTemplate]
    /// Master switch for the "Open With" section. When false the whole apps
    /// submenu is hidden regardless of individual app enabled state.
    public var appsSectionEnabled: Bool
    /// When false, app icons are hidden from the Finder contextual menu. The
    /// apps list in Settings is unaffected — this ONLY controls the right-click
    /// menu rendered by FinderSync. Default is true (icons shown).
    public var showAppIcons: Bool

    public init(
        isEnabled: Bool = true,
        appItems: [AppMenuItem] = [],
        actionItems: [ActionMenuItem] = ActionMenuItem.defaults,
        newFileTemplates: [NewFileTemplate] = NewFileTemplate.defaults,
        appsSectionEnabled: Bool = true,
        showAppIcons: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.appItems = appItems
        self.actionItems = actionItems
        self.newFileTemplates = newFileTemplates
        self.appsSectionEnabled = appsSectionEnabled
        self.showAppIcons = showAppIcons
    }

    // Custom Codable: older configs predate `appsSectionEnabled` and
    // `showAppIcons`; decode both as true so existing users keep seeing their
    // apps submenu with icons.
    private enum CodingKeys: String, CodingKey {
        case isEnabled, appItems, actionItems, newFileTemplates, appsSectionEnabled, showAppIcons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.appItems = try c.decodeIfPresent([AppMenuItem].self, forKey: .appItems) ?? []
        self.actionItems = try c.decodeIfPresent([ActionMenuItem].self, forKey: .actionItems) ?? ActionMenuItem.defaults
        self.newFileTemplates = try c.decodeIfPresent([NewFileTemplate].self, forKey: .newFileTemplates) ?? NewFileTemplate.defaults
        self.appsSectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .appsSectionEnabled) ?? true
        self.showAppIcons = try c.decodeIfPresent(Bool.self, forKey: .showAppIcons) ?? true
    }
}

extension MenuConfiguration {
    public static let `default`: MenuConfiguration = {
        MenuConfiguration(
            isEnabled: true,
            appItems: [],
            actionItems: ActionMenuItem.defaults,
            newFileTemplates: NewFileTemplate.defaults
        )
    }()
}

extension ActionMenuItem {
    public static let defaults: [ActionMenuItem] = [
        ActionMenuItem(actionType: .newFile, isEnabled: true),
        ActionMenuItem(actionType: .copyPath, isEnabled: true),
        ActionMenuItem(actionType: .copyFileName, isEnabled: true),
        ActionMenuItem(actionType: .toggleHidden, isEnabled: true),
    ]
}

// Sendable conformances are declared at each model's definition site
// (Shared/Models/*.swift), so they are not restated here.
