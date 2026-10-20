import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

// MARK: - Skills Tab

struct SkillsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    var onManageCapabilities: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSkill: Skill?
    @State private var retirementError: String?
    @State private var retirementRecoveryID: UUID?

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var workspaceSkills: [Skill] {
        workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn }.sorted { $0.name < $1.name }
    }

    private var sharedLibrarySkills: [Skill] {
        globalSkills.filter { globalSkill in
            !globalSkill.isSystemBuiltIn &&
            !workspaceSkills.contains { $0.id == globalSkill.id }
        }
        .sorted { $0.name < $1.name }
    }

    private var hasVisibleSkills: Bool {
        !workspaceSkills.isEmpty || !sharedLibrarySkills.isEmpty
    }

    var body: some View {
        let showingDetail = selectedSkill != nil
        let enabledSkillIDs = Set(WorkspaceCapabilityActivation.state(of: workspace).globalSkillIDs)

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(Stanford.heading(18))

                    Text("Intent & Behavior")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if showingDetail {
                        Button {
                            selectedSkill = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(Stanford.body(13))
                        }
                    } else {
                        Button { onManageCapabilities() } label: {
                            Label("Manage Capabilities", systemImage: "square.grid.2x2")
                                .font(Stanford.body(13))
                        }

                        Button { createSkill() } label: {
                            Label("New Skill", systemImage: "plus")
                                .font(Stanford.body(13))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
            if let retirementError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(retirementError)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.red)
                    if let retirementRecoveryID {
                        Button("Finish recovery") { finishRetirementRecovery(retirementRecoveryID) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            ZStack(alignment: .topLeading) {
                if let skill = selectedSkill {
                    SkillEditorView(skill: skill, workspace: workspace, onDelete: {
                        deleteSkill(skill)
                    })
                } else if !hasVisibleSkills {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        if !workspaceSkills.isEmpty {
                            ConfigureSelectionSection("Workspace Skills") {
                                ForEach(workspaceSkills) { skill in
                                    ConfigureSelectionCard {
                                        Button {
                                            selectedSkill = skill
                                        } label: {
                                            HStack(spacing: 12) {
                                                skillRow(skill)
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .font(Stanford.ui(11, weight: .semibold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !sharedLibrarySkills.isEmpty {
                            ConfigureSelectionSection("Shared Library") {
                                ForEach(sharedLibrarySkills) { skill in
                                    let enabled = enabledSkillIDs.contains(skill.id.uuidString)

                                    ConfigureSelectionCard {
                                        HStack(spacing: 12) {
                                            Button {
                                                selectedSkill = skill
                                            } label: {
                                                HStack(spacing: 12) {
                                                    skillRow(skill)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "chevron.right")
                                                        .font(Stanford.ui(11, weight: .semibold))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .buttonStyle(.plain)

                                            Button(enabled ? "Disable" : "Enable") {
                                                toggleGlobalSkill(skill)
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let skill = workspace.skills.first(where: { $0.id == focusItemID }) {
                selectedSkill = skill
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.skills.color.opacity(0.5))
            Text("No Skills Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Skills define what your agent can do — which tools it can use, behavioral instructions, and attached connectors and tools.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    createSkill()
                } label: {
                    Label("Create Blank", systemImage: "plus")
                        .font(Stanford.body(14))
                }

                Button {
                    onManageCapabilities()
                } label: {
                    Label("Manage Capabilities", systemImage: "square.grid.2x2")
                        .font(Stanford.body(14))
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.skills.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func skillRow(_ skill: Skill) -> some View {
        let subtitle = skill.skillDescription.isEmpty
            ? "\(skill.allowedTools.count) capabilities configured"
            : skill.skillDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(
                    systemName: skill.icon,
                    color: skill.isGlobal ? Stanford.poppy : ConfigureTab.skills.color
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name.isEmpty ? "Untitled" : skill.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(subtitle)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: "\(skill.allowedTools.count) capabilities")
                if !skill.connectors.isEmpty {
                    ConfigureCardChip(title: "\(skill.connectors.count) connector\(skill.connectors.count == 1 ? "" : "s")")
                }
                if !skill.localTools.isEmpty {
                    ConfigureCardChip(title: "\(skill.localTools.count) tool\(skill.localTools.count == 1 ? "" : "s")")
                }
            }
        }
    }

    private func createSkill() {
        let skill = Skill(name: "New Skill", allowedTools: Skill.defaultAllowed)
        skill.workspace = workspace
        modelContext.insert(skill)
        selectedSkill = skill
        CapabilityPersistence.saveResourceMutation(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillCreated, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "allowed_tools_count": String(skill.allowedTools.count)
        ])
    }

    private func toggleGlobalSkill(_ skill: Skill) {
        let idString = skill.id.uuidString
        WorkspaceCapabilityActivation.mutate(workspace) { $0.toggleGlobalSkill(idString) }
        workspace.updatedAt = Date()
        CapabilityPersistence.saveResourceMutation(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillToolPermissionChanged, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "enabled_global": String(WorkspaceCapabilityActivation.state(of: workspace).globalSkillIDs.contains(idString))
        ])
    }

    private func deleteSkill(_ skill: Skill) {
        let wasSelected = selectedSkill?.id == skill.id
        WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace, modelContext: modelContext)
        do {
            try SkillRetirement.remove(skill, modelContext: modelContext)
            if wasSelected { selectedSkill = nil }
            retirementError = nil
            retirementRecoveryID = nil
        } catch let problem as PluginOperationProblem {
            // The row may already be deleted. Keep recovery available outside
            // its editor rather than trying to restore an unproved domain save.
            selectedSkill = nil
            showRetirementError(problem)
        } catch { showRetirementError(error) }
    }

    private func finishRetirementRecovery(_ id: UUID) {
        do {
            try SkillRetirement.recover(id, modelContext: modelContext)
            retirementError = nil
            retirementRecoveryID = nil
        } catch {
            showRetirementError(error)
            retirementRecoveryID = id
        }
    }

    private func showRetirementError(_ error: Error) {
        retirementRecoveryID = nil
        if let problem = error as? PluginOperationProblem, case .savedRecoveryPending(let id) = problem {
            retirementRecoveryID = id
        }
        retirementError = error.localizedDescription
    }

}
