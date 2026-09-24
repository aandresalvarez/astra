import Foundation
import Testing

/// The shelf panels (Files, Query, Browser) drifted into three toolbar button
/// styles, two tab strips with different accents, stacked `.bar` materials, and
/// seven white-wash strengths. They now share `ShelfChrome`; this scan keeps
/// them from forking again.
@Suite("Shelf chrome")
struct ShelfChromeTests {
    private let shelfFiles = [
        "ShelfMarkdownPanelView.swift",
        "ShelfQueryPanelView.swift",
        "ShelfBrowserPanelView.swift",
        "ShelfWorkspaceAppPreviewView.swift",
        "Components/ShelfFileNavigatorComponents.swift"
    ]

    /// Specialized styles with no shared equivalent: the tinted Browse files
    /// toggle, the query picker field, the browser engine menu, and quick links.
    private let specializedButtonStyles: Set<String> = [
        "BrowseFilesToolbarButtonStyle", "QueryWorkflowFieldButtonStyle",
        "BrowserEngineMenuButtonStyle", "BrowserQuickLinkButtonStyle"
    ]

    /// Data marks, not chrome: result-table striping and chart bars.
    private let dataMarkFills = ["Stanford.fog.opacity(0.34)", "Stanford.lagunita.opacity(0.82)"]

    @Test("Shelf panels draw on the shared chrome instead of their own")
    func shelvesUseSharedChrome() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views")
        let rules: [(pattern: String, fix: String)] = [
            (#"\.background\(\.bar\)"#, "the shelf container already paints .bar"),
            (#"cardBackground\.opacity"#, "use ShelfChrome.contentSurface or raisedSurface"),
            (#"\.(fill|background)\([^)\n]*opacity\(0?\.\d*[1-9]"#, "use a Stanford fill step"),
            (#"cornerRadius: (?!4\b)\d"#, "use ShelfChrome.controlRadius or a Stanford radius"),
            (#"struct \w+ButtonStyle"#, "reuse ShelfToolbarButtonStyle or ShelfSoftButtonStyle")
        ]
        var violations: [String] = []
        for file in shelfFiles {
            let lines = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if dataMarkFills.contains(where: line.contains) { continue }
                if let name = line.firstMatch(of: #/struct (\w+ButtonStyle)/#)?.1, specializedButtonStyles.contains(String(name)) {
                    continue
                }
                for rule in rules where line.range(of: rule.pattern, options: .regularExpression) != nil {
                    violations.append("\(file):\(index + 1)  \(rule.fix): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(violations.isEmpty, "Shelf chrome drift:\n\(violations.joined(separator: "\n"))")
    }
}
