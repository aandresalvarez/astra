import Foundation
import Testing

@Suite("TaskMainView crash regressions")
struct TaskMainViewCrashRegressionTests {
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
