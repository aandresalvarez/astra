import SwiftUI

/// Shared bottom toolbar for both new-task and follow-up composers.
struct ComposerToolbar: View {
    // MARK: - Required

    let model: String
    let budget: Int
    var skills: [Skill] = []
    var workspace: Workspace?
    let isRunning: Bool
    let hasInput: Bool
    let onAttachFile: () -> Void
    let onPasteClipboard: () -> Void
    let onSend: () -> Void

    // MARK: - Optional callbacks

    var onStop: (() -> Void)?
    var onModelChange: ((String) -> Void)?
    var onBudgetChange: ((Int) -> Void)?
    var onRemoveSkill: ((Skill) -> Void)?
    var onToggleSkill: ((Skill, Bool) -> Void)?
    var onManageSkills: (() -> Void)?

    // MARK: - Permission mode (new task composer)

    @Binding var skipPermissions: Bool
    @Binding var useAgentTeam: Bool
    @Binding var teamSize: Int
    @Binding var isPlanMode: Bool
    var isPlanModeDisabled: Bool = false
    var planModeHelp: String = "Plan and refine before creating a runnable task"

    // MARK: - Submit button style

    var submitIcon: String = "arrow.up.circle.fill"
    var submitTitle: String?          // nil = icon-only send button
    var submitColor: Color = Stanford.cardinalRed
    var showPermissionControls: Bool = false

    // MARK: - SSH connections

    var sshConnections: [SSHConnection] = []

    @State private var isPlusHovered = false

    var body: some View {
        HStack(spacing: 8) {
            plusMenu

            modelBudgetPill

            if showPermissionControls {
                teamModeButton
                planModeToggle
            }

            skillChips

            if !sshConnections.isEmpty {
                sshIndicator
            }

            Spacer()

            submitArea
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Plus Menu

    private var plusMenu: some View {
        Menu {
            Button {
                onAttachFile()
            } label: {
                Label("Add files or photos", systemImage: "paperclip")
            }

            Divider()
            let userSkills = (workspace?.skills ?? []).filter { !$0.isSystemBuiltIn }
            if !userSkills.isEmpty {
                Menu {
                    ForEach(userSkills.sorted { $0.name < $1.name }) { skill in
                        let isEnabled = skills.contains { $0.id == skill.id }
                        Button {
                            onToggleSkill?(skill, !isEnabled)
                        } label: {
                            HStack {
                                Text(skill.name)
                                if isEnabled { Image(systemName: "checkmark") }
                            }
                        }
                    }

                    if onManageSkills != nil {
                        Divider()
                        Button {
                            onManageSkills?()
                        } label: {
                            Label("Manage skills\u{2026}", systemImage: "gearshape")
                        }
                    }
                } label: {
                    Label("Skills", systemImage: "puzzlepiece")
                }
            }
        } label: {
            Text("+")
                .font(Stanford.ui(28, weight: .light))
                .foregroundStyle(isPlusHovered ? Stanford.black : Stanford.coolGrey)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isPlusHovered ? 0.15 : 0.06))
                )
                .animation(.easeInOut(duration: 0.15), value: isPlusHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 38, height: 38)
        .contentShape(Circle())
        .onHover { isPlusHovered = $0 }
    }

    // MARK: - Model / Budget Pill

