import SwiftUI
import ASTRACore

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
    var planModeHelp: String = "Plan and refine before creating a runnable task"
    var onPolicyLevelChange: ((AgentPolicyLevel) -> Void)?

    // MARK: - Submit button style

    var submitIcon: String = "arrow.up.circle.fill"
    var submitTitle: String?          // nil = icon-only send button
    var submitColor: Color = Stanford.cardinalRed
    var showSecurityGate: Bool = false
    var showPermissionControls: Bool = false

    // MARK: - SSH connections

    var sshConnections: [SSHConnection] = []

    @AppStorage(AppStorageKeys.budgetEnforcementMode) private var budgetEnforcementModeRaw = TaskExecutionDefaults.budgetEnforcementMode.rawValue
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var globalDefaultPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @State private var isPlusHovered = false
    @State private var isPolicySheetPresented = false

    var body: some View {
        HStack(spacing: 10) {
            plusMenu

            if showSecurityGate || showPermissionControls {
                permissionModeButton
            }

            Spacer(minLength: 8)

            taskStatusPill
            runtimeStatusPill
            submitArea
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
        Menu {
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
                    Label("Plan mode", systemImage: "text.badge.checkmark")
                }
                .disabled(isPlanModeDisabled)

                Toggle(isOn: $useAgentTeam) {
                    Label("Agent team", systemImage: "person.3")
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
            let userSkills = availableSkills.isEmpty
                ? (workspace?.skills ?? []).filter { !$0.isSystemBuiltIn }
                : availableSkills
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

    private var runtimeStatusPill: some View {
        modelBudgetPill(compact: false)
    }

    @ViewBuilder
    private var taskStatusPill: some View {
        if let status = taskStatus,
           let presentation = taskStatusPresentation(for: status) {
            HStack(spacing: 5) {
                Image(systemName: presentation.icon)
                    .font(Stanford.ui(11, weight: .semibold))
                Text(presentation.label)
                    .font(Stanford.caption(12).weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(presentation.color.opacity(0.10))
            .clipShape(Capsule())
            .help(presentation.help)
            .accessibilityLabel("Task status")
            .accessibilityValue(presentation.label)
        }
    }

    private func modelBudgetPill(compact: Bool) -> some View {
        Menu {
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
                                cachedClaudeModelsJSON: claudeAvailableModels,
                                cachedCopilotModelsJSON: copilotAvailableModels
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

            Menu {
                ForEach(TaskExecutionDefaults.budgetPresets, id: \.self) { b in
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

            Label("Enforcement: \(budgetEnforcementSummary)", systemImage: budgetEnforcementIcon)

            if !skills.isEmpty || !sshConnections.isEmpty || showPermissionControls {
                Divider()
            }

            if showPermissionControls {
                Label(useAgentTeam ? "Team: \(teamSize)" : "Solo agent", systemImage: useAgentTeam ? "person.3.fill" : "person")
                Label(isPlanMode ? "Plan mode on" : "Plan mode off", systemImage: "text.badge.checkmark")
            }

            if !skills.isEmpty {
                Menu {
                    ForEach(skills.sorted { $0.name < $1.name }) { skill in
                        Button {
                            onRemoveSkill?(skill)
                        } label: {
                            Label("Remove \(skill.name)", systemImage: "xmark")
                        }
                    }
                } label: {
                    Label(skills.count == 1 ? "1 skill active" : "\(skills.count) skills active", systemImage: "puzzlepiece.fill")
                }
            }

            if !sshConnections.isEmpty {
                Section("Remote Machines") {
                    ForEach(sshConnections) { conn in
                        let isOk = conn.lastTestResult == true
                        Label {
                            Text("\(conn.displayLabel)  —  \(conn.host)")
                        } icon: {
                            Image(systemName: isOk ? "circle.fill" : "circle")
                                .foregroundStyle(isOk ? Stanford.paloAltoGreen : Stanford.coolGrey)
                        }
                    }
                }
            }
        } label: {
            runtimeStatusLabel(style: .full)
            .foregroundStyle(isRunning ? Stanford.lagunita : Stanford.coolGrey)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, 6)
            .background((isRunning ? Stanford.lagunita : Color.primary).opacity(isRunning ? 0.13 : 0.07))
            .clipShape(Capsule())
        }
        .help(runtimeStatusHelp)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                    .font(Stanford.ui(11, weight: .medium))
            }

            switch style {
            case .full:
                Text(runtimeStatusText(includeRuntime: true))
                    .font(Stanford.caption(12).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            case .medium:
                Text(runtimeStatusText(includeRuntime: false))
                    .font(Stanford.caption(12).weight(.medium))
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
            ForEach(AgentPolicyLevel.allCases) { level in
                Button {
                    setPolicyLevel(level)
                } label: {
                    HStack {
                        Label(level.displayName, systemImage: level.symbolName)
                        if currentPolicyLevel == level {
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
                    Image(systemName: currentPolicyLevel.symbolName)
                        .font(Stanford.ui(12, weight: .semibold))
                    Text(currentPolicyLevel.displayName)
                        .font(Stanford.caption(13).weight(.medium))
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(Stanford.ui(9, weight: .bold))
                }
            }
            .foregroundStyle(policyColor(currentPolicyLevel))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, 6)
            .background(policyColor(currentPolicyLevel).opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(currentPolicyLevel.shortDescription)
        .accessibilityIdentifier("SecurityGate")
        .accessibilityLabel("Agent Policy")
        .accessibilityValue(currentPolicyLevel.displayName)
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
        case .autonomous: Stanford.poppy
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
                        .font(Stanford.caption(11).weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(useAgentTeam ? Stanford.plum : Stanford.coolGrey)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 5)
            .background(useAgentTeam ? Stanford.plum.opacity(0.12) : Stanford.fog)
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
                Image(systemName: "text.badge.checkmark")
                    .font(Stanford.ui(11, weight: .medium))
                if !compact {
                    Text("Plan mode")
                        .font(Stanford.caption(13))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(isPlanMode ? Stanford.cardinalRed : Stanford.coolGrey)
            .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isPlanModeDisabled)
        .help(compact ? "Plan mode — \(planModeHelp.lowercased())" : planModeHelp)
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
                        .font(Stanford.ui(10, weight: .medium))
                    Text("\(sorted.count)")
                        .font(Stanford.caption(11).weight(.semibold))
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
        return skills.count == 1 ? "Skill: \(names)" : "Skills (\(skills.count)): \(names)"
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
                    .font(Stanford.ui(10, weight: .medium))
                    .foregroundStyle(statusColor)
                if compact {
                    if !connected.isEmpty && connected.count > 1 {
                        Text("\(connected.count)")
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(statusColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Text(label)
                        .font(Stanford.caption(11))
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
                .foregroundStyle(canSubmit ? .white : Color.primary.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(canSubmit ? submitColor : Color.primary.opacity(0.10))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("ComposerSubmitButton")
        } else {
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Stanford.ui(28))
                    .foregroundStyle(canSubmit ? Stanford.cardinalRed : Color.primary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Helpers

    private func modelDisplayName(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runtimeModels(for runtime: AgentRuntimeID) -> [String] {
        RuntimeModelAvailability.models(
            for: runtime,
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
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
        AgentRuntimeID(rawValue: runtimeID) ?? TaskExecutionDefaults.runtime
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
        }
    }

    private func taskStatusPresentation(for status: TaskStatus) -> (label: String, icon: String, color: Color, help: String)? {
        switch status {
        case .pendingUser:
            return (
                "Needs input",
                "person.crop.circle.badge.questionmark",
                Stanford.poppy,
                "The task is waiting for your review or approval."
            )
        case .failed:
            return (
                "Failed",
                "exclamationmark.triangle.fill",
                Stanford.cardinalRed,
                "The task stopped with an error. Resume or retry when ready."
            )
        case .budgetExceeded:
            return (
                "Budget exceeded",
                "exclamationmark.triangle.fill",
                Stanford.cardinalRed,
                "The task ran out of token budget. Raise the budget, resume, or retry."
            )
        case .cancelled:
            return (
                "Cancelled",
                "xmark.circle.fill",
                Stanford.coolGrey,
                "The task was stopped before completion."
            )
        case .completed:
            return (
                "Completed",
                "checkmark.circle.fill",
                Stanford.paloAltoGreen,
                "The task completed."
            )
        case .draft, .queued, .running:
            return nil
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
