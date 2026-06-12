// Diff viewer for the repository panel: the changed-file diff sheet and the
// line/hunk rendering it relies on. Extracted from WorkspaceGitSectionView to
// keep that owner file within its architecture-fitness line budget.

import SwiftUI
import ASTRAGitContracts

struct ChangedFileDiffSheet: View {
    let diff: GitFileDiff
    let isLoading: Bool
    let onOpenFile: () -> Void
    let onCopyDiff: () -> Void
    let onApplyHunk: (String) -> Void
    let onStageToggle: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanded = false

    private var stageLabel: String {
        diff.file.isStaged ? "Unstage file" : "Stage file"
    }

    private var canOpenFile: Bool {
        !diff.file.isDeleted && diff.kind != .unavailable
    }

    private var canCopyDiff: Bool {
        diff.hasDiff
    }

    private var hunkActionLabel: String {
        diff.kind == .staged ? "Unstage hunk" : "Stage hunk"
    }

    private var canApplyHunks: Bool {
        diff.hasDiff
            && !diff.file.isConflict
            && diff.kind != .untracked
            && diff.kind != .unavailable
    }

    private var hunks: [RepositoryDiffPresentation.Hunk] {
        guard canApplyHunks else { return [] }
        return RepositoryDiffPresentation.hunks(from: diff.diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: isExpanded ? 900 : 660,
            idealWidth: isExpanded ? 1120 : 820,
            maxWidth: isExpanded ? 1400 : 980,
            minHeight: isExpanded ? 640 : 440,
            idealHeight: isExpanded ? 820 : 560,
            maxHeight: isExpanded ? 1000 : 720
        )
        .background(Stanford.cardBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            statusBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(diff.file.displayPath)
                    .font(Stanford.ui(14, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Use compact diff view" : "Expand diff view")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Stanford.ui(11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !diff.hasDiff {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading diff...")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diff.hasDiff {
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    diffScrollContent(availableWidth: proxy.size.width)
                        .frame(minWidth: max(0, proxy.size.width), alignment: .topLeading)
                }
                .background(Stanford.panelBackground.opacity(0.72))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: messageIcon)
                    .font(Stanford.ui(22, weight: .medium))
                    .foregroundStyle(messageColor)
                Text(diff.message ?? "No textual diff is available for this file.")
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func diffScrollContent(availableWidth: CGFloat) -> some View {
        if hunks.isEmpty {
            DiffLinesView(
                lines: RepositoryDiffPresentation.lines(from: diff.diff),
                minimumWidth: max(0, availableWidth - 24)
            )
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hunks) { hunk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Hunk")
                                .font(Stanford.caption(11).weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(hunkActionLabel) {
                                onApplyHunk(hunk.patch)
                            }
                            .font(Stanford.caption(11).weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(minWidth: max(0, availableWidth - 44), alignment: .leading)

                        DiffLinesView(lines: hunk.lines, minimumWidth: max(0, availableWidth - 44))
                    }
                    .padding(10)
                    .frame(minWidth: max(0, availableWidth - 24), alignment: .leading)
                    .background(Stanford.panelBackground.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if diff.isTruncated {
                Label("Diff truncated", systemImage: "scissors")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusWarn)
            } else if diff.file.isDeleted {
                Label("File deleted", systemImage: "trash")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusError)
            } else if diff.file.isConflict {
                Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusError)
            }

            Spacer(minLength: 10)

            Button(action: onCopyDiff) {
                Label("Copy diff", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canCopyDiff)

            Button(action: onOpenFile) {
                Label("Open file", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canOpenFile)

            Button(action: onStageToggle) {
                Label(stageLabel, systemImage: diff.file.isStaged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(diff.file.isConflict)
        }
        .font(Stanford.caption(12).weight(.medium))
        .padding(12)
    }

    private var statusBadge: some View {
        Text(diff.file.status)
            .font(Stanford.caption(10).weight(.bold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var subtitle: String {
        switch diff.kind {
        case .staged: "Staged diff"
        case .unstaged: "Working tree diff"
        case .untracked: "Untracked file preview"
        case .unavailable: "Diff unavailable"
        }
    }

    private var statusColor: Color {
        if diff.file.isConflict { return Stanford.statusError }
        switch diff.file.status {
        case "A", "?": return Stanford.statusHealthy
        case "M": return Stanford.statusWarn
        case "D": return Stanford.statusError
        default: return Stanford.statusInfo
        }
    }

    private var messageIcon: String {
        diff.kind == .unavailable ? "exclamationmark.triangle" : "doc.text.magnifyingglass"
    }

    private var messageColor: Color {
        diff.kind == .unavailable ? Stanford.statusWarn : .secondary
    }
}

struct RepositoryDiffPresentation {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case addition
            case deletion
            case hunkHeader
            case fileHeader
            case context
        }

        let id: Int
        let text: String
        let kind: Kind
    }

    struct Hunk: Identifiable, Equatable {
        let id: Int
        let patch: String
        let lines: [Line]
    }

    static func lines(from text: String) -> [Line] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .enumerated()
            .map { offset, line in
                Line(id: offset, text: line, kind: kind(for: line))
            }
    }

    static func hunks(from diff: String) -> [Hunk] {
        let diffLines = diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var header: [String] = []
        var current: [String] = []
        var result: [Hunk] = []

        func finishCurrent() {
            guard !current.isEmpty else { return }
            let patch = (header + current).joined(separator: "\n") + "\n"
            result.append(Hunk(id: result.count, patch: patch, lines: lines(from: current.joined(separator: "\n"))))
            current = []
        }

        for line in diffLines {
            if line.hasPrefix("diff --git ") {
                finishCurrent()
                header = [line]
            } else if line.hasPrefix("@@ ") {
                finishCurrent()
                current = [line]
            } else if current.isEmpty {
                header.append(line)
            } else {
                current.append(line)
            }
        }
        finishCurrent()
        return result
    }

    static func kind(for line: String) -> Line.Kind {
        if line.hasPrefix("@@ ") {
            return .hunkHeader
        }
        if line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ") {
            return .fileHeader
        }
        if line.hasPrefix("+") {
            return .addition
        }
        if line.hasPrefix("-") {
            return .deletion
        }
        return .context
    }
}

struct DiffLinesView: View {
    let lines: [RepositoryDiffPresentation.Line]
    let minimumWidth: CGFloat

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(lines) { line in
                DiffLineRow(line: line, minimumWidth: minimumWidth)
            }
        }
        .textSelection(.enabled)
        .frame(minWidth: minimumWidth, alignment: .leading)
    }
}

struct DiffLineRow: View {
    let line: RepositoryDiffPresentation.Line
    let minimumWidth: CGFloat

    var body: some View {
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 8) {
            Text(prefix)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .trailing)

            Text(displayText)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(minWidth: minimumWidth, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var displayText: String {
        line.text.isEmpty ? " " : line.text
    }

    private var prefix: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .hunkHeader: "@@"
        case .fileHeader: ">"
        case .context: " "
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded
        case .deletion: Stanford.diffRemoved
        case .hunkHeader: Stanford.lagunita
        case .fileHeader: .secondary
        case .context: .primary.opacity(0.92)
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded
        case .deletion: Stanford.diffRemoved
        case .hunkHeader: Stanford.lagunita
        case .fileHeader: Stanford.statusInfo
        case .context: .secondary.opacity(0.55)
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded.opacity(0.13)
        case .deletion: Stanford.diffRemoved.opacity(0.13)
        case .hunkHeader: Stanford.lagunita.opacity(0.15)
        case .fileHeader: Color.primary.opacity(0.045)
        case .context: Color.clear
        }
    }
}
