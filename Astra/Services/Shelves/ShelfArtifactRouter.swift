import Foundation

enum ShelfArtifactRouter {
    private static let filesShelfExtensions: Set<String> = [
        "md", "markdown", "qmd", "txt", "text", "log",
        "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml", "plist",
        "swift", "py", "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm",
        "sh", "bash", "zsh", "fish", "sql", "r", "rb", "go", "rs",
        "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm",
        "php", "pl", "lua", "env", "ini", "cfg", "conf"
    ]

    private static let filesShelfFileNames: Set<String> = [
        ".env", ".gitignore", ".npmrc", ".zshrc", ".bashrc",
        "dockerfile", "makefile", "rakefile", "gemfile", "podfile",
        "readme", "license", "changelog"
    ]

    static func shelfID(for path: String) -> ShelfID? {
        if isHTMLFile(path) { return .browser }
        if isSQLFile(path) { return .query }
        if isFilesShelfFile(path) { return .files }
        return nil
    }

    static func isFilesShelfFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return filesShelfExtensions.contains(ext)
            || filesShelfFileNames.contains(name)
            || name.hasPrefix(".env.")
    }

    private static func isHTMLFile(_ path: String) -> Bool {
        ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func isSQLFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "sql"
    }
}
