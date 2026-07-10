import SwiftUI
import ASTRAModels
import ASTRAPersistence
import ASTRACore

struct TaskCheckpointSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let run: TaskRunSnapshot
    let stepNumber: Int
    let statusText: String
    let completedText: String
    let durationText: String
    let tokenText: String
    let fileCount: Int
    let outputPreview: String

    var title: String {
        "Step \(stepNumber)"
    }

    var subtitle: String {
        let parts = [statusText, completedText, tokenText]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " - ")
    }
}

struct TaskCheckpointComparison: Equatable, Sendable {
    let selected: TaskCheckpointSummary
    let includedRunCount: Int
    let excludedRunCount: Int
    let includedTokenCount: Int
    let excludedTokenCount: Int
    let includedFileCount: Int
    let excludedFileCount: Int
    let includedFiles: [String]
    let excludedFiles: [String]
    let laterOutputPreview: String
    let canRestore: Bool
    let restoreDisabledReason: String?

    var branchSummary: String {
        if excludedRunCount == 0 {
            return "This checkpoint is the current branch tip."
        }
        return "\(excludedRunCount) later step\(excludedRunCount == 1 ? "" : "s") will stay on the current task."
    }
}

enum TaskCheckpointPresentation {
    static let restoreActionTitle = "Fork Conversation"
    static let sectionTitle = "Checkpoints"

    static func summaries(from runs: [TaskRunSnapshot]) -> [TaskCheckpointSummary] {
        runs.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
            .enumerated()
            .map { index, run in
                TaskCheckpointSummary(
                    id: run.id,
                    run: run,
                    stepNumber: index + 1,
                    statusText: statusText(for: run.status),
                    completedText: completedText(for: run),
                    durationText: durationText(for: run),
                    tokenText: tokenText(for: run.tokensUsed),
                    fileCount: uniqueFilePaths(in: run).count,
                    outputPreview: preview(run.output, maxCharacters: 220)
                )
            }
    }

