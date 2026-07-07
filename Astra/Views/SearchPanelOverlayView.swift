import SwiftUI
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

// MARK: - Search Panel Overlay
//
// Extracted from TaskSidebarView.swift: the overlay is a self-contained
// surface (own query, own state, own dismissal) and the sidebar file sits
// against its architecture line budget.

struct SearchPanelOverlayContainer: View {
    @Query(sort: \AgentTask.queuePosition) private var tasks: [AgentTask]

    let workspaces: [Workspace]
    @Binding var selectedTask: AgentTask?
    @Binding var selectedWorkspace: Workspace?
    @Binding var isActive: Bool

    var body: some View {
        SearchPanelOverlay(
            tasks: tasks,
            workspaces: workspaces,
            selectedTask: $selectedTask,
            selectedWorkspace: $selectedWorkspace,
            isActive: $isActive
        )
    }
}

struct SearchPanelOverlay: View {
    let tasks: [AgentTask]
    let workspaces: [Workspace]
    @Binding var selectedTask: AgentTask?
    @Binding var selectedWorkspace: Workspace?
    @Binding var isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    @State private var selectedIndex = 0

    private var presentationAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private func dismiss() {
        withAnimation(presentationAnimation) {
            isActive = false
            searchText = ""
        }
    }

    private var recentTasks: [AgentTask] {
        SearchPanelOverlayResults.recentTasks(tasks, workspaces: workspaces)
    }

    private var filteredTasks: [AgentTask] {
        SearchPanelOverlayResults.filteredTasks(searchText: searchText, tasks: tasks, workspaces: workspaces)
    }

    private var filteredWorkspaces: [Workspace] {
        SearchPanelOverlayResults.filteredWorkspaces(
            searchText: searchText,
            workspaces: workspaces,
            taskCount: tasks.count
        )
    }

    private func toggleStarred(for workspace: Workspace) {
        workspace.isStarred.toggle()
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func togglePinned(for task: AgentTask) {
        task.isPinned.toggle()
        task.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    var body: some View {
        ZStack {
            Stanford.scrim.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(Stanford.ui(15))
                        .foregroundStyle(.secondary)

                    TextField("Search tasks and workspaces", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Stanford.ui(16))
                        .focused($isFocused)
                        .onSubmit {
                            if let task = filteredTasks.first {
                                selectedTask = task
                                dismiss()
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                // Results
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !filteredWorkspaces.isEmpty {
                            Text("Workspaces")
                                .font(Stanford.caption(11).weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            ForEach(filteredWorkspaces) { ws in
                                HStack(spacing: 6) {
                                    Button {
                                        selectedWorkspace = ws
                                        selectedTask = nil
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "folder.fill")
                                                .font(Stanford.ui(13))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 18)
                                            Text(ws.name)
                                                .font(Stanford.ui(14))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(ws.name)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        toggleStarred(for: ws)
                                    } label: {
                                        Image(systemName: ws.isStarred ? "star.fill" : "star")
                                            .font(Stanford.ui(13, weight: .semibold))
                                            .foregroundStyle(ws.isStarred ? Stanford.lagunita : .secondary)
                                            .frame(width: 26, height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(ws.isStarred ? "Unstar workspace" : "Star workspace")
                                    .accessibilityLabel(ws.isStarred ? "Unstar \(ws.name)" : "Star \(ws.name)")
                                }
                                .padding(.leading, 16)
                                .padding(.trailing, 12)
                                .padding(.vertical, 7)
                            }
                        }

                        Text(searchText.isEmpty ? "Recent tasks" : "Tasks")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, filteredWorkspaces.isEmpty ? 10 : 14)
                            .padding(.bottom, 4)

                        ForEach(Array(filteredTasks.enumerated()), id: \.element.id) { idx, task in
                            HStack(spacing: 6) {
                                Button {
                                    selectedTask = task
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "bubble.left")
                                            .font(Stanford.ui(13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        SidebarTaskTitleText(
                                            presentation: Formatters.sidebarTaskTitlePresentation(task.title),
                                            font: Stanford.ui(14, weight: task.shouldShowUnread ? .semibold : .regular)
                                        )
                                        .layoutPriority(1)
                                        Spacer()
                                        if let ws = task.workspace {
                                            Text(Formatters.shortenIdentifierTokens(ws.name, maxTokenLength: 24, keepEachSide: 8))
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .help(ws.name)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    togglePinned(for: task)
                                } label: {
                                    Image(systemName: task.isPinned ? "pin.fill" : "pin")
                                        .font(Stanford.ui(13, weight: .semibold))
                                        .foregroundStyle(task.isPinned ? Stanford.lagunita : .secondary)
                                        .frame(width: 26, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(task.isPinned ? "Unpin task" : "Pin task")
                                .accessibilityLabel(task.isPinned ? "Unpin \(task.title)" : "Pin \(task.title)")
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 12)
                            .padding(.vertical, 7)
                            .background(idx == selectedIndex ? Color.primary.opacity(0.06) : .clear)
                        }

                        if filteredTasks.isEmpty && filteredWorkspaces.isEmpty {
                            HStack {
                                Spacer()
                                Text("No results found")
                                    .font(Stanford.ui(13))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 350)
            }
            .frame(width: 520)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
            .onExitCommand { dismiss() }
            .onAppear { isFocused = true }
            .onChange(of: searchText) { _, _ in selectedIndex = 0 }
        }
        .transition(.opacity)
    }
}
