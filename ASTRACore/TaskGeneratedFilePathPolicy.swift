import Foundation

/// Pure file-extension checks extracted from `Astra/Services/Tasks/TaskGeneratedFiles.swift`
/// as part of Track A2.1 (finishing A2's Models cycle-break), so
/// `Astra/Models/Artifact.swift` can depend on them without pulling in the
/// rest of that file's Shelf-infrastructure-coupled logic
/// (`CoreShelfRegistry`, `HostFileAccessBroker`, `ShelfArtifactRouter`).
public enum TaskGeneratedFilePathPolicy {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "qmd"]

    public static func isHTMLFile(_ path: String) -> Bool {
        ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func isMarkdownFile(_ path: String) -> Bool {
        markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func isSQLFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "sql"
    }
}
