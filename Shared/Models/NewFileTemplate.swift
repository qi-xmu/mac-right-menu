import Foundation

public struct NewFileTemplate: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(name).\(fileExtension)" }

    public var name: String
    public var fileExtension: String
    public var defaultContent: String

    public init(name: String, fileExtension: String, defaultContent: String = "") {
        self.name = name
        self.fileExtension = fileExtension
        self.defaultContent = defaultContent
    }

    public var fileName: String {
        "\(name).\(fileExtension)"
    }

    public static let defaults: [NewFileTemplate] = {
        [
            NewFileTemplate(name: "Text File", fileExtension: "txt"),
            NewFileTemplate(name: "Markdown", fileExtension: "md", defaultContent: "# \n"),
            NewFileTemplate(name: "JSON", fileExtension: "json", defaultContent: "{\n  \n}\n"),
            NewFileTemplate(name: "Rich Text", fileExtension: "rtf"),
        ]
    }()

    public static func == (lhs: NewFileTemplate, rhs: NewFileTemplate) -> Bool {
        lhs.id == rhs.id
    }
}
