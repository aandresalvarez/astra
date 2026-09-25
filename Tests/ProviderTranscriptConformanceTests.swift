import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Replays real provider streams — captured with
/// `script/capture_provider_stream.sh` into `Tests/Fixtures/ProviderStreams` —
/// through the real adapter, event pipeline and recorder, and checks the same
/// transcript contract for every provider.
///
/// The expected transcript comes from the fixture itself, read the way each
/// provider documents its frames, never through ASTRA's parsers. A defect that
/// exists today is listed per fixture in `knownIssues`, scoped to the items it
/// affects: those failures are reported as one known issue, and any other
/// failure of the same check is a real one. When a phase of
/// docs/specs/2026-09-23-provider-message-identity-plan.md fixes a defect, its
/// known issue stops being recorded and the suite fails until the entry is
/// deleted.
@Suite("Provider transcript conformance", .serialized)
@MainActor
struct ProviderTranscriptConformanceTests {
    @Test("Replayed provider stream meets the transcript contract", arguments: ProviderStreamFixture.all)
    func replayedStreamMeetsTranscriptContract(_ fixture: ProviderStreamFixture) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let frames = try fixture.frameLines()
        let truth = ProviderStreamTruth(fixture: fixture, frames: frames)
        #expect(!truth.messages.isEmpty, "fixture has no assistant messages")

        // The fake CLI runs sandboxed, so it reads a copy inside the harness
        // root rather than the test bundle.
        let streamURL = harness.rootURL.appendingPathComponent("\(fixture.provider)-\(fixture.scenario).jsonl")
        try (frames.joined(separator: "\n") + "\n").write(to: streamURL, atomically: true, encoding: .utf8)
        let body = "cat \(HeadlessChatScenarioTests.shQuoteSandboxPath(streamURL.path))\nexit 0"
        let script: String
        switch fixture.runtime {
        case .claudeCode: script = HeadlessChatScenarioTests.claudeScript(body: body)
        case .copilotCLI: script = HeadlessChatScenarioTests.copilotScript(body: body)
        default: script = "#!/bin/sh\n\(body)"
        }
        let executablePath = try harness.writeExecutable(named: fixture.executableName, script: script)

        let restoreStructuredOutput = fixture.runtime == .antigravityCLI
            ? Self.enableAntigravityStructuredOutput(executablePath: executablePath)
            : {}
        defer { restoreStructuredOutput() }

        let task = harness.makeTask(runtime: fixture.runtime, goal: "Draft a short reply to Dana", model: fixture.model)
        // The captures contain real Write / apply_patch / run_command calls. A
        // restricted policy would stop the replay at the first one; the
        // transcript contract is independent of permission enforcement.
        let worker = harness.makeWorker(
            runtime: fixture.runtime,
            executablePath: executablePath,
            permissionPolicy: .autonomous
        )
        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        let output = run.output
        let collapsedOutput = collapsed(output)
        let events = task.events

        report(.runCompletes, of: fixture, failures: run.status == .completed ? [] : [
            (run.stopReason, "run ended \(run.status) with stopReason=\(run.stopReason)")
        ])

        // Two provider messages can carry the same text; each text must be
        // recorded exactly as many times as the provider sent it.
        var expectedMultiplicity: [String: Int] = [:]
        for message in truth.messages { expectedMultiplicity[collapsed(message), default: 0] += 1 }
        let collapsedMessages = truth.messages.map(collapsed)
        report(.eachMessageOnce, of: fixture, failures: truth.messages.enumerated().compactMap { index, message in
            let text = collapsed(message)
            guard truth.messages.firstIndex(where: { collapsed($0) == text }) == index else { return nil }
            let expected = expectedMultiplicity[text] ?? 1
            let occurrences = messageCount(text, in: collapsedOutput, among: collapsedMessages)
            return occurrences == expected
                ? nil
                : (multiplicityItem(message, recorded: occurrences, sent: expected),
                   "recorded \(occurrences)x, sent \(expected)x: \(message.prefix(80))")
        })

        // Lines two messages glued together are not the provider's lines, so
        // only lines the provider actually sent are counted.
        let sent = lineCounts(truth.messages.joined(separator: "\n"))


