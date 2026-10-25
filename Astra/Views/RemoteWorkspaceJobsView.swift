import SwiftUI
import SwiftData
import ASTRAModels
import WorkspaceToolSupport

struct RemoteWorkspaceJobsView: View {
    let task: AgentTask
    @Environment(\.modelContext) private var modelContext
    @State private var monitor = RemoteWorkspaceJobMonitor.shared
    @State private var expanded = false
    @State private var output = RemoteWorkspaceJobOutputState()

    var body: some View {
        let state = monitor.presentation(task: task, context: modelContext)
        if !state.jobs.isEmpty || state.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "network")
                    Text("Remote jobs").font(.headline)
                    Text("\(state.jobs.count)").foregroundStyle(.secondary)
                    Spacer()
                    if state.refreshing { ProgressView().controlSize(.small) }
                    Button("Check now") { Task { await monitor.refresh(task: task, context: modelContext) } }
                        .disabled(state.refreshing)
                    Button(expanded ? "Less" : "Details") { expanded.toggle() }
                }
                ForEach(state.jobs, id: \.jobID) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(job.label ?? job.connectionTarget).lineLimit(1)
                            Spacer()
                            Text(job.cancellationRequestedAt != nil && !job.status.isTerminal ? "Cancellation pending" : job.status.rawValue)
                            if !job.status.isTerminal {
                                Button("Cancel job") { monitor.requestCancellation(task: task, jobID: job.jobID, context: modelContext) }
                                    .disabled(job.cancellationRequestedAt != nil)
                                    .accessibilityLabel("Cancel \(job.label ?? job.jobID)")
                                    .accessibilityIdentifier("RemoteJobCancel_\(job.jobID)")
                            }
                        }
                        if let verified = job.lastVerifiedAt {
                            Text("Last checked \(verified.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Waiting for a complete SSH reply.").font(.caption).foregroundStyle(.secondary) }
                        if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        if let error = job.lastObservation?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        if expanded {
                            Text(job.command).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                            Button("Read output") {
                                let requestID = output.begin(taskID: task.id, jobID: job.jobID, label: job.label ?? job.jobID)
                                Task {
                                    let text = await monitor.tail(task: task, jobID: job.jobID, context: modelContext)
                                    output.complete(requestID: requestID, text: text)
                                }
                            }
                                .accessibilityLabel("Read output for \(job.label ?? job.jobID)")
                                .accessibilityIdentifier("RemoteJobOutput_\(job.jobID)")
                        }
                    }
                }
                Text("ASTRA keeps the workspace reserved: SSH job results cannot confirm that detached or external tools have stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if expanded, let selection = output.visible(for: task.id) {
                    Text("Output for \(selection.label)").font(.caption.bold())
                    ScrollView {
                        Text(selection.text.map { $0.isEmpty ? "No output yet." : $0 } ?? "Loading output…")
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 140)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}
