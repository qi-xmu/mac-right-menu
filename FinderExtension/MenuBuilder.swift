import AppKit
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "menu-builder")

/// Builds the NSMenu hierarchy from MenuConfiguration.
enum MenuBuilder {

        private static var isDarkMode: Bool {
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }

        private static func icon(_ name: String) -> NSImage {
            let size = NSSize(width: 18, height: 18)
            let img = NSImage(size: size)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return img
            }
            let color: NSColor = isDarkMode ? .white : .black
            let tinted = symbol.withSymbolConfiguration(
                .init(hierarchicalColor: color)
            )
            img.lockFocus()
            (tinted ?? symbol).draw(in: NSRect(origin: .zero, size: size))
            img.unlockFocus()
            return img
        }

    static func buildMenu(
        configuration: MenuConfiguration,
        hasSelection: Bool,
        targetURL: URL?,
        target: AnyObject,
        action handlerSelector: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: String(localized: "mac-right-menu"))

        let enabledApps = configuration.appItems.filter(\.isEnabled)
        let enabledActions = configuration.actionItems.filter(\.isEnabled)

        // ── Section: New File (tag: 0–999) ──
        if enabledActions.contains(where: { $0.actionType == .newFile }) {
            let templates = configuration.newFileTemplates
            if !templates.isEmpty {
                let submenuItem = NSMenuItem(title: String(localized: "New File"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("doc.badge.plus")
                let submenu = NSMenu(title: String(localized: "New File"))
                for (index, template) in templates.enumerated() {
                    let item = NSMenuItem(title: template.fileName, action: handlerSelector, keyEquivalent: "")
                    item.target = target
                    item.tag = Constants.TagBase.newFile.rawValue + index
                    item.representedObject = template
                    submenu.addItem(item)
                }
                menu.setSubmenu(submenu, for: submenuItem)
                menu.addItem(submenuItem)
            }
        }

        // ── Section: Open With (tag: 1000–1999) ──
        if !enabledApps.isEmpty {
            if enabledApps.count == 1, let app = enabledApps.first {
                let item = NSMenuItem(
                    title: String(localized: "Open in \(app.displayName)"),
                    action: handlerSelector,
                    keyEquivalent: ""
                )
                item.target = target
                item.tag = Constants.TagBase.appItem.rawValue
                item.image = app.icon
                item.isEnabled = hasSelection
                item.representedObject = app
                menu.addItem(item)
            } else {
                let submenuItem = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("menubar.dock.rectangle")
                let submenu = NSMenu(title: String(localized: "Open With"))
                for (index, app) in enabledApps.enumerated() {
                    let appItem = NSMenuItem(title: app.displayName, action: handlerSelector, keyEquivalent: "")
                    appItem.target = target
                    appItem.tag = Constants.TagBase.appItem.rawValue + index
                    appItem.image = app.icon
                    appItem.representedObject = app
                    appItem.isEnabled = hasSelection
                    submenu.addItem(appItem)
                }
                menu.setSubmenu(submenu, for: submenuItem)
                menu.addItem(submenuItem)
            }
        }

        // ── Section: 操作 (tag: 2000–2999) ──
        let operationActions: [ActionType] = [.copyPath, .copyFileName, .toggleHidden, .openParent]
        let hasOps = enabledActions.contains(where: { operationActions.contains($0.actionType) })
        if hasOps {
            for actionItem in enabledActions where operationActions.contains(actionItem.actionType) {
                let tag: Int
                switch actionItem.actionType {
                case .copyPath:     tag = Constants.TagBase.copyPath.rawValue
                case .copyFileName: tag = Constants.TagBase.copyFileName.rawValue
                case .toggleHidden: tag = Constants.TagBase.toggleHidden.rawValue
                case .openParent:   tag = Constants.TagBase.openParent.rawValue
                default:            continue
                }
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = tag
                item.image = actionItem.iconName.flatMap { icon($0) } ?? icon("gearshape")
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        return menu
    }
}
