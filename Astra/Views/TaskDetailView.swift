import SwiftUI
import ASTRACore
import ASTRAModels

struct DiffsTabView: View {
    let task: AgentTask
    @State private var selectedChange: StoredFileChange?
    @State private var latestRun: TaskRun?

    private func rebuildLatestRun() {
        latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    var changes: [StoredFileChange] {
        latestRun?.fileChanges ?? []
    }

    var body: some View {
        Group {
        if changes.isEmpty {
            ContentUnavailableView("No File Changes", systemImage: "doc.text.magnifyingglass",
                                   description: Text("File changes will appear here when the agent writes or edits files."))
        } else {
            HSplitView {
                // File list
                List(changes, selection: $selectedChange) { change in
                    HStack {
                        Image(systemName: change.kind == .write ? "doc.badge.plus" : "pencil")
                            .foregroundStyle(change.kind == .write ? Stanford.paloAltoGreen : Stanford.poppy)
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: change.path).lastPathComponent)
                                .font(Stanford.body(15))
                            Text(change.path)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .tag(change)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedChange = change }
                }
                .frame(minWidth: 180, maxWidth: 250)

                // Diff detail
                if let change = selectedChange {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(change.changeType, systemImage: change.kind == .write ? "doc.badge.plus" : "pencil")
                                    .font(Stanford.ui(15, weight: .semibold))
                                Spacer()
                                Text(change.timestamp, style: .time)
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }

                            Text(change.path)
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)

                            if change.kind == .write {
                                if let content = change.content {
                                    Text("New file content:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(.secondary)
                                    Text(content)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffAdded.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            } else {
                                if let oldStr = change.oldString {
                                    Text("Removed:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(Stanford.diffRemoved)
                                    Text(oldStr)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffRemoved.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                if let newStr = change.newString {
                                    Text("Added:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(Stanford.diffAdded)
                                    Text(newStr)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffAdded.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text",
                                           description: Text("Select a file from the list to view changes."))
                }
            }
        }
        } // Group
        .onAppear { rebuildLatestRun() }
        .onChange(of: task.runs.count) { rebuildLatestRun() }
    }
}
