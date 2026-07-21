import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task activity presentation")
struct TaskActivityPresentationTests {
    private func request(
        for task: AgentTask,
        eventID: UUID = UUID(),
        sequence: Int,
        state: TaskTurnRequestState,
        blockerSummary: String? = nil,
        terminalReason: String? = nil
    ) -> TaskTurnRequestSnapshot {
        let request = TaskTurnRequest(
            task: task,
            messageEventID: eventID,
            sequence: sequence,
            state: state,
            submittedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
        request.blockerSummary = blockerSummary
        request.terminalReason = terminalReason
        return request.snapshot
    }

    @Test("Running wins task-level presentation while queued turns retain their own state")
    func taskActivityUsesDeterministicPrecedence() {
        let task = makeTask(status: .completed)
        let resourceWait = request(
            for: task,
            sequence: 1,
            state: .waitingForResource,
            blockerSummary: "Build task is using this workspace"
        )
        let running = request(for: task, sequence: 2, state: .running)

        let activity = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: [resourceWait, running]
        )

        #expect(activity.kind == .running)
        #expect(activity.request?.id == running.id)
        #expect(activity.showsPersistentSidebarGlyph)

        let waitingOnly = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: [resourceWait]
        )
        #expect(waitingOnly.kind == .waitingForResource)
        #expect(waitingOnly.sidebarSubtitle == "Build task is using this workspace")
        #expect(waitingOnly.dockTitle == "Waiting for workspace")
    }

    @Test("A queued follow-up behind a running task stays individually retractable")
    func queuedFollowUpBehindRunningTaskStaysCancellable() {
        let task = makeTask(status: .running)
        let queued = request(
            for: task,
            sequence: 3,
            state: .waitingForWorker
        )

        // Initial run active with no running request (send-while-running).
        let noRunningRequest = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: [queued]
        )
        #expect(noRunningRequest.kind == .running)
        #expect(noRunningRequest.waitingRequest?.id == queued.id)
        #expect(noRunningRequest.cancellableQueuedRequest?.id == queued.id)
        #expect(noRunningRequest.dockTitle == "Message queued")
        #expect(noRunningRequest.dockSummary?.isEmpty == false)

        // A running request plus a later queued follow-up.
        let running = request(for: task, sequence: 2, state: .running)
        let withRunningRequest = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: [running, queued]
        )
        #expect(withRunningRequest.kind == .running)
        #expect(withRunningRequest.request?.id == running.id)
        #expect(withRunningRequest.cancellableQueuedRequest?.id == queued.id)

        // No queued follow-up: running rows keep their dockless presentation.
        let runningOnly = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: task.status,
            requests: [running]
        )
        #expect(runningOnly.dockTitle == nil)
        #expect(runningOnly.dockSummary == nil)
        #expect(runningOnly.cancellableQueuedRequest == nil)

        // Waiting rows keep owning their own request.
        let waitingOnly = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: .completed,
            requests: [queued]
        )
        #expect(waitingOnly.kind == .waitingForWorker)
        #expect(waitingOnly.cancellableQueuedRequest?.id == queued.id)

        // An admitted (starting) request is already owned by a worker: scoped
        // cancellation must never target it, only a queued follow-up.
        let admitted = request(for: task, sequence: 2, state: .admitted)
        let starting = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: .completed,
            requests: [admitted, queued]
        )
        #expect(starting.kind == .starting)
        #expect(starting.cancellableQueuedRequest?.id == queued.id)
        let startingAlone = TaskActivityPresentation.resolve(
            taskID: task.id,
            taskStatus: .completed,
            requests: [admitted]
        )
        #expect(startingAlone.cancellableQueuedRequest == nil)
    }

    @Test("Message lifecycle resolves by durable event identity, never message text or timestamp")
    func messageLifecycleUsesEventID() {
        let task = makeTask(status: .completed)
        let firstEventID = UUID()
        let secondEventID = UUID()
        let first = request(for: task, eventID: firstEventID, sequence: 1, state: .waitingForWorker)
        let second = request(
            for: task,
            eventID: secondEventID,
            sequence: 2,
            state: .waitingForResource,
            blockerSummary: "Report task is using this workspace"
        )

        let firstChip = TaskTurnMessageLifecyclePresentation.resolve(
            messageEventID: firstEventID,
            requests: [first, second]
        )
        let secondChip = TaskTurnMessageLifecyclePresentation.resolve(
            messageEventID: secondEventID,
            requests: [first, second]
        )

        #expect(firstChip?.title == "Queued")
        #expect(secondChip?.title == "Waiting for workspace")
        #expect(secondChip?.detail == "Report task is using this workspace")
        #expect(TaskTurnMessageLifecyclePresentation.resolve(messageEventID: UUID(), requests: [first, second]) == nil)
    }

    @Test("Conversation snapshot carries the durable event ID into its user bubble")
    func conversationSnapshotPreservesUserMessageEventID() {
        let task = makeTask(goal: "Original request")
        let event = makeEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Same text can be submitted twice",
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [event],
            runs: []
        )
        guard case let .userMessage(eventID, text, _) = snapshot.conversationItems.last else {
            Issue.record("Expected durable user-message bubble")
            return
        }
        #expect(eventID == event.id)
        #expect(text == event.payload)
    }

    @Test("Waiting and terminal states carry visible, accessible labels")
    func waitingAndTerminalStatesStayExplainable() {
        let task = makeTask(status: .completed)
        let eventID = UUID()
        let waiting = request(for: task, eventID: eventID, sequence: 1, state: .waitingForWorker)
        let activity = TaskActivityPresentation.resolve(taskID: task.id, taskStatus: task.status, requests: [waiting])

        #expect(activity.sidebarDescription == "Waiting for a worker")
        #expect(
            SidebarThreadRowLayout.showsStatusIcon(
                for: .completed,
                isUnread: false,
                isHovered: false,
                isSelected: false,
                activity: activity
            )
        )

        let failed = request(
            for: task,
            eventID: UUID(),
            sequence: 2,
            state: .failed,
            terminalReason: "Workspace became unavailable"
        )
        let cancelled = request(for: task, eventID: UUID(), sequence: 3, state: .cancelled)
        let failedChip = TaskTurnMessageLifecyclePresentation.resolve(messageEventID: failed.messageEventID, requests: [failed])
        let cancelledChip = TaskTurnMessageLifecyclePresentation.resolve(messageEventID: cancelled.messageEventID, requests: [cancelled])

        #expect(failedChip?.isVisible == true)
        #expect(failedChip?.accessibilityLabel == "Couldn’t start. Workspace became unavailable")
        #expect(cancelledChip?.isVisible == true)
        #expect(cancelledChip?.accessibilityLabel == "Cancelled")
    }

    @Test("Workspace index counts waiting work independently from running work")
    func workspaceActivityCountsAreDistinct() {
        let workspace = makeWorkspace()
        let runningTask = makeTask(status: .running, workspace: workspace)
        let waitingTask = makeTask(status: .completed, workspace: workspace)
        let waiting = request(for: waitingTask, sequence: 1, state: .waitingForResource)
        let activities = TaskActivityPresentation.resolveByTaskID(
            tasks: [runningTask, waitingTask],
            requests: [waiting]
        )

        let index = SidebarTaskIndex(
            tasks: [runningTask, waitingTask],
            searchText: "",
            taskActivities: activities
        )
        #expect(index.runningTaskCount(in: workspace) == 1)
        #expect(index.waitingTaskCount(in: workspace) == 1)
        #expect(index.reviewTasks(for: workspace).map(\.id) == [runningTask.id, waitingTask.id])
    }

    @Test("Waiting counts include tasks the user already marked done")
    func waitingCountIncludesDoneTasks() {
        let workspace = makeWorkspace()
        let doneTask = makeTask(status: .completed, workspace: workspace)
        doneTask.isDone = true
        let waiting = request(for: doneTask, sequence: 1, state: .waitingForWorker)
        let activities = TaskActivityPresentation.resolveByTaskID(
            tasks: [doneTask],
            requests: [waiting]
        )

        let index = SidebarTaskIndex(
            tasks: [doneTask],
            searchText: "",
            taskActivities: activities
        )
        // Submission never clears `isDone`, so a done-filter here would hide
        // the saved follow-up whenever the workspace drawer is collapsed.
        #expect(index.waitingTaskCount(in: workspace) == 1)
        #expect(SidebarTaskIndex.isSidebarReviewTask(doneTask, activity: activities[doneTask.id]))
    }

    @Test("Running count keeps done tasks whose durable follow-up is executing")
    func runningCountIncludesDoneTasksWithRunningRequest() {
        let workspace = makeWorkspace()
        let doneTask = makeTask(status: .running, workspace: workspace)
        doneTask.isDone = true
        let running = request(for: doneTask, sequence: 1, state: .running)
        // A done task running WITHOUT a durable request stays excluded — the
        // user closed it and no explicit follow-up is executing.
        let doneNoRequest = makeTask(status: .running, workspace: workspace)
        doneNoRequest.isDone = true

        let activities = TaskActivityPresentation.resolveByTaskID(
            tasks: [doneTask, doneNoRequest],
            requests: [running]
        )
        let index = SidebarTaskIndex(
            tasks: [doneTask, doneNoRequest],
            searchText: "",
            taskActivities: activities
        )
        // The waiting count already includes done tasks; the indicator must
        // not vanish at the exact moment the waiting turn starts running.
        #expect(index.runningTaskCount(in: workspace) == 1)
    }

    @Test("Failure chips distinguish admission failures from post-start failures")
    func failureChipsDistinguishAdmissionFromRuntimeFailures() {
        let task = makeTask(status: .failed)
        let neverStarted = request(
            for: task,
            sequence: 1,
            state: .failed,
            terminalReason: "task_folder_create_failed"
        )

        let started = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 2,
            state: .running
        )
        started.startedAt = Date()
        started.state = .failed
        started.terminalReason = "provider_exit_1"
        let startedSnapshot = started.snapshot

        let admissionChip = TaskTurnMessageLifecyclePresentation.resolve(
            messageEventID: neverStarted.messageEventID,
            requests: [neverStarted]
        )
        let runtimeChip = TaskTurnMessageLifecyclePresentation.resolve(
            messageEventID: startedSnapshot.messageEventID,
            requests: [startedSnapshot]
        )

        #expect(admissionChip?.title == "Couldn’t start")
        #expect(runtimeChip?.title == "Run failed")
    }

    @Test("resolveByTaskID matches each task to only its own requests")
    func resolveByTaskIDGroupsRequestsPerTaskCorrectly() {
        let workspace = makeWorkspace()
        let taskA = makeTask(status: .completed, workspace: workspace)
        let taskB = makeTask(status: .completed, workspace: workspace)
        let taskC = makeTask(status: .completed, workspace: workspace)
        let waitingA = request(for: taskA, sequence: 1, state: .waitingForWorker)
        let runningB = request(for: taskB, sequence: 1, state: .running)
        // taskC has no requests at all — its presentation must idle out
        // rather than pick up a sibling task's request from the shared array.

        let activities = TaskActivityPresentation.resolveByTaskID(
            tasks: [taskA, taskB, taskC],
            requests: [waitingA, runningB]
        )

        #expect(activities[taskA.id]?.kind == .waitingForWorker)
        #expect(activities[taskA.id]?.request?.id == waitingA.id)
        #expect(activities[taskB.id]?.kind == .running)
        #expect(activities[taskB.id]?.request?.id == runningB.id)
        #expect(activities[taskC.id]?.kind == .idle)
        #expect(activities[taskC.id]?.request == nil)
    }
}