    static func comparison(
        for selectedID: UUID?,
        in summaries: [TaskCheckpointSummary]
    ) -> TaskCheckpointComparison? {
        guard !summaries.isEmpty else { return nil }
        let selected = summaries.first { $0.id == selectedID } ?? summaries.last!
        guard let selectedIndex = summaries.firstIndex(where: { $0.id == selected.id }) else {
            return nil
        }

        let included = Array(summaries.prefix(through: selectedIndex))
        let excluded = Array(summaries.dropFirst(selectedIndex + 1))
        let restoreDisabledReason = restoreDisabledReason(for: selected.run)
        let includedFiles = filePaths(in: included)
        let excludedFiles = filePaths(in: excluded)

        return TaskCheckpointComparison(
            selected: selected,
            includedRunCount: included.count,
            excludedRunCount: excluded.count,
            includedTokenCount: included.reduce(0) { $0 + $1.run.tokensUsed },
            excludedTokenCount: excluded.reduce(0) { $0 + $1.run.tokensUsed },
            includedFileCount: includedFiles.count,
            excludedFileCount: excludedFiles.count,
            includedFiles: includedFiles,
            excludedFiles: excludedFiles,
            laterOutputPreview: preview(
                excluded.reversed().first { !$0.run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.run.output ?? "",
                maxCharacters: 220
            ),
            canRestore: restoreDisabledReason == nil,
            restoreDisabledReason: restoreDisabledReason
        )
    }

    static func statusText(for status: RunStatus) -> String {
        switch status {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .timeout:
            return "Timed out"
        case .budgetExceeded:
            return "Budget exceeded"
        }
    }

    private static func restoreDisabledReason(for run: TaskRunSnapshot) -> String? {
        run.status == .running ? "Wait for this step to finish before restoring from it." : nil
    }

    private static func completedText(for run: TaskRunSnapshot) -> String {
        guard let completedAt = run.completedAt else {
            return "In progress"
        }
        return completedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private static func durationText(for run: TaskRunSnapshot) -> String {
        guard let completedAt = run.completedAt else { return "" }
        let seconds = max(0, Int(completedAt.timeIntervalSince(run.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func tokenText(for tokens: Int) -> String {
        guard tokens > 0 else { return "" }
        return Formatters.formatTokens(tokens)
    }

    private static func filePaths(in summaries: [TaskCheckpointSummary]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for summary in summaries {
            for path in uniqueFilePaths(in: summary.run) {
                guard seen.insert(path).inserted else { continue }
                paths.append(path)
            }
        }

        return paths
    }

    private static func uniqueFilePaths(in run: TaskRunSnapshot) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for change in run.fileChanges {
            guard seen.insert(change.path).inserted else { continue }
            paths.append(change.path)
        }

        return paths
    }

    private static func preview(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty else { return "No visible text output." }
        if normalized.count <= maxCharacters { return normalized }
        return String(normalized.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

struct TaskCheckpointBrowserSheet: View {
    let task: AgentTask
    let snapshot: TaskThreadSnapshot
    let onRestore: (TaskRunSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRunID: UUID?

    private var summaries: [TaskCheckpointSummary] {
        TaskCheckpointPresentation.summaries(from: snapshot.sortedRuns)
    }

    private var comparison: TaskCheckpointComparison? {
        TaskCheckpointPresentation.comparison(for: selectedRunID, in: summaries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if summaries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    checkpointList
                        .frame(width: 280)
                    Divider()
                    comparisonPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Stanford.panelBackground)
        .onAppear(perform: ensureSelection)
        .onChange(of: summaries.map(\.id)) { _, _ in ensureSelection() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Stanford.ui(22, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(TaskCheckpointPresentation.sectionTitle)
                    .font(Stanford.ui(20, weight: .semibold))
                    .foregroundStyle(Stanford.black)
                Text(task.isForked ? "Forked task - compare branch history" : "Browse, compare, and restore task branch points")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
    }

    private var checkpointList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(summaries) { summary in
                    checkpointRow(summary)

                    if summary.id != summaries.last?.id {
                        Divider()
                            .padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(.regularMaterial.opacity(0.35))
    }

    private func checkpointRow(_ summary: TaskCheckpointSummary) -> some View {
        let isSelected = (selectedRunID ?? summaries.last?.id) == summary.id

        return Button {
            selectedRunID = summary.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: summary.run.status == .running ? "circle.dashed" : "arrow.triangle.branch")
                    .font(Stanford.ui(16, weight: .medium))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle()
                            .fill(isSelected ? Stanford.lagunita.opacity(0.12) : Color.clear)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title)
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    Text(combinedRowSubtitle(for: summary))
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(combinedRowSubtitle(for: summary))
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall)
                        .fill(Stanford.lagunita.opacity(0.08))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.title), \(summary.subtitle)")
    }

    @ViewBuilder
    private var comparisonPane: some View {
        if let comparison {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    comparisonHeader(comparison)
                    factGrid(comparison)
                    compareSection(
                        title: "Conversation Included Up To Checkpoint",
                        subtitle: "\(comparison.includedRunCount) step\(comparison.includedRunCount == 1 ? "" : "s") copied into the new conversation.",
                        files: comparison.includedFiles,
                        fileCount: comparison.includedFileCount,
                        outputPreview: comparison.selected.outputPreview
                    )
                    compareSection(
                        title: "After Checkpoint",
                        subtitle: comparison.branchSummary,
                        files: comparison.excludedFiles,
                        fileCount: comparison.excludedFileCount,
                        outputPreview: comparison.laterOutputPreview
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func comparisonHeader(_ comparison: TaskCheckpointComparison) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(comparison.selected.title)
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(Stanford.black)
                Text(comparison.selected.subtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                if task.isForked {
                    Text("This task was already forked at source step \(task.forkedAtRunIndex + 1).")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    onRestore(comparison.selected.run)
                    dismiss()
                } label: {
                    Label(TaskCheckpointPresentation.restoreActionTitle, systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!comparison.canRestore)
                .help(comparison.restoreDisabledReason ?? "Create a new conversation from this checkpoint")

                if let reason = comparison.restoreDisabledReason {
                    Text(reason)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }
        }
    }

    private func factGrid(_ comparison: TaskCheckpointComparison) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 120), spacing: 10),
                GridItem(.flexible(minimum: 120), spacing: 10),
                GridItem(.flexible(minimum: 120), spacing: 10),
                GridItem(.flexible(minimum: 120), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            factCell(title: "Kept", value: "\(comparison.includedRunCount) steps", icon: "checkmark.circle")
            factCell(title: "Later", value: "\(comparison.excludedRunCount) steps", icon: "clock")
            factCell(title: "Kept Tokens", value: Formatters.formatTokens(comparison.includedTokenCount), icon: "number")
            factCell(title: "Later Tokens", value: Formatters.formatTokens(comparison.excludedTokenCount), icon: "number")
            factCell(title: "Kept Files", value: "\(comparison.includedFileCount)", icon: "doc.text")
            factCell(title: "Later Files", value: "\(comparison.excludedFileCount)", icon: "doc.text")
        }
    }

    private func factCell(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
    }

    private func compareSection(
        title: String,
        subtitle: String,
        files: [String],
        fileCount: Int,
        outputPreview: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(Stanford.black)
                Text(subtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(outputPreview)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)

                if fileCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(Stanford.black)

                        ForEach(files.prefix(5), id: \.self) { path in
                            Text(path)
                                .font(Stanford.mono(10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if files.count > 5 {
                            Text("+\(files.count - 5) more")
                                .font(Stanford.caption(10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Stanford.ui(28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No checkpoints yet")
                .font(Stanford.ui(16, weight: .semibold))
                .foregroundStyle(Stanford.black)
            Text("Completed runs will appear here as branch restore points.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func rowDetail(for summary: TaskCheckpointSummary) -> String {
        var parts: [String] = []
        if !summary.durationText.isEmpty {
            parts.append(summary.durationText)
        }
        if summary.fileCount > 0 {
            parts.append("\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " - ")
    }

    /// One quiet subtitle line for the checkpoint row — the status/token summary
    /// plus any duration/file detail, folded together so the collapsed row stays
    /// a single line (full text in the row's .help tooltip).
    private func combinedRowSubtitle(for summary: TaskCheckpointSummary) -> String {
        let detail = rowDetail(for: summary)
        return detail.isEmpty ? summary.subtitle : "\(summary.subtitle) · \(detail)"
    }

    private func ensureSelection() {
        guard !summaries.isEmpty else {
            selectedRunID = nil
            return
        }
        if selectedRunID == nil || !summaries.contains(where: { $0.id == selectedRunID }) {
            selectedRunID = summaries.last?.id
        }
    }
}
