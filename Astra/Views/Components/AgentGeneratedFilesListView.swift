import AppKit
import SwiftUI
import ASTRACore

/// How many rows the generated-files card lays out. The card is an eager stack
/// inside a transcript bubble, and its input is the whole task folder, so it
/// expands inline only while the list is short; a longer list opens the task's
/// Files index, which is lazy.
enum AgentGeneratedFilesListPresentation {
    static let collapsedRowLimit = 6
    static let expandedRowLimit = 50

    enum Overflow: Equatable {
        case allShown
        /// The rest fits in the card: "Show all" expands it.
        case expandInline
        /// Too many rows for the bubble: open the Files index instead.
        case openFilesIndex
    }

    static func visiblePaths(_ paths: [String], isExpanded: Bool) -> ArraySlice<String> {
        isExpanded && paths.count <= expandedRowLimit ? paths[...] : paths.prefix(collapsedRowLimit)
    }

    static func overflow(pathCount: Int, visibleCount: Int) -> Overflow {
        guard pathCount > visibleCount else { return .allShown }
        return pathCount <= expandedRowLimit ? .expandInline : .openFilesIndex
    }

    static func filesIndexTitle(pathCount: Int) -> String {
        "Show all \(pathCount.formatted()) in Files"
    }
}

/// Generated-files attachment list rendered for a finished agent turn. Pulled
/// into its own struct so the parent bubble does not re-evaluate this `ForEach`
/// each time unrelated bubble state changes.
///
/// Per body pass it touches only the visible rows and the count. Anything a
/// row needs from the whole list comes precomputed on the listing: recounting
/// basenames per row cost ~0.8 s a pass on a 31,774-file task folder.
struct AgentGeneratedFilesListView: View {
    let listing: TaskGeneratedFileListing
    let onOpen: ((String) -> Void)?
    let onShowAllFiles: () -> Void
    @State private var isExpanded = false

    var body: some View {
        let pathCount = listing.paths.count
        let visiblePaths = AgentGeneratedFilesListPresentation.visiblePaths(listing.paths, isExpanded: isExpanded)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(Stanford.coolGrey)
                Text("Files")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text("\(pathCount)")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(groupedPaths(visiblePaths), id: \.title) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)

                    ForEach(group.paths, id: \.self) { path in
                        Button {
                            if let onOpen {
                                onOpen(path)
                            } else {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: Formatters.fileIcon(for: path))
                                    .font(Stanford.ui(11))
                                Text(TaskFileIndex.displayName(for: path, duplicateBasenames: listing.duplicateBasenames))
                                    .font(Stanford.caption(12))
                                    .underline()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                        .help(TaskGeneratedFiles.shelfDestination(for: path)?.title ?? "Open file")
                    }
                }
            }

            switch AgentGeneratedFilesListPresentation.overflow(pathCount: pathCount, visibleCount: visiblePaths.count) {
            case .allShown:
                EmptyView()
            case .expandInline:
                overflowButton("Show all") { isExpanded = true }
            case .openFilesIndex:
                overflowButton(AgentGeneratedFilesListPresentation.filesIndexTitle(pathCount: pathCount),
                               action: onShowAllFiles)
                    .help("Open the task's Files list")
            }
        }
        .padding(.top, 2)
    }

    private func overflowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
        }
        .buttonStyle(.plain)
    }

    private func groupedPaths(_ visiblePaths: ArraySlice<String>) -> [(title: String, paths: [String])] {
        let grouped = Dictionary(grouping: visiblePaths, by: groupTitle(for:))
        return ["Task docs", "Project changes"].compactMap { title in
            guard let paths = grouped[title], !paths.isEmpty else { return nil }
            return (title, paths)
        }
    }

    private func groupTitle(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["plan.md", "guidelines.md", "status_report.md", "pr_review_analysis.md", "pr_description.md"].contains(name) ||
            ["md", "markdown", "qmd", "txt", "html", "htm", "pdf"].contains(ext) {
            return "Task docs"
        }
        return "Project changes"
    }
}
