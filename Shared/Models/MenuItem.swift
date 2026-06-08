import AppKit

/// Protocol defining a menu item that can appear in Finder's right-click menu.
/// Both AppMenuItem (open with app) and ActionMenuItem (copy, delete, etc.) conform to this.
public protocol MenuItem: Codable, Identifiable, Equatable {
    var id: String { get }
    var title: String { get }
    var iconName: String? { get }
    var isEnabled: Bool { get set }
}

/// The type of action an ActionMenuItem performs
public enum ActionType: String, Codable, CaseIterable {
    case newFile
    case copyPath
    case copyFileName
    case toggleHidden
    case openParent

    public var displayTitle: String {
        switch self {
        case .copyPath: return String(localized: "Copy Path")
        case .copyFileName: return String(localized: "Copy File Name")
        case .newFile: return String(localized: "New File")
        case .toggleHidden: return String(localized: "Toggle Hidden")
        case .openParent: return String(localized: "Open Parent Directory")
        }
    }

    public var systemIconName: String {
        switch self {
        case .copyPath: return "document.on.clipboard"
        case .copyFileName: return "text.cursor"
        case .newFile: return "doc.badge.plus"
        case .toggleHidden: return "eye.slash"
        case .openParent: return "arrow.up.doc"
        }
    }
}
