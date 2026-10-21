import Foundation
import ASTRACore

/// A bounded first look at the directory the provider runs in — its top-level
/// entries, one level of children, and the README's opening lines — plus
/// guidance on reading in few steps and sizing the answer.
///
/// Agent CLIs run one model round-trip per tool step, so an agent that opens
/// with `ls`, then the README, then each manifest one at a time spends most of
/// an "explain this project" turn waiting on sequential calls (task 77F74B69:
/// 26 steps, ~84 s of a 118 s turn). Listing the directory costs ASTRA
/// milliseconds; the guidance asks the agent to batch what it still reads.
///
/// Rebuilt from the filesystem on every launch and never stored, so it has
/// no second owner to keep in sync. Loaded off the main actor, and each
/// directory read stops after a fixed number of entries, so a huge folder
/// costs a bounded amount of work.
///
/// Everything taken from the workspace — names and README text — is rendered
/// as untrusted data, and nothing is read through a link that leaves the
/// working directory: ASTRA reads on the host, outside the provider sandbox.
struct WorkspaceOrientationPromptGuidance: Sendable, Equatable {
    let text: String

    static let empty = WorkspaceOrientationPromptGuidance(text: "")
    static let maxTopLevelEntries = 40
    static let maxChildNamesPerDirectory = 12
    /// Entries read from one directory before the listing stops counting.
    static let maxScannedEntriesPerDirectory = 400
    static let maxNameCharacters = 80
    static let maxTreeCharacters = 3_000
    static let maxReadmeLines = 40
    static let maxReadmeCharacters = 2_000
    static let treeMarker = "ASTRA_WORKSPACE_TREE"
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

