import AppKit
import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

struct ScheduleEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsSnapshotStore

    let workspace: Workspace
    var schedule: TaskSchedule?

    // Prefill from existing task (Convert to Routine)
    var prefillName: String?
    var prefillGoal: String?
    var prefillRuntimeID: String?
    var prefillModel: String?
    var prefillBudget: Int?
    var prefillSkillIDs: Set<String>?
    var prefillConversationContext: String?
    var prefillScheduleType: ScheduleType?
    var prefillHour: Int?
    var prefillMinute: Int?
    var prefillDayOfWeek: Int?
    var prefillIntervalSeconds: Int?
    var prefillSourceTaskID: UUID?

    @State private var name = ""
    @State private var routineDescription = ""
    @State private var goal = ""
    @State private var runtimeID = TaskExecutionDefaults.runtime.rawValue
    @State private var model = TaskExecutionDefaults.model
    @State private var tokenBudget = TaskExecutionDefaults.tokenBudget
    @State private var scheduleType: ScheduleType = .daily
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var intervalSeconds = 3600
    @State private var dailyHour = 9
    @State private var dailyMinute = 0
    @State private var weeklyDayOfWeek = 2 // Monday
    @State private var selectedSkillIDs: Set<String> = []
    @State private var routinePaths: [String] = []
    @State private var resultMode: ScheduleResultMode = .sameThread
    @State private var showDeleteConfirm = false

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var availableSkills: [Skill] {
        let workspaceSkills = workspace.skills.filter { !$0.isGlobal }
        let enabledIDs = Set(workspace.enabledGlobalSkillIDs)
        let enabledGlobals = globalSkills.filter { enabledIDs.contains($0.id.uuidString) }
        return (workspaceSkills + enabledGlobals).sorted { $0.name < $1.name }
    }

    private let budgetPresets = TaskExecutionDefaults.budgetPresets
    private let intervalPresets = [
        (label: "15 min", value: 900),
        (label: "30 min", value: 1800),
        (label: "1 hour", value: 3600),
        (label: "4 hours", value: 14400),
        (label: "12 hours", value: 43200)
    ]
    private let weekdays = [
        (label: "Sunday", value: 1),
        (label: "Monday", value: 2),
        (label: "Tuesday", value: 3),
        (label: "Wednesday", value: 4),
        (label: "Thursday", value: 5),
        (label: "Friday", value: 6),
        (label: "Saturday", value: 7)
    ]

    private var isEditing: Bool { schedule != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasConversationContext: Bool {
        if let ctx = prefillConversationContext, !ctx.isEmpty { return true }
        if let s = schedule, !s.conversationContext.isEmpty { return true }
        return false
    }

    private var conversationContextLineCount: Int {
        let ctx = prefillConversationContext ?? schedule?.conversationContext ?? ""
        return ctx.components(separatedBy: "\n\nUser: ").count +
               ctx.components(separatedBy: "\n\nAgent: ").count - 1
    }

    private var timeString: String {
        let h = dailyHour % 12 == 0 ? 12 : dailyHour % 12
        let period = dailyHour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h, dailyMinute, period)
    }

    private var frequencyDescription: String {
        switch scheduleType {
        case .once: return "Runs once at the specified time"
        case .interval:
            let preset = intervalPresets.first { $0.value == intervalSeconds }
            return "Runs every \(preset?.label ?? "\(intervalSeconds/60) min")"
        case .daily: return "Runs daily at \(timeString)"
        case .weekly:
            let day = weekdays.first { $0.value == weeklyDayOfWeek }?.label ?? "?"
            return "Runs every \(day) at \(timeString)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Routine" : "New Routine")
                        .font(Stanford.heading(20))
                        .foregroundStyle(Stanford.black)
                    if isEditing, let s = schedule {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(s.isEnabled ? Stanford.paloAltoGreen : Stanford.coolGrey)
                                .frame(width: 7, height: 7)
                            Text(s.isEnabled ? "Active" : "Paused")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.coolGrey)
                            if s.fireCount > 0 {
                                Text("  \(s.fireCount) runs")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(Stanford.coolGrey)
                            }
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.coolGrey)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // MARK: - Routine
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Routine")

                        VStack(spacing: 1) {
                            fieldRow {
                                Text("Name").foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                TextField("e.g., Jira support ticket triage", text: $name)
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.plain)
                            }
                            Divider().padding(.leading, 16)
                            fieldRow {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Description").foregroundStyle(Stanford.coolGrey)
                                    TextField("Short note about when this routine is useful", text: $routineDescription, axis: .vertical)
                                        .textFieldStyle(.plain)
                                        .lineLimit(2...5)
                                }
                            }
                            Divider().padding(.leading, 16)
                            fieldRow {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Instructions").foregroundStyle(Stanford.coolGrey)
                                    TextField("What should the agent do each run?", text: $goal, axis: .vertical)
                                        .textFieldStyle(.plain)
                                        .lineLimit(4...8)
                                }
                            }
                        }
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))

                        if hasConversationContext {
                            HStack(spacing: 8) {
                                Image(systemName: "text.bubble.fill")
                                    .font(Stanford.body(12))
                                    .foregroundStyle(Stanford.lagunita)
                                Text("Conversation context attached")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                Text("\(conversationContextLineCount) messages")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(Stanford.coolGrey)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Stanford.fog)
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    // MARK: - Folders
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            sectionLabel("Folders")
                            Spacer()
                            Button {
                                addRoutineFolders()
                            } label: {
                                Label("Add Folder", systemImage: "plus")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(Stanford.lagunita)
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(spacing: 1) {
                            if routinePaths.isEmpty {
                                fieldRow {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text("No routine-specific folders")
                                        .foregroundStyle(Stanford.coolGrey)
                                    Spacer()
                                }
                            } else {
                                ForEach(Array(routinePaths.enumerated()), id: \.element) { index, path in
                                    routinePathRow(path)
                                    if index < routinePaths.count - 1 {
                                        Divider().padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))
                    }

                    // MARK: - Frequency
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Frequency")

                        // Segmented picker for schedule type
                        Picker("", selection: $scheduleType) {
                            Text("Once").tag(ScheduleType.once)
                            Text("Interval").tag(ScheduleType.interval)
                            Text("Daily").tag(ScheduleType.daily)
                            Text("Weekly").tag(ScheduleType.weekly)
                        }
                        .pickerStyle(.segmented)

                        VStack(spacing: 1) {
                            switch scheduleType {
                            case .once:
                                fieldRow {
                                    DatePicker("Run at", selection: $onceDate, in: Date()...)
                                        .labelsHidden()
                                }

                            case .interval:
                                fieldRow {
                                    Text("Repeat every").foregroundStyle(Stanford.coolGrey)
                                    Spacer()
                                    Picker("", selection: $intervalSeconds) {
                                        ForEach(intervalPresets, id: \.value) { preset in
                                            Text(preset.label).tag(preset.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 120)
                                }

                            case .daily:
                                timePicker

                            case .weekly:
                                fieldRow {
                                    Text("Day").foregroundStyle(Stanford.coolGrey)
                                    Spacer()
                                    Picker("", selection: $weeklyDayOfWeek) {
                                        ForEach(weekdays, id: \.value) { day in
                                            Text(day.label).tag(day.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                }
                                Divider().padding(.leading, 16)
                                timePicker
                            }
                        }
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))

                        // Frequency summary
                        Text(frequencyDescription)
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                            .padding(.horizontal, 4)
                    }

                    // MARK: - Execution & Results
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Execution")

                        VStack(spacing: 1) {
                            fieldRow {
                                Text("Provider").foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                Picker("", selection: $runtimeID) {
                                    ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                                        Text(runtime.displayName).tag(runtime.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 180)
                                .onChange(of: runtimeID) {
                                    let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
                                    model = RuntimeModelAvailability.modelForRuntimeSwitch(
                                        currentModel: model,
                                        to: runtime,
                                        cache: runtimeModelCache
                                    )
                                }
                            }
                            Divider().padding(.leading, 16)
                            fieldRow {
                                Text("Model").foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                modelSelectionControl
                            }
                            Divider().padding(.leading, 16)
                            fieldRow {
                                Text("Token Budget").foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                Picker("", selection: $tokenBudget) {
                                    ForEach(budgetPresets, id: \.self) { b in
                                        Text(RuntimeBudgetPresentation.compactLabel(for: b)).tag(b)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                            Divider().padding(.leading, 16)
                            fieldRow {
                                Text("Deliver results").foregroundStyle(Stanford.coolGrey)
                                Spacer()
                                Picker("", selection: $resultMode) {
                                    ForEach(ScheduleResultMode.allCases, id: \.self) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 160)
                            }
                        }
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))

                        Text(resultMode.description)
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                            .padding(.horizontal, 4)
                    }

                    // MARK: - Capabilities
                    if !availableSkills.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("Capabilities")

                            VStack(spacing: 1) {
                                ForEach(Array(availableSkills.enumerated()), id: \.element.id) { index, skill in
                                    fieldRow {
                                        Label(skill.name, systemImage: skill.icon)
                                            .foregroundStyle(Stanford.black)
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { selectedSkillIDs.contains(skill.id.uuidString) },
                                            set: { enabled in
                                                if enabled {
                                                    selectedSkillIDs.insert(skill.id.uuidString)
                                                } else {
                                                    selectedSkillIDs.remove(skill.id.uuidString)
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                    }
                                    if index < availableSkills.count - 1 {
                                        Divider().padding(.leading, 16)
                                    }
                                }
                            }
                            .background(Stanford.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            // MARK: - Footer
            HStack(spacing: 12) {
                if isEditing {
                    Button {
                        toggleEnabled()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: schedule?.isEnabled == true ? "pause.circle" : "play.circle")
                            Text(schedule?.isEnabled == true ? "Pause" : "Resume")
                        }
                        .font(Stanford.body(13))
                        .foregroundStyle(schedule?.isEnabled == true ? Stanford.poppy : Stanford.paloAltoGreen)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .font(Stanford.body(13))
                        .foregroundStyle(Stanford.cardinalRed.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(isEditing ? "Save" : "Create Routine") {
                    save()
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: true))
                .controlSize(.regular)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 760)
        .alert("Delete Routine", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteSchedule() }
        } message: {
            Text("This will permanently delete \"\(schedule?.name ?? "")\" and stop all future runs.")
        }
        .onAppear {
            if let s = schedule {
                name = s.name
                routineDescription = s.routineDescription
                goal = s.routineInstructions
                runtimeID = s.resolvedRuntimeID.rawValue
                model = s.model
                tokenBudget = s.tokenBudget
                scheduleType = s.scheduleType
                onceDate = s.nextFireDate
                intervalSeconds = s.intervalSeconds
                dailyHour = s.dailyHour
                dailyMinute = s.dailyMinute
                weeklyDayOfWeek = s.weeklyDayOfWeek
                selectedSkillIDs = Set(s.skillIDs)
                routinePaths = s.routinePaths
                resultMode = s.resultMode
            } else {
                // Apply prefill values (Convert to Routine flow)
                let settings = runtimeSettingsSnapshot
                runtimeID = prefillRuntimeID ?? settings.defaultRuntime.rawValue
                if let n = prefillName { name = n }
                if let g = prefillGoal { goal = g }
                if let m = prefillModel {
                    model = m
                } else {
                    let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
                    model = RuntimeModelAvailability.normalizedModel(
                        settings.defaultModel,
                        for: runtime,
                        cache: runtimeModelCache
                    )
                }
                if let b = prefillBudget { tokenBudget = b }
                if let t = prefillScheduleType { scheduleType = t }
                if let h = prefillHour { dailyHour = h }
                if let min = prefillMinute { dailyMinute = min }
                if let d = prefillDayOfWeek { weeklyDayOfWeek = d }
                if let i = prefillIntervalSeconds { intervalSeconds = i }
                if let ids = prefillSkillIDs { selectedSkillIDs = ids }
            }
            alignModelWithRuntime()
        }
        .onChange(of: appSettings.runtimeSettings.modelCacheSignature) {
            alignModelWithRuntime()
        }
    }

    // MARK: - Reusable Components

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Stanford.caption(11))
            .fontWeight(.semibold)
            .foregroundStyle(Stanford.coolGrey)
            .tracking(0.8)
            .padding(.horizontal, 4)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .font(Stanford.body(14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var runtimeModels: [String] {
        RuntimeModelAvailability.models(
            for: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID),
            cache: runtimeModelCache
        )
    }

    private var runtimeModelCache: RuntimeModelAvailabilityCache {
        runtimeSettingsSnapshot.runtimeModelCache
    }

    private var runtimeSettingsSnapshot: RuntimeSettingsSnapshot {
        appSettings.runtimeSettings
    }

    private var modelSelectionControl: some View {
        HStack(spacing: 8) {
            TextField("Model ID", text: $model, prompt: Text("Type or choose"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 240)
                .textSelection(.enabled)
            Menu {
                ForEach(runtimeModels, id: \.self) { candidate in
                    Button {
                        model = candidate
                    } label: {
                        ModelMenuItemLabel(
                            presentation: RuntimeModelMenuOptionPresentation(
                                model: candidate,
                                runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID),
                                cache: runtimeModelCache
                            ),
                            isSelected: model == candidate
                        )
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(12).weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose Model")
        }
    }

    private func alignModelWithRuntime() {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
        model = RuntimeModelAvailability.normalizedModel(
            model,
            for: runtime,
            cache: runtimeModelCache
        )
    }

    private var timePicker: some View {
        fieldRow {
            Text("Time").foregroundStyle(Stanford.coolGrey)
            Spacer()
            HStack(spacing: 4) {
                Picker("", selection: $dailyHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
                Text(":")
                    .foregroundStyle(Stanford.coolGrey)
                Picker("", selection: $dailyMinute) {
                    ForEach([0, 15, 30, 45], id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }
        }
    }

    private func routinePathRow(_ path: String) -> some View {
        fieldRow {
            Image(systemName: "folder")
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .foregroundStyle(Stanford.black)
                    .lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                removeRoutinePath(path)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove folder")
        }
    }

    // MARK: - Actions

    private func addRoutineFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = "Choose folders this routine can use as context"
        panel.prompt = "Add Folders"
        guard panel.runModal() == .OK else { return }

        let newPaths = panel.urls.map(\.path)
        routinePaths = uniquePaths(routinePaths + newPaths)
    }

    private func removeRoutinePath(_ path: String) {
        routinePaths.removeAll { $0 == path }
    }

    private func save() {
        let s = schedule ?? TaskSchedule(name: "", workspace: workspace)

        s.name = name.trimmingCharacters(in: .whitespaces)
        s.routineDescription = routineDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        s.routineInstructions = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
        s.runtimeID = resolvedRuntime.rawValue
        s.model = RuntimeModelAvailability.normalizedModel(
            model,
            for: resolvedRuntime,
            cache: runtimeModelCache
        )
        s.tokenBudget = tokenBudget
        s.scheduleType = scheduleType
        s.intervalSeconds = intervalSeconds
        s.dailyHour = dailyHour
        s.dailyMinute = dailyMinute
        s.weeklyDayOfWeek = weeklyDayOfWeek
        s.skillIDs = Array(selectedSkillIDs)
        s.routinePaths = routinePaths
        s.resultMode = resultMode

        // Set conversation context and source task on first creation only
        if schedule == nil {
            if let ctx = prefillConversationContext, !ctx.isEmpty {
                s.conversationContext = ctx
            }
            if let sourceID = prefillSourceTaskID {
                s.sourceTaskID = sourceID
            }
        }

        // Compute initial nextFireDate
        switch scheduleType {
        case .once:
            s.nextFireDate = onceDate
        case .interval:
            s.nextFireDate = Date().addingTimeInterval(TimeInterval(intervalSeconds))
        case .daily:
            s.nextFireDate = Calendar.current.nextDate(
                after: Date(),
                matching: DateComponents(hour: dailyHour, minute: dailyMinute),
                matchingPolicy: .nextTime
            ) ?? Date().addingTimeInterval(86400)
        case .weekly:
            s.nextFireDate = Calendar.current.nextDate(
                after: Date(),
                matching: DateComponents(hour: dailyHour, minute: dailyMinute, weekday: weeklyDayOfWeek),
                matchingPolicy: .nextTime
            ) ?? Date().addingTimeInterval(604800)
        }

        s.isEnabled = ScheduleEditorPersistencePolicy.enabledStateAfterSave(existingIsEnabled: schedule?.isEnabled)
        s.updatedAt = Date()

        if schedule == nil {
            modelContext.insert(s)
        }

        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        dismiss()
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func toggleEnabled() {
        guard let s = schedule else { return }
        s.isEnabled.toggle()
        s.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        dismiss()
    }

    private func deleteSchedule() {
        guard let s = schedule else { return }
        modelContext.delete(s)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        dismiss()
    }
}
