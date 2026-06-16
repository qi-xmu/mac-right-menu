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

    public var displayTitle: String {
        switch self {
        case .copyPath: return String(localized: "Copy Path")
        case .copyFileName: return String(localized: "Copy File Name")
        case .newFile: return String(localized: "New File")
        case .toggleHidden: return String(localized: "Toggle Hidden")
        }
    }

    public var systemIconName: String {
        switch self {
        case .copyPath: return "document.on.clipboard"
        case .copyFileName: return "text.cursor"
        case .newFile: return "doc.badge.plus"
        case .toggleHidden: return "eye.slash"
        }
    }

    /// Short user-facing description shown under each action in Settings.
    public var localizedDescription: String {
        switch self {
        case .copyPath: return String(localized: "Copy the full file path to clipboard")
        case .copyFileName: return String(localized: "Copy only the file name to clipboard")
        case .newFile: return String(localized: "Create a new file from templates")
        case .toggleHidden: return String(localized: "Show or hide files in Finder")
        }
    }
}
