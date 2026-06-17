import SwiftUI
import SwiftData
import ASTRACore

struct NewTaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsSnapshotStore
    var workspace: Workspace?

    @State private var title = ""
    @State private var goal = ""
    @State private var runtimeID = TaskExecutionDefaults.runtime.rawValue
    @State private var model = TaskExecutionDefaults.model
    @State private var tokenBudget = TaskExecutionDefaults.tokenBudget
    @State private var policyLevelRaw = AgentPolicyLevel.review.rawValue
    @State private var isolationStrategy: IsolationStrategy = .sameDirectory
    @State private var validationStrategy: ValidationStrategy = .manual
    @State private var maxTurns = 0
    @State private var testCommand = ""
    @State private var inputFiles: [String] = []
    @State private var contextSnippet = ""
    @State private var constraintsText = ""
    @State private var criteriaText = ""

    private let budgetPresets = TaskExecutionDefaults.budgetPresets
    private let turnPresets = [0, 5, 10, 25, 50, 100]

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !goal.trimmingCharacters(in: .whitespaces).isEmpty &&
        workspace != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Task")
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            TopDividerShade(height: 14)

            // Form
            Form {
                Section("Task") {
                    TextField("Title", text: $title, prompt: Text("e.g., Refactor auth module"))
                        .accessibilityIdentifier("TaskTitleField")
                    TextField("Goal", text: $goal, prompt: Text("What should the agent accomplish?"), axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("TaskGoalField")
                }

                Section("Workspace") {
                    if let ws = workspace {
                        Label(ws.name, systemImage: ws.icon)
                            .foregroundStyle(Stanford.coolGrey)
                    }
                    Picker("Isolation", selection: $isolationStrategy) {
                        Text("Same Directory").tag(IsolationStrategy.sameDirectory)
                        Text("Git Branch").tag(IsolationStrategy.gitBranch)
                        Text("Copy").tag(IsolationStrategy.copy)
                    }
                }

                Section("Execution") {
                    Picker("Provider", selection: $runtimeID) {
                        ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                            Text(runtime.displayName).tag(runtime.rawValue)
                        }
                    }
                    .onChange(of: runtimeID) {
                        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
                        let previousModel = model
                        let resolvedModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                            currentModel: model,
                            to: runtime,
                            cache: runtimeModelCache
                        )
                        model = resolvedModel
                        AppLogger.breadcrumb(action: "new_task_runtime_changed", category: "UI", fields: [
                            "source": "new_task_sheet",
                            "runtime": runtime.rawValue,
                            "previous_model": previousModel,
                            "model": resolvedModel,
                            "model_changed": String(previousModel != resolvedModel)
                        ])
                    }

                    modelSelectionRow

                    Picker("Token Budget", selection: $tokenBudget) {
                        ForEach(budgetPresets, id: \.self) { b in
                            Text(b == 0 ? "Unlimited" : "\(b / 1000)k tokens").tag(b)
                        }
                    }

                    Picker("Agent Policy", selection: $policyLevelRaw) {
                        ForEach(AgentPolicyLevel.primaryCases) { level in
                            Label(level.displayName, systemImage: level.symbolName)
                                .tag(level.rawValue)
                        }
                    }
                    Text(AgentPolicyLevel.normalized(policyLevelRaw).shortDescription)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)

                    Picker("Max Turns", selection: $maxTurns) {
                        ForEach(turnPresets, id: \.self) { t in
                            Text(t == 0 ? "Unlimited" : "\(t) turns").tag(t)
                        }
                    }

                    Picker("Validation", selection: $validationStrategy) {
                        Text("Manual Review").tag(ValidationStrategy.manual)
                        Text("Run Tests").tag(ValidationStrategy.runTests)
                        Text("AI Self-Check").tag(ValidationStrategy.aiCheck)
                    }

                    if validationStrategy == .runTests {
                        TextField("Test Command", text: $testCommand, prompt: Text("e.g., swift test, npm test"))
                    }
                }

                Section("Context Files (optional)") {
                    ForEach(inputFiles, id: \.self) { file in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(file)
                                .font(Stanford.caption(12))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                inputFiles.removeAll { $0 == file }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Add File") {
                            addInputFile()
                        }
                        Spacer()
                    }
                    TextField("Or paste a context snippet", text: $contextSnippet, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Constraints (optional)") {
                    TextField("One per line", text: $constraintsText, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Acceptance Criteria (optional)") {
                    TextField("One per line", text: $criteriaText, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Task") {
                    createTask()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .accessibilityIdentifier("CreateTaskButton")
            }
            .padding()
        }
        .frame(width: 520, height: 680)
        .onAppear {
            let settings = runtimeSettingsSnapshot
            runtimeID = settings.defaultRuntime.rawValue
            model = settings.normalizedDefaultModel
            tokenBudget = settings.defaultBudget
            policyLevelRaw = AgentPolicyDefaults.effectiveLevel(
                workspace: workspace,
                globalDefaultRaw: settings.defaultPolicyLevelRaw
            ).userFacingLevel.rawValue
        }
        .onChange(of: appSettings.runtimeSettings.modelCacheSignature) {
            alignModelWithRuntimeCache()
        }
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

    private func alignModelWithRuntimeCache() {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
        model = RuntimeModelAvailability.normalizedModel(model, for: runtime, cache: runtimeModelCache)
    }

    private var modelSelectionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Model")
            Spacer()
            TextField("Model ID", text: $model, prompt: Text("Type or choose a model"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 220)
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

    private func addInputFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !inputFiles.contains(url.path) {
                    inputFiles.append(url.path)
                }
            }
        }
    }

    private func createTask() {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
        let resolvedModel = RuntimeModelAvailability.normalizedModel(
            model,
            for: runtime,
            cache: runtimeModelCache
        )
        let task = AgentTask(
            title: title.trimmingCharacters(in: .whitespaces),
            goal: goal.trimmingCharacters(in: .whitespaces),
            workspace: workspace,
            tokenBudget: tokenBudget,
            model: resolvedModel,
            runtime: runtime,
            isolationStrategy: isolationStrategy,
            validationStrategy: validationStrategy
        )

        if !constraintsText.isEmpty {
            task.constraints = constraintsText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        if !criteriaText.isEmpty {
            task.acceptanceCriteria = criteriaText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        task.maxTurns = maxTurns
        task.testCommand = testCommand.trimmingCharacters(in: .whitespaces)

        // Add context files and snippet as inputs
        var allInputs = inputFiles
        let snippet = contextSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            allInputs.append(snippet)
        }
        task.inputs = allInputs
        task.status = .queued

        modelContext.insert(task)
        TaskPolicyStore.recordSelection(
            level: AgentPolicyLevel.normalized(policyLevelRaw),
            task: task,
            modelContext: modelContext,
            source: "new_task_sheet"
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        dismiss()
    }
}
