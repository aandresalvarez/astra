import SwiftUI
import ASTRACore

struct ComposerTaskStatusPresentation {
    let label: String
    let icon: String
    let color: Color
    let help: String
}

enum ComposerToolbarPresentation {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let controlSpacing: CGFloat = 8
    static let addButtonSize: CGFloat = 30
    static let addButtonFrameSize: CGFloat = 32
    static let addButtonCornerRadius: CGFloat = 9
    static let addIconSize: CGFloat = 14
    static let addButtonUsesRoundedSquare = true
    static let addButtonUsesBorderedChrome = true
    static let addButtonUsesBackgroundFill = false
    static let chipHorizontalPadding: CGFloat = 10
    static let chipVerticalPadding: CGFloat = 6
    static let chipCornerRadius: CGFloat = 10
    static let chipFontSize: CGFloat = 12
    static let chipIconSize: CGFloat = 11
    static let runtimePillUsesBorderedChrome = true
    static let runtimePillUsesBackgroundFill = false
    static let taskStatusPillUsesBorderedChrome = true
    static let menuControlsUsePlainButtonStyle = true
    static let permissionHorizontalPadding: CGFloat = 10
    static let permissionFontSize: CGFloat = 13
    static let permissionIconSize: CGFloat = 12
    static let submitButtonSize: CGFloat = 30
    static let submitIconSize: CGFloat = 13
    static let permissionModeUsesFlatChrome = true
}

/// Shared bottom toolbar for both new-task and follow-up composers.
struct ComposerToolbar: View {
    // MARK: - Required

    let model: String
    var runtimeID: String = AgentRuntimeID.claudeCode.rawValue
    let budget: Int
    var skills: [Skill] = []
    var availableSkills: [Skill] = []
    var workspace: Workspace?
    var runtimeReadinessStates: [AgentRuntimeID: RuntimeReadinessState] = [:]
    var taskStatus: TaskStatus?
    var taskStatusOverride: ComposerTaskStatusPresentation? = nil
    let isRunning: Bool
    let hasInput: Bool
    let onAttachFile: () -> Void
    let onPasteClipboard: () -> Void
    let onSend: () -> Void

    // MARK: - Optional callbacks

    var onStop: (() -> Void)?
    var onModelChange: ((String) -> Void)?
    var onRuntimeChange: ((String) -> Void)?
    var onBudgetChange: ((Int) -> Void)?
    var onRemoveSkill: ((Skill) -> Void)?
    var onToggleSkill: ((Skill, Bool) -> Void)?
    var onManageSkills: (() -> Void)?

    // MARK: - Permission mode (new task composer)

    @Binding var skipPermissions: Bool
    @Binding var policyLevelRaw: String
    @Binding var useAgentTeam: Bool
    @Binding var teamSize: Int
    @Binding var isPlanMode: Bool
    var isPlanModeDisabled: Bool = false
    var planModeHelp: String = "Turn on Goal Mode to define and approve a goal before execution"
    var onPolicyLevelChange: ((AgentPolicyLevel) -> Void)?

    // MARK: - Submit button style

    var submitIcon: String = "arrow.up.circle.fill"
    var submitTitle: String?          // nil = icon-only send button
    var submitColor: Color = Stanford.lagunita
    var showSecurityGate: Bool = false
    var showPermissionControls: Bool = false

    // MARK: - SSH connections

    var sshConnections: [SSHConnection] = []

    @AppStorage(AppStorageKeys.budgetEnforcementMode) private var budgetEnforcementModeRaw = TaskExecutionDefaults.budgetEnforcementMode.rawValue
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var globalDefaultPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @State private var isPlusHovered = false
    @State private var isPolicySheetPresented = false

