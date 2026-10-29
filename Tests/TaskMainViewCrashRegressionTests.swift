import Foundation
import Testing

@Suite("TaskMainView crash regressions")
struct TaskMainViewCrashRegressionTests {
    @Test("TaskMainView defers selected-task refresh work out of view update callbacks")
    func taskMainViewDefersSelectedTaskRefreshWork() throws {
        let source = try fileText("Astra/Views/TaskMainView.swift")

        #expect(source.contains(".task(id: task.persistentModelID) {\n            await initializeDisplayedTaskState()\n        }"))
        #expect(source.contains("private func deferTaskViewMutation(_ operation: @escaping @MainActor () -> Void)"))
        #expect(!source.contains(".onChange(of: task.id) {\n            PerformanceTelemetry.log(\"chat_open_selected_task\""))
        #expect(!source.contains(".onAppear {\n            PerformanceTelemetry.log(\"chat_open_selected_task\""))
        // The observer callbacks are methods, kept out of `body`'s modifier
        // chain for the type-checker, and each defers before anything else.
        #expect(source.contains("onSnapshotChange: { noteThreadSnapshotChange() }"))
        #expect(source.contains("onGeneratedFilesChange: { noteGeneratedFilesChange() }"))
        #expect(source.contains("private func noteThreadSnapshotChange() {\n        deferTaskViewMutation {"))
        #expect(source.contains("private func noteGeneratedFilesChange() {\n        deferTaskViewMutation {"))
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
        let owner = try fileText("Astra/Views/WorkspaceRailEnvironmentLifecycle.swift")
        #expect(owner.contains(".task(id: RepositoryContext("))
        #expect(owner.contains(".task(id: ContainerContext("))
        #expect(owner.contains("guard await deferViewUpdate()"))
        #expect(owner.contains("Task.sleep(for: .milliseconds(1))"))
        #expect(owner.contains("return !Task.isCancelled"))
        let rail = try fileText("Astra/Views/WorkspaceRightRailView.swift")
        #expect(rail.contains(".modifier(WorkspaceRailEnvironmentLifecycle("))
        for path in ["Astra/Views/WorkspaceGitSectionView.swift", "Astra/Views/WorkspaceDockerSectionView.swift"] {
            let child = try fileText(path)
            #expect(!child.contains("viewModel.setup("), "Disclosure must not own model setup")
            #expect(!child.contains("viewModel.pauseRefresh()"), "Folding controls must not pause the visible summary")
        }

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

        // The one-line row (rail v2) gives the key layout priority over the
        // trailing value, so a long scope value can never squeeze the title.
        #expect(pickerSource.contains("key: viewModel.environmentPickerTitle"))
        #expect(pickerSource.contains("Image(systemName: \"chevron.up.chevron.down\")"))
        #expect(!pickerSource.contains("RailCountBadge"))
        let rowLineStart = try #require(dockerSource.range(of: "private func rowLine<Trailing: View>("))
        let rowLineSource = String(dockerSource[rowLineStart.lowerBound...])
        #expect(rowLineSource.contains(".layoutPriority(1)"))
        #expect(rowLineSource.contains(".frame(maxWidth: .infinity, minHeight: Layout.rowHeight, alignment: .leading)"))
    }

    private func fileText(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
