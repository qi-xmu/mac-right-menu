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

        // ── Section: New File ──
        if enabledActions.contains(where: { $0.actionType == .newFile }) {
            let newFileTemplates = configuration.newFileTemplates
            if !newFileTemplates.isEmpty {
                let submenuItem = NSMenuItem(title: String(localized: "New File"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("doc.badge.plus")
                let submenu = NSMenu(title: String(localized: "New File"))
                for (index, template) in newFileTemplates.enumerated() {
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

        // ── Section: Open With (if there are configured apps) ──
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
                menu.addItem(item)
            } else {
                let submenuItem = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                submenuItem.image = icon("menubar.dock.rectangle")
                let submenu = NSMenu(title: String(localized: "Open With"))
                for app in enabledApps {
                    let appItem = NSMenuItem(title: app.displayName, action: handlerSelector, keyEquivalent: "")
                    appItem.target = target
                    appItem.tag = Constants.TagBase.appItem.rawValue
                    appItem.image = app.icon
                    appItem.representedObject = app
                    appItem.isEnabled = hasSelection
                    submenu.addItem(appItem)
                }
                menu.setSubmenu(submenu, for: submenuItem)
                menu.addItem(submenuItem)
            }
        }

        // ── Section: Copy Actions ──
        for actionItem in enabledActions {
            switch actionItem.actionType {
            case .copyPath, .copyFileName:
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = Constants.TagBase.copyPath.rawValue + (actionItem.actionType == .copyFileName ? 1 : 0)
                item.image = actionItem.iconName.flatMap { icon($0) } ?? icon("document.on.clipboard")
                item.isEnabled = hasSelection
                menu.addItem(item)
            default:
                break
            }
        }

        // ── Section: File Operations ──
        let fileOps: [ActionType] = [.toggleHidden]
        let hasFileOps = enabledActions.contains(where: { fileOps.contains($0.actionType) })
        if hasFileOps {
            for actionItem in enabledActions where fileOps.contains(actionItem.actionType) {
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = Constants.TagBase.toggleHidden.rawValue
                item.image = actionItem.iconName.flatMap { icon($0) } ?? icon("gearshape")
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        // ── Section: Navigation ──
        let hasNav = enabledActions.contains(where: { $0.actionType == .openParent })
        if hasNav {
            for actionItem in enabledActions where actionItem.actionType == .openParent {
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = Constants.TagBase.openParent.rawValue
                item.image = actionItem.iconName.flatMap { icon($0) } ?? icon("arrow.up.doc")
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        return menu
    }
}
