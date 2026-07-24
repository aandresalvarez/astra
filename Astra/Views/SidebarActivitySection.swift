import SwiftUI
import ASTRAModels

/// A cross-workspace supervision surface for live work. Workspace drawers
/// remain the navigation hierarchy; this derived list makes concurrency
/// inspectable without requiring several drawers to be open at once.
struct SidebarActivitySection<Row: View>: View {
    let tasks: [AgentTask]
    let counts: SidebarWorkspaceActivityCounts
    @ViewBuilder let row: (AgentTask) -> Row

    @State private var showsAll = false

    private var visibleTasks: [AgentTask] {
        showsAll ? tasks : Array(tasks.prefix(SidebarLeanPresentation.sectionPreviewLimit))
    }

    var body: some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text("Activity")
                        .font(Stanford.caption(14))
                        .foregroundStyle(.secondary)
                    SidebarCountBadge(count: tasks.count)
                    WorkspaceActivityIndicator(counts: counts)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleTasks, content: row)

                    if tasks.count > visibleTasks.count {
                        disclosureButton("Show \(tasks.count - visibleTasks.count) more") {
                            showsAll = true
                        }
                    } else if showsAll,
                              tasks.count > SidebarLeanPresentation.sectionPreviewLimit {
                        disclosureButton("Show less") { showsAll = false }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 8)
        }
    }

    private func disclosureButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .padding(.leading, SidebarWorkspaceTaskList.showMoreLeadingPadding)
    }
}
