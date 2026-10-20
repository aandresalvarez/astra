import Foundation
import ASTRACore

/// A bounded first look at the directory the provider runs in — its top-level
/// entries, one level of children, and the README's opening lines — plus
/// guidance on reading in few steps and sizing the answer.
///
/// Agent CLIs run one model round-trip per tool step, so an agent that opens
/// with `ls`, then the README, then each manifest one at a time spends most of
/// a "explain this project" turn waiting on sequential calls (task 77F74B69:
/// 26 steps, ~84 s of a 118 s turn). Listing the directory costs ASTRA
/// milliseconds; the guidance asks the agent to batch what it still reads.
///
/// Rebuilt from the filesystem on every launch and never stored, so it has
/// no second owner to keep in sync. Loaded off the main actor because a
/// workspace can hold directories with very many entries.
struct WorkspaceOrientationPromptGuidance: Sendable, Equatable {
    let text: String

    static let empty = WorkspaceOrientationPromptGuidance(text: "")
    static let maxTopLevelEntries = 40
    static let maxChildNamesPerDirectory = 12
    static let maxTreeCharacters = 3_000
    static let maxReadmeLines = 40
    static let maxReadmeCharacters = 2_000
    static let readmeMarker = "ASTRA_WORKSPACE_README"

    /// Dependency, build, and cache folders whose children say nothing about
    /// the project. They are still named, just not expanded.
    static let unexpandedDirectoryNames: Set<String> = [
        "node_modules", "__pycache__", "venv", "env", "build", "dist", "target",
        "DerivedData", "Pods", "vendor", "coverage", "site-packages"
    ]

    static let readingGuidance = """
    How to work through this request efficiently:
    - Every tool step costs a full model round-trip. Use the orientation above instead of listing the working directory again.
    - When you need several files, read them in one step — one shell command such as `head -n 120 file_a file_b file_c`, or several tool calls issued together — rather than one file per step.
    - Read only what the request needs. For a question about this workspace (explain, describe, what, where, how, why), the orientation plus a few key files is usually enough: stop reading once you can answer, and do not run the project's code just to describe it.
    - Size the final answer to the question. An overview or explanation should be a short, scannable answer of a few paragraphs or bullets, not an exhaustive report, unless the user asks for depth, a full report, or a file.
    """

    func appending(to prompt: String) -> String {
        text.isEmpty ? prompt : prompt + "\n\n" + text
    }

    static func load(directory: String) async -> WorkspaceOrientationPromptGuidance {
        await Task.detached(priority: .userInitiated) {
            make(directory: directory)
        }.value
    }

    static func make(
        directory: String,
        broker: HostFileAccessBroker = HostFileAccessBroker()
    ) -> WorkspaceOrientationPromptGuidance {
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        // A home or filesystem root is not a project; listing it would only
        // put the user's folder names in the prompt.
        let home = broker.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard !directory.isEmpty, resolvedRoot != "/", resolvedRoot != home else { return .empty }
        let intent = HostFileAccessIntent.implicitScan(root: root)
        guard let entries = try? sortedVisibleEntries(of: root, broker: broker, intent: intent),
              !entries.isEmpty else {
            return .empty
        }

        var treeLines: [String] = []
        var treeCharacters = 0
        var shown = 0
        for entry in entries.prefix(maxTopLevelEntries) {
            let line = describe(entry, broker: broker, intent: intent)
            guard treeCharacters + line.count + 1 <= maxTreeCharacters else { break }
            treeLines.append(line)
            treeCharacters += line.count + 1
            shown += 1
        }
        if shown < entries.count {
            treeLines.append("- (+\(entries.count - shown) more entries not shown)")
        }

        var sections = [
            "Workspace orientation: ASTRA listed the working directory when this turn started (hidden entries omitted). It may be incomplete, so read a file before relying on its details.",
            "Top-level entries:\n" + treeLines.joined(separator: "\n")
        ]
        if let readme = readmeHead(in: entries, broker: broker, intent: intent) {
            sections.append(PromptUntrustedDataBlock.render(
                title: "The first \(readme.shownLines) lines of \(readme.name)",
                marker: readmeMarker,
                content: readme.text
            ))
        }
        sections.append(readingGuidance)
        return WorkspaceOrientationPromptGuidance(text: sections.joined(separator: "\n\n"))
    }

    private struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
    }

    private struct ReadmeHead {
        let name: String
        let text: String
        let shownLines: Int
    }

    private static func sortedVisibleEntries(
        of directory: URL,
        broker: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) throws -> [Entry] {
        try broker.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles], intent: intent)
            .map { url in
                Entry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                )
            }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory
                    ? lhs.isDirectory
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func describe(_ entry: Entry, broker: HostFileAccessBroker, intent: HostFileAccessIntent) -> String {
        guard entry.isDirectory else {
            guard let size = broker.fileSize(at: entry.url, intent: intent) else { return "- \(entry.name)" }
            return "- \(entry.name) (\(formattedSize(size)))"
        }
        guard !unexpandedDirectoryNames.contains(entry.name) else { return "- \(entry.name)/ (not expanded)" }
        // Names come from the directory listing alone; only the children shown
        // pay for a stat to mark subdirectories.
        guard let children = try? broker.contentsOfDirectory(at: entry.url, options: [.skipsHiddenFiles], intent: intent) else {
            return "- \(entry.name)/"
        }
        guard !children.isEmpty else { return "- \(entry.name)/ (empty)" }
        let names = children
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shownNames = names.prefix(maxChildNamesPerDirectory).map { name in
            let child = entry.url.appendingPathComponent(name)
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory ? name + "/" : name
        }
        let more = names.count > shownNames.count ? ", +\(names.count - shownNames.count) more" : ""
        return "- \(entry.name)/ (\(names.count) entries): \(shownNames.joined(separator: ", "))\(more)"
    }

    private static func readmeHead(
        in entries: [Entry],
        broker: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> ReadmeHead? {
        let preferredNames = ["readme.md", "readme", "readme.rst", "readme.txt", "readme.markdown"]
        guard let readme = preferredNames.lazy.compactMap({ preferred in
            entries.first { !$0.isDirectory && $0.name.lowercased() == preferred }
        }).first,
              let data = try? broker.readData(at: readme.url, maxBytes: maxReadmeCharacters * 2, keeping: .prefix, intent: intent) else {
            return nil
        }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxReadmeLines)
            .map(String.init)
        while lines.joined(separator: "\n").count > maxReadmeCharacters, lines.count > 1 {
            lines.removeLast()
        }
        var head = lines.joined(separator: "\n")
        if head.count > maxReadmeCharacters { head = String(head.prefix(maxReadmeCharacters)) }
        guard !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReadmeHead(name: readme.name, text: head, shownLines: lines.count)
    }

    private static func formattedSize(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_024 * 1_024 { return "\(bytes / 1_024) KB" }
        return String(format: "%.1f MB", Double(bytes) / Double(1_024 * 1_024))
    }
}
