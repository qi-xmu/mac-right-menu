import Foundation

/// Persisted application configuration (replaces the deprecated
/// `MenuConfiguration`). Bundles the two halves of the design doc:
///   - `menu`: the doc's `Config` (menu tree), pushed to the Extension over RPC.
///   - `actions`: the doc's `ActionDefMap`, used by the Container to execute
///     clicks. Never sent to the Extension.
///
/// `MenuItem.actionID` is the link between the two: a leaf in `menu.menus`
/// references an entry in `actions`.
public struct AppConfig: Codable, Equatable, Sendable {
    public var menu: MenuConfig
    public var actions: ActionDefMap

    public init(menu: MenuConfig = .default, actions: ActionDefMap = [:]) {
        self.menu = menu
        self.actions = actions
    }

    /// Default seeded config: a New File section (txt, md) plus the three
    /// general operations, laid out as the legacy default menu. `actionID`s
    /// follow `Constants.TagBase`.
    public static let `default`: AppConfig = {
        var actions: ActionDefMap = [:]
        var menus: [MenuItem] = []

        // ── New File section (actionID 0…; templates from NewFileTemplate.defaults) ──
        let templates = NewFileTemplate.defaults
        var newFileLeaves: [MenuItem] = []
        for (index, template) in templates.enumerated() {
            let id = Constants.TagBase.newFile.rawValue + index
            actions[id] = .newFile(template: template)
            newFileLeaves.append(MenuItem(
                id: "newFile.\(template.id)",
                showAppIcons: false,
                showCondition: .isDir,
                multiItemSupport: false,
                actionID: id,
                icon: .none,
                name: template.resolvedFileName
            ))
        }
	        menus.append(MenuItem(
	            id: "section.newFile",
	            showAppIcons: true,
	            showCondition: .isDir,
	            multiItemSupport: false,
	            actionID: 0,
	            icon: .sfSymbol("doc.badge.plus"),
	            name: String(localized: "New File"),
	            subMenus: newFileLeaves
	        ))

	        // ── Open With section (actionID 1000…; pre-populated with installed apps) ──
	        let defaultApps: [String] = [
	            "/System/Applications/Utilities/Terminal.app",
	            "/Applications/Visual Studio Code.app",
	        ]
	        var appLeaves: [MenuItem] = []
	        var appIndex = 0
	        for path in defaultApps {
	            guard FileManager.default.fileExists(atPath: path) else { continue }
	            let id = Constants.TagBase.appItem.rawValue + appIndex
	            let target = AppTarget(appURL: URL(fileURLWithPath: path))
	            actions[id] = .openWith(app: target)
	            appLeaves.append(MenuItem(
	                id: "app.\(target.id)",
	                showAppIcons: false,
	                showCondition: .both,
	                multiItemSupport: true,
	                actionID: id,
	                icon: .appIcon(path: path),
	                name: target.displayName
	            ))
	            appIndex += 1
	        }
	        if !appLeaves.isEmpty {
	            menus.append(MenuItem(
	                id: "section.apps",
	                showAppIcons: true,
	                showCondition: .both,
	                multiItemSupport: true,
	                actionID: 0,
	                icon: .sfSymbol("menubar.dock.rectangle"),
	                name: String(localized: "Open With"),
	                subMenus: appLeaves
	            ))
	        }

	        // ── General operations (fixed actionIDs 2000/2001/2002) ──
        let operations: [(GeneralOperation, Int)] = [
            (.copyPath,     Constants.TagBase.copyPath.rawValue),
            (.copyFileName, Constants.TagBase.copyFileName.rawValue),
            (.toggleHidden, Constants.TagBase.toggleHidden.rawValue),
        ]
        for (operation, id) in operations {
            actions[id] = .general(operation: operation)
            menus.append(MenuItem(
                id: "op.\(operation.rawValue)",
                showAppIcons: true,
                showCondition: .both,
                multiItemSupport: true,
                actionID: id,
                icon: .sfSymbol(operation.systemIconName),
                name: operation.displayTitle
            ))
        }

        return AppConfig(
            menu: MenuConfig(isEnabled: true, showAppIcons: true, menus: menus),
            actions: actions
        )
    }()
}
