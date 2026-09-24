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
        report(.eachMessageOnce, of: fixture, failures: truth.messages.enumerated().compactMap { index, message in
            let text = collapsed(message)
            guard truth.messages.firstIndex(where: { collapsed($0) == text }) == index else { return nil }
            let expected = expectedMultiplicity[text] ?? 1
            let occurrences = collapsedOutput.components(separatedBy: text).count - 1
            return occurrences == expected
                ? nil
                : (message, "recorded \(occurrences)x, sent \(expected)x: \(message.prefix(80))")
        })

        // Match messages left to right: each must be found after the previous
        // match. A message present only earlier is out of order; one absent
        // everywhere belongs to eachMessageOnce.
        var cursor = collapsedOutput.startIndex
        var outOfOrder: [String] = []
        for message in truth.messages {
            let text = collapsed(message)
            if let match = collapsedOutput.range(of: text, range: cursor..<collapsedOutput.endIndex) {
                cursor = match.upperBound
            } else if collapsedOutput.contains(text) {
                outOfOrder.append(String(message.prefix(60)))
            }
        }
        report(.messagesInOrder, of: fixture, failures: outOfOrder.map {
            ($0, "message recorded before the one the provider sent ahead of it: \($0)")
        })

        // Lines two messages glued together are not the provider's lines, so
        // only lines the provider actually sent are counted.
        let sent = lineCounts(truth.messages.joined(separator: "\n"))
        // The item carries the overage, so a known issue can cover "one extra
        // copy of a short line" without also excusing a worse duplication.
        report(.noExtraLines, of: fixture, failures: lineCounts(output).sorted { $0.key < $1.key }.compactMap { line, count in
            guard let expected = sent[line], count > expected else { return nil }
            return (extraLineItem(line, overage: count - expected, sent: expected), "line recorded \(count)x, sent \(expected)x: \(line.prefix(80))")
        })

        // Every other line must be a join of one message's last line with the
        // next message's first line (messages are appended without a
        // separator), at most once per such boundary; anything else is text
        // the provider never sent.
        let joins = truth.boundaryJoins
        report(.noUnsentLines, of: fixture, failures: lineCounts(output).sorted { $0.key < $1.key }.compactMap { line, count in
            guard sent[line] == nil else { return nil }
            let boundaries = joins[line] ?? 0
            if boundaries == 0 {
                return (line, "line the provider never sent: \(line.prefix(80))")
            }
            return count <= boundaries
                ? nil
                : (line, "boundary join recorded \(count)x across \(boundaries) boundary(ies): \(line.prefix(80))")
        })

        // Collapsed comparisons ignore line breaks, so each message present in
        // the output must also keep its lines and blank-line paragraph breaks.
        // Counted per occurrence: every recorded copy of a text, up to how
        // many the provider sent, must keep its structure.
        let structuredOutput = lineStructure(output)
        report(.paragraphStructure, of: fixture, failures: truth.messages.enumerated().compactMap { index, message in
            let text = collapsed(message)
            guard truth.messages.firstIndex(where: { collapsed($0) == text }) == index else { return nil }
            let present = min(expectedMultiplicity[text] ?? 1, collapsedOutput.components(separatedBy: text).count - 1)
            let structured = structuredOutput.components(separatedBy: lineStructure(message)).count - 1
            return structured >= present
                ? nil
                : (message, "line or paragraph breaks lost in \(present - structured) of \(present) copies: \(message.prefix(80))")
        })

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
                    guard collapsedSoFar.components(separatedBy: text).count - 1 > rank else { continue }
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

        let recordedOutcomes = multiset(events.compactMap { event -> String? in
            switch event.type {
            case TaskEventTypes.Tool.result.rawValue: "success"
            case TaskEventTypes.Tool.resultFailed.rawValue: "failure"
            default: nil
            }
        })
        let expectedOutcomes = multiset(truth.toolResultOutcomes)
        report(.toolResultsRecorded, of: fixture, failures: ["success", "failure"].compactMap { outcome in
            let expected = expectedOutcomes[outcome] ?? 0
            let recorded = recordedOutcomes[outcome] ?? 0
            return expected == recorded ? nil : (outcome, "\(outcome) tool results: provider reported \(expected), recorded \(recorded)")
        })

        if let usage = truth.usage {
            #expect(fixture.notExercised[.usageRecorded] == nil, "fixture now reports usage; drop usageRecorded from notExercised")
            report(.usageRecorded, of: fixture, failures: [
                ("input", usage.input, run.inputTokens),
                ("output", usage.output, run.outputTokens)
            ].compactMap { name, expected, recorded in
                expected == recorded ? nil : (name, "\(name) tokens: provider reported \(expected), recorded \(recorded)")
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

        let rawFrameInOutput = output.contains(#"{"type":""#) || output.contains(#"{"event":""#)
        report(.noRawProviderJSON, of: fixture, failures: rawFrameInOutput ? [("", "raw provider frame in run output")] : [])

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
        report(.fileChangesRecorded, of: fixture, failures: Set(recordedPaths.keys).union(expectedPaths.keys).sorted().compactMap { path in
            let expected = expectedPaths[path] ?? 0
            let recorded = recordedPaths[path] ?? 0
            return expected == recorded ? nil : (path, "file \(path): provider wrote \(expected)x, recorded \(recorded)x")
        })

        report(.noSpuriousErrors, of: fixture, failures: events
            .filter { $0.type == TaskEventTypes.System.error.rawValue }
            .map { ($0.payload, "a successful turn recorded an error: \($0.payload.prefix(80))") })

        // Follow-ups resume the provider's own session, so the identity the
        // stream announced must reach both durable owners.
        if let sessionID = truth.sessionID {
            #expect(fixture.notExercised[.sessionRecorded] == nil, "fixture now announces a session; drop sessionRecorded from notExercised")
            report(.sessionRecorded, of: fixture, failures: [
                ("task.sessionId", task.sessionId),
                ("run.providerSessionId", run.providerSessionId)
            ].compactMap { field, recorded in
                recorded == sessionID ? nil : (field, "\(field): provider session \(sessionID), recorded \(recorded ?? "nil")")
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
        let answer = try #require(truth.answer, "fixture has no answer message")
        let answerFailure: (item: String, message: String)? =
            if !collapsed(displayed).contains(collapsed(answer)) {
                ("text", "answer bubble is missing answer text: \(answer.prefix(80))")
            } else if !lineStructure(displayed).contains(lineStructure(answer)) {
                ("structure", "answer bubble lost the answer's line or paragraph breaks")
            } else {
                nil
            }
        report(.answerVisible, of: fixture, failures: answerFailure.map { [$0] } ?? [])
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
        case toolResultsRecorded
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
                .eachMessageOnce: .items("the envelope echo re-appends the short closing message whole (plan phase 1)") {
                    $0.hasPrefix("The draft reply is saved")
                },
                .noExtraLines: .shortLines("the envelope echo re-appends every line under 80 characters (plan phase 1)"),
                .answerVisible: .whole("the answer precedes the Write call, so only the sign-off is shown (plan phase 3)")
            ]
        ),
        ProviderStreamFixture(
            provider: "claude",
            scenario: "subagent",
            runtime: .claudeCode,
            executableName: "claude",
            model: "claude-sonnet-5",
            knownIssues: [:],
            notExercised: [
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
                    $0 == "answer.md"
                },
                .sessionRecorded: .whole("Copilot names its session only in the result frame, which is not read (plan phase 2)"),
                .answerVisible: .whole("the answer precedes the apply_patch call, so only the sign-off is shown (plan phase 3)")
            ],
            notExercised: [.usageRecorded: "Copilot's stream reports premium requests, not tokens"]
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
                .eachMessageOnce: .items("last-completed-wins keeps only the final agent_message (plan phase 2)") {
                    !$0.hasPrefix("The draft is saved")
                },
                .fileChangesRecorded: .items("file_change paths nest under changes[] and are dropped (plan phase 2)") {
                    $0 == "answer.md"
                },
                .noSpuriousErrors: .items("config-warning items of type error are recorded as agent errors (plan phase 2)") {
                    $0.hasPrefix("Configured value for")
                },
                .usageRecorded: .items("cached_input_tokens are added to input_tokens, which already include them (plan phase 2)") {
                    $0 == "input"
                },
                .completionRecorded: .items("ASTRA_EVENT markers in agent_message items are stripped, never recorded (plan phase 2)") {
                    $0 == "Drafted the reply and saved answer.md"
                },
                .answerVisible: .whole("the answer message is dropped before it can be shown (plan phase 2)")
            ]
        ),
        ProviderStreamFixture(
            provider: "cursor",
            scenario: "answer-write-signoff",
            runtime: .cursorCLI,
            executableName: "cursor-agent",
            model: "composer-2.5-fast",
            knownIssues: [
                .eachMessageOnce: .items("the last frame re-sends the previous message and echo residue splits it (plan phase 2)") {
                    $0.hasSuffix("The same draft is saved in `answer.md`.")
                },
                .noExtraLines: .shortLines("re-sent short lines of the previous message are appended again (plan phase 2)"),
                .toolCallsRecorded: .items("tool_call frames are not parsed (plan phase 4)") {
                    ["readToolCall", "editToolCall"].contains($0)
                },
                .toolResultsRecorded: .items("tool_call completions are not parsed (plan phase 4)") { $0 == "success" },
                .fileChangesRecorded: .items("editToolCall writes are not parsed (plan phase 4)") {
                    $0 == "answer.md"
                },
                .answerVisible: .items("the re-sent previous message splits the answer with echo residue (plan phase 2)") {
                    $0 == "text"
                }
            ]
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
    /// Collapsed "last line of a message + first line of the next message",
    /// counted per boundary: the only lines, besides the provider's own, that
    /// appending messages without a separator can produce, once each.
    private(set) var boundaryJoins: [String: Int] = [:]
    /// The message the user asked for: the drafted reply in the
    /// answer-write-signoff scenario, otherwise the last message.
    private(set) var answer: String?

    init(fixture: ProviderStreamFixture, frames: [String]) {
        var rawMessages: [String] = []
        var rawSequence: [RawStep] = []
        var antigravityMessageIndex: [Int: Int] = [:]
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
                if type == "system", ["task_notification", "task_completed"].contains(frame["subtype"] as? String ?? ""),
                   let taskID = frame["task_id"] as? String {
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
                let data = frame["data"] as? [String: Any]
                if type == "assistant.message", let text = data?["content"] as? String {
                    appendMessage(text)
                } else if type == "result" {
                    // Copilot's stdout names its session only in the result.
                    sessionID = frame["sessionId"] as? String
                } else if type == "tool.execution_complete" {
                    toolResultOutcomes.append(data?["success"] as? Bool == false ? "failure" : "success")
                } else if type == "tool.execution_start" {
                    appendTool(data?["toolName"] as? String ?? "tool")
                    if data?["toolName"] as? String == "apply_patch", let patch = data?["arguments"] as? String {
                        writtenPaths += Self.patchedPaths(in: patch)
                    }
                }
            case .codexCLI:
                let item = frame["item"] as? [String: Any]
                if type == "item.completed", item?["type"] as? String == "agent_message",
                   let text = item?["text"] as? String {
                    appendMessage(text)
                } else if type == "thread.started" {
                    sessionID = frame["thread_id"] as? String
                } else if type == "item.started", item?["type"] as? String == "command_execution" {
                    appendTool("command_execution")
                } else if type == "item.completed", item?["type"] as? String == "command_execution" {
                    let exitCode = item?["exit_code"] as? Int
                    toolResultOutcomes.append(exitCode == nil || exitCode == 0 ? "success" : "failure")
                } else if type == "turn.completed", let reported = frame["usage"] as? [String: Any] {
                    // Codex's input_tokens already include cached_input_tokens:
                    // its own total_tokens is input_tokens + output_tokens.
                    usage = (int(reported["input_tokens"]), int(reported["output_tokens"]))
                } else if type == "item.completed", item?["type"] as? String == "file_change",
                          let changes = item?["changes"] as? [[String: Any]] {
                    writtenPaths += changes.compactMap { $0["path"] as? String }
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
                    if let previous = rawMessages.last, !previous.isEmpty, text.hasPrefix(previous) {
                        rawMessages[rawMessages.count - 1] = text
                    } else if !text.isEmpty {
                        appendMessage(text)
                    }
                } else if type == "result", let reported = frame["usage"] as? [String: Any] {
                    // Cursor reports cache reads and writes apart from input,
                    // as Anthropic does; it gives no total to check against.
                    usage = (
                        int(reported["inputTokens"]) + int(reported["cacheReadTokens"]) + int(reported["cacheWriteTokens"]),
                        int(reported["outputTokens"])
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
                if frame["event"] as? String == "init" {
                    sessionID = frame["conversation_id"] as? String
                }
                if frame["event"] as? String == "result",
                   let reported = (frame["result"] as? [String: Any])?["usage"] as? [String: Any] {
                    // input_tokens already count cached reads (total_tokens = input + output).
                    usage = (int(reported["input_tokens"]), int(reported["output_tokens"]))
                }
                guard frame["event"] as? String == "step_update",
                      let step = frame["step_update"] as? [String: Any],
                      let index = step["step_index"] as? Int else { continue }
                if step["step_type"] as? String == "agent_response" {
                    let delta = step["text_delta"] as? String ?? ""
                    if let position = antigravityMessageIndex[index] {
                        rawMessages[position] += delta
                    } else {
                        antigravityMessageIndex[index] = rawMessages.count
                        appendMessage(delta)
                    }
                } else if step["step_type"] as? String == "tool", ["DONE", "ERROR"].contains(step["state"] as? String) {
                    toolResultOutcomes.append(step["state"] as? String == "DONE" ? "success" : "failure")
                } else if step["step_type"] as? String == "tool", step["state"] as? String == "ACTIVE" {
                    appendTool(step["tool_name"] as? String ?? "tool")
                    let parameters = (step["tool_info"] as? [String: Any])?["parameters"] as? [String: Any]
                    if step["tool_name"] as? String == "write_to_file", let path = parameters?["TargetFile"] as? String {
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
            // Either spelling of the join, but one boundary is one join.
            for join in Set([collapsed(lastLine + firstLine), collapsed(lastLine + " " + firstLine)]) {
                boundaryJoins[join, default: 0] += 1
            }
        }

        answer = messages.first { $0.contains("Suggested reply") } ?? messages.last
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

private let extraLineSeparator = "\u{1F}"

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
