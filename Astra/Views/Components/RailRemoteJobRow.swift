// The rail's Remote jobs box: one row per SSH job the selected task started,
// expanding in place to its last check, message, command and output. Kept out
// of WorkspaceRightRailView so that owner file stays under its line budget.

import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport

private typealias RailLayout = WorkspaceRailSectionPresentation.Layout

struct RailRemoteJobRow: View {
    let row: WorkspaceRailSectionPresentation.Row
    let task: AgentTask
    let job: RemoteWorkspaceJobRecord
    /// Another task's request waits on this task's jobs: they stay checked.
    var awaited = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor = RemoteWorkspaceJobMonitor.shared
    @State private var isExpanded = false
    @State private var output = RemoteWorkspaceJobOutputState()

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 6 : 0) {
            Button {
                withAnimation(AstraMotion.disclosure(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    CapabilityLeadingIcon(systemImage: row.systemImage, brand: nil, pointSize: RailLayout.leadingIconFontSize)
                        .foregroundStyle(.secondary)
                        .frame(width: RailLayout.leadingIconFrame)
                    // Labels share prefixes ("… attempt 2"): keep both ends.
                    Text(row.title)
                        .font(Stanford.ui(RailLayout.rowTitleFontSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let status = row.value {
                        Text(status)
                            .font(Stanford.caption(RailLayout.rowValueFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                }
                .frame(maxWidth: .infinity, minHeight: RailLayout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.title)
            .accessibilityValue(row.value ?? "")
            .padding(.leading, 6)
            .padding(.trailing, 4)

            if isExpanded {
                details
                    .padding(.leading, RailLayout.leadingIconFrame + 8 + 6)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let verified = job.lastVerifiedAt {
                    Text("Last checked \(verified.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Waiting for a complete SSH reply.")
                }
                if WorkspaceRailRemoteJobPresentation.isSettled(job, awaited: awaited) {
                    Text("ASTRA no longer checks this job by itself. Use Refresh to check it now.")
                }
                if let message = job.message { Text(message) }
                if let error = job.lastObservation?.error { Text(error) }
                Text("ASTRA keeps the workspace reserved: SSH job results cannot confirm that detached or external tools have stopped.")
                    .foregroundStyle(.tertiary)
            }
            .font(Stanford.caption(RailLayout.rowValueFontSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(job.command)
                .font(Stanford.mono(RailLayout.rowValueFontSize - 0.5))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Read output", action: readOutput)
                    .accessibilityLabel("Read output for \(row.title)")
                    .accessibilityIdentifier("RemoteJobOutput_\(job.jobID)")
                if WorkspaceRailRemoteJobPresentation.canCancel(job) {
                    Button("Cancel job") { monitor.requestCancellation(task: task, jobID: job.jobID, context: modelContext) }
                        .accessibilityLabel("Cancel \(row.title)")
                        .accessibilityIdentifier("RemoteJobCancel_\(job.jobID)")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)

            if let selection = output.visible(for: task.id) {
                ScrollView {
                    Text(selection.text.map { $0.isEmpty ? "No output yet." : $0 } ?? "Loading output…")
                        .font(Stanford.mono(RailLayout.rowValueFontSize - 0.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
        }
    }

    private func readOutput() {
        let requestID = output.begin(taskID: task.id, jobID: job.jobID, label: row.title)
        Task {
            let text = await monitor.tail(task: task, jobID: job.jobID, context: modelContext)
            output.complete(requestID: requestID, text: text)
        }
    }
}

/// The box's closing note while the last check failed.
struct RailRemoteJobsFootnote: View {
    let checkError: String

    var body: some View {
        Text(checkError)
            .foregroundStyle(.secondary)
            .font(Stanford.caption(RailLayout.rowValueFontSize))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}
