import Foundation
import Testing

@Suite("TaskMainView crash regressions")
struct TaskMainViewCrashRegressionTests {
    @Test("Docker recovery ownership is app-scoped across main windows")
    func dockerRecoveryOwnershipIsAppScoped() throws {
        let contentSource = try fileText("Astra/Views/ContentView.swift")
        let appSource = try fileText("Astra/ASTRAApp.swift")

        #expect(contentSource.contains("@ObservedObject var dockerImageRecovery: DockerImageRecoveryCoordinator"))
        #expect(!contentSource.contains("@StateObject private var dockerImageRecovery = DockerImageRecoveryCoordinator()"))
        #expect(appSource.contains("@StateObject private var dockerImageRecovery = DockerImageRecoveryCoordinator()"))
        #expect(appSource.contains("dockerImageRecovery: dockerImageRecovery"))
    }

    @Test("Docker recovery reconciliation honors the workspace recovery export flag")
    func dockerRecoveryReconciliationHonorsExportFlag() throws {
        let appSource = try fileText("Astra/ASTRAApp.swift")
        let reconcilerSource = try fileText("Astra/Services/Runtime/DockerImageRecoveryReconciler.swift")

        #expect(appSource.contains("reconcileInterruptedRecoveries(modelContext: modelContext, autoExportWorkspaces: !skipWorkspaceRecovery)"))
        #expect(reconcilerSource.contains("autoExportWorkspaces: Bool = true"))
        #expect(reconcilerSource.contains("saveWithoutAutoExport(modelContext: modelContext"))
    }

    @Test("Workspace deletion invalidates task Docker recovery before the cascade")
    func workspaceDeletionInvalidatesDockerRecoveryBeforeCascade() throws {
        let source = try fileText("Astra/Views/ContentView.swift")
        let deleteStart = try #require(source.range(of: "private func deleteWorkspace(_ ws: Workspace)"))
        let deleteEnd = try #require(source[deleteStart.upperBound...].range(of: "\n    private func importWorkspace()"))
        let deleteSource = String(source[deleteStart.lowerBound..<deleteEnd.lowerBound])
        let invalidation = try #require(deleteSource.range(of: "dockerImageRecovery.invalidateIfTaskDeleted"))
        let cascade = try #require(deleteSource.range(of: "coordinator.deleteWorkspace"))

        #expect(deleteSource.contains("for task in ws.tasks"))
        #expect(invalidation.lowerBound < cascade.lowerBound)
    }

    @Test("Composer submissions fail closed while task Docker recovery is active")
    func composerSubmissionsGateDockerRecovery() throws {
        let source = try fileText("Astra/Views/TaskMainView.swift")
        let sendStart = try #require(source.range(of: "private func sendMessage()"))
        let sendEnd = try #require(source[sendStart.upperBound...].range(of: "\n    private func recordMCPInstallCommand"))
        let sendSource = String(source[sendStart.lowerBound..<sendEnd.lowerBound])
        let conversationStart = try #require(source.range(of: "private func sendConversationMessage(_ msg: String)"))
        let conversationEnd = try #require(source[conversationStart.upperBound...].range(of: "\n    private func sendPlanningMessage"))
        let conversationSource = String(source[conversationStart.lowerBound..<conversationEnd.lowerBound])

        #expect(sendSource.contains("sendAction.launchesProviderWork && dockerImageRecovery.isBusy(for: task.id)"))
        #expect(sendSource.contains("composer_blocked_docker_recovery"))
        #expect(conversationSource.contains("guard !dockerImageRecovery.isBusy(for: task.id) else"))
        #expect(source.contains("isRunning: task.status == .running || isPlanning || dockerImageRecovery.isBusy(for: task.id)"))
    }

    @Test("TaskMainView defers selected-task refresh work out of view update callbacks")
    func taskMainViewDefersSelectedTaskRefreshWork() throws {
        let source = try fileText("Astra/Views/TaskMainView.swift")

        #expect(source.contains(".task(id: task.id) {\n            await initializeDisplayedTaskState()\n        }"))
        #expect(source.contains("private func deferTaskViewMutation(_ operation: @escaping @MainActor () -> Void)"))
        #expect(!source.contains(".onChange(of: task.id) {\n            PerformanceTelemetry.log(\"chat_open_selected_task\""))
        #expect(!source.contains(".onAppear {\n            PerformanceTelemetry.log(\"chat_open_selected_task\""))
        #expect(source.contains("onSnapshotChange: {\n                    deferTaskViewMutation {"))
        #expect(source.contains("onGeneratedFilesChange: {\n                    deferTaskViewMutation {"))
        #expect(source.contains(".onPreferenceChange(ChatBottomPositionPreferenceKey.self) { bottomMinY in\n                    deferTaskViewMutation {"))
        #expect(source.contains(".onPreferenceChange(ChatTopPositionPreferenceKey.self) { topMinY in\n                    deferTaskViewMutation {"))
        #expect(!source.contains(".defaultScrollAnchor(.bottom)"))
        #expect(source.contains("guard isNowAtBottom != isChatAtBottom else { return }"))
    }

    @Test("Task policy details do not use missing SF Symbols")
    func taskPolicyDetailsAvoidMissingSFSymbols() throws {
        for path in [
            "Astra/Views/TaskMainView.swift",
            "Astra/Views/Components/ComposerToolbar.swift"
        ] {
            let source = try fileText(path)
            #expect(!source.contains("checklist.shield"), "\(path) should avoid symbols missing from the system symbol set")
        }
    }