    var body: some View {
        HStack(spacing: ComposerToolbarPresentation.controlSpacing) {
            plusMenu

            if showSecurityGate || showPermissionControls {
                permissionModeButton
            }

            Spacer(minLength: ComposerToolbarPresentation.controlSpacing)

            taskStatusPill
            runtimeStatusPill
            submitArea
        }
        .padding(.horizontal, ComposerToolbarPresentation.horizontalPadding)
        .padding(.vertical, ComposerToolbarPresentation.verticalPadding)
        .sheet(isPresented: $isPolicySheetPresented) {
            AgentPolicySheet(
                runtime: resolvedRuntime,
                model: model,
                workspace: workspace,
                skills: skills,
                selectedPolicyLevelRaw: $policyLevelRaw,
                globalDefaultLevelRaw: $globalDefaultPolicyLevelRaw,
                skipPermissions: $skipPermissions,
                onPolicyLevelChange: onPolicyLevelChange
            )
        }
    }

    // MARK: - Plus Menu

    private var plusMenu: some View {
        let shape = RoundedRectangle(
            cornerRadius: ComposerToolbarPresentation.addButtonCornerRadius,
            style: .continuous
        )

        return Menu {
            Button {
                onAttachFile()
            } label: {
                Label("Add files or photos", systemImage: "paperclip")
            }

            Button {
                onPasteClipboard()
            } label: {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
            }

            if showPermissionControls {
                Divider()

                Toggle(isOn: $isPlanMode) {
                    Label(isPlanMode ? "Goal mode on" : "Goal mode off", systemImage: "target")
                }
                .disabled(isPlanModeDisabled)

                Toggle(isOn: $useAgentTeam) {
                    Label(useAgentTeam ? "Agent team on" : "Agent team off", systemImage: "person.3")
                }

                if useAgentTeam {
                    Menu {
                        ForEach(2...5, id: \.self) { size in
                            Button("\(size) teammates") { teamSize = size }
                        }
                    } label: {
                        Label("Team size: \(teamSize)", systemImage: "number")
                    }
                }
            }

            Divider()
            let taskCapabilities = composerMenuCapabilities
            if !taskCapabilities.isEmpty || onManageSkills != nil {
                Menu {
                    if taskCapabilities.isEmpty {
                        Label("No task capabilities available", systemImage: "puzzlepiece")
                    }

                    ForEach(taskCapabilities) { skill in
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
                            Label("Manage capabilities\u{2026}", systemImage: "gearshape")
                        }
                    }
                } label: {
                    Label(capabilitiesMenuTitle, systemImage: skills.isEmpty ? "puzzlepiece" : "puzzlepiece.fill")
                }
            }

            if !sshConnections.isEmpty {
                Divider()
                Menu {
                    ForEach(sshConnections) { conn in
                        let isOk = conn.lastTestResult == true
                        Label {
                            Text("\(conn.displayLabel) - \(conn.host)")
                        } icon: {
                            Image(systemName: isOk ? "circle.fill" : "circle")
                                .foregroundStyle(isOk ? Stanford.paloAltoGreen : Stanford.coolGrey)
                        }
                    }
                } label: {
                    Label(remoteMachinesTitle, systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(Stanford.ui(ComposerToolbarPresentation.addIconSize, weight: .semibold))
                .foregroundStyle(isPlusHovered ? Stanford.black : Stanford.coolGrey)
                .frame(
                    width: ComposerToolbarPresentation.addButtonSize,
                    height: ComposerToolbarPresentation.addButtonSize
                )
                .animation(.easeInOut(duration: 0.15), value: isPlusHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(
            width: ComposerToolbarPresentation.addButtonFrameSize,
            height: ComposerToolbarPresentation.addButtonFrameSize
        )
        .background(shape.fill(Color.clear))
        .overlay(
            shape
                .stroke(Color.primary.opacity(isPlusHovered ? 0.16 : 0.12), lineWidth: 1)
        )
        .contentShape(shape)
        .onHover { isPlusHovered = $0 }
        .help("Add files, paste from clipboard, or adjust task options")
        .accessibilityLabel("Composer actions")
    }

    // MARK: - Provider / Model Pill

    private var runtimeStatusPill: some View {
        providerModelPill(compact: false)
    }

    @ViewBuilder
    private var taskStatusPill: some View {
        if let presentation = resolvedTaskStatusPresentation {
            let shape = RoundedRectangle(
                cornerRadius: ComposerToolbarPresentation.chipCornerRadius,
                style: .continuous
            )
            HStack(spacing: 5) {
                Image(systemName: presentation.icon)
                    .font(Stanford.ui(ComposerToolbarPresentation.chipIconSize))
                Text(presentation.label)
                    .font(Stanford.chatMeta(ComposerToolbarPresentation.chipFontSize))
                    .lineLimit(1)
            }
            .foregroundStyle(presentation.color)
            .padding(.horizontal, ComposerToolbarPresentation.chipHorizontalPadding)
            .padding(.vertical, ComposerToolbarPresentation.chipVerticalPadding)
            .background(presentation.color.opacity(0.075))
            .clipShape(shape)
            .overlay(
                shape.stroke(presentation.color.opacity(0.16), lineWidth: 1)
            )
            .help(presentation.help)
            .accessibilityLabel("Task status")
            .accessibilityValue(presentation.label)
        }
    }

    private var resolvedTaskStatusPresentation: ComposerTaskStatusPresentation? {
        if let taskStatusOverride { return taskStatusOverride }
        guard let taskStatus else { return nil }
        return taskStatusPresentation(for: taskStatus)
    }

    private func providerModelPill(compact: Bool) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: ComposerToolbarPresentation.chipCornerRadius,
            style: .continuous
        )

        return Menu {
            Menu {
                let runtimes = selectableRuntimes
                if runtimes.isEmpty {
                    Label(runtimeReadinessStates.isEmpty ? "Checking providers" : "No ready providers",
                          systemImage: runtimeReadinessStates.isEmpty ? "clock" : "exclamationmark.triangle")
                }
                ForEach(runtimes) { runtime in
                    Button {
                        onRuntimeChange?(runtime.rawValue)
                        onModelChange?(
                            RuntimeModelAvailability.modelForRuntimeSwitch(
                                currentModel: model,
                                to: runtime,
                                cache: runtimeModelCache
                            )
                        )
                    } label: {
                        HStack {
                            Text(runtime.displayName)
                            if resolvedRuntime == runtime { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Provider", systemImage: "server.rack")
            }

            Menu {
                let candidates = runtimeModels(for: resolvedRuntime)
                let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedModel.isEmpty, !candidates.contains(trimmedModel) {
                    Label("Custom: \(modelDisplayName(trimmedModel))", systemImage: "pencil")
                    Divider()
                }
                ForEach(candidates, id: \.self) { candidate in
                    Button { onModelChange?(candidate) } label: {
                        HStack {
                            Text(modelDisplayName(candidate))
                            if model == candidate { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Model", systemImage: "cpu")
            }

            Divider()

            Menu {
                ForEach(TaskExecutionDefaults.budgetPresets, id: \.self) { preset in
                    Button {
                        onBudgetChange?(preset)
                    } label: {
                        HStack {
                            Text(budgetSummary(preset))
                            if budget == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(onBudgetChange == nil)
                }
            } label: {
                Label("Budget: \(budgetSummary(budget))", systemImage: "gauge.with.needle")
            }

            Menu {
                ForEach(BudgetEnforcementMode.allCases) { mode in
                    Button {
                        budgetEnforcementModeRaw = mode.rawValue
                    } label: {
                        HStack {
                            Text(mode.label)
                            if budgetEnforcementMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .help(mode.helpText)
                }
            } label: {
                Label("Enforcement: \(budgetEnforcementSummary)", systemImage: budgetEnforcementIcon)
            }
        } label: {
            runtimeStatusLabel(style: .full)
                .foregroundStyle(runtimePillColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .padding(.horizontal, compact ? 9 : ComposerToolbarPresentation.chipHorizontalPadding)
        .padding(.vertical, ComposerToolbarPresentation.chipVerticalPadding)
        .background(runtimePillBackground)
        .clipShape(shape)
        .overlay(
            shape.stroke(runtimePillStroke, lineWidth: 1)
        )
        .help(runtimeStatusHelp)
    }

    private var runtimePillColor: Color {
        switch taskStatus {
        case .some(.failed), .some(.budgetExceeded):
            return Stanford.failed
        case .some(.pendingUser):
            return Stanford.poppy
        default:
            return isRunning ? Stanford.lagunita : Stanford.coolGrey
        }
    }

    private var runtimePillBackground: Color {
        Color.clear
    }

    private var runtimePillStroke: Color {
        switch taskStatus {
        case .some(.failed), .some(.budgetExceeded), .some(.pendingUser):
            return runtimePillColor.opacity(0.16)
        default:
            return (isRunning ? Stanford.lagunita : Color.primary).opacity(isRunning ? 0.15 : 0.08)
        }
    }

    private enum RuntimeStatusLabelStyle {
        case full
        case medium
        case iconOnly
    }

    private func runtimeStatusLabel(style: RuntimeStatusLabelStyle) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "cpu")
                    .font(Stanford.ui(ComposerToolbarPresentation.chipIconSize))
            }

            switch style {
            case .full:
                Text(runtimeStatusText(includeRuntime: true))
                    .font(Stanford.chatMeta(ComposerToolbarPresentation.chipFontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            case .medium:
                Text(runtimeStatusText(includeRuntime: false))
                    .font(Stanford.chatMeta(ComposerToolbarPresentation.chipFontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            case .iconOnly:
                EmptyView()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Permission Controls

    private var permissionModeButton: some View {
        permissionModeButton(compact: false)
    }

    private func permissionModeButton(compact: Bool) -> some View {
        Menu {
            ForEach(AgentPolicyLevel.primaryCases) { level in
                Button {
                    setPolicyLevel(level)
                } label: {
                    HStack {
                        Label(level.displayName, systemImage: level.symbolName)
                        if currentPolicyLevel.userFacingLevel == level {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                isPolicySheetPresented = true
            } label: {
                Label("Policy details...", systemImage: "checklist.shield")
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: currentPolicyLevel.userFacingLevel.symbolName)
                        .font(Stanford.ui(ComposerToolbarPresentation.permissionIconSize))
                    Text(currentPolicyLevel.userFacingLevel.displayName)
                        .font(Stanford.chatMeta(ComposerToolbarPresentation.permissionFontSize))
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(Stanford.ui(9))
                }
            }
            .foregroundStyle(policyColor(currentPolicyLevel.userFacingLevel))
            .padding(.horizontal, compact ? 8 : ComposerToolbarPresentation.permissionHorizontalPadding)
            .padding(.vertical, ComposerToolbarPresentation.chipVerticalPadding)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(currentPolicyLevel.userFacingLevel.shortDescription)
        .accessibilityIdentifier("SecurityGate")
        .accessibilityLabel("Agent Policy")
        .accessibilityValue(currentPolicyLevel.userFacingLevel.displayName)
    }

    private var currentPolicyLevel: AgentPolicyLevel {
        skipPermissions ? .autonomous : AgentPolicyLevel.normalized(policyLevelRaw)
    }

    private func setPolicyLevel(_ level: AgentPolicyLevel) {
        policyLevelRaw = level.rawValue
        skipPermissions = level == .autonomous
        onPolicyLevelChange?(level)
    }

    private func policyColor(_ level: AgentPolicyLevel) -> Color {
        switch level {
        case .locked: Stanford.cardinalRed
        case .review: Stanford.paloAltoGreen
        case .build: Stanford.lagunita
        case .network: Stanford.sky
        case .autonomous: Stanford.lagunita
        case .custom: Stanford.plum
        }
    }

    private var teamModeButton: some View {
        teamModeButton(compact: false)
    }

    private func teamModeButton(compact: Bool) -> some View {
        Button { useAgentTeam.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: useAgentTeam ? "person.3.fill" : "person")
                    .font(Stanford.ui(11))
                if !compact {
                    Text(useAgentTeam ? "Team ×\(teamSize)" : "Solo")
                        .font(Stanford.caption(13))
                        .fixedSize(horizontal: true, vertical: false)
                } else if useAgentTeam {
                    Text("×\(teamSize)")
                        .font(Stanford.caption(11))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(useAgentTeam ? Stanford.plum : Stanford.coolGrey)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(useAgentTeam ? 0.055 : 0.035))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(useAgentTeam ? "Agent team active (×\(teamSize)). Right-click to change size." : "Solo agent")
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
        planModeToggle(compact: false)
    }

    private func planModeToggle(compact: Bool) -> some View {
        Toggle(isOn: $isPlanMode) {
            HStack(spacing: 4) {
                Image(systemName: "target")
                    .font(Stanford.ui(11))
                if !compact {
                    Text("Goal mode")
                        .font(Stanford.chatMeta(13))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(isPlanMode ? Stanford.lagunita : Stanford.coolGrey)
            .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isPlanModeDisabled)
        .help(compact ? "Goal mode - \(planModeHelp.lowercased())" : planModeHelp)
        .accessibilityIdentifier("PlanModeToggle")
    }

    // MARK: - Capability Chips

    private var visibleSkillLimit: Int { 1 }

    private var composerMenuCapabilities: [Skill] {
        let configuredSkills = availableSkills.isEmpty
            ? (workspace?.skills ?? []).filter { !$0.isSystemBuiltIn }
            : availableSkills
        var seenIDs = Set<UUID>()
        var merged: [Skill] = []

        for skill in configuredSkills + skills {
            guard !seenIDs.contains(skill.id) else { continue }
            seenIDs.insert(skill.id)
            merged.append(skill)
        }

        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var capabilitiesMenuTitle: String {
        if skills.isEmpty { return "Task capabilities" }
        return skills.count == 1 ? "1 task capability active" : "\(skills.count) task capabilities active"
    }

    private var remoteMachinesTitle: String {
        let readyCount = sshConnections.filter { $0.lastTestResult == true }.count
        if readyCount > 0 {
            return readyCount == 1 ? "1 remote ready" : "\(readyCount) remotes ready"
        }
        return sshConnections.count == 1 ? "1 remote configured" : "\(sshConnections.count) remotes configured"
    }

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
                            .font(Stanford.chatMeta())
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Stanford.lagunita.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
    }

    @ViewBuilder
    private var compactSkillChips: some View {
        let sorted = skills.sorted { $0.name < $1.name }
        if !sorted.isEmpty {
            Menu {
                ForEach(sorted) { skill in
                    Button {
                        onRemoveSkill?(skill)
                    } label: {
                        Label("Remove \(skill.name)", systemImage: "xmark")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "puzzlepiece.fill")
                        .font(Stanford.ui(10))
                    Text("\(sorted.count)")
                        .font(Stanford.chatMeta())
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Stanford.lagunita)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Stanford.lagunita.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(skillsTooltip(sorted))
        }
    }

    private func skillsTooltip(_ skills: [Skill]) -> String {
        let names = skills.map(\.name).joined(separator: ", ")
        return skills.count == 1 ? "Task capability: \(names)" : "Task capabilities (\(skills.count)): \(names)"
    }

    private func skillChip(_ skill: Skill) -> some View {
        HStack(spacing: 3) {
            Text(skill.name)
                .font(Stanford.chatMeta())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 90)
                .foregroundStyle(Stanford.lagunita)
            Button {
                onRemoveSkill?(skill)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10))
                    .foregroundStyle(Stanford.lagunita.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Stanford.lagunita.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
    }

    // MARK: - SSH Indicator

    private var sshIndicator: some View {
        sshIndicator(compact: false)
    }

    private func sshIndicator(compact: Bool) -> some View {
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
                    .font(Stanford.ui(10))
                    .foregroundStyle(statusColor)
                if compact {
                    if !connected.isEmpty && connected.count > 1 {
                        Text("\(connected.count)")
                            .font(Stanford.chatMeta())
                            .foregroundStyle(statusColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Text(label)
                        .font(Stanford.chatMeta())
                        .lineLimit(1)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))
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
                    Image(systemName: "stop.fill")
                        .font(Stanford.ui(ComposerToolbarPresentation.submitIconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(
                            width: ComposerToolbarPresentation.submitButtonSize,
                            height: ComposerToolbarPresentation.submitButtonSize
                        )
                        .background(Circle().fill(Stanford.cardinalRed))
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
                Image(systemName: submitSymbolName)
                    .font(Stanford.ui(ComposerToolbarPresentation.submitIconSize, weight: .semibold))
                    .foregroundStyle(canSubmit ? .white : Color.primary.opacity(0.38))
                    .frame(
                        width: ComposerToolbarPresentation.submitButtonSize,
                        height: ComposerToolbarPresentation.submitButtonSize
                    )
                    .background(
                        Circle()
                            .fill(canSubmit ? submitColor : Color.primary.opacity(0.065))
                    )
                    .overlay(
                        Circle()
                            .stroke(canSubmit ? submitColor.opacity(0.0) : Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .help(submitTitle)
            .accessibilityIdentifier("ComposerSubmitButton")
            .accessibilityLabel(submitTitle)
        } else {
            Button {
                onSend()
            } label: {
                Image(systemName: submitSymbolName)
                    .font(Stanford.ui(ComposerToolbarPresentation.submitIconSize, weight: .semibold))
                    .foregroundStyle(canSubmit ? .white : Color.primary.opacity(0.38))
                    .frame(
                        width: ComposerToolbarPresentation.submitButtonSize,
                        height: ComposerToolbarPresentation.submitButtonSize
                    )
                    .background(
                        Circle()
                            .fill(canSubmit ? submitColor : Color.primary.opacity(0.065))
                    )
                    .overlay(
                        Circle()
                            .stroke(canSubmit ? submitColor.opacity(0.0) : Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("ComposerSubmitButton")
            .accessibilityLabel("Send")
        }
    }

    // MARK: - Helpers

    private var submitSymbolName: String {
        submitIcon == "arrow.up.circle.fill" ? "arrow.up" : submitIcon
    }

    private func modelDisplayName(_ model: String) -> String {
        RuntimeModelDisplayName.displayName(model)
    }

    private func runtimeModels(for runtime: AgentRuntimeID) -> [String] {
        RuntimeModelAvailability.models(
            for: runtime,
            cache: runtimeModelCache
        )
    }

    private var runtimeModelCache: RuntimeModelAvailabilityCache {
        runtimeSettingsSnapshot.runtimeModelCache
    }

    private var runtimeSettingsSnapshot: RuntimeSettingsSnapshot {
        RuntimeSettingsSnapshotStore.runtimeSnapshot(
            defaultRuntimeID: runtimeID,
            defaultModel: model,
            defaultBudget: budget,
            skipPermissions: skipPermissions,
            defaultPolicyLevelRaw: policyLevelRaw,
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels,
            runtimeModelCacheRevision: runtimeModelCacheRevision,
            providerSnapshot: RuntimeSettingsSnapshotStore.providerSnapshot()
        )
    }

    private func shortModelDisplayName(_ model: String) -> String {
        let normalized = modelDisplayName(model)
        let lower = normalized.lowercased()

        if lower.contains("sonnet") {
            return versionedModelName("Sonnet", from: normalized)
        }
        if lower.contains("opus") {
            return versionedModelName("Opus", from: normalized)
        }
        if lower.contains("haiku") {
            return versionedModelName("Haiku", from: normalized)
        }
        if lower.hasPrefix("gpt-") {
            return normalized
                .replacingOccurrences(of: "gpt-", with: "GPT-")
                .replacingOccurrences(of: "-mini", with: " Mini")
        }
        return normalized
    }

    private func versionedModelName(_ family: String, from model: String) -> String {
        let parts = model.split(separator: "-")
        let numbers = parts.filter { part in
            part.allSatisfy(\.isNumber)
        }
        guard numbers.count >= 2 else { return family }
        return "\(family) \(numbers[0]).\(numbers[1])"
    }

    private var resolvedRuntime: AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
    }

    private var canSubmit: Bool {
        hasInput && (runtimeReadinessStates.isEmpty || runtimeReadinessStates[resolvedRuntime] == .ready)
    }

    private var displayedRuntime: AgentRuntimeID? {
        if runtimeReadinessStates[resolvedRuntime] == .ready {
            return resolvedRuntime
        }
        return selectableRuntimes.first
    }

    private var selectableRuntimes: [AgentRuntimeID] {
        RuntimeProviderAvailabilityService.readyRuntimes(from: runtimeReadinessStates)
    }

    private var runtimeStatusHelp: String {
        if runtimeReadinessStates.isEmpty {
            return "Checking provider readiness"
        }
        guard let displayedRuntime else {
            return "No ready provider. Finish CLI setup before running a task."
        }
        return "\(displayedRuntime.displayName) · \(modelDisplayName(model)) · \(budgetSummary(budget)) · \(budgetEnforcementMode.label)"
    }

    private func runtimeStatusText(includeRuntime: Bool) -> String {
        if runtimeReadinessStates.isEmpty {
            return "Checking provider"
        }
        guard let displayedRuntime else {
            return "Provider setup needed"
        }
        let modelPart = displayedRuntime == resolvedRuntime ? shortModelDisplayName(model) : "Ready"
        return includeRuntime
            ? "\(shortRuntimeName(displayedRuntime)) · \(modelPart) · \(budgetSummary(budget))"
            : "\(modelPart) · \(budgetSummary(budget))"
    }

    private func shortRuntimeName(_ runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: "Claude"
        case .copilotCLI: "Copilot"
        case .antigravityCLI: "Antigravity"
        case .codexCLI: "Codex"
        default: runtime.displayName
        }
    }

    private func taskStatusPresentation(for status: TaskStatus) -> ComposerTaskStatusPresentation? {
        let review = TaskPresentationState.reviewPresentation(status: status, isClosed: false)
        guard let label = review.composerLabel,
              let icon = review.composerIcon,
              let help = review.composerHelp else { return nil }
        return ComposerTaskStatusPresentation(
            label: label,
            icon: icon,
            color: composerTaskStatusColor(for: review.tone),
            help: help
        )
    }

    private func composerTaskStatusColor(for tone: TaskReviewTone) -> Color {
        switch tone {
        case .quiet:
            return Stanford.coolGrey
        case .attention:
            return Stanford.poppy
        case .failed:
            return Stanford.failed
        case .closed:
            return Stanford.paloAltoGreen
        }
    }

    private func budgetSummary(_ budget: Int) -> String {
        budget == 0 ? "∞" : "\(budget / 1000)k"
    }

    private var budgetEnforcementMode: BudgetEnforcementMode {
        BudgetEnforcementMode(rawValue: budgetEnforcementModeRaw) ?? TaskExecutionDefaults.budgetEnforcementMode
    }

    private var budgetEnforcementSummary: String {
        switch budgetEnforcementMode {
        case .hardStop: "Stop"
        case .warning: "Warn"
        }
    }

    private var budgetEnforcementIcon: String {
        switch budgetEnforcementMode {
        case .hardStop: "hand.raised.fill"
        case .warning: "exclamationmark.triangle"
        }
    }
}
