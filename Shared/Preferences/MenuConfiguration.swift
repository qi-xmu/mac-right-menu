import Foundation

/// The full menu configuration that is persisted to App Group UserDefaults
/// and shared between Container App and Finder Extension.
public struct MenuConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var appItems: [AppMenuItem]
    public var actionItems: [ActionMenuItem]
    public var newFileTemplates: [NewFileTemplate]

    public init(
        isEnabled: Bool = true,
        appItems: [AppMenuItem] = [],
        actionItems: [ActionMenuItem] = ActionMenuItem.defaults,
        newFileTemplates: [NewFileTemplate] = NewFileTemplate.defaults
    ) {
        self.isEnabled = isEnabled
        self.appItems = appItems
        self.actionItems = actionItems
        self.newFileTemplates = newFileTemplates
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
        ActionMenuItem(actionType: .openParent, isEnabled: true),
    ]
}

// MARK: - Sendable conformances

extension AppMenuItem: @unchecked Sendable {}
extension ActionMenuItem: @unchecked Sendable {}
extension NewFileTemplate: @unchecked Sendable {}
