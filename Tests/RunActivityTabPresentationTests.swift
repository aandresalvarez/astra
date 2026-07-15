import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Run activity tab presentation")
struct RunActivityTabPresentationTests {
    private static let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!

    @Test("available activity tabs follow the scan-first order")
    func tabOrder() {
        let run = completedRunSnapshot()
        let activity = TaskRunActivity(
            tools: [],
            toolCalls: [
                TaskToolCall(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000511")!,
                    payload: "Using tool: Bash: echo ready"
                )
            ],
            toolResults: [
                TaskToolResult(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000512")!,
                    payload: "ready"
                )
            ],
            notices: [],
            fileChanges: [],
            hasOmittedFileChanges: false,
            permissionManifest: nil
        )
        let presentation = RunActivityPresentation(
            run: run,
            activity: activity,
            notices: [],
            progressMessages: [progressMessage(index: 0)]
        )

        let tabs = presentation.tabDescriptors(hasPlanItems: false)

        #expect(tabs.map(\.tab) == [.updates, .tools, .logs])
        #expect(tabs.map(\.count) == [1, 1, 1])
    }

    @Test("plan state keeps Updates available before narration arrives")
    func planKeepsUpdatesAvailable() {
        let presentation = RunActivityPresentation(
            run: completedRunSnapshot(),
            activity: .empty,
            notices: []
        )

        #expect(presentation.tabDescriptors(hasPlanItems: false).map(\.tab) == [.logs])
        #expect(presentation.tabDescriptors(hasPlanItems: true).map(\.tab) == [.updates, .logs])
        #expect(presentation.tabDescriptors(hasPlanItems: false).first?.count == nil)
    }

    @Test("tab selection is per-run and survives disclosure toggles")
    func selectionSurvivesDisclosureToggle() {
        let runID = Self.runID
        let presentation = RunActivityPresentation(
            run: completedRunSnapshot(),
            activity: .empty,
            notices: [],
            progressMessages: [progressMessage(index: 0)]
        )
        let tabs = [
            RunActivityTabDescriptor(tab: .updates, count: 1),
            RunActivityTabDescriptor(tab: .tools, count: 2)
        ]
        var state = RunActivityDisclosureState()

        #expect(state.selectedTab(runID: runID, availableTabs: tabs) == .updates)
        state.select(.tools, runID: runID, availableTabs: tabs)
        state.toggle(runID: runID, presentation: presentation)
        state.toggle(runID: runID, presentation: presentation)

        #expect(state.selectedTab(runID: runID, availableTabs: tabs) == .tools)
        #expect(state.selectedTab(runID: runID, availableTabs: Array(tabs.prefix(1))) == .updates)
    }

    @Test("progress timeline uses typed plan order and caps live narration")
    func progressTimelinePresentation() {
        let messages = (0..<5).map(progressMessage(index:))
        let planItems = [
            TaskProtocolTodoItem(id: "inspect", text: "Inspect package", status: .done),
            TaskProtocolTodoItem(id: "fix", text: "Fix staging", status: .pending),
            TaskProtocolTodoItem(id: "validate", text: "Validate output", status: .pending)
        ]

        let compact = RunActivityProgressTimelinePresentation(
            messages: messages,
            planItems: planItems,
            showsAllMessages: false
        )
        let expanded = RunActivityProgressTimelinePresentation(
            messages: messages,
            planItems: planItems,
            showsAllMessages: true
        )

        #expect(compact.phases.map(\.status) == [.completed, .active, .upcoming])
        #expect(compact.visibleMessages.map(\.text) == ["Update 2", "Update 3", "Update 4"])
        #expect(compact.hiddenMessageCount == 2)
        #expect(expanded.visibleMessages == messages)
        #expect(expanded.hiddenMessageCount == 0)
    }

    @Test("completed plans keep their progress attached to the final phase")
    func completedPlanProgressAttachment() {
        let timeline = RunActivityProgressTimelinePresentation(
            messages: [progressMessage(index: 0)],
            planItems: [
                TaskProtocolTodoItem(id: "inspect", text: "Inspect", status: .done),
                TaskProtocolTodoItem(id: "verify", text: "Verify", status: .done)
            ],
            showsAllMessages: false
        )

        #expect(timeline.phases.map(\.status) == [.completed, .completed])
        #expect(timeline.messageAttachmentPhaseID == "verify")
        #expect(timeline.visibleMessages.count == 1)
    }

    @Test("run disclosure exposes a forgiving pointer target")
    func disclosureHitTarget() {
        #expect(RunActivityLayout.disclosureMinimumHitHeight >= 40)
        #expect(RunActivityLayout.disclosureIconHitFrame >= 28)
    }

    @Test("agent response preserves the disclosure as an accessibility control")
    func disclosureAccessibilityContainer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskMainView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func chatAgentBubble("))
        let end = try #require(source[start.upperBound...].range(of: "private func completedEmptyRunNotice()"))
        let bubble = source[start.lowerBound..<end.lowerBound]

        #expect(bubble.contains(".accessibilityElement(children: .contain)"))
        #expect(!bubble.contains(".accessibilityElement(children: .combine)"))
    }

    @Test("update history choice is tracked independently for each run")
    func updateHistoryState() {
        let otherRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        var state = RunActivityDisclosureState()

        state.toggleAllUpdates(runID: Self.runID)

        #expect(state.showsAllUpdates(runID: Self.runID))
        #expect(!state.showsAllUpdates(runID: otherRunID))

        state.toggleAllUpdates(runID: Self.runID)
        #expect(!state.showsAllUpdates(runID: Self.runID))
    }

    private func completedRunSnapshot() -> TaskRunSnapshot {
        let task = makeTask(status: .completed)
        let run = TaskRun(task: task)
        run.id = Self.runID
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 10)
        run.stopReason = "completed"
        return TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))
    }

    private func progressMessage(index: Int) -> TaskRunProgressMessage {
        TaskRunProgressMessage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 600 + index))!,
            text: "Update \(index)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}