        // Messages and tool calls must interleave as the provider produced
        // them: a message counts as recorded once the response rows up to that
        // point contain it. Lost messages and tools belong to other checks.
        var recordedSteps: [TranscriptStep] = []
        var responseSoFar = ""
        var seenMessages = Set<Int>()
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            if event.type == TaskEventTypes.Conversation.agentResponse.rawValue {
                responseSoFar += event.payload
                let collapsedSoFar = collapsed(responseSoFar)
                // The k-th message with a given text is recorded once that
                // text has occurred k times, so identical messages on either
                // side of a tool call keep their own positions.
                for (index, message) in truth.messages.enumerated() where !seenMessages.contains(index) {
                    let text = collapsed(message)
                    let rank = truth.messages[..<index].filter { collapsed($0) == text }.count
                    guard messageCount(text, in: collapsedSoFar, among: collapsedMessages) > rank else { continue }
                    seenMessages.insert(index)
                    recordedSteps.append(.message(index))
                }
            } else if event.type == TaskEventTypes.Tool.use.rawValue {
                recordedSteps.append(.tool(toolName(fromUsePayload: event.payload)))
            }
        }
        let expectedSteps = commonSteps(truth.sequence, with: recordedSteps)
        let actualSteps = commonSteps(recordedSteps, with: truth.sequence)
        report(.toolsInterleaved, of: fixture, failures: expectedSteps == actualSteps ? [] : [
            ("", "provider order \(expectedSteps), recorded \(actualSteps)")
        ])

        // The durable transcript is the response rows, not run.output: each
        // message must reach them exactly as many times as the provider sent
        // it, no copy missing and none extra.
        let collapsedRows = collapsed(responseSoFar)
        report(.messagesInResponseRows, of: fixture, failures: truth.messages.enumerated().compactMap { index, message in
            let text = collapsed(message)
            guard truth.messages.firstIndex(where: { collapsed($0) == text }) == index else { return nil }
            let expected = expectedMultiplicity[text] ?? 1
            let occurrences = messageCount(text, in: collapsedRows, among: collapsedMessages)
            return occurrences == expected
                ? nil
                : (multiplicityItem(message, recorded: occurrences, sent: expected),
                   "in agent.response rows \(occurrences)x, sent \(expected)x: \(message.prefix(80))")
        })

        // Messages must appear in provider order in the output and in the
        // durable rows alike, which also catches two messages reversed inside
        // one row.
        let sources = [("run output", output), ("agent.response rows", responseSoFar)]
        report(.messagesInOrder, of: fixture, failures: sources.flatMap { source, text in
            outOfOrderMessages(in: collapsed(text), messages: truth.messages).map {
                ($0, "message in \(source) recorded before the one the provider sent ahead of it: \($0)")
            }
        })

        // Collapsed comparisons ignore line breaks, so each message present in
        // the output and in the durable rows must also keep its lines and
        // blank-line paragraph breaks. Counted per occurrence: every recorded
        // copy of a text, up to how many the provider sent, must keep its
        // structure.
        let structuredMessages = truth.messages.map(lineStructure)
        report(.paragraphStructure, of: fixture, failures: sources.flatMap { source, recorded in
            let collapsedRecorded = collapsed(recorded)
            let structuredRecorded = lineStructure(recorded)
            return truth.messages.enumerated().compactMap { index, message -> (item: String, message: String)? in
                let text = collapsed(message)
                guard truth.messages.firstIndex(where: { collapsed($0) == text }) == index else { return nil }
                let present = min(expectedMultiplicity[text] ?? 1, messageCount(text, in: collapsedRecorded, among: collapsedMessages))
                // A copy inside a longer message that contains it is that
                // message's, as in messageCount.
                let structured = messageCount(lineStructure(message), in: structuredRecorded, among: structuredMessages)
                return structured >= present
                    ? nil
                    : (message, "line or paragraph breaks lost in \(present - structured) of \(present) copies in \(source): \(message.prefix(80))")
            }
        })

        // The item carries the overage, so a known issue can cover "one extra
        // copy of a short line" without also excusing a worse duplication.
        report(.noExtraLines, of: fixture, failures: sources.flatMap { source, text in
            lineCounts(text).sorted { $0.key < $1.key }.compactMap { line, count in
                guard let expected = sent[line], count > expected else { return nil }
                return (
                    extraLineItem(line, overage: count - expected, sent: expected),
                    "line in \(source) recorded \(count)x, sent \(expected)x: \(line.prefix(80))"
                )
            }
        })

        // Neither the output nor the durable rows may hold text the provider
        // never sent, apart from joins at message boundaries.
        report(.noUnsentLines, of: fixture, failures: sources.flatMap {
            unsentLineFailures(in: $0.1, sent: sent, boundaries: truth.boundaryJoins, source: $0.0)
        })

        let recordedOutcomes = multiset(events.compactMap { event -> String? in
            switch event.type {
            case TaskEventTypes.Tool.result.rawValue: "success"
            case TaskEventTypes.Tool.resultFailed.rawValue: "failure"
            default: nil
            }
        })
        let expectedOutcomes = multiset(truth.toolResultOutcomes)
        func outcomeFailures(_ outcome: String) -> [(item: String, message: String)] {
            let expected = expectedOutcomes[outcome] ?? 0
            let recorded = recordedOutcomes[outcome] ?? 0
            return expected == recorded ? [] : [(outcome, "\(outcome) tool results: provider reported \(expected), recorded \(recorded)")]
        }
        report(.toolResultsRecorded, of: fixture, failures: outcomeFailures("success"))
        // Without a failing tool call the failure count is zero against zero,
        // so the gap is declared instead of passing silently.
        if expectedOutcomes["failure"] == nil {
            #expect(fixture.notExercised[.failedToolResultsRecorded] != nil,
                    "no tool call in the capture fails; list failedToolResultsRecorded in notExercised")
        } else {
            #expect(fixture.notExercised[.failedToolResultsRecorded] == nil,
                    "fixture now has a failed tool call; drop failedToolResultsRecorded from notExercised")
        }
        report(.failedToolResultsRecorded, of: fixture, failures: outcomeFailures("failure"))

        if let usage = truth.usage {
            #expect(fixture.notExercised[.usageRecorded] == nil, "fixture now reports usage; drop usageRecorded from notExercised")
            // Typed apart: inferred in one expression, this outlasts the CI
            // compiler's type-checking limit.
            let totals: [(name: String, expected: Int, recorded: Int)] = [
                ("input", usage.input, run.inputTokens),
                ("output", usage.output, run.outputTokens)
            ]
            report(.usageRecorded, of: fixture, failures: totals.compactMap { total -> (item: String, message: String)? in
                guard total.expected != total.recorded else { return nil }
                return (valueItem(total.name, expected: String(total.expected), recorded: String(total.recorded)),
                        "\(total.name) tokens: provider reported \(total.expected), recorded \(total.recorded)")
            })
        } else {
            #expect(fixture.notExercised[.usageRecorded] != nil,
                    "fixture reports no token usage; list usageRecorded in notExercised")
        }

        // Each distinct complete marker must leave its durable astra.complete
        // event. Identical markers are recorded once per run by design
        // (AgentRuntimeEventPipeline.shouldEmit: markers are idempotent), so
        // expected summaries are unique.
        let recordedSummaries = multiset(events
            .filter { $0.type == "astra.complete" }
            .compactMap { event in
                (try? JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any])?["summary"] as? String
            })
        let expectedSummaries = multiset(truth.completionSummaries)
        // With no marker in the capture the comparison below is empty against
        // empty, so the gap must be declared rather than pass silently.
        if truth.completionSummaries.isEmpty {
            #expect(fixture.notExercised[.completionRecorded] != nil,
                    "fixture sends no complete marker; list completionRecorded in notExercised")
        } else {
            #expect(fixture.notExercised[.completionRecorded] == nil,
                    "fixture now sends a complete marker; drop completionRecorded from notExercised")
        }
        report(.completionRecorded, of: fixture, failures: Set(recordedSummaries.keys).union(expectedSummaries.keys).sorted().compactMap { summary in
            let expected = expectedSummaries[summary] ?? 0
            let recorded = recordedSummaries[summary] ?? 0
            return expected == recorded ? nil : (summary, "completion \"\(summary)\": marked \(expected)x, recorded \(recorded)x")
        })

        report(.noRawProviderJSON, of: fixture, failures: sources.flatMap { source, text in
            text.components(separatedBy: "\n").filter(isRawProviderFrame).map { ("", "raw provider frame in \(source): \($0.prefix(80))") }
        })

        // Tool calls are compared by name as a multiset, so a dropped call
        // cannot hide behind an extra or duplicated one.
        let recordedTools = multiset(events
            .filter { $0.type == TaskEventTypes.Tool.use.rawValue }
            .map { toolName(fromUsePayload: $0.payload) })
        let expectedTools = multiset(truth.toolNames)
        report(.toolCallsRecorded, of: fixture, failures: Set(recordedTools.keys).union(expectedTools.keys).sorted().compactMap { name in
            let expected = expectedTools[name] ?? 0
            let recorded = recordedTools[name] ?? 0
            return expected == recorded ? nil : (name, "tool \(name): provider called \(expected)x, recorded \(recorded)x")
        })

        if fixture.notExercised[.fileChangesRecorded] == nil {
            #expect(!truth.writtenPaths.isEmpty,
                    "fixture writes no file; capture one or list fileChangesRecorded in notExercised")
        } else {
            #expect(truth.writtenPaths.isEmpty,
                    "fixture now writes a file; drop fileChangesRecorded from notExercised")
        }
        // Paths are compared relative to the workspace, with multiplicity: a
        // change recorded under the wrong directory is a different file.
        let workspaceRoots = ["/workspace", harness.workspaceURL.path]
        let recordedPaths = multiset(run.fileChanges.map { workspaceRelative($0.path, roots: workspaceRoots) })
        let expectedPaths = multiset(truth.writtenPaths.map { workspaceRelative($0, roots: workspaceRoots) })
        report(.fileChangesRecorded, of: fixture, failures: Set(recordedPaths.keys).union(expectedPaths.keys).sorted().compactMap { path -> (item: String, message: String)? in
            let expected = expectedPaths[path] ?? 0
            let recorded = recordedPaths[path] ?? 0
            guard expected != recorded else { return nil }
            return (valueItem(path, expected: String(expected), recorded: String(recorded)),
                    "file \(path): provider wrote \(expected)x, recorded \(recorded)x")
        })

        report(.noSpuriousErrors, of: fixture, failures: events
            .filter { $0.type == TaskEventTypes.System.error.rawValue }
            .map { ($0.payload, "a successful turn recorded an error: \($0.payload.prefix(80))") })

        // Follow-ups resume the provider's own session, so the identity the
        // stream announced must reach both durable owners.
        if let sessionID = truth.sessionID {
            #expect(fixture.notExercised[.sessionRecorded] == nil, "fixture now announces a session; drop sessionRecorded from notExercised")
            let owners: [(field: String, recorded: String?)] = [
                ("task.sessionId", task.sessionId),
                ("run.providerSessionId", run.providerSessionId)
            ]
            report(.sessionRecorded, of: fixture, failures: owners.compactMap { owner -> (item: String, message: String)? in
                guard owner.recorded != sessionID else { return nil }
                let recorded = owner.recorded ?? "nil"
                return (valueItem(owner.field, expected: sessionID, recorded: recorded),
                        "\(owner.field): provider session \(sessionID), recorded \(recorded)")
            })
        } else {
            #expect(fixture.notExercised[.sessionRecorded] != nil,
                    "fixture announces no session; list sessionRecorded in notExercised")
        }

        // A subagent's start and finish must each leave a durable team event
        // carrying the provider's task id.
        if fixture.scenario == "subagent" {
            #expect(!truth.subagentStarts.isEmpty, "the subagent fixture starts no subagent")
        }
        let recordedLifecycle = multiset(events.compactMap { event -> String? in
            switch event.type {
            case TaskEventTypes.Team.agentStarted.rawValue: "started \(event.agentId ?? "")"
            case TaskEventTypes.Team.agentCompleted.rawValue: "completed \(event.agentId ?? "")"
            default: nil
            }
        })
        let expectedLifecycle = multiset(
            truth.subagentStarts.map { "started \($0)" } + truth.subagentCompletions.map { "completed \($0)" }
        )
        report(.subagentLifecycle, of: fixture, failures: Set(recordedLifecycle.keys).union(expectedLifecycle.keys).sorted().compactMap { step in
            let expected = expectedLifecycle[step] ?? 0
            let recorded = recordedLifecycle[step] ?? 0
            return expected == recorded ? nil : (step, "subagent \(step): provider reported \(expected)x, recorded \(recorded)x")
        })

        // The bubble must hold the whole answer, not a digest of it: all of
        // its text, and its line and paragraph breaks.
        let snapshot = TaskThreadSnapshot(task: task)
        let displayed = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))).displayText
        let answer = try #require(truth.answer, "fixture has no answer message (answer-write-signoff needs a `## Suggested reply` heading line)")
        let answerCopies = collapsed(displayed).components(separatedBy: collapsed(answer)).count - 1
        let answerFailure: (item: String, message: String)? =
            if answerCopies == 0 {
                ("text", "answer bubble is missing answer text: \(answer.prefix(80))")
            } else if answerCopies > 1 {
                ("duplicate", "answer bubble shows the answer \(answerCopies)x")
            } else if !lineStructure(displayed).contains(lineStructure(answer)) {
                ("structure", "answer bubble lost the answer's line or paragraph breaks")
            } else {
                nil
            }
        report(.answerVisible, of: fixture, failures: answerFailure.map { [$0] } ?? [])
    }

    @Test("A join line several boundaries can produce is charged to one of them, and each boundary joins once")
    func boundaryJoinsAreMatchedToBoundaries() {
        // `a` + `bc` and `ab` + `c` can both produce `abc`.
        let overlapping: [Set<String>] = [["abc", "a bc"], ["abc", "ab c"]]
        #expect(unsentLineFailures(in: "abc\nabc", sent: [:], boundaries: overlapping, source: "output").isEmpty)
        #expect(unsentLineFailures(in: "abc\nabc\nabc", sent: [:], boundaries: overlapping, source: "output").count == 1)
        // Both spellings of one boundary are two joins, one too many.
        #expect(unsentLineFailures(in: "abc\na bc", sent: [:], boundaries: [["abc", "a bc"]], source: "output").count == 1)
        #expect(unsentLineFailures(in: "xyz", sent: [:], boundaries: overlapping, source: "output").count == 1)
    }

    @Test("A message inside a longer provider message is not counted as a copy of it")
    func overlappingMessagesAreCountedApart() {
        let messages = ["Done", "Done with work"]
        #expect(messageCount("Done", in: "DoneDone with work", among: messages) == 1)
        #expect(messageCount("Done with work", in: "DoneDone with work", among: messages) == 1)
        #expect(messageCount("Done", in: "Done with work", among: messages) == 0)
        #expect(messageCount("Done", in: "DoneDoneDone with work", among: messages) == 2)
    }

    @Test("Two messages reversed in one text are out of order; a missing second copy is not")
    func reversedMessagesAreOutOfOrder() {
        #expect(outOfOrderMessages(in: "Second. First.", messages: ["First.", "Second."]) == ["Second."])
        #expect(outOfOrderMessages(in: "First. Second.", messages: ["First.", "Second."]).isEmpty)
        #expect(outOfOrderMessages(in: "Done. Then.", messages: ["Done.", "Then.", "Done."]).isEmpty)
    }

    @Test("Generic Codex tool items are tool calls in the fixture truth")
    func genericCodexToolItemsAreToolCalls() {
        #expect(ProviderStreamTruth.isGenericCodexToolItem(["type": "mcp_tool_call", "name": "fetch"]))
        #expect(ProviderStreamTruth.isGenericCodexToolItem(["type": "web_search", "name": "search"]))
        #expect(!ProviderStreamTruth.isGenericCodexToolItem(["type": "command_execution", "command": "ls"]))
        #expect(!ProviderStreamTruth.isGenericCodexToolItem(["type": "agent_message", "text": "Hi"]))
        #expect(!ProviderStreamTruth.isGenericCodexToolItem(["type": "error", "message": "warning"]))
    }

    @Test("Copilot frame types are read from every discriminator and envelope, as the runtime reads them")
    func copilotFrameTypesMatchTheRuntime() {
        let shutdown: [String: Any] = ["event": "SESSION.SHUTDOWN", "payload": ["modelMetrics": [:]]]
        #expect(ProviderStreamTruth.copilotFrame(shutdown).type == "session.shutdown")
        let wrapped: [String: Any] = ["type": "event", "data": ["type": "result", "sessionId": "s"]]
        let resolved = ProviderStreamTruth.copilotFrame(wrapped)
        #expect(resolved.type == "result")
        #expect(resolved.object["sessionId"] as? String == "s")
        let payloadTyped: [String: Any] = ["data": ["type": "assistant.message", "content": "Hi"]]
        #expect(ProviderStreamTruth.copilotFrame(payloadTyped).type == "assistant.message")
    }

    @Test("Copilot tool calls and results are classified by every shape the stream uses")
    func copilotToolRolesCoverEveryShape() {
        #expect(ProviderStreamTruth.copilotToolRole("tool.execution_start", [:]) == .use)
        #expect(ProviderStreamTruth.copilotToolRole("tool.execution_complete", ["data": ["toolCallId": "c"]]) == .result)
        #expect(ProviderStreamTruth.copilotToolRole("tool.result", ["toolUseId": "x", "success": false]) == .result)
        #expect(ProviderStreamTruth.copilotToolRole("custom", ["toolResult": ["content": "x"]]) == .result)
        #expect(ProviderStreamTruth.copilotToolRole("assistant.tool_call_delta", [:]) == nil)
        #expect(ProviderStreamTruth.copilotToolRole("tool.execution_progress", [:]) == nil)
    }

    @Test("Fixture truth reads tool names, message items and step states as the runtime does")
    func truthReadsEveryRuntimeShape() throws {
        func fixture(_ runtime: AgentRuntimeID) throws -> ProviderStreamFixture {
            try #require(ProviderStreamFixture.all.first { $0.runtime == runtime })
        }
        let copilot = ProviderStreamTruth(fixture: try fixture(.copilotCLI), frames: [
            #"{"type":"tool.use","tool":{"name":"fetch"}}"#
        ])
        #expect(copilot.toolNames == ["fetch"])

        let codex = ProviderStreamTruth(fixture: try fixture(.codexCLI), frames: [
            #"{"type":"item.completed","item":{"type":"message","content":[{"text":"First."}]}}"#,
            #"{"type":"item.completed","item":{"kind":"Assistant_Message","text":"Second."}}"#
        ])
        #expect(codex.messages == ["First.", "Second."])

        let antigravity = ProviderStreamTruth(fixture: try fixture(.antigravityCLI), frames: [
            #"{"event":"Step_Update","step_update":{"step_index":1,"step_type":"TOOL","state":"active","tool_info":{"name":"run_command"}}}"#,
            #"{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"error"}}"#
        ])
        #expect(antigravity.toolNames == ["run_command"])
        #expect(antigravity.toolResultOutcomes == ["failure"])
    }

    @Test("A multiplicity known issue covers only its exact defect")
    func multiplicityKnownIssuesAreExact() {
        let extra = ProviderStreamKnownIssue.oneExtraCopy("one extra copy") { $0 == "Done." }
        #expect(extra.covers(multiplicityItem("Done.", recorded: 2, sent: 1)))
        #expect(!extra.covers(multiplicityItem("Done.", recorded: 3, sent: 1)))
        #expect(!extra.covers(multiplicityItem("Done.", recorded: 0, sent: 1)))
        #expect(!extra.covers(multiplicityItem("Other.", recorded: 2, sent: 1)))
        let lost = ProviderStreamKnownIssue.lost("lost")
        #expect(lost.covers(multiplicityItem("Done.", recorded: 0, sent: 1)))
        #expect(!lost.covers(multiplicityItem("Done.", recorded: 2, sent: 1)))
    }

    /// Records each failure of `check`. Failures the fixture's known issue
    /// covers are recorded together under that known issue; the rest are real
    /// failures. A known issue with nothing left to cover is itself reported,
    /// so a fix cannot land without deleting its entry.
    private func report(
        _ check: ProviderStreamFixture.Check,
        of fixture: ProviderStreamFixture,
        failures: [(item: String, message: String)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let known = fixture.knownIssues[check]
        for failure in failures where known?.covers(failure.item) != true {
            Issue.record(Comment(rawValue: "\(check.rawValue): \(failure.message)"), sourceLocation: sourceLocation)
        }
        guard let known else { return }
        let covered = failures.filter { known.covers($0.item) }
        withKnownIssue(Comment(rawValue: "\(check.rawValue): \(known.reason)"), sourceLocation: sourceLocation) {
            for failure in covered {
                Issue.record(Comment(rawValue: failure.message), sourceLocation: sourceLocation)
            }
        }
    }

    /// Antigravity only speaks stream-json once ASTRA has cached that the
    /// binary supports it (normally from `agy --help` during readiness). The
    /// cache is one process-wide key, so the previous value is restored.
    private static func enableAntigravityStructuredOutput(executablePath: String) -> () -> Void {
        let key = AppStorageKeys.runtimeStructuredOutputKey(for: .antigravityCLI)
        let previous = UserDefaults.standard.object(forKey: key)
        AntigravityCLIRuntime.cacheStructuredOutputSupport(true, executablePath: executablePath)
        return {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// One entry of a run's transcript: a message (by index into the provider's
/// messages) or a tool call (by name).
enum TranscriptStep: Hashable, CustomStringConvertible {
    case message(Int)
    case tool(String)

    var description: String {
        switch self {
        case .message(let index): "message \(index + 1)"
        case .tool(let name): "tool \(name)"
        }
    }
}

/// A defect the suite expects today, limited to the failures it explains.
struct ProviderStreamKnownIssue: Sendable {
    let reason: String
    /// Which failing items this defect explains: a message, a line, an
    /// excerpt, a file name or an error payload, or `""` for a whole-check
    /// failure.
    let covers: @Sendable (String) -> Bool

    static func whole(_ reason: String) -> Self {
        Self(reason: reason) { _ in true }
    }

    static func items(_ reason: String, where covers: @escaping @Sendable (String) -> Bool) -> Self {
        Self(reason: reason, covers: covers)
    }

    /// A message recorded exactly once more than the provider sent it;
    /// dropping it, or any further copy, is a new defect.
    static func oneExtraCopy(_ reason: String, of message: @escaping @Sendable (String) -> Bool) -> Self {
        items(reason) { item in
            guard let (text, recorded, sent) = multiplicity(of: item) else { return false }
            return recorded == sent + 1 && message(text)
        }
    }

    /// A message missing entirely; a copy recorded too often is a new defect.
    static func lost(_ reason: String, of message: @escaping @Sendable (String) -> Bool = { _ in true }) -> Self {
        items(reason) { item in
            guard let (text, recorded, _) = multiplicity(of: item) else { return false }
            return recorded == 0 && message(text)
        }
    }

    /// The per-line echo check re-appends each copy of a line under its
    /// 80-character floor once; a longer line, or more extra copies than the
    /// provider sent, is a new defect.
    static func shortLines(_ reason: String) -> Self {
        items(reason) { item in
            let parts = item.components(separatedBy: extraLineSeparator)
            guard parts.count == 3, let overage = Int(parts[1]), let sent = Int(parts[2]) else { return false }
            return overage <= sent && parts[0].count < 80
        }
    }
}

struct ProviderStreamFixture: CustomTestStringConvertible, Sendable {
    enum Check: String, Sendable {
        case runCompletes
        case eachMessageOnce
        case messagesInOrder
        case noExtraLines
        case noUnsentLines
        case paragraphStructure
        case toolsInterleaved
        case messagesInResponseRows
        case toolResultsRecorded
        case failedToolResultsRecorded
        case usageRecorded
        case completionRecorded
        case noRawProviderJSON
        case toolCallsRecorded
        case fileChangesRecorded
        case noSpuriousErrors
        case sessionRecorded
        case subagentLifecycle
        case answerVisible
    }

    let provider: String
    let scenario: String
    let runtime: AgentRuntimeID
    let executableName: String
    let model: String
    let knownIssues: [Check: ProviderStreamKnownIssue]
    /// Checks this capture cannot exercise, and why. The suite fails if the
    /// capture starts exercising one, so coverage gaps stay explicit.
    var notExercised: [Check: String] = [:]

    var testDescription: String { "\(provider)/\(scenario)" }

    func frameLines() throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: scenario,
            withExtension: "jsonl",
            subdirectory: "ProviderStreams/\(provider)"
        ))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static let all: [ProviderStreamFixture] = [
        ProviderStreamFixture(
            provider: "claude",
            scenario: "answer-write-signoff",
            runtime: .claudeCode,
            executableName: "claude",
            model: "claude-sonnet-5",
            knownIssues: [
                .answerVisible: .items("the answer precedes the Write call, so only the sign-off is shown (plan phase 3)") { $0 == "text" }
            ],
            notExercised: [.failedToolResultsRecorded: "no tool call in this capture fails"]
        ),
        ProviderStreamFixture(
            provider: "claude",
            scenario: "subagent",
            runtime: .claudeCode,
            executableName: "claude",
            model: "claude-sonnet-5",
            knownIssues: [:],
            notExercised: [
                .failedToolResultsRecorded: "no tool call in this capture fails",
                .fileChangesRecorded: "the subagent scenario only reads",
                .completionRecorded: "the subagent scenario asks for no complete marker"
            ]
        ),
        ProviderStreamFixture(
            provider: "copilot",
            scenario: "answer-write-signoff",
            runtime: .copilotCLI,
            executableName: "copilot",
            model: "gpt-5",
            // Copilot re-sends narration that carries toolRequests as text, but
            // this capture's only such message is the run's first, which the
            // whole-output echo check already drops; prod runs show the
            // doubling on later narration.
            knownIssues: [
                .fileChangesRecorded: .items("apply_patch writes are not recorded as file changes (plan phase 4)") {
                    valueParts(of: $0).map { $0.name == "answer.md" && $0.recorded == "0" } == true
                },
                .sessionRecorded: .items("Copilot names its session only in the result frame, which is not read (plan phase 2)") {
                    valueParts(of: $0)?.recorded == "nil"
                },
                .answerVisible: .items("the answer precedes the apply_patch call, so only the sign-off is shown (plan phase 3)") { $0 == "text" }
            ],
            notExercised: [
                .failedToolResultsRecorded: "no tool call in this capture fails",
                .usageRecorded: "the capture has no session.shutdown frame, the only one with token totals"
            ]
        ),
        ProviderStreamFixture(
            provider: "codex",
            scenario: "answer-write-signoff",
            runtime: .codexCLI,
            executableName: "codex",
            model: "gpt-5.5",
            knownIssues: [
                .runCompletes: .items("config-warning items of type error fail the run as agent_reported_error (plan phase 2)") {
                    $0 == "agent_reported_error"
                },
                .eachMessageOnce: .lost("last-completed-wins keeps only the final agent_message (plan phase 2)") {
                    !$0.hasPrefix("The draft is saved")
                },
                .messagesInResponseRows: .lost("agent_message items become completions, which write no agent.response rows (plan phase 2)"),
                .fileChangesRecorded: .items("file_change paths nest under changes[] and are dropped (plan phase 2)") {
                    valueParts(of: $0).map { $0.name == "answer.md" && $0.recorded == "0" } == true
                },
                .noSpuriousErrors: .items("config-warning items of type error are recorded as agent errors (plan phase 2)") {
                    $0.hasPrefix("Configured value for")
                },
                .usageRecorded: .items("cached_input_tokens are added to input_tokens, which already include them (plan phase 2)") {
                    // 65,359 input tokens plus the 53,632 cached ones again.
                    valueParts(of: $0).map { [$0.name, $0.expected, $0.recorded] } == ["input", "65359", "118991"]
                },
                .completionRecorded: .items("ASTRA_EVENT markers in agent_message items are stripped, never recorded (plan phase 2)") {
                    $0 == "Drafted the reply and saved answer.md"
                },
                .answerVisible: .items("the answer message is dropped before it can be shown (plan phase 2)") { $0 == "text" }
            ],
            notExercised: [.failedToolResultsRecorded: "no tool call in this capture fails"]
        ),
        ProviderStreamFixture(
            provider: "cursor",
            scenario: "answer-write-signoff",
            runtime: .cursorCLI,
            executableName: "cursor-agent",
            model: "composer-2.5-fast",
            knownIssues: [
                .noExtraLines: .shortLines("re-sent short lines of the previous message are appended again (plan phase 2)"),
                .toolCallsRecorded: .items("tool_call frames are not parsed (plan phase 4)") {
                    ["readToolCall", "editToolCall"].contains($0)
                },
                .toolResultsRecorded: .items("tool_call completions are not parsed (plan phase 4)") { $0 == "success" },
                .fileChangesRecorded: .items("editToolCall writes are not parsed (plan phase 4)") {
                    valueParts(of: $0).map { $0.name == "answer.md" && $0.recorded == "0" } == true
                }
            ],
            notExercised: [.failedToolResultsRecorded: "no tool call in this capture fails"]
        ),
        ProviderStreamFixture(
            provider: "antigravity",
            scenario: "answer-write-signoff",
            runtime: .antigravityCLI,
            executableName: "agy",
            model: "Gemini 3.5 Flash",
            knownIssues: [:],
            // agy's print mode ends the turn on a response without tool calls,
            // so the answer-first scenario never reaches its write. A
            // write-first capture was withheld: that run's agent explored
            // outside the workspace (env, /tmp), which the capture audit now
            // refuses.
            notExercised: [
                .failedToolResultsRecorded: "no tool call in this capture fails",
                .fileChangesRecorded: "agy ends the turn after the text-only answer",
                .completionRecorded: "agy ends the turn before the closing marker message"
            ]
        )
    ]
}

/// What the provider actually said and did, read straight from the fixture
/// frames.
struct ProviderStreamTruth {
    private(set) var messages: [String] = []
    /// Every tool call's name, subagent calls included: ASTRA records those
    /// as tool activity too.
    private(set) var toolNames: [String] = []
    /// Messages and tool calls in the order the provider produced them.
    private(set) var sequence: [TranscriptStep] = []
    /// "success" / "failure" for every tool result the provider reported.
    private(set) var toolResultOutcomes: [String] = []
    /// The run's token totals as the provider reports them, when it does.
    private(set) var usage: (input: Int, output: Int)?
    /// Distinct summaries of the `ASTRA_EVENT` complete markers in the main
    /// messages; identical markers are one event by protocol design.
    private(set) var completionSummaries: [String] = []

    private enum RawStep {
        case message(Int)
        case tool(String)
    }
    private(set) var writtenPaths: [String] = []
    /// The session the provider announced, which a follow-up resumes.
    private(set) var sessionID: String?
    /// Task ids of the subagents the provider started and finished.
    private(set) var subagentStarts: [String] = []
    private(set) var subagentCompletions: [String] = []
    /// For each boundary between consecutive messages, the spellings of
    /// "last line + first line" (with or without a space): the only lines,
    /// besides the provider's own, that appending messages without a
    /// separator can produce, once per boundary.
    private(set) var boundaryJoins: [Set<String>] = []
    /// The message the user asked for: in the answer-write-signoff scenario
    /// the one with a `## Suggested reply` heading line, otherwise the last
    /// message.
    private(set) var answer: String?

    init(fixture: ProviderStreamFixture, frames: [String]) {
        var rawMessages: [String] = []
        var rawSequence: [RawStep] = []
        var antigravityMessageIndex: [Int: Int] = [:]
        // Codex tool items already counted as started, by item id.
        var codexStartedTools = Set<String>()
        // Cursor's last full assistant frame, which the next one may repeat.
        var cursorSnapshot = ""
        func appendMessage(_ text: String) {
            rawSequence.append(.message(rawMessages.count))
            rawMessages.append(text)
        }
        func appendTool(_ name: String) {
            toolNames.append(name)
            rawSequence.append(.tool(name))
        }
        for line in frames {
            guard let data = line.data(using: .utf8),
                  let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = frame["type"] as? String
            switch fixture.runtime {
            case .claudeCode:
                if type == "system", frame["subtype"] as? String == "init" {
                    sessionID = frame["session_id"] as? String
                }
                // `local_agent` and `in_process_teammate` tasks are subagents;
                // other task types are background shells.
                if type == "system", frame["subtype"] as? String == "task_started",
                   ["local_agent", "in_process_teammate"].contains(frame["task_type"] as? String ?? ""),
                   let taskID = frame["task_id"] as? String {
                    subagentStarts.append(taskID)
                }
                // Only a subagent's completion: a background shell task also
                // sends one, and it is not a team event.
                if type == "system", ["task_notification", "task_completed"].contains(frame["subtype"] as? String ?? ""),
                   let taskID = frame["task_id"] as? String, subagentStarts.contains(taskID) {
                    subagentCompletions.append(taskID)
                }
                if type == "result", let modelUsage = frame["modelUsage"] as? [String: [String: Any]] {
                    // Anthropic reports cache reads and writes apart from input.
                    let entries = Array(modelUsage.values)
                    usage = (
                        entries.reduce(0) {
                            $0 + int($1["inputTokens"]) + int($1["cacheReadInputTokens"]) + int($1["cacheCreationInputTokens"])
                        },
                        entries.reduce(0) { $0 + int($1["outputTokens"]) }
                    )
                }
                if type == "user", let blocks = (frame["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        toolResultOutcomes.append(block["is_error"] as? Bool == true ? "failure" : "success")
                    }
                }
                // Subagent frames carry a parent_tool_use_id; only the main
                // agent's messages are the user's transcript, but every tool
                // call is tool activity.
                guard type == "assistant",
                      let message = frame["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let isMainAgent = frame["parent_tool_use_id"] is NSNull || frame["parent_tool_use_id"] == nil
                for block in blocks {
                    if block["type"] as? String == "text", isMainAgent, let text = block["text"] as? String {
                        appendMessage(text)
                    } else if block["type"] as? String == "tool_use" {
                        appendTool(block["name"] as? String ?? "tool")
                        if ["Write", "Edit", "MultiEdit"].contains(block["name"] as? String ?? ""),
                           let path = (block["input"] as? [String: Any])?["file_path"] as? String {
                            writtenPaths.append(path)
                        }
                    }
                }
            case .copilotCLI:
                // Copilot's type can sit under several keys and inside
                // envelopes; read it the way the runtime does.
                let (type, object) = Self.copilotFrame(frame)
                let data = Self.copilotPayload(object)
                // A field can sit on the frame or in its payload; the runtime
                // reads both, the frame first, skipping a value of the wrong
                // type (a null on the frame falls back to the payload).
                func field<T>(_ key: String, as _: T.Type = T.self) -> T? { object[key] as? T ?? data?[key] as? T }
                if type == "assistant.message", let text = field("content", as: String.self) {
                    appendMessage(text)
                } else if type == "session.shutdown", let metrics = field("modelMetrics", as: [String: Any].self) {
                    // Per-model totals with the runtime's aliases, each read
                    // from the entry's usage first and the entry second.
                    // Copilot counts cache reads and writes next to input.
                    let entries = metrics.values.compactMap { $0 as? [String: Any] }
                    func total(_ keys: [String]) -> Int {
                        entries.reduce(0) { sum, entry in
                            let usage = entry["usage"] as? [String: Any]
                            let value = keys.lazy.compactMap { usage?[$0] as? NSNumber }.first
                                ?? keys.lazy.compactMap { entry[$0] as? NSNumber }.first
                            return sum + (value?.intValue ?? 0)
                        }
                    }
                    usage = (
                        total(["inputTokens", "input_tokens", "promptTokens", "prompt_tokens"])
                            + total(["cacheReadTokens", "cacheReadInputTokens", "cache_read_input_tokens"])
                            + total(["cacheWriteTokens", "cacheCreationInputTokens", "cache_creation_input_tokens"]),
                        total(["outputTokens", "output_tokens", "completionTokens", "completion_tokens"])
                    )
                } else if type == "result" {
                    // Copilot's stdout names its session only in the result.
                    sessionID = field("sessionId", as: String.self)
                } else if let role = Self.copilotToolRole(type, object) {
                    // Every shape Copilot's stream uses for a tool call or
                    // result, not only tool.execution_start / _complete.
                    switch role {
                    case .result:
                        let explicitError = ["is_error", "isError", "error"].lazy.compactMap { field($0, as: Bool.self) }.first
                        let success = ["success", "succeeded", "ok"].lazy.compactMap { field($0, as: Bool.self) }.first
                        let failed = explicitError ?? success.map { !$0 } ?? false
                        toolResultOutcomes.append(failed ? "failure" : "success")
                    case .use:
                        // A tool can also arrive as `{"tool": {"name": …}}`.
                        let flatName: String? = ["tool", "toolName", "name"].lazy.compactMap { field($0, as: String.self) }.first
                        let nestedName: String? = field("tool", as: [String: Any].self)?["name"] as? String
                        let name = flatName ?? nestedName ?? "tool"
                        appendTool(name)
                        if name == "apply_patch", let patch = field("arguments", as: String.self) {
                            writtenPaths += Self.patchedPaths(in: patch)
                        }
                    }
                }
            case .codexCLI:
                let item = frame["item"] as? [String: Any]
                // Item types are read as the runtime reads them: `type` or
                // `kind`, any case; three of them are assistant messages.
                let itemType = item.flatMap(Self.codexItemType)
                if type == "item.completed", ["agent_message", "message", "assistant_message"].contains(itemType),
                   let text = item.flatMap(Self.codexText) {
                    appendMessage(text)
                } else if type == "thread.started" {
                    sessionID = frame["thread_id"] as? String
                } else if type == "item.started", itemType == "command_execution" {
                    appendTool("command_execution")
                } else if type == "item.completed", itemType == "command_execution" {
                    let exitCode = item?["exit_code"] as? Int
                    toolResultOutcomes.append(exitCode == nil || exitCode == 0 ? "success" : "failure")
                } else if type == "turn.completed", let reported = frame["usage"] as? [String: Any] {
                    // Codex's input_tokens already include cached_input_tokens:
                    // its own total_tokens is input_tokens + output_tokens.
                    usage = (int(reported["input_tokens"]), int(reported["output_tokens"]))
                } else if type == "item.completed", itemType == "file_change",
                          let changes = item?["changes"] as? [[String: Any]] {
                    writtenPaths += changes.compactMap { $0["path"] as? String }
                } else if let item, Self.isGenericCodexToolItem(item) {
                    // Any other tool item (an MCP call, a web search): one
                    // call when it starts, one result when it completes.
                    let id = item["id"] as? String ?? ""
                    if type == "item.started" || (type == "item.completed" && !codexStartedTools.contains(id)) {
                        codexStartedTools.insert(id)
                        appendTool(["name", "tool", "tool_name", "toolName"].lazy.compactMap { item[$0] as? String }.first ?? "tool")
                    }
                    if type == "item.completed" {
                        let failed = (item["status"] as? String)?.lowercased() == "failed" || item["error"] != nil
                        toolResultOutcomes.append(failed ? "failure" : "success")
                    }
                }
            case .cursorCLI:
                // Cursor's last assistant frame repeats the previous message
                // and appends to it, so a frame that extends the previous
                // message's text continues that message.
                if type == "system", frame["subtype"] as? String == "init" {
                    sessionID = frame["session_id"] as? String
                } else if type == "assistant",
                   let message = frame["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined()
                    if !cursorSnapshot.isEmpty, text.hasPrefix(cursorSnapshot) {
                        // The frame repeats the previous one and adds to it.
                        // Straight after it, the same message grew; after a
                        // tool call, the addition is a new message at its own
                        // place in the sequence.
                        let addition = String(text.dropFirst(cursorSnapshot.count))
                        if case .message? = rawSequence.last {
                            rawMessages[rawMessages.count - 1] += addition
                        } else if !addition.isEmpty {
                            appendMessage(addition)
                        }
                    } else if !text.isEmpty {
                        appendMessage(text)
                    }
                    cursorSnapshot = text
                } else if type == "result", let reported = frame["usage"] as? [String: Any] {
                    // Cursor reports cache reads and writes apart from input,
                    // as Anthropic does; it gives no total to check against.
                    // Each field resolves as StreamUsage decodes it: the
                    // snake_case name first, then its camelCase aliases.
                    let field = { (keys: [String]) in keys.lazy.compactMap { reported[$0] as? NSNumber }.first?.intValue ?? 0 }
                    usage = (
                        field(["input_tokens", "inputTokens"]) + field(["cachedInputTokens"])
                            + field(["cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens"])
                            + field(["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteTokens"]),
                        field(["output_tokens", "outputTokens"])
                    )
                } else if type == "tool_call", frame["subtype"] as? String == "completed" {
                    let call = (frame["tool_call"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] }.first
                    let result = call?["result"] as? [String: Any]
                    toolResultOutcomes.append(result?["success"] != nil ? "success" : "failure")
                } else if type == "tool_call", frame["subtype"] as? String == "started" {
                    let call = frame["tool_call"] as? [String: Any] ?? [:]
                    appendTool(call.keys.first { $0.hasSuffix("ToolCall") } ?? "tool")
                    let edit = call["editToolCall"] as? [String: Any]
                    if let path = (edit?["args"] as? [String: Any])?["path"] as? String {
                        writtenPaths.append(path)
                    }
                }
            case .antigravityCLI:
                // Cased as the runtime reads them: events and step types
                // lowercased, states uppercased.
                let event = (frame["event"] as? String)?.lowercased()
                if event == "init" {
                    sessionID = frame["conversation_id"] as? String
                }
                if event == "result",
                   let reported = (frame["result"] as? [String: Any])?["usage"] as? [String: Any] {
                    // input_tokens already count cached reads (total_tokens = input + output).
                    usage = (int(reported["input_tokens"]), int(reported["output_tokens"]))
                }
                guard event == "step_update",
                      let step = frame["step_update"] as? [String: Any],
                      let index = step["step_index"] as? Int else { continue }
                let stepType = (step["step_type"] as? String)?.lowercased()
                let state = (step["state"] as? String)?.uppercased()
                let info = step["tool_info"] as? [String: Any]
                let toolName: String = step["tool_name"] as? String ?? info?["name"] as? String ?? "tool"
                if stepType == "agent_response" {
                    let delta = step["text_delta"] as? String ?? ""
                    if let position = antigravityMessageIndex[index] {
                        rawMessages[position] += delta
                    } else {
                        antigravityMessageIndex[index] = rawMessages.count
                        appendMessage(delta)
                    }
                } else if stepType == "tool", state == "DONE" || state == "ERROR" {
                    toolResultOutcomes.append(state == "DONE" ? "success" : "failure")
                } else if stepType == "tool", state == "ACTIVE" {
                    appendTool(toolName)
                    let parameters = info?["parameters"] as? [String: Any]
                    if toolName == "write_to_file", let path = parameters?["TargetFile"] as? String {
                        writtenPaths.append(path)
                    }
                }
            default:
                continue
            }
        }
        for raw in rawMessages {
            for line in raw.components(separatedBy: "\n") {
                let marker = line.trimmingCharacters(in: .whitespaces)
                guard marker.hasPrefix("ASTRA_EVENT "),
                      let data = marker.dropFirst("ASTRA_EVENT ".count).data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      event["type"] as? String == "complete",
                      let summary = event["summary"] as? String,
                      !completionSummaries.contains(summary) else { continue }
                completionSummaries.append(summary)
            }
        }
        var messageIndexByRaw: [Int: Int] = [:]
        for (rawIndex, raw) in rawMessages.enumerated() {
            let visible = Self.visibleText(raw)
            guard !visible.isEmpty else { continue }
            messageIndexByRaw[rawIndex] = messages.count
            messages.append(visible)
        }
        sequence = rawSequence.compactMap { step in
            switch step {
            case .message(let rawIndex): messageIndexByRaw[rawIndex].map { .message($0) }
            case .tool(let name): .tool(name)
            }
        }
        for (earlier, later) in zip(messages, messages.dropFirst()) {
            let lastLine = earlier.components(separatedBy: "\n").last ?? ""
            let firstLine = later.components(separatedBy: "\n").first ?? ""
            boundaryJoins.append(Set([collapsed(lastLine + firstLine), collapsed(lastLine + " " + firstLine)]))
        }

        // The drafted reply is the message with the scenario's own heading
        // line, not one that only mentions it. In that scenario it is
        // required: falling back to another message would let a bubble that
        // shows only the sign-off pass.
        let draftedReply = messages.first { message in
            message.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "## Suggested reply" }
        }
        answer = fixture.scenario == "answer-write-signoff" ? draftedReply : messages.last
    }

    private static let copilotTypeKeys = ["type", "event", "kind", "sessionUpdate", "name"]

    /// A Copilot frame's type, lowercased, and the object it describes, as
    /// CopilotStreamEventParser reads them: the first discriminator on the
    /// frame, else on its data/payload object, with envelopes typed
    /// event/message/data/payload unwrapped however deep.
    static func copilotFrame(_ frame: [String: Any]) -> (type: String, object: [String: Any]) {
        let payload = copilotPayload(frame)
        let type = (copilotTypeKeys.lazy.compactMap { frame[$0] as? String }.first
            ?? payload.flatMap { inner in copilotTypeKeys.lazy.compactMap { inner[$0] as? String }.first }
            ?? "").lowercased()
        if ["event", "message", "data", "payload"].contains(type), let payload,
           copilotTypeKeys.contains(where: { payload[$0] is String }) {
            return copilotFrame(payload)
        }
        return (type, frame)
    }

    enum CopilotToolRole {
        case use
        case result
    }

    /// Whether a Copilot frame is a tool call or a tool result, by the shapes
    /// the stream uses: after the conversation, session, progress, permission
    /// and error frames that are neither, a type naming a tool use, call or
    /// start is a call; a type naming a tool result, output or completion, or
    /// a `toolResult` field, is a result; a tool identity on any other frame is
    /// a call.
    static func copilotToolRole(_ type: String, _ object: [String: Any]) -> CopilotToolRole? {
        let conversation: Set<String> = [
            "user.message", "assistant.turn_start", "assistant.turn_end", "assistant.message_start", "assistant.idle",
            "assistant.reasoning", "assistant.reasoning_delta", "assistant.tool_call_delta", "assistant.message_delta",
            "assistant.message", "agent_message_chunk", "agent_thought_chunk", "thinking",
            "tool.execution_partial_result", "tool.execution_progress"
        ]
        guard !conversation.contains(type), !type.hasPrefix("session."), !type.contains("reasoning"),
              !type.contains("permission"), !type.contains("approval"),
              !type.contains("error"), type != "failed" else { return nil }
        let payload = copilotPayload(object)
        func has(_ keys: [String]) -> Bool { keys.contains { object[$0] != nil || payload?[$0] != nil } }
        let isResult = type.contains("tool") && ["result", "output", "complete"].contains(where: type.contains)
            || has(["toolResult"])
        if type.contains("tool") && ["use", "call", "start"].contains(where: type.contains) { return .use }
        if has(["tool", "toolName", "tool_call_id", "toolUseId", "callId"]) && !isResult { return .use }
        return isResult ? .result : nil
    }

    /// A Codex item the stream reports as a tool call other than a command:
    /// its type names a tool, or it carries a `tool` / `name`. Messages,
    /// reasoning, file changes and commands are read on their own.
    static func codexItemType(_ item: [String: Any]) -> String? {
        ["type", "kind"].lazy.compactMap { key -> String? in
            let value = (item[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value?.lowercased() : nil
        }.first
    }

    /// CodexStreamEventParser.textValue: the first nonempty text field, then
    /// nested objects, then content and summary parts joined.
    static func codexText(_ object: [String: Any]) -> String? {
        for key in ["text", "delta", "message", "content", "output", "error", "summary", "aggregated_output"] {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        for key in ["item", "data", "message", "delta", "content"] {
            if let nested = object[key] as? [String: Any], let text = codexText(nested) { return text }
        }
        for key in ["content", "summary"] {
            if let parts = object[key] as? [[String: Any]] {
                let text = parts.compactMap(codexText).joined()
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    static func isGenericCodexToolItem(_ item: [String: Any]) -> Bool {
        let type = codexItemType(item) ?? ""
        let ownShapes = ["agent_message", "message", "assistant_message", "file_change", "command_execution"]
        guard !ownShapes.contains(type), !type.contains("reasoning"), !type.contains("error") else { return false }
        return type.contains("tool") || item["tool"] != nil || item["name"] != nil
    }

    static func copilotPayload(_ object: [String: Any]) -> [String: Any]? {
        object["data"] as? [String: Any] ?? object["payload"] as? [String: Any]
    }

    /// The recorder strips ASTRA protocol marker lines from visible text.
    private static func visibleText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `*** Add File: <path>` / `*** Update File: <path>` headers of a patch.
    private static func patchedPaths(in patch: String) -> [String] {
        patch.components(separatedBy: "\n").compactMap { line in
            for header in ["*** Add File: ", "*** Update File: "] where line.hasPrefix(header) {
                return String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }
}

private func collapsed(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

/// Whitespace collapsed within each line, line breaks kept, and any run of
/// blank lines reduced to one paragraph break.
private func lineStructure(_ text: String) -> String {
    var lines: [String] = []
    for line in text.components(separatedBy: "\n").map(collapsed) {
        if line.isEmpty, lines.last?.isEmpty ?? true { continue }
        lines.append(line)
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
}

/// `steps` keeping only entries `other` also has, each at most as often as it
/// occurs there, in order.
private func commonSteps(_ steps: [TranscriptStep], with other: [TranscriptStep]) -> [TranscriptStep] {
    var remaining = other.reduce(into: [TranscriptStep: Int]()) { $0[$1, default: 0] += 1 }
    return steps.filter { step in
        guard let count = remaining[step], count > 0 else { return false }
        remaining[step] = count - 1
        return true
    }
}

/// Copies of `message` in `text` (both collapsed), leaving out occurrences
/// that are part of a longer provider message containing it: `Done` inside
/// `Done with work` belongs to that message, not a copy of `Done`.
private func messageCount(_ message: String, in text: String, among messages: [String]) -> Int {
    guard !message.isEmpty else { return 0 }
    let covering = Set(messages.filter { $0.count > message.count && $0.contains(message) })
        .flatMap { nonOverlappingRanges(of: $0, in: text) }
    return nonOverlappingRanges(of: message, in: text).filter { range in
        !covering.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
    }.count
}

private func nonOverlappingRanges(of needle: String, in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start = text.startIndex
    while let range = text.range(of: needle, range: start..<text.endIndex) {
        ranges.append(range)
        start = range.upperBound
    }
    return ranges
}

/// Messages found in `text` (collapsed) only before the one the provider sent
/// ahead of them. Matching runs left to right; a message absent everywhere
/// belongs to the multiplicity checks.
private func outOfOrderMessages(in text: String, messages: [String]) -> [String] {
    var cursor = text.startIndex
    var outOfOrder: [String] = []
    var rankByNeedle: [String: Int] = [:]
    for message in messages {
        let needle = collapsed(message)
        // The k-th copy of a text is out of order only if the text has at
        // least k copies; a missing copy belongs to the multiplicity checks.
        let rank = rankByNeedle[needle, default: 0]
        rankByNeedle[needle] = rank + 1
        if let match = text.range(of: needle, range: cursor..<text.endIndex) {
            cursor = match.upperBound
        } else if nonOverlappingRanges(of: needle, in: text).count > rank {
            outOfOrder.append(String(message.prefix(60)))
        }
    }
    return outOfOrder
}

/// Lines of `text` the provider never sent. A line may instead be a join of
/// one message's last line with the next message's first line (messages are
/// appended without a separator), and each boundary joins at most once, in
/// either spelling. A line that several boundaries can produce is charged to
/// one of them, never to all: occurrences are matched to boundaries.
private func unsentLineFailures(
    in text: String,
    sent: [String: Int],
    boundaries: [Set<String>],
    source: String
) -> [(item: String, message: String)] {
    let unsent = lineCounts(text).filter { sent[$0.key] == nil }
    var failures: [(item: String, message: String)] = []
    var occurrences: [String] = []
    for line in unsent.keys.sorted() {
        if boundaries.contains(where: { $0.contains(line) }) {
            occurrences += Array(repeating: line, count: unsent[line] ?? 0)
        } else {
            failures.append((line, "line in \(source) the provider never sent: \(line.prefix(80))"))
        }
    }
    // Augmenting-path matching of occurrences to the boundaries that can
    // produce them.
    var occurrenceAtBoundary = [Int?](repeating: nil, count: boundaries.count)
    func charge(_ occurrence: Int, visited: inout Set<Int>) -> Bool {
        for boundary in boundaries.indices where boundaries[boundary].contains(occurrences[occurrence]) {
            guard visited.insert(boundary).inserted else { continue }
            if let other = occurrenceAtBoundary[boundary], !charge(other, visited: &visited) { continue }
            occurrenceAtBoundary[boundary] = occurrence
            return true
        }
        return false
    }
    var uncharged: [String: Int] = [:]
    for occurrence in occurrences.indices {
        var visited = Set<Int>()
        if !charge(occurrence, visited: &visited) {
            uncharged[occurrences[occurrence], default: 0] += 1
        }
    }
    for (line, extra) in uncharged.sorted(by: { $0.key < $1.key }) {
        failures.append((line, "boundary join in \(source) recorded \(extra)x more than its boundaries allow: \(line.prefix(80))"))
    }
    return failures
}

/// A provider frame leaked into the text, whatever its key order: a line that
/// is a JSON object with a frame discriminator, or that holds one glued to
/// text. Protocol marker lines are the recorder's, not a provider's.
private func isRawProviderFrame(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix(AstraRunProtocolParser.markerToken) else { return false }
    if let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
        return object["type"] != nil || object["event"] != nil
    }
    // The discriminator can be the object's first key or a later one.
    return trimmed.range(
        of: #"\{\s*"(?:type|event)"\s*:\s*"|\{\s*"[^"]+"\s*:.*"(?:type|event)"\s*:\s*""#,
        options: .regularExpression
    ) != nil
}

private let extraLineSeparator = "\u{1F}"

/// A value-mismatch failure item (a token total, a session id): the field,
/// what the provider reported and what was recorded, so a known issue can
/// cover one exact wrong value rather than any.
private func valueItem(_ name: String, expected: String, recorded: String) -> String {
    [name, expected, recorded].joined(separator: extraLineSeparator)
}

private func valueParts(of item: String) -> (name: String, expected: String, recorded: String)? {
    let parts = item.components(separatedBy: extraLineSeparator)
    guard parts.count == 3 else { return nil }
    return (parts[0], parts[1], parts[2])
}

/// A message-multiplicity failure item: the message and how many times it was
/// recorded and sent, so a known issue can cover one exact defect.
private func multiplicityItem(_ message: String, recorded: Int, sent: Int) -> String {
    [message, String(recorded), String(sent)].joined(separator: extraLineSeparator)
}

private func multiplicity(of item: String) -> (message: String, recorded: Int, sent: Int)? {
    let parts = item.components(separatedBy: extraLineSeparator)
    guard parts.count == 3, let recorded = Int(parts[1]), let sent = Int(parts[2]) else { return nil }
    return (parts[0], recorded, sent)
}

/// A `noExtraLines` failure item: the line, how many copies too many, and how
/// many the provider sent.
private func extraLineItem(_ line: String, overage: Int, sent: Int) -> String {
    [line, String(overage), String(sent)].joined(separator: extraLineSeparator)
}

private func int(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
}

private func multiset(_ items: [String]) -> [String: Int] {
    items.reduce(into: [:]) { counts, item in counts[item, default: 0] += 1 }
}

/// The tool name in a recorded `Using tool: <name>[: <summary>]` payload.
private func toolName(fromUsePayload payload: String) -> String {
    let body = payload.hasPrefix("Using tool: ") ? String(payload.dropFirst("Using tool: ".count)) : payload
    return String(body.prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces)
}

/// A path relative to whichever workspace root contains it; other paths stay
/// absolute so a wrong directory never matches.
private func workspaceRelative(_ path: String, roots: [String]) -> String {
    // A relative stored path is already workspace-relative, as
    // TaskArtifactPathNormalizer treats it; never resolve it against the
    // test process's working directory.
    guard path.hasPrefix("/") else {
        return (path as NSString).standardizingPath
    }
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    for root in roots {
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        for candidate in [base, "/private" + base] where standardized.hasPrefix(candidate + "/") {
            return String(standardized.dropFirst(candidate.count + 1))
        }
    }
    return standardized
}

private func lineCounts(_ text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in text.components(separatedBy: "\n") {
        let key = collapsed(line)
        // A lone `>` is a quote block's blank line: part of the paragraph
        // structure, so it is counted like any other line.
        guard !key.isEmpty else { continue }
        counts[key, default: 0] += 1
    }
    return counts
}
