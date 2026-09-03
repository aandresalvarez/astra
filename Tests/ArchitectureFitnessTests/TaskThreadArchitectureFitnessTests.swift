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
}
