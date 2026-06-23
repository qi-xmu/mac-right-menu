import Foundation

/// Payload for a `.newFile` `ActionDef` (project characteristic). A template is
/// fully defined by its file name + extension (e.g. "未命名" + "md" → "未命名.md");
/// there is no separate "template name" concept. The extension also drives
/// content selection later.
public struct NewFileTemplate: Codable, Identifiable, Equatable, Sendable {
    /// Stable identity = resolved file name (base + extension).
    public var id: String { resolvedFileName }

    /// Base file name (no extension). Empty means "use the localized Untitled
    /// default" (未命名 / Untitled), resolved lazily so the default follows the
    /// system language until the user types a custom name.
    public var fileName: String
    public var fileExtension: String
    public var defaultContent: String

    public init(fileName: String = "", fileExtension: String, defaultContent: String = "") {
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.defaultContent = defaultContent
    }

    /// The base name (no extension): the user's `fileName` if non-empty, else
    /// the localized "Untitled".
    public var resolvedBaseName: String {
        fileName.isEmpty ? String(localized: "Untitled") : fileName
    }

    /// Full file name (base + extension) used both as the menu label and as the
    /// created file's name, e.g. "未命名.md".
    public var resolvedFileName: String {
        "\(resolvedBaseName).\(fileExtension)"
    }

    public static let defaults: [NewFileTemplate] = [
        NewFileTemplate(fileExtension: "txt"),
        NewFileTemplate(fileExtension: "md"),
    ]

    public static func == (lhs: NewFileTemplate, rhs: NewFileTemplate) -> Bool {
        lhs.id == rhs.id
    }
}
