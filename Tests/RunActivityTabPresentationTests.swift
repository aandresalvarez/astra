import AppKit
import Foundation
import SwiftUI
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

    @Test("plan-only runs keep activity details reachable")
    func planOnlyRunHasVisibleDetails() {
        let presentation = RunActivityPresentation.empty

        #expect(!presentation.hasVisibleDetails(hasPlanItems: false))
        #expect(presentation.hasVisibleDetails(hasPlanItems: true))
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
            historyAnchorID: nil
        )
        let expanded = RunActivityProgressTimelinePresentation(
            messages: messages,
            planItems: planItems,
            historyAnchorID: messages.last?.id
        )

        #expect(compact.phases.map(\.status) == [.completed, .active, .upcoming])
        #expect(compact.visibleMessages.map(\.text) == ["Update 2", "Update 3", "Update 4"])
        #expect(compact.hiddenMessageCount == 2)
        #expect(expanded.visibleMessages == messages)
        #expect(expanded.hiddenMessageCount == 0)
        #expect(expanded.isBrowsingHistory)
    }

    @Test("completed plans keep their progress attached to the final phase")
    func completedPlanProgressAttachment() {
        let timeline = RunActivityProgressTimelinePresentation(
            messages: [progressMessage(index: 0)],
            planItems: [
                TaskProtocolTodoItem(id: "inspect", text: "Inspect", status: .done),
                TaskProtocolTodoItem(id: "verify", text: "Verify", status: .done)
            ],
            historyAnchorID: nil
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

    @Test("live run activity limits clock invalidation to the elapsed badge")
    func liveRunActivityLimitsClockInvalidationToElapsedBadge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskMainView.swift"),
            encoding: .utf8
        )

        let disclosureStart = try #require(source.range(of: "private func runActivityDisclosureContent("))
        let disclosureEnd = try #require(
            source[disclosureStart.upperBound...].range(of: "private func runActivityDisclosureTitle(")
        )
        let disclosure = String(source[disclosureStart.lowerBound..<disclosureEnd.lowerBound])
        #expect(disclosure.components(separatedBy: "TimelineView(.periodic(from: .now, by: 1))").count - 1 == 1)

        let summaryStart = try #require(source.range(of: "private func runActivitySummaryPartsText("))
        let summaryEnd = try #require(
            source[summaryStart.upperBound...].range(of: "private func runActivityDetails(")
        )
        let summary = String(source[summaryStart.lowerBound..<summaryEnd.lowerBound])
        #expect(!summary.contains("TimelineView"))
        #expect(!summary.contains("now: Date"))

        let badgeStart = try #require(source.range(of: "private func runActivityLiveBadge("))
        let badgeEnd = try #require(
            source[badgeStart.upperBound...].range(of: "private func compactLiveDuration(")
        )
        let badge = String(source[badgeStart.lowerBound..<badgeEnd.lowerBound])
        #expect(!badge.contains(".animation("))
        #expect(!badge.contains("sin("))
    }

    @Test("update history anchor is tracked independently for each run")
    func updateHistoryState() {
        let otherRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let anchorID = progressMessage(index: 12).id
        var state = RunActivityDisclosureState()

        state.setUpdateHistoryAnchor(anchorID, runID: Self.runID)

        #expect(state.updateHistoryAnchor(runID: Self.runID) == anchorID)
        #expect(state.updateHistoryAnchor(runID: otherRunID) == nil)

        state.setUpdateHistoryAnchor(nil, runID: Self.runID)
        #expect(state.updateHistoryAnchor(runID: Self.runID) == nil)
    }

    @Test("2,500 updates remain in stable bounded history pages")
    func largeProgressHistoryUsesBoundedStablePages() throws {
        let messages = (0..<2_500).map(progressMessage(index:))
        let latest = RunActivityProgressTimelinePresentation(
            messages: messages,
            planItems: [],
            historyAnchorID: messages.last?.id
        )

        #expect(latest.visibleMessages.count == RunActivityProgressTimelinePresentation.historyPageSize)
        #expect(latest.visibleMessages.first?.text == "Update 2480")
        #expect(latest.visibleMessages.last?.text == "Update 2499")
        #expect(latest.olderMessageCount == 2_480)
        #expect(latest.newerMessageCount == 0)

        let originalPageIDs = latest.visibleMessages.map(\.id)
        let appendedMessages = messages + [progressMessage(index: 2_500)]
        let stableAfterAppend = RunActivityProgressTimelinePresentation(
            messages: appendedMessages,
            planItems: [],
            historyAnchorID: messages.last?.id
        )
        #expect(stableAfterAppend.visibleMessages.map(\.id) == originalPageIDs)
        #expect(stableAfterAppend.newerMessageCount == 1)

        var anchorID = try #require(latest.latestPageAnchorID)
        var visitedIDs = Set<UUID>()
        while true {
            let page = RunActivityProgressTimelinePresentation(
                messages: messages,
                planItems: [],
                historyAnchorID: anchorID
            )
            #expect(page.visibleMessages.count <= RunActivityProgressTimelinePresentation.historyPageSize)
            visitedIDs.formUnion(page.visibleMessages.map(\.id))
            guard let olderAnchorID = page.olderPageAnchorID else { break }
            anchorID = olderAnchorID
        }
        #expect(visitedIDs.count == messages.count)
    }

    @Test("progress rows retain a fixed visual line budget")
    func progressRowsRetainFixedVisualLineBudget() throws {
        #expect(RunActivityLayout.progressMessageLineLimit == 4)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/RunActivityTabsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".lineLimit(RunActivityLayout.progressMessageLineLimit)"))
        #expect(!source.contains(".lineLimit(presentation.showsAllMessages ? nil"))
    }

    @MainActor
    @Test("2,500-update timeline renders within a bounded surface")
    func largeProgressHistoryHasBoundedRenderedHeight() throws {
        let messages = (0..<2_500).map(progressMessage(index:))
        let presentation = RunActivityProgressTimelinePresentation(
            messages: messages,
            planItems: [],
            historyAnchorID: messages.last?.id
        )
        let host = NSHostingView(rootView: RunActivityProgressTimelineView(
            presentation: presentation,
            isRunning: true,
            onSelectHistoryAnchor: { _ in }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        let width = host.widthAnchor.constraint(equalToConstant: 620)
        width.isActive = true
        defer { width.isActive = false }

        host.layoutSubtreeIfNeeded()
        let renderedHeight = host.fittingSize.height

        #expect(renderedHeight > 0)
        #expect(renderedHeight < 4_000, "bounded page rendered at \(renderedHeight) points")
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
