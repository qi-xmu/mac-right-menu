import Foundation

/// Payload sent from the Extension to the Container when a menu item is clicked
/// (the `Action` from `new_menu_design.md`). The Container resolves `actionID`
/// via its `ActionDefMap` and executes the matching `ActionDef`.
public struct MenuAction: Codable, Sendable, Equatable {
    public var actionID: Int
    /// `FIFinderSyncController.default().targetedURL()`. Optional because that
    /// API can return nil in some contexts.
    public var targetURL: URL?
    /// `FIFinderSyncController.default().selectedItemURLs()` — empty in the
    /// empty-space / container context, in which case the Container falls back
    /// to `targetURL` (the containing folder).
    public var selectedURLs: [URL]

    public init(actionID: Int, targetURL: URL?, selectedURLs: [URL]) {
        self.actionID = actionID
        self.targetURL = targetURL
        self.selectedURLs = selectedURLs
    }
}