    /// The preview's manifest with this orientation as its last section, so
    /// "What will be sent" shows what the launch appends.
    func appending(to manifest: PromptAssemblyManifest, directory: String) -> PromptAssemblyManifest {
        guard !text.isEmpty else { return manifest }
        var result = manifest
        result.prompt = appending(to: manifest.prompt)
        result.promptCharacterCount = result.prompt.count
        result.estimatedPromptTokens = Self.estimatedTokens(result.prompt.count)
        result.sections.append(PromptAssemblySectionManifest(
            kind: .workspaceOrientation,
            tokenBudget: PromptContextBudgetProfile.standard.tokenBudget(for: .workspaceOrientation),
            estimatedOriginalTokens: Self.estimatedTokens(text.count),
            estimatedIncludedTokens: Self.estimatedTokens(text.count),
            originalCharacterCount: text.count,
            includedCharacterCount: text.count,
            isTruncated: false,
            sourcePointers: [PromptAssemblySourcePointer(label: "working directory", target: directory)],
            includedTextPreview: String(text.prefix(3_000))
        ))
        return result
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
        guard !directory.isEmpty else { return .empty }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        // A home or filesystem root is not a project; listing it would only
        // put the user's folder names in the prompt.
        let home = broker.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard root.path != "/", root.path != home else { return .empty }
        let intent = HostFileAccessIntent.implicitScan(root: root)
        let listing = boundedListing(of: root, broker: broker, intent: intent)
        guard !listing.urls.isEmpty else { return .empty }
        let entries = listing.urls.map { entry(for: $0, root: root) }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory
                    ? lhs.isDirectory
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        var treeLines: [String] = []
        var treeCharacters = 0
        for entry in entries.prefix(maxTopLevelEntries) {
            let line = describe(entry, broker: broker, intent: intent)
            guard treeCharacters + line.count + 1 <= maxTreeCharacters else { break }
            treeLines.append(line)
            treeCharacters += line.count + 1
        }
        if treeLines.count < entries.count || listing.isCapped {
            treeLines.append("- (more entries not shown)")
        }

        var sections = [
            "Workspace orientation: ASTRA listed the working directory when this turn started (hidden entries omitted). It may be incomplete, so read a file before relying on its details.",
            PromptUntrustedDataBlock.render(
                title: "The working directory's top-level entries",
                marker: treeMarker,
                content: treeLines.joined(separator: "\n")
            )
        ]
        if let readme = readmeHead(in: entries, root: root, broker: broker, intent: intent) {
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
        /// A regular file or real directory, not a link, so reading it cannot
        /// reach outside the working directory.
        let isContained: Bool
    }

    private struct Listing {
        let urls: [URL]
        let isCapped: Bool
    }

    private struct ReadmeHead {
        let name: String
        let text: String
        let shownLines: Int
    }

    /// Reads at most `maxScannedEntriesPerDirectory` entries, lazily, so the
    /// cost of a directory with a million files is that of a few hundred.
    private static func boundedListing(
        of directory: URL,
        broker: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> Listing {
        guard let enumerator = broker.enumerator(
            at: directory,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
            intent: intent,
            errorHandler: { _, _ in true }
        ) else {
            return Listing(urls: [], isCapped: false)
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard urls.count < maxScannedEntriesPerDirectory else { return Listing(urls: urls, isCapped: true) }
            urls.append(url)
        }
        return Listing(urls: urls, isCapped: false)
    }

    private static func entry(for url: URL, root: URL) -> Entry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        let isLink = values?.isSymbolicLink == true
        let resolved = url.resolvingSymlinksInPath().path
        let staysInRoot = resolved.hasPrefix(root.path + "/")
        let isDirectory = isLink
            ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            : values?.isDirectory == true
        return Entry(
            url: url,
            name: displayName(url.lastPathComponent),
            isDirectory: isDirectory,
            isContained: !isLink && staysInRoot && (isDirectory || values?.isRegularFile == true)
        )
    }

    private static func describe(_ entry: Entry, broker: HostFileAccessBroker, intent: HostFileAccessIntent) -> String {
        guard entry.isContained else {
            return "- \(entry.name)\(entry.isDirectory ? "/" : "") (link, not followed)"
        }
        guard entry.isDirectory else {
            guard let size = broker.fileSize(at: entry.url, intent: intent) else { return "- \(entry.name)" }
            return "- \(entry.name) (\(formattedSize(size)))"
        }
        guard !unexpandedDirectoryNames.contains(entry.name) else { return "- \(entry.name)/ (not expanded)" }
        let listing = boundedListing(of: entry.url, broker: broker, intent: intent)
        guard !listing.urls.isEmpty else { return "- \(entry.name)/ (empty)" }
        let names = listing.urls
            .map { (name: displayName($0.lastPathComponent), url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Only the children shown pay for a stat to mark subdirectories.
        let shownNames = names.prefix(maxChildNamesPerDirectory).map { child in
            (try? child.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? child.name + "/" : child.name
        }
        let count = listing.isCapped ? "\(maxScannedEntriesPerDirectory)+" : "\(names.count)"
        let more = names.count > shownNames.count || listing.isCapped ? ", and more" : ""
        return "- \(entry.name)/ (\(count) entries): \(shownNames.joined(separator: ", "))\(more)"
    }

    /// A filename is attacker-chosen text: keep it on one line and short.
    private static func displayName(_ name: String) -> String {
        let flattened = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? "?" : scalar
        }))
        guard flattened.count > maxNameCharacters else { return flattened }
        return String(flattened.prefix(maxNameCharacters)) + "…"
    }

    private static func readmeHead(
        in entries: [Entry],
        root: URL,
        broker: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> ReadmeHead? {
        let preferredNames = ["readme.md", "readme", "readme.rst", "readme.txt", "readme.markdown"]
        guard let readme = preferredNames.lazy.compactMap({ preferred in
            entries.first { $0.isContained && !$0.isDirectory && $0.name.lowercased() == preferred }
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

    private static func estimatedTokens(_ characters: Int) -> Int {
        max(1, Int(ceil(Double(characters) / 4)))
    }
}
