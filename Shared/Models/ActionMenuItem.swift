import Foundation

public struct ActionMenuItem: MenuItem, @unchecked Sendable {
    public var id: String { actionType.rawValue }
    public var title: String { actionType.displayTitle }
    public var iconName: String? { actionType.systemIconName }
    public var isEnabled: Bool

    public var actionType: ActionType

    public init(actionType: ActionType, isEnabled: Bool = true) {
        self.actionType = actionType
        self.isEnabled = isEnabled
    }

    public static func == (lhs: ActionMenuItem, rhs: ActionMenuItem) -> Bool {
        lhs.id == rhs.id
    }
}
