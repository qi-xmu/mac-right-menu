import Foundation

/// A "new file" template. A template is fully defined by its file name +
/// extension (e.g. "未命名" + "md" → creates "未命名.md"); there is no separate
/// "template name" concept. The extension also drives content selection later
/// (future: user can pick a file of this extension to seed `defaultContent`).
public struct NewFileTemplate: Codable, Identifiable, Equatable, Sendable {
    /// Stable identity = resolved file name (base + extension).
    public var id: String { resolvedFileName }

    /// Base file name (no extension). Empty string means "use the localized
    /// Untitled default" (未命名 / Untitled), resolved lazily so the default
    /// follows the system language until the user types a custom name.
    public var fileName: String
    public var fileExtension: String
    public var defaultContent: String
    /// Whether this template appears in the Finder "New File" submenu.
    /// Mirrors the per-item toggle used by Actions/Apps.
    public var isEnabled: Bool

    public init(fileName: String = "", fileExtension: String, defaultContent: String = "", isEnabled: Bool = true) {
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.defaultContent = defaultContent
        self.isEnabled = isEnabled
    }

    // Custom Codable to migrate older configs: the legacy model had a separate
    // `name` field (and an optional `fileName`). On decode we prefer `fileName`
    // when present, fall back to the legacy `name`, then to "" (→ localized
    // "Untitled"). Encoding always writes the current shape (no `name`).
    private enum CodingKeys: String, CodingKey {
        case fileName, fileExtension, defaultContent, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer a real base file name when present (current shape). Legacy
        // configs had an optional `fileName`; if absent we fall back to "" which
        // resolves to the localized "Untitled". A legacy `name` (e.g.
        // "Markdown") was never a real base file name, so it is intentionally
        // discarded rather than promoted.
        if let base = try c.decodeIfPresent(String.self, forKey: .fileName), !base.isEmpty {
            self.fileName = base
        } else {
            self.fileName = ""
        }
        self.fileExtension = try c.decode(String.self, forKey: .fileExtension)
        self.defaultContent = try c.decodeIfPresent(String.self, forKey: .defaultContent) ?? ""
        // Older configs predate `isEnabled`; default to enabled so existing
        // templates keep appearing in the menu.
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(fileExtension, forKey: .fileExtension)
        try c.encode(defaultContent, forKey: .defaultContent)
        try c.encode(isEnabled, forKey: .isEnabled)
    }

    /// The base name (no extension): the user's `fileName` if non-empty, else
    /// the localized "Untitled".
    public var resolvedBaseName: String {
        fileName.isEmpty ? String(localized: "Untitled") : fileName
    }

    /// Full file name (base + extension) used both as the menu label and as
    /// the actual created file's name, e.g. "未命名.md".
    public var resolvedFileName: String {
        "\(resolvedBaseName).\(fileExtension)"
    }

    public static let defaults: [NewFileTemplate] = {
        [
            NewFileTemplate(fileExtension: "txt"),
            NewFileTemplate(fileExtension: "md"),
        ]
    }()

    public static func == (lhs: NewFileTemplate, rhs: NewFileTemplate) -> Bool {
        lhs.id == rhs.id
    }
}
