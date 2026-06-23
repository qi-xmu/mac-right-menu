import Foundation

/// The kind of action a leaf menu item performs (the
/// `NEW_FILE | OPEN_WITH | GENERAL | CUSTOM` from the design doc).
public enum ActionDefType: String, Codable, Sendable {
    case newFile    // NEW_FILE
    case openWith   // OPEN_WITH
    case general    // GENERAL
    case custom     // CUSTOM (shell; reserved, not yet implemented)
}

/// Definition of a single action (the `ActionDef` from the design doc), keyed
/// by `actionID` in an `ActionDefMap`. The Container looks up
/// `actionMap[actionID]` on click and executes the payload.
///
/// Modeled as an enum with associated values so each case carries exactly its
/// own payload (the doc's `...`) and no invalid combination is representable.
/// The `actionID` itself is the dictionary key, so it is not stored here.
public enum ActionDef: Codable, Equatable, Sendable {
    /// Create a new file from a template.
    case newFile(template: NewFileTemplate)
    /// Open the selected target(s) with an application.
    case openWith(app: AppTarget)
    /// A built-in general operation (copy path, copy name, toggle hidden).
    case general(operation: GeneralOperation)
    /// Run a custom shell command. Reserved — not yet wired in the UI.
    case custom(command: String)

    public var actionType: ActionDefType {
        switch self {
        case .newFile:  return .newFile
        case .openWith: return .openWith
        case .general:  return .general
        case .custom:   return .custom
        }
    }
}

/// `actionID → ActionDef` (the `ActionDefMap<Int, ActionDef>` from the design
/// doc). The key is the `actionID` carried by a leaf `MenuItem`. Built and
/// persisted by the Container (as part of `AppConfig`); never sent to the
/// Extension.
public typealias ActionDefMap = [Int: ActionDef]

/// The specific operation a `.general` `ActionDef` performs. This is the
/// general-purpose subset of the former `ActionType` — `.newFile` is now its
/// own `ActionDefType` carrying a `NewFileTemplate` payload.
public enum GeneralOperation: String, Codable, Sendable, CaseIterable {
    case copyPath
    case copyFileName
    case toggleHidden

    /// Localized menu / settings title.
    public var displayTitle: String {
        switch self {
        case .copyPath:     return String(localized: "Copy Path")
        case .copyFileName: return String(localized: "Copy File Name")
        case .toggleHidden: return String(localized: "Toggle Hidden")
        }
    }

    /// SF Symbol name used for the menu icon.
    public var systemIconName: String {
        switch self {
        case .copyPath:     return "document.on.clipboard"
        case .copyFileName: return "text.cursor"
        case .toggleHidden: return "eye.slash"
        }
    }

    /// Short user-facing description shown in Settings.
    public var localizedDescription: String {
        switch self {
        case .copyPath:     return String(localized: "Copy the full file path to clipboard")
        case .copyFileName: return String(localized: "Copy only the file name to clipboard")
        case .toggleHidden: return String(localized: "Show or hide files in Finder")
        }
    }
}