    @Test("Right-rail setup work is deferred out of SwiftUI lifecycle callbacks")
    func rightRailSetupDefersViewModelMutation() throws {
        let dockerSource = try fileText("Astra/Views/WorkspaceDockerSectionView.swift")
        #expect(dockerSource.contains(".task(id: setupSignature) {\n            await setupAfterViewUpdate()\n        }"))
        #expect(dockerSource.contains("private var setupSignature: String"))
        #expect(dockerSource.contains("private func setupAfterViewUpdate() async"))
        #expect(dockerSource.contains("viewModel.setup(for: workspace, selectedTask: selectedTask)"))
        #expect(!dockerSource.contains(".onAppear {\n            viewModel.setup(for: workspace, selectedTask: selectedTask)"))
        #expect(!dockerSource.contains(".onChange(of: selectedTask?.id) {\n            viewModel.setup(for: workspace, selectedTask: selectedTask)"))

        let gitSource = try fileText("Astra/Views/WorkspaceGitSectionView.swift")
        #expect(gitSource.contains(".task(id: repositorySetupSignature) {\n                await setupRepositoryPanelAfterViewUpdate()\n            }"))
        #expect(gitSource.contains("private var repositorySetupSignature: String"))
        #expect(gitSource.contains("private func setupRepositoryPanelAfterViewUpdate() async"))
        #expect(!gitSource.contains(".onAppear {\n            viewModel.setup(for: workspace, selectedTask: selectedTask)"))
        #expect(!gitSource.contains(".onChange(of: selectedTask?.id) {\n            viewModel.setup(for: workspace, selectedTask: selectedTask)"))
    }

    @Test("Canvas refresh signatures do not walk live task relationships in SwiftUI body")
    func canvasRefreshSignaturesAvoidLiveRelationshipWalks() throws {
        for path in [
            "Astra/Views/ContentView.swift",
            "Astra/Views/WorkspaceCanvasPanelView.swift"
        ] {
            let source = try fileText(path)
            #expect(!source.contains("selectedTask.runs.max"), "\(path) should not sort live task runs from body signatures")
            #expect(!source.contains("selectedTask.runs.count"), "\(path) should not count live task runs from body signatures")
            #expect(source.contains("TaskCanvasRefreshSignature"), "\(path) should use the value-snapshot canvas signature")
        }

        let signatureSource = try fileText("Astra/Views/TaskCanvasRefreshSignature.swift")
        #expect(!signatureSource.contains("task.events.count"), "Canvas refresh signatures should use scalar task tokens, not live event relationship counts")
        #expect(!signatureSource.contains("task.runs"), "Canvas refresh signatures should not walk live run relationships")
    }

    @Test("Composer capability snapshot loader reacts to approval changes without name-heavy signatures")
    func composerCapabilitySnapshotLoaderAvoidsStaleApprovalAndNameHeavySignatures() throws {
        let source = try fileText("Astra/Views/ComposerCapabilitySnapshot.swift")

        #expect(source.contains(".onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged))"))
        #expect(source.contains("approvalRefreshID = UUID()"))
        #expect(source.contains("withTaskCancellationHandler"))
        #expect(source.contains("loadTask.cancel()"))
        #expect(source.contains("revisionSignature(for skill: Skill)"))
        #expect(!source.contains("\\($0.id.uuidString):\\($0.name)"))
    }

    @Test("Composer capability work stays out of large SwiftUI body views")
    func composerCapabilityWorkStaysOutOfLargeSwiftUIBodyViews() throws {
        for path in [
            "Astra/Views/ChatPanelView.swift",
            "Astra/Views/TaskMainView.swift"
        ] {
            let source = try fileText(path)
            #expect(!source.contains("@Query(filter: #Predicate<Skill> { $0.isGlobal == true })"), "\(path) should not own global skill queries")
            #expect(!source.contains("@Query(filter: #Predicate<Connector> { $0.isGlobal == true })"), "\(path) should not own global connector queries")
            #expect(!source.contains("@Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })"), "\(path) should not own global tool queries")
            #expect(!source.contains("WorkspaceCapabilities("), "\(path) should not resolve capabilities from render-time computed properties")
            #expect(source.contains("ComposerCapabilitySnapshotLoader"), "\(path) should consume cached composer capability snapshots")
        }
    }

    @Test("Container environment picker keeps text from being squeezed by scope badge")
    func containerEnvironmentPickerKeepsTextFromBeingSqueezedByScopeBadge() throws {
        let dockerSource = try fileText("Astra/Views/WorkspaceDockerSectionView.swift")
        let pickerStart = try #require(dockerSource.range(of: "private var environmentPickerRow"))
        let nextRowStart = try #require(dockerSource[pickerStart.upperBound...].range(of: "private var credentialProjectionRow"))
        let pickerSource = String(dockerSource[pickerStart.lowerBound..<nextRowStart.lowerBound])

        #expect(pickerSource.contains("rowTitle(viewModel.environmentPickerTitle)"))
        #expect(pickerSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(pickerSource.contains("Image(systemName: \"chevron.up.chevron.down\")"))
        #expect(!pickerSource.contains("RailCountBadge(viewModel.activeScopeLabel)"))
    }

    private func fileText(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
