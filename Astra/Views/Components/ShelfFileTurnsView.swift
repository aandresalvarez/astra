import AppKit
import SwiftUI
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

/// Browse files by turn: what each request created, edited, or removed,
/// newest first. The newest turn starts open; a row opens the file's current
/// version.
struct ShelfFileTurnsView: View {
    let task: AgentTask
    let searchText: String
    let selectedPath: String?
    let onOpen: (String) -> Void
    /// Routes HTML and SQL to the Browser and Query shelves, as Folders does.
    var onOpenGeneratedFile: ((String) -> Void)?
    /// Changes when the user asks Browse files to refresh.
    var refreshToken = 0
    /// Browse files' "Show hidden paths": off hides dot-named files and folders.
    var showsHiddenPaths = false

    @Environment(\.modelContext) private var modelContext
    @State private var turns: [TaskFileTurn] = []
    @State private var hasLoaded = false
    /// Turns whose expansion the user flipped from the default.
    @State private var flippedTurns: Set<Int> = []
    /// Turns showing every file rather than the first `entryPreviewLimit`.
    @State private var fullyShownTurns: Set<Int> = []

    private struct RefreshKey: Equatable {
        let taskID: UUID
        let updatedAt: Date
        let refreshToken: Int
    }

    var body: some View {
        let visible = ShelfFileTurnsPresentation.visibleTurns(
            turns,
            matching: searchText,
            showsHiddenPaths: showsHiddenPaths
        )
        VStack(alignment: .leading, spacing: 0) {
            if !hasLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading turns…")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else if visible.isEmpty {
                emptyState
            } else {
                ForEach(visible) { turn in
                    if turn.number != visible.first?.number {
                        Divider().padding(.leading, 29)
                    }
                    turnSection(turn, isExpanded: isExpanded(turn, newest: visible.first?.number))
                }
                if visible.contains(where: \.listsNewFilesOnly) {
                    Text(ShelfFileTurnsPresentation.newFilesOnlyNote)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
        }
        // `updatedAt` moves whenever a run records a change or finishes.
        .task(id: RefreshKey(taskID: task.id, updatedAt: task.updatedAt, refreshToken: refreshToken)) {
            await reload()
        }
        .accessibilityIdentifier("FilesShelfTurnsList")
    }

    private func isExpanded(_ turn: TaskFileTurn, newest: Int?) -> Bool {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return (turn.number == newest) != flippedTurns.contains(turn.number)
    }

    private func turnSection(_ turn: TaskFileTurn, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if flippedTurns.contains(turn.number) {
                    flippedTurns.remove(turn.number)
                } else {
                    flippedTurns.insert(turn.number)
                }
            } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ShelfFileTurnsPresentation.title(for: turn))
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(ShelfFileTurnsPresentation.subtitle(for: turn))
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if turn.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ShelfFileTurnsPresentation.requestTooltip(for: turn))
            .accessibilityIdentifier("FilesShelfTurn-\(turn.number)")

            if isExpanded {
                // The panel's lazy list holds this view as one row, so every
                // row here is built at once; a bulk run's thousands of files
                // wait for the user to ask for them.
                let showsAll = fullyShownTurns.contains(turn.number)
                ForEach(ShelfFileTurnsPresentation.shownEntries(of: turn, showsAll: showsAll)) { entry in
                    entryRow(entry)
                }
                if !showsAll, turn.entries.count > ShelfFileTurnsPresentation.entryPreviewLimit {
                    Button {
                        fullyShownTurns.insert(turn.number)
                    } label: {
                        Text(ShelfFileTurnsPresentation.showAllTitle(for: turn))
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.leading, 43)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("FilesShelfTurnShowAll-\(turn.number)")
                }
            }
        }
    }

    private func entryRow(_ entry: TaskFileTurn.Entry) -> some View {
        let isSelected = selectedPath == entry.path
        let name = (entry.displayPath as NSString).lastPathComponent
        let folder = (entry.displayPath as NSString).deletingLastPathComponent
        let destination = TaskGeneratedFileQuerySeam.required.shelfDestination(for: entry.path)
        return Button {
            onOpen(entry.path)
        } label: {
            HStack(spacing: 7) {
                Color.clear.frame(width: 12, height: 12)

                Image(systemName: destination?.systemImage ?? Formatters.fileIcon(for: entry.path))
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(ShelfFileTurnsPresentation.iconColor(for: destination))
                    .frame(width: 16)

                Text(name)
                    .font(Stanford.caption(12).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .primary)
                    .strikethrough(entry.change == .removed)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if !folder.isEmpty {
                    Text(folder)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                Text(ShelfFileTurnsPresentation.label(for: entry.change))
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Stanford.lagunita.opacity(Stanford.fillTint) : Color.clear)
            .opacity(entry.exists ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!entry.exists)
        .help(ShelfFileTurnsPresentation.entryTooltip(for: entry))
        .contextMenu {
            // The same menu as a file row in Folders.
            if entry.exists {
                Button {
                    onOpen(entry.path)
                } label: {
                    Label("Open in Files", systemImage: "doc.text")
                }
                if let destination, destination != .files, let onOpenGeneratedFile {
                    Button {
                        onOpenGeneratedFile(entry.path)
                    } label: {
                        Label(destination.title, systemImage: destination.systemImage)
                    }
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if entry.exists {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                } label: {
                    Label("Open in Default App", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Stanford.ui(18, weight: .medium))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No file changes yet" : "No matching files")
                .font(Stanford.caption(12).weight(.semibold))
            Text(searchText.isEmpty
                ? "Files each turn creates, edits, or removes appear here."
                : "No turn changed a file with that name.")
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    private func reload() async {
        if hasLoaded {
            // A streaming run records tool changes one at a time; coalesce them.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        // The store is read directly, and a streaming run records its tool
        // changes in the main context unsaved; those runs are handed over as
        // they are rather than saving everything the context holds.
        let pendingRuns = (modelContext.insertedModelsArray + modelContext.changedModelsArray)
            .compactMap { $0 as? TaskRun }
            .filter { $0.task?.id == task.id }
            .map(TaskFileTurnsReader.PendingRun.init)
        let access = TaskWorkspaceAccess(task: task)
        let additionalRoots = ([task.workspace?.primaryPath].compactMap { $0 } + (task.workspace?.additionalPaths ?? []))
            .filter { !$0.isEmpty && $0 != access.effectiveWorkspacePath }
        let store = TaskThreadHistoryStore(container: modelContext.container)
        let started = Date()
        let loaded = (try? await store.fileTurns(
            taskID: task.id,
            taskFolder: access.taskFolder,
            workspacePath: access.effectiveWorkspacePath,
            executionPath: access.codeWorkingDirectory,
            additionalRoots: additionalRoots,
            pendingRuns: pendingRuns
        )) ?? []
        guard !Task.isCancelled else { return }
        turns = loaded
        hasLoaded = true
        AppLogger.debug(
            "file_turns_loaded turns=\(loaded.count) files=\(loaded.reduce(0) { $0 + $1.entries.count }) " +
                "duration_ms=\(Int(Date().timeIntervalSince(started) * 1_000))",
            category: "Performance",
            taskID: task.id
        )
    }
}

/// Copy and filtering for `ShelfFileTurnsView`, kept out of the view so tests
/// can pin them.
enum ShelfFileTurnsPresentation {
    static let newFilesOnlyNote = "Older turns list new files only."

    /// Rows an open turn shows before "Show all".
    static let entryPreviewLimit = 100

    static func shownEntries(of turn: TaskFileTurn, showsAll: Bool) -> ArraySlice<TaskFileTurn.Entry> {
        showsAll ? turn.entries[...] : turn.entries.prefix(entryPreviewLimit)
    }

    static func showAllTitle(for turn: TaskFileTurn) -> String {
        "Show all \(turn.entries.count) files"
    }

    /// The first line the user wrote; a message that was only attachments
    /// reads as such.
    static func title(for turn: TaskFileTurn) -> String {
        let firstLine = turn.request
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty || firstLine.lowercased().hasPrefix("attached files:") {
            return "Attached files"
        }
        return firstLine
    }

    /// `Turn 3 · Today at 2:14 PM · 1 new, 2 edited`
    static func subtitle(for turn: TaskFileTurn, formatter: DateFormatter = requestDateFormatter) -> String {
        var parts = ["Turn \(turn.number)", turn.isRunning ? "Running" : formatter.string(from: turn.requestedAt)]
        let counts = TaskFileTurn.Change.allCases.compactMap { change -> String? in
            let count = turn.entries.filter { $0.change == change }.count
            return count > 0 ? "\(count) \(label(for: change))" : nil
        }
        if !counts.isEmpty {
            parts.append(counts.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Matches the Folders row's tint for the shelf a file opens in.
    static func iconColor(for destination: TaskGeneratedFileShelfDestination?) -> Color {
        switch destination {
        case .browser?: Stanford.sky
        case .query?: Stanford.paloAltoGreen
        case .files?: Stanford.lagunita
        case nil: .secondary
        }
    }

    static func label(for change: TaskFileTurn.Change) -> String {
        switch change {
        case .new: "new"
        case .edited: "edited"
        case .removed: "removed"
        }
    }

    static func requestTooltip(for turn: TaskFileTurn) -> String {
        let request = turn.request.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.count > 500 ? String(request.prefix(500)) + "…" : request
    }

    static func entryTooltip(for entry: TaskFileTurn.Entry, formatter: DateFormatter = requestDateFormatter) -> String {
        guard entry.exists || entry.change == .removed else {
            return "\(entry.path)\nNo longer on disk"
        }
        let verb = switch entry.change {
        case .new: "Created"
        case .edited: "Edited"
        case .removed: "Removed"
        }
        return "\(entry.path)\n\(verb) \(formatter.string(from: entry.changedAt))"
    }

    /// Turns with a file whose path matches, showing only the matches; a
    /// request whose text matches keeps all of its files. Without
    /// `showsHiddenPaths`, dot-named files and folders inside each root are
    /// left out, as the Folders organization leaves them out; a configured
    /// root whose own name starts with a dot is not.
    static func visibleTurns(
        _ turns: [TaskFileTurn],
        matching searchText: String,
        showsHiddenPaths: Bool = true
    ) -> [TaskFileTurn] {
        let shown = showsHiddenPaths ? turns : turns.compactMap { turn -> TaskFileTurn? in
            let entries = turn.entries.filter { entry in
                !entry.pathInRoot.split(separator: "/").contains { $0.hasPrefix(".") }
            }
            guard !entries.isEmpty || turn.isRunning else { return nil }
            return turn.replacingEntries(entries)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return shown }
        return shown.compactMap { turn in
            if turn.request.localizedCaseInsensitiveContains(query) { return turn }
            let matches = turn.entries.filter { $0.displayPath.localizedCaseInsensitiveContains(query) }
            guard !matches.isEmpty else { return nil }
            return turn.replacingEntries(matches)
        }
    }

    static let requestDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private extension TaskFileTurn {
    func replacingEntries(_ entries: [Entry]) -> TaskFileTurn {
        TaskFileTurn(
            number: number,
            request: request,
            requestedAt: requestedAt,
            isRunning: isRunning,
            entries: entries,
            listsNewFilesOnly: listsNewFilesOnly
        )
    }
}