    private var modelBudgetPill: some View {
        Menu {
            Menu {
                Button { onModelChange?("claude-opus-4-6") } label: {
                    HStack {
                        Text("Opus")
                        if model.contains("opus") { Image(systemName: "checkmark") }
                    }
                }
                Button { onModelChange?("claude-sonnet-4-6") } label: {
                    HStack {
                        Text("Sonnet")
                        if model.contains("sonnet") { Image(systemName: "checkmark") }
                    }
                }
                Button { onModelChange?("claude-haiku-4-5-20251001") } label: {
                    HStack {
                        Text("Haiku")
                        if model.contains("haiku") { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                Label("Model", systemImage: "cpu")
            }

            Menu {
                ForEach([10000, 25000, 50000, 100000, 200000, 500000, 1000000, 0], id: \.self) { b in
                    Button { onBudgetChange?(b) } label: {
                        HStack {
                            Text(budgetSummary(b))
                            if budget == b { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Budget", systemImage: "gauge.with.needle")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(Stanford.ui(11, weight: .medium))
                Text("\(shortModelName(model)) · \(budgetSummary(budget))")
                    .font(Stanford.caption(12))
            }
            .foregroundStyle(Stanford.coolGrey)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Stanford.fog)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Permission Controls

    private var permissionModeButton: some View {
        Button { skipPermissions.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: skipPermissions ? "lock.open.fill" : "lock.fill")
                    .font(Stanford.ui(11))
                Text(skipPermissions ? "Auto" : "Review")
                    .font(Stanford.caption(13))
            }
            .foregroundStyle(skipPermissions ? Stanford.paloAltoGreen : Stanford.poppy)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(skipPermissions ? Stanford.paloAltoGreen.opacity(0.12) : Stanford.poppy.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(skipPermissions ? "Quick run tasks immediately" : "Switch the composer into plan and review flow before creating a runnable task")
        .accessibilityIdentifier("PermissionToggle")
    }

    private var teamModeButton: some View {
        Button { useAgentTeam.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: useAgentTeam ? "person.3.fill" : "person")
                    .font(Stanford.ui(11))
                Text(useAgentTeam ? "Team ×\(teamSize)" : "Solo")
                    .font(Stanford.caption(13))
            }
            .foregroundStyle(useAgentTeam ? Stanford.plum : Stanford.coolGrey)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(useAgentTeam ? Stanford.plum.opacity(0.12) : Stanford.fog)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TeamToggle")
        .accessibilityValue(useAgentTeam ? "Team" : "Solo")
        .contextMenu {
            if useAgentTeam {
                ForEach(2...5, id: \.self) { size in
                    Button("\(size) teammates") { teamSize = size }
                }
            }
        }
    }

    private var planModeToggle: some View {
        Toggle(isOn: $isPlanMode) {
            HStack(spacing: 4) {
                Image(systemName: "text.badge.checkmark")
                    .font(Stanford.ui(11, weight: .medium))
                Text("Plan mode")
                    .font(Stanford.caption(13))
            }
            .foregroundStyle(isPlanMode ? Stanford.cardinalRed : Stanford.coolGrey)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isPlanModeDisabled)
        .help(planModeHelp)
        .accessibilityIdentifier("PlanModeToggle")
    }

    // MARK: - Skill Chips

    private var visibleSkillLimit: Int { 1 }

    @ViewBuilder
    private var skillChips: some View {
        let sorted = skills.sorted { $0.name < $1.name }
        if !sorted.isEmpty {
            HStack(spacing: 4) {
                ForEach(sorted.prefix(visibleSkillLimit)) { skill in
                    skillChip(skill)
                }

                if sorted.count > visibleSkillLimit {
                    Menu {
                        ForEach(sorted.dropFirst(visibleSkillLimit)) { skill in
                            Button {
                                onRemoveSkill?(skill)
                            } label: {
                                Label("Remove \(skill.name)", systemImage: "xmark")
                            }
                        }
                    } label: {
                        Text("+\(sorted.count - visibleSkillLimit)")
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Stanford.lagunita.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
    }

    private func skillChip(_ skill: Skill) -> some View {
        HStack(spacing: 3) {
            Text(skill.name)
                .font(Stanford.caption(11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 90)
                .foregroundStyle(Stanford.lagunita)
            Button {
                onRemoveSkill?(skill)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(Stanford.lagunita.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Stanford.lagunita.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - SSH Indicator

    private var sshIndicator: some View {
        let connected = sshConnections.filter { $0.lastTestResult == true }
        let label = connected.isEmpty
            ? "SSH"
            : (connected.count == 1 ? connected[0].displayLabel : "SSH · \(connected.count)")
        let statusColor: Color = connected.isEmpty ? Stanford.coolGrey : Stanford.paloAltoGreen

        return Menu {
            Section("Remote Machines") {
                ForEach(sshConnections) { conn in
                    let isOk = conn.lastTestResult == true
                    Button { } label: {
                        Label {
                            Text("\(conn.displayLabel)  —  \(conn.host)")
                        } icon: {
                            Image(systemName: isOk ? "circle.fill" : "circle")
                                .foregroundStyle(isOk ? Stanford.paloAltoGreen : Stanford.coolGrey)
                                .font(Stanford.ui(7))
                        }
                    }
                    .disabled(true)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(Stanford.ui(10, weight: .medium))
                    .foregroundStyle(statusColor)
                Text(label)
                    .font(Stanford.caption(11))
                    .lineLimit(1)
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(connected.isEmpty
              ? "No active SSH connections"
              : connected.map { "\($0.displayLabel) (\($0.host))" }.joined(separator: "\n"))
    }

    // MARK: - Submit Area

    @ViewBuilder
    private var submitArea: some View {
        if isRunning {
            if let onStop {
                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(Stanford.ui(28))
                        .foregroundStyle(Stanford.cardinalRed)
                }
                .buttonStyle(.plain)
                .help("Stop task")
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } else if let submitTitle {
            Button {
                onSend()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: submitIcon)
                        .font(Stanford.ui(14, weight: .semibold))
                    Text(submitTitle)
                        .font(Stanford.body(15))
                        .fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(hasInput ? submitColor : Stanford.sandstone)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasInput)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("ComposerSubmitButton")
        } else {
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Stanford.ui(28))
                    .foregroundStyle(hasInput ? Stanford.cardinalRed : Stanford.sandstone.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!hasInput)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Helpers

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("haiku") { return "Haiku" }
        return "Sonnet"
    }

    private func budgetSummary(_ budget: Int) -> String {
        budget == 0 ? "∞" : "\(budget / 1000)k"
    }
}
