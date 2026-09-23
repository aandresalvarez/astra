import Foundation
import Testing

@Suite("Task thread architecture fitness")
struct TaskThreadArchitectureFitnessTests {
    @Test("Production reads stay storage paged and event driven")
    func productionReadsStayStoragePagedAndEventDriven() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let planTelemetry = try source("Astra/Views/TaskMainViewPerformanceTelemetry.swift", root: root)
        let historyReader = try source("Astra/Services/Tasks/TaskThreadHistoryReader.swift", root: root)
        let viewModel = try source("Astra/Views/TaskThreadViewModel.swift", root: root)

        #expect(!taskMainView.contains("pollSnapshotTriggerWhileLive"))
        #expect(!taskMainView.contains("livePollIntervalNanoseconds"))
        #expect(!taskMainView.contains("task.events.count"))
        #expect(!taskMainView.contains("task.runs.count"))
        #expect(!planTelemetry.contains("task.events"))
        #expect(!planTelemetry.contains("task.runs"))
        #expect(taskMainView.contains("requestSnapshotRefresh(for: task)"))
        #expect(taskMainView.contains("modelContext: modelContext"))
        #expect(historyReader.contains("descriptor.fetchLimit = limit + 1"))
        // State anchors were once fetched once per loaded run, which cost up to
        // 51 main-actor round trips per page. Membership must stay an in-memory
        // filter over a single fetch.
        #expect(!historyReader.contains("for run in runs"))
        #expect(historyReader.contains("let loadedRunIDs = Set(runs.map(\\.id))"))
        // Streaming appends re-read only the rows at or after the tail cursor.
        // Losing either half of that pair silently restores a full page read on
        // every invalidation.
        #expect(historyReader.contains("static func tailPage("))
        #expect(viewModel.contains("historyTailCursor"))
        #expect(!viewModel.contains("loadedHistoryRuns.values.min"))
        #expect(!viewModel.contains("loadedHistoryEvents.values.min"))
        // The reader runs on `TaskThreadHistoryStore`'s background context.
        // Re-isolating it to the main actor, or routing either read around the
        // store, puts the app's largest measured main-actor block back on the
        // UI path. `initialPage` deliberately stays reachable from the view
        // model: it is the count-invariant fallback when a tail read cannot
        // account for every change.
        let historyStore = try source("Astra/Services/Tasks/TaskThreadHistoryStore.swift", root: root)
        #expect(!historyReader.contains("@MainActor"))
        #expect(historyStore.contains("actor TaskThreadHistoryStore"))
        #expect(historyStore.contains("ModelContext(container)"))
        #expect(viewModel.contains("store.initialPage("))
        #expect(viewModel.contains("store.tailPage("))
        #expect(!viewModel.contains("TaskThreadHistoryReader."))
    }

    /// Writable test seams must not ship. `historyFlushResultOverrideForTesting`
    /// is the reason this is a fitness test and not a convention: production
    /// consults it *before* the real pre-read save, so a release build able to
    /// reach it would report a failed save as succeeded and freeze the
    /// transcript silently — the exact defect that seam exists to test.
    /// Read-only `private(set)` counters are deliberately out of scope; they
    /// cannot lie to production.
    @Test("Writable transcript test seams stay out of release builds")
    func writableTranscriptTestSeamsStayOutOfReleaseBuilds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePath = "Astra/Views/TaskThreadViewModel.swift"
        let lines = try source(relativePath, root: root).components(separatedBy: "\n")
        let debugLines = debugGatedLineNumbers(in: lines)

        var seamNames: [String] = []
        var offenders: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let name = writableTestSeamName(in: trimmed) else { continue }
            seamNames.append(name)
            guard !debugGated(index + 1, in: debugLines) else { continue }
            offenders.append("\(relativePath):\(index + 1): \(trimmed)")
        }

        #expect(!seamNames.isEmpty, "Seam scan found nothing to check — the pattern stopped matching.")
        for (index, line) in lines.enumerated() where !debugGated(index + 1, in: debugLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), writableTestSeamName(in: trimmed) == nil else { continue }
            for name in seamNames where trimmed.contains(name) {
                offenders.append("\(relativePath):\(index + 1): \(trimmed)")
            }
        }

        #expect(
            offenders.isEmpty,
            "Writable *ForTesting seams and their call sites must be inside #if DEBUG: \(offenders.sorted())"
        )
    }

    /// Line numbers (1-based) enclosed by an `#if DEBUG`. Nested `#if`s are
    /// tracked by depth so an unrelated inner condition cannot close the gate.
    private func debugGatedLineNumbers(in lines: [String]) -> Set<Int> {
        var gated = Set<Int>()
        var depth = 0
        var debugDepths: [Int] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
                if trimmed.contains("DEBUG") { debugDepths.append(depth) }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if debugDepths.last == depth { debugDepths.removeLast() }
                depth = max(0, depth - 1)
                continue
            }
            if !debugDepths.isEmpty { gated.insert(index + 1) }
        }
        return gated
    }

    private func debugGated(_ line: Int, in gated: Set<Int>) -> Bool {
        gated.contains(line)
    }

    /// `var somethingForTesting` that an outside caller can assign. `let`,
    /// `private(set) var`, functions and computed statics are not seams a
    /// release build can be made to lie with.
    private func writableTestSeamName(in line: String) -> String? {
        guard let range = line.range(of: #"^(?:@\w+\s+)*var\s+[A-Za-z0-9_]*ForTesting\b"#, options: .regularExpression) else {
            return nil
        }
        return line[range]
            .replacingOccurrences(of: #"^(?:@\w+\s+)*var\s+"#, with: "", options: .regularExpression)
    }

    @Test("TaskRun output writes go through the protocol-marker mutators")
    func taskRunOutputWritesGoThroughTheProtocolMarkerMutators() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskRun = try source("Astra/Models/TaskRun.swift", root: root)

        // `hasProtocolEvents` is a cached derivation of `output`, and plan
        // recovery selects candidate runs from it in SQL. Reopening either
        // setter lets a writer move the text without the flag, which silently
        // drops recovered plan progress with no test failure anywhere else.
        #expect(taskRun.contains("public private(set) var output: String"))
        #expect(taskRun.contains("public private(set) var hasProtocolEvents: Bool?"))
        #expect(taskRun.contains("public func setOutput("))
        #expect(taskRun.contains("public func appendOutput("))
        #expect(taskRun.contains("public func refreshProtocolMarkerFlag("))

        // Belt and braces for the day someone relaxes `private(set)`: no
        // run-shaped receiver outside the model may assign the text directly.
        let assignment = try NSRegularExpression(pattern: #"\b\w*[Rr]un\.output\s*(=[^=]|\+=)"#)
        var offenders: [String] = []
        for directory in ["Astra", "ASTRACore", "AppExecutable"] {
            for file in try swiftFiles(under: root.appendingPathComponent(directory))
            where file.lastPathComponent != "TaskRun.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                if assignment.firstMatch(in: text, range: range) != nil {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "These write TaskRun.output directly: \(offenders.joined(separator: ", "))")
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }

    @Test("Transcript rows stay grouped below the outer stack, which must not be lazy")
    func transcriptRowsStayGroupedBelowOuterStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let summaryStart = try #require(taskMainView.range(of: "private func summaryContent(decisionDockVisible: Bool)"))
        let summaryEnd = try #require(
            taskMainView[summaryStart.upperBound...].range(of: "private func recordTranscriptReadinessIfAvailable()")
        )
        let summarySource = String(taskMainView[summaryStart.lowerBound..<summaryEnd.lowerBound])

        #expect(summarySource.contains("VStack(alignment: .leading, spacing: 10) {"))
        // Deliberately NOT lazy, and this second assertion is load-bearing because
        // "LazyVStack(alignment:..." also satisfies the `contains` above. Matched on
        // the call form `LazyVStack(` rather than the bare type name so the
        // explanatory comment at the stack itself — which necessarily names the type
        // it is warning against — does not trip it.
        //
        // A lazy stack keeps an item-phase cache whose `AllItemsPhaseMutation` writes
        // back into the AttributeGraph; combined with the intrinsic-size invalidation
        // every selectable `Text` performs through its `SelectionOverlay`, that forms
        // a non-terminating `GraphHost.flushTransactions()` cycle. It froze the app
        // for 2h56m at 99% CPU on a five-row transcript on 2026-08-18. The full
        // mechanism is written up at the stack itself in TaskMainView.swift.
        #expect(!summarySource.contains("LazyVStack("))
        #expect(summarySource.contains("chatThreadContent(decisionDockVisible: decisionDockVisible)"))
        #expect(!summarySource.contains("ForEach(currentThreadSnapshot.conversationItems)"))
        #expect(taskMainView.contains("private func chatThreadContentBody(decisionDockVisible: Bool)"))
        #expect(taskMainView.contains("ForEach(currentThreadSnapshot.conversationItems) { item in"))
    }

    @Test("Task-wide decision policy is resolved once outside transcript rows")
    func taskWideDecisionPolicyIsResolvedOnceOutsideTranscriptRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let agentBubbleStart = try #require(taskMainView.range(of: "private func chatAgentBubble("))
        let agentBubbleEnd = try #require(
            taskMainView[agentBubbleStart.upperBound...].range(of: "private func completedEmptyRunNotice()")
        )
        let agentBubbleSource = String(taskMainView[agentBubbleStart.lowerBound..<agentBubbleEnd.lowerBound])

        #expect(taskMainView.contains("let dockPresentation = taskDecisionDockPresentation"))
        #expect(taskMainView.components(separatedBy: "taskDecisionDockPresentation").count - 1 == 2)
        #expect(agentBubbleSource.contains("decisionDockVisible: Bool"))
        #expect(!agentBubbleSource.contains("taskDecisionDockPresentation"))
        #expect(!agentBubbleSource.contains("shouldShowTaskDecisionDock"))
    }

    /// Between "shell visible" and "snapshot applied" a large thread spent
    /// 1–1.5 s rendering as a goal bubble over an empty column. The gate keys
    /// on the applied-snapshot readiness for *this* task, so a previous task's
    /// snapshot can never stand in for it.
    @Test("Transcript shows a loading state until its first snapshot applies")
    func transcriptShowsLoadingStateUntilFirstSnapshotApplies() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        #expect(taskMainView.contains(
            "TaskThreadLoadingGate(isLoading: !threadViewModel.appliedSnapshotReadiness.isReady(for: task.id))"
        ))
    }

    /// On the 2026-09-15 production profile, `taskDecisionDockPresentation`
    /// reached `pendingGitHubPullRequest(task:run:)` and `pendingMutations(task:)`
    /// on every body pass — every keystroke — and each faulted every event of a
    /// 362-event thread through `performAndWait`. The answers now live in
    /// `TaskMainViewDecisionOutcomes.swift`, recomputed only when the snapshot
    /// revision or the task's durable revision moves.
    @Test("Decision-dock outcomes are resolved off the snapshot, not per body pass")
    func decisionDockOutcomesAreNotResolvedPerBodyPass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let outcomes = try source("Astra/Views/TaskMainViewDecisionOutcomes.swift", root: root)

        #expect(!taskMainView.contains("hasPendingGitHubPullRequest(task:"))
        #expect(!taskMainView.contains("pendingGitHubPullRequest(task:"))
        #expect(!taskMainView.contains("pendingTargets(task:"))
        #expect(!taskMainView.contains("pendingMutations(task:"))
        #expect(taskMainView.contains(".task(id: decisionOutcomeInputSignature)"))
        #expect(outcomes.contains("threadViewModel.appliedSnapshotRevision"))
        #expect(outcomes.contains("pendingMutations(taskID: task.id, in: modelContext)"))
        #expect(!outcomes.contains("task.events"))
        #expect(!outcomes.contains("task.runs"))
    }

    /// `body` reads `messageText`, so it re-runs on every keystroke, and it
    /// used to build `TaskMissionControlSnapshot` two or three times per pass:
    /// each build a `stat` of the task folder plus a read and decode of
    /// `current_state.json`, on the main thread. The snapshot is now a `@State`
    /// cache rebuilt under `.task(id:)` from a key of scalars, the read happens
    /// detached, and a save of the state file is what invalidates it.
    @Test("Mission-control snapshot is cached, not read from disk per body pass")
    func missionControlSnapshotIsNotReadPerBodyPass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let missionControl = try source("Astra/Views/TaskMainViewMissionControl.swift", root: root)
        let snapshot = try source("Astra/Services/Tasks/TaskMissionControlSnapshot.swift", root: root)
        let stateManager = try source("Astra/Services/Persistence/TaskContextStateManager.swift", root: root)

        // Nothing `body` reaches builds the snapshot or reads the state file.
        #expect(!taskMainView.contains("TaskMissionControlSnapshot.build("))
        #expect(!taskMainView.contains("TaskContextStateManager.load("))
        #expect(!taskMainView.contains("Source.load("))
        #expect(taskMainView.contains("inputs: missionControlSnapshotInputs,"))
        // The refresh is one `.modifier` call on `body`'s chain. With its
        // closures inline, CI's compiler could not type-check the chain.
        #expect(taskMainView.contains(".modifier(TaskMissionControlSnapshotRefresh("))
        #expect(!taskMainView.contains("TaskContextStateSaveObserver("))

        // The key compares values the view already holds: not `messageText`,
        // no relationship faults, no filesystem, and not `updatedAt`, which
        // every runtime event bumps. Comments are skipped because the
        // rationale necessarily names what the code must not touch.
        let inputs = try code(in: snapshot, from: "struct Inputs: Equatable {", to: "static func build(")
        let key = try code(in: missionControl, from: "var missionControlSnapshotInputs:", to: "var missionControlPresentation:")
        for forbidden in ["messageText", "task.artifacts", "task.events", "task.runs", ".taskFolder",
                          "FileManager", "TaskContextStateManager", "updatedAt"] {
            #expect(!inputs.contains(forbidden), "Snapshot inputs must not read \(forbidden)")
            #expect(!key.contains(forbidden), "The snapshot key must not read \(forbidden)")
        }
        #expect(key.contains("stateRevision: missionControlStateRevision"))

        // The load runs off the main actor in a loader cancelled with the
        // `.task(id:)` — not a detached task, which would finish every
        // superseded read — and the model is read only once it returns.
        let recompute = try code(
            in: missionControl,
            from: "func recomputeMissionControlSnapshot() async {",
            to: "func noteContextRefreshForMissionControl()"
        )
        #expect(!recompute.contains("Task.detached("))
        let load = try #require(recompute.range(of: "await TaskMissionControlSnapshot.Source.loaded("))
        let build = try #require(recompute.range(of: "TaskMissionControlSnapshot.build("))
        #expect(load.lowerBound < build.lowerBound)
        let loader = try code(in: snapshot, from: "nonisolated static func loaded(", to: "struct Inputs: Equatable {")
        let cancellation = try #require(loader.range(of: "guard !Task.isCancelled"))
        let read = try #require(loader.range(of: "load(workspacePath:"))
        #expect(cancellation.lowerBound < read.lowerBound)

        // Invalidation: the only write of the file announces itself, and the
        // view turns that announcement into the key's revision.
        #expect(stateManager.components(separatedBy: "saveStateWithoutAudit(").count - 1 == 2)
        #expect(stateManager.contains("TaskContextStateSaveNotifier.post(result, taskID: taskID)"))
        let refresh = try code(in: missionControl, from: "struct TaskMissionControlSnapshotRefresh", to: nil)
        #expect(refresh.contains(".task(id: inputs)"))
        #expect(refresh.contains("TaskContextStateSaveObserver(taskID: inputs.taskID)"))
        #expect(refresh.contains("stateRevision &+= 1"))
        #expect(taskMainView.contains("stateRevision: $missionControlStateRevision,"))
        // The view's own refresh adds a bump only for a folder that moved
        // without a save; bumping on every refresh read a saved file twice.
        #expect(taskMainView.contains("noteContextRefreshForMissionControl()"))
        #expect(!taskMainView.contains("missionControlStateRevision &+= 1"))
        let afterRefresh = try code(
            in: missionControl,
            from: "func noteContextRefreshForMissionControl() {",
            to: "struct TaskMissionControlSnapshotRefresh"
        )
        #expect(afterRefresh.contains("!= missionControlSnapshotCache.taskFolder"))
    }

    /// Two more places `body` reached into the task folder on every keystroke.
    /// The diagnostics key named the folder, which is a `stat` to resolve, and
    /// counted `task.artifacts`. Every run bubble counted its changed files by
    /// finding the folder again and symlink-walking it and each path. Both are
    /// now caches keyed on scalars, read and walked in detached tasks.
    @Test("Task-folder caches key on scalars and read the folder off the main actor")
    func taskFolderCachesDoNotTouchTheFolderPerBodyPass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let caches = try source("Astra/Views/TaskMainViewTaskFolderCaches.swift", root: root)
        let counts = try source("Astra/Services/Tasks/TaskRunVisibleFileChangeCounts.swift", root: root)

        // The bubble reads a cached count; nothing on the body path classifies
        // paths, and both caches refresh under `.task(id:)`.
        #expect(!taskMainView.contains("userFacingFileChangeCount("))
        #expect(!taskMainView.contains("TaskOutputArtifactPathPolicy."))
        #expect(taskMainView.contains("self.visibleFileChangeCount(for: run)"))
        #expect(taskMainView.contains(".task(id: diagnosticFileGroupsInputSignature)"))
        #expect(taskMainView.contains(".task(id: runFileChangeCountInputs)"))

        // Both keys are values the view already holds.
        let diagnosticsKey = try code(
            in: caches,
            from: "var diagnosticFileGroupsInputSignature: String {",
            to: "func recomputeDiagnosticFileGroups()"
        )
        let countsKey = try code(
            in: caches,
            from: "var runFileChangeCountInputs:",
            to: "func visibleFileChangeCount("
        )
        for forbidden in ["messageText", "task.artifacts", "task.events", "task.runs", ".taskFolder",
                          "FileManager", "ResolvedRoot", "relativePath("] {
            #expect(!diagnosticsKey.contains(forbidden), "The diagnostics key must not read \(forbidden)")
            #expect(!countsKey.contains(forbidden), "The changed-file count key must not read \(forbidden)")
        }

        // The folder is found inside the detached work, never before it.
        for (from, to) in [
            ("func recomputeDiagnosticFileGroups() async {", "var runFileChangeCountInputs:"),
            ("func recomputeRunFileChangeCounts() async {", nil as String?)
        ] {
            let recompute = try code(in: caches, from: from, to: to)
            let detached = try #require(recompute.range(of: "Task.detached("))
            let folder = try #require(recompute.range(of: "TaskFolderResolvingAdapter.taskFolder("))
            #expect(detached.lowerBound < folder.lowerBound)
            #expect(!recompute.contains("TaskWorkspaceAccess(task: task).taskFolder"))
        }

        // One root resolution per rebuild; the per-path loop only uses it.
        let counted = try code(in: counts, from: "static func counted(", to: "static func visibleCount(")
        let perPath = try code(in: counts, from: "static func visibleCount(", to: nil)
        #expect(counted.contains("ResolvedRoot(taskFolder)"))
        #expect(!perPath.contains("ResolvedRoot("))
        #expect(perPath.contains("relativePath(path, under: root)"))
    }

    /// `TaskGeneratedFilesTrigger` is built in `TaskThreadChangeObserver.body`,
    /// which re-runs with `TaskMainView.body` on every keystroke. It resolved
    /// the task folder (a `stat`) and counted `task.artifacts` (a relationship
    /// fault) each time. It is now scalars, and new rows arrive as an
    /// announcement from the one service every row goes through. The last
    /// check keeps it that way: a new place that gives a task artifacts has to
    /// announce them, or be reviewed onto this list.
    @Test("The generated-files trigger reads no folder and no relationship")
    func generatedFilesTriggerStaysOffTheFilesystem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let snapshot = try source("Astra/Views/TaskThreadSnapshot.swift", root: root)
        let observers = try source("Astra/Views/TaskMainViewObservers.swift", root: root)
        let service = try source("Astra/Services/Persistence/TaskArtifactPersistenceService.swift", root: root)

        let trigger = try code(in: snapshot, from: "struct TaskGeneratedFilesTrigger: Equatable {", to: nil)
        for forbidden in ["taskFolder", "task.artifacts", "task.events", "task.runs", "FileManager"] {
            #expect(!trigger.contains(forbidden), "The generated-files trigger must not read \(forbidden)")
        }
        #expect(trigger.contains("effectiveWorkspacePath"))

        // The observer turns the service's announcement into the trigger's
        // revision, so a burst of rows still reaches the callback once per update.
        #expect(observers.contains(".onReceive(NotificationCenter.default.publisher(for: .taskArtifactsDidChange))"))
        #expect(observers.contains("artifactsRevision &+= 1"))
        #expect(observers.contains("artifactsRevision: artifactsRevision"))

        // Both entry points announce, and rows are only ever inserted from
        // them: two definitions of `insertArtifact` and three calls.
        #expect(service.components(separatedBy: "TaskArtifactChangeNotifier.post(taskID: task.id)").count - 1 == 2)
        #expect(service.components(separatedBy: "insertArtifact(").count - 1 == 5)

        // Outside the service, artifacts are only built for tasks no view has
        // open yet: an import, a detached launch copy, a scratch fork manifest.
        let reviewed: Set<String> = [
            "Astra/Services/Persistence/TaskArtifactPersistenceService.swift",
            "Astra/Services/Persistence/WorkspaceConfigManager.swift",
            "Astra/Services/Tasks/TaskExecutionLaunchSnapshotApplicator.swift",
            "Astra/Services/Tasks/TaskForkManifestService.swift"
        ]
        let construction = try NSRegularExpression(pattern: #"\bArtifact\(\s*task:"#)
        var builders = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Astra"),
            includingPropertiesForKeys: nil
        )
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard construction.firstMatch(in: text, range: range) != nil else { continue }
            builders.insert(String(url.path.dropFirst(root.path.count + 1)))
        }
        #expect(
            builders == reviewed,
            "New code gives a task artifacts outside TaskArtifactPersistenceService: \(builders.subtracting(reviewed).sorted())"
        )
    }

    @Test("Waiting-turn dock never preempts a live permission decision")
    func waitingTurnDockNeverPreemptsALivePermissionDecision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let dockStart = try #require(
            taskMainView.range(of: "private var taskDecisionDockPresentation: TaskDecisionDockPresentation? {")
        )
        let dockEnd = try #require(
            taskMainView[dockStart.upperBound...].range(of: "private var taskDecisionArtifactPaths: [String] {")
        )
        let dockSource = String(taskMainView[dockStart.lowerBound..<dockEnd.lowerBound])

        // `TaskMainView` is a SwiftUI view and not directly instantiable in
        // headless tests, so — matching the source-scan style already used
        // above for this same property — assert the queued-follow-up
        // waiting dock only preempts `TaskDecisionDockContextBuilder.build`
        // (which is what actually renders Approve/Deny/Stop) when no
        // permission request is open. Without this guard, a follow-up
        // queued behind a running provider that then raises a live
        // permission request leaves the user unable to approve, deny, or
        // stop without first cancelling every queued message.
        #expect(dockSource.contains("!runtimePermissionState.hasOpenApprovalRequest"))
        let guardRange = try #require(dockSource.range(of: "!runtimePermissionState.hasOpenApprovalRequest"))
        let waitingReturnRange = try #require(dockSource.range(of: "return waitingPresentation"))
        #expect(guardRange.lowerBound < waitingReturnRange.lowerBound)
    }

    /// `NSRegularExpression(pattern:)` compiles an ICU program every call, and
    /// the transcript derivation applies these patterns once per line of every
    /// run on every streaming rebuild. Compiling them per call cost 2x the
    /// whole derivation in release measurements, and it is invisible to Swift
    /// optimization because the work happens inside Foundation.
    @Test("Transcript presentation compiles its regexes once, not per line")
    func transcriptPresentationCompilesItsRegexesOnce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var offenders: [String] = []
        for path in [
            "ASTRACore/MarkdownRenderPreparation.swift",
            "ASTRACore/TaskRunAnswerPresentationPolicy.swift"
        ] {
            for (index, line) in try source(path, root: root).components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let compiles = trimmed.contains("NSRegularExpression(pattern:")
                    || trimmed.contains("options: .regularExpression")
                // Only a `static let` at type scope compiles once for the
                // process. A local `let` inside a function recompiles per call.
                guard compiles, !trimmed.hasPrefix("private static let"),
                      !trimmed.hasPrefix("static let") else { continue }
                offenders.append("\(path):\(index + 1): \(trimmed)")
            }
        }
        #expect(offenders.isEmpty, "Regexes on the snapshot build path must be hoisted: \(offenders)")
    }

    /// The build path normalizes once, in `joinedResponsePayloads`. Routing the
    /// result back through `presentation(rawText:)` re-runs sentence repair,
    /// blank-line collapse and the markdown reflow over the same string.
    @Test("Joined response payloads are not normalized a second time")
    func joinedResponsePayloadsAreNotNormalizedTwice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let snapshot = try source("Astra/Views/TaskThreadSnapshot.swift", root: root)
        #expect(snapshot.contains("presentation(normalizedText: finalText)"))
        #expect(!snapshot.contains("presentation(rawText: finalText)"))
    }

    /// `LogSanitizer` rewrites any `[A-Za-z0-9_-]{40,}` run as
    /// `[redacted-token]`, so a telemetry event name that long is written to
    /// the log without its own name. That silently deleted
    /// `task_open_snapshot_main_actor_apply_wait` (exactly 40 characters) from
    /// every production log it ever appeared in.
    @Test("Telemetry event names stay under the log sanitizer's redaction length")
    func telemetryEventNamesStayUnderTheRedactionLength() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Astra"),
            includingPropertiesForKeys: nil
        )
        let pattern = try NSRegularExpression(
            pattern: #"PerformanceTelemetry\.(?:log|logIfNeeded|measure)\(\s*"([A-Za-z0-9_\-]{40,})""#
        )
        var offenders: [String] = []
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                offenders.append("\(url.lastPathComponent): \(text[nameRange])")
            }
        }
        #expect(
            offenders.isEmpty,
            "Event names of 40+ characters are redacted out of the log entirely: \(offenders)"
        )
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The non-comment lines between two markers (or to the end of `text`).
    private func code(in text: String, from start: String, to end: String?) throws -> String {
        let startRange = try #require(text.range(of: start))
        let tail = text[startRange.lowerBound...]
        let endIndex = try end.map { try #require(tail.range(of: $0)).lowerBound } ?? tail.endIndex
        return tail[..<endIndex]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
