import Foundation
import SwiftData
import ASTRACore

@Model
public final class Artifact {
    public var id: UUID
    public var task: AgentTask?
    public var type: String
    public var path: String
    public var content: String?
    public var version: Int
    public var createdAt: Date

    public init(task: AgentTask, type: String, path: String, content: String? = nil, version: Int = 1) {
        self.id = UUID()
        self.task = task
        self.type = ArtifactKind(rawValue: type).rawValue
        self.path = path
        self.content = content
        self.version = version
        self.createdAt = Date()
    }

    public var kind: ArtifactKind {
        get { ArtifactKind(rawValue: type) }
        set { type = newValue.rawValue }
    }

    /// Whether the artifact file still exists on disk
    public var isStale: Bool {
        !FileManager.default.fileExists(atPath: path)
    }
}

public struct ArtifactKind: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? Self.file.rawValue : trimmed.lowercased()
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public static let file: ArtifactKind = "file"
    public static let html: ArtifactKind = "html"
    public static let markdown: ArtifactKind = "markdown"
    public static let sql: ArtifactKind = "sql"
    public static let json: ArtifactKind = "json"
    public static let csv: ArtifactKind = "csv"
    public static let tsv: ArtifactKind = "tsv"
    public static let text: ArtifactKind = "txt"
    public static let pdf: ArtifactKind = "pdf"
    public static let doc: ArtifactKind = "doc"
    public static let docx: ArtifactKind = "docx"
    public static let rtf: ArtifactKind = "rtf"
    public static let swift: ArtifactKind = "swift"
    public static let python: ArtifactKind = "py"
    public static let javascript: ArtifactKind = "js"
    public static let typescript: ArtifactKind = "ts"
    public static let jsx: ArtifactKind = "jsx"
    public static let tsx: ArtifactKind = "tsx"
    public static let yaml: ArtifactKind = "yaml"
    public static let yml: ArtifactKind = "yml"

    public static func forPath(_ path: String) -> ArtifactKind {
        if TaskGeneratedFilePathPolicy.isHTMLFile(path) { return .html }
        if TaskGeneratedFilePathPolicy.isMarkdownFile(path) { return .markdown }
        if TaskGeneratedFilePathPolicy.isSQLFile(path) { return .sql }
        let ext = URL(fileURLWithPath: path).pathExtension
        return ArtifactKind(rawValue: ext)
    }

    public var isHTML: Bool {
        rawValue == Self.html.rawValue
    }

    public var isTextInspectable: Bool {
        Self.textInspectableKinds.contains(self)
    }

    private static let textInspectableKinds: Set<ArtifactKind> = [
        .html, .markdown, "md", .text, "text", .json, .javascript, "css",
        .csv, "xml", .sql, .python, .swift, .typescript, .tsx, .jsx, .yaml, .yml
    ]
}
