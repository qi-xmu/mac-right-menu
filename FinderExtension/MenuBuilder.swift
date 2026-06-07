import AppKit
import os.log

private let logger = Logger(subsystem: Constants.extensionBundleID, category: "menu-builder")

/// Builds the NSMenu hierarchy from MenuConfiguration.
enum MenuBuilder {

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
                submenuItem.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: String(localized: "Open With"))
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
            menu.addItem(NSMenuItem.separator())
        }

        // ── Section: Copy Actions ──
        for actionItem in enabledActions {
            switch actionItem.actionType {
            case .copyPath, .copyFileName:
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.tag = Constants.TagBase.copyPath.rawValue + (actionItem.actionType == .copyFileName ? 1 : 0)
                item.image = NSImage(systemSymbolName: actionItem.iconName ?? "document.on.clipboard", accessibilityDescription: actionItem.title)
                item.isEnabled = hasSelection
                menu.addItem(item)
            default:
                break
            }
        }

        // ── Section: New File ──
        if enabledActions.contains(where: { $0.actionType == .newFile }) {
            let newFileTemplates = configuration.newFileTemplates
            if !newFileTemplates.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let submenuItem = NSMenuItem(title: String(localized: "New File"), action: nil, keyEquivalent: "")
                submenuItem.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: String(localized: "New File"))
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

        // ── Section: File Operations ──
        let fileOps: [ActionType] = [.moveToTrash, .toggleHidden]
        let hasFileOps = enabledActions.contains(where: { fileOps.contains($0.actionType) })
        if hasFileOps {
            menu.addItem(NSMenuItem.separator())
            for actionItem in enabledActions where fileOps.contains(actionItem.actionType) {
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.image = NSImage(systemSymbolName: actionItem.iconName ?? "gearshape", accessibilityDescription: actionItem.title)
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        // ── Section: Navigation ──
        let hasNav = enabledActions.contains(where: { $0.actionType == .openParent })
        if hasNav {
            menu.addItem(NSMenuItem.separator())
            for actionItem in enabledActions where actionItem.actionType == .openParent {
                let item = NSMenuItem(title: actionItem.title, action: handlerSelector, keyEquivalent: "")
                item.target = target
                item.image = NSImage(systemSymbolName: actionItem.iconName ?? "arrow.up.doc", accessibilityDescription: actionItem.title)
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
        }

        // ── Section: Test ──
        menu.addItem(NSMenuItem.separator())
        let testItem = NSMenuItem(
            title: String(localized: "Ping"),
            action: handlerSelector,
            keyEquivalent: ""
        )
        testItem.target = target
        testItem.tag = Constants.TagBase.testItem.rawValue
        testItem.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: String(localized: "Test"))
        testItem.isEnabled = true
        menu.addItem(testItem)

        return menu
    }
}
