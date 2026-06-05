import Foundation
import SwiftData

@Model
final class Artifact {
    var id: UUID
    var task: AgentTask?
    var type: String
    var path: String
    var content: String?
    var version: Int
    var createdAt: Date

    init(task: AgentTask, type: String, path: String, content: String? = nil, version: Int = 1) {
        self.id = UUID()
        self.task = task
        self.type = ArtifactKind(rawValue: type).rawValue
        self.path = path
        self.content = content
        self.version = version
        self.createdAt = Date()
    }

    var kind: ArtifactKind {
        get { ArtifactKind(rawValue: type) }
        set { type = newValue.rawValue }
    }

    /// Whether the artifact file still exists on disk
    var isStale: Bool {
        !FileManager.default.fileExists(atPath: path)
    }
}

struct ArtifactKind: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? Self.file.rawValue : trimmed.lowercased()
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    static let file: ArtifactKind = "file"
    static let html: ArtifactKind = "html"
    static let markdown: ArtifactKind = "markdown"
    static let sql: ArtifactKind = "sql"
    static let json: ArtifactKind = "json"
    static let csv: ArtifactKind = "csv"
    static let tsv: ArtifactKind = "tsv"
    static let text: ArtifactKind = "txt"
    static let pdf: ArtifactKind = "pdf"
    static let doc: ArtifactKind = "doc"
    static let docx: ArtifactKind = "docx"
    static let rtf: ArtifactKind = "rtf"
    static let swift: ArtifactKind = "swift"
    static let python: ArtifactKind = "py"
    static let javascript: ArtifactKind = "js"
    static let typescript: ArtifactKind = "ts"
    static let jsx: ArtifactKind = "jsx"
    static let tsx: ArtifactKind = "tsx"
    static let yaml: ArtifactKind = "yaml"
    static let yml: ArtifactKind = "yml"

    static func forPath(_ path: String) -> ArtifactKind {
        if TaskGeneratedFiles.isHTMLFile(path) { return .html }
        if TaskGeneratedFiles.isMarkdownFile(path) { return .markdown }
        if TaskGeneratedFiles.isSQLFile(path) { return .sql }
        let ext = URL(fileURLWithPath: path).pathExtension
        return ArtifactKind(rawValue: ext)
    }

    var isHTML: Bool {
        rawValue == Self.html.rawValue
    }

    var isTextInspectable: Bool {
        Self.textInspectableKinds.contains(self)
    }

    private static let textInspectableKinds: Set<ArtifactKind> = [
        .html, .markdown, "md", .text, "text", .json, .javascript, "css",
        .csv, "xml", .sql, .python, .swift, .typescript, .tsx, .jsx, .yaml, .yml
    ]
}
