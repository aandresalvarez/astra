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
/// The expected messages come from the fixture itself, read the way each
/// provider documents its frames, never through ASTRA's parsers. Checks that
/// fail today are listed per fixture in `knownIssues` and run under
/// `withKnownIssue`, so a phase of
/// docs/specs/2026-09-23-provider-message-identity-plan.md that fixes one
/// turns it into a failure until its entry is deleted.
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
        verify(.runCompletes, of: fixture) {
            #expect(run.status == .completed, "stopReason=\(run.stopReason)")
        }
        let output = run.output
        let collapsedOutput = collapsed(output)
        let events = task.events

        verify(.eachMessageOnce, of: fixture) {
            for message in truth.messages {
                let occurrences = collapsedOutput.components(separatedBy: collapsed(message)).count - 1
                #expect(occurrences == 1, "recorded \(occurrences)x: \(message.prefix(80))")
            }
        }

        verify(.noExtraLines, of: fixture) {
            // Lines two messages glued together are not the provider's lines,
            // so only lines the provider actually sent are counted.
            let sent = lineCounts(truth.messages.joined(separator: "\n"))
            for (line, count) in lineCounts(output) where sent[line] != nil {
                let expected = sent[line] ?? 0
                #expect(count <= expected, "line recorded \(count)x, sent \(expected)x: \(line.prefix(80))")
            }
        }

        verify(.noRawProviderJSON, of: fixture) {
            #expect(!output.contains(#"{"type":""#) && !output.contains(#"{"event":""#),
                    "raw provider frame in run output")
        }

        verify(.toolCallsRecorded, of: fixture) {
            let recorded = events.filter { $0.type == TaskEventTypes.Tool.use.rawValue }.count
            #expect(recorded >= truth.toolCallCount, "recorded \(recorded) of \(truth.toolCallCount) tool calls")
        }

        verify(.noSpuriousErrors, of: fixture) {
            let errors = events.filter { $0.type == TaskEventTypes.System.error.rawValue }
            #expect(errors.isEmpty, "a successful turn recorded errors: \(errors.map { $0.payload.prefix(80) })")
        }

        verify(.answerVisible, of: fixture) {
            let snapshot = TaskThreadSnapshot(task: task)
            let displayed = collapsed(
                snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))).displayText
            )
            for marker in truth.answerMarkers {
                #expect(displayed.contains(collapsed(marker)), "answer bubble is missing \(marker.prefix(60))")
            }
        }
    }

    private func verify(
        _ check: ProviderStreamFixture.Check,
        of fixture: ProviderStreamFixture,
        _ body: () -> Void
    ) {
        if let reason = fixture.knownIssues[check] {
            withKnownIssue(Comment(rawValue: "\(check.rawValue): \(reason)"), body)
        } else {
            body()
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

struct ProviderStreamFixture: CustomTestStringConvertible, Sendable {
    enum Check: String, Sendable {
        case runCompletes
        case eachMessageOnce
        case noExtraLines
        case noRawProviderJSON
        case toolCallsRecorded
        case noSpuriousErrors
        case answerVisible
    }

    let provider: String
    let scenario: String
    let runtime: AgentRuntimeID
    let executableName: String
    let model: String
    let knownIssues: [Check: String]

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
                .eachMessageOnce: "the envelope echo re-appends a short message whole (plan phase 1)",
                .noExtraLines: "the envelope echo re-appends every line under 80 characters (plan phase 1)",
                .answerVisible: "the answer precedes the Write call, so only the sign-off is shown (plan phase 3)"
            ]
        ),
        ProviderStreamFixture(
            provider: "claude",
            scenario: "subagent",
            runtime: .claudeCode,
            executableName: "claude",
            model: "claude-sonnet-5",
            knownIssues: [:]
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
                .answerVisible: "the answer precedes the apply_patch call, so only the sign-off is shown (plan phase 3)"
            ]
        ),
        ProviderStreamFixture(
            provider: "codex",
            scenario: "answer-write-signoff",
            runtime: .codexCLI,
            executableName: "codex",
            model: "gpt-5.5",
            knownIssues: [
                .runCompletes: "config-warning items of type error fail the run as agent_reported_error (plan phase 2)",
                .eachMessageOnce: "last-completed-wins keeps only the final agent_message (plan phase 2)",
                .noSpuriousErrors: "config-warning items of type error are recorded as agent errors (plan phase 2)",
                .answerVisible: "the answer message is dropped before it can be shown (plan phase 2)"
            ]
        ),
        ProviderStreamFixture(
            provider: "cursor",
            scenario: "answer-write-signoff",
            runtime: .cursorCLI,
            executableName: "cursor-agent",
            model: "composer-2.5-fast",
            knownIssues: [
                .eachMessageOnce: "the last frame re-sends the previous message, and only its long lines are dropped (plan phase 2)",
                .noExtraLines: "re-sent short lines of the previous message are appended again (plan phase 2)",
                .toolCallsRecorded: "tool_call frames are not parsed (plan phase 4)"
            ]
        ),
        ProviderStreamFixture(
            provider: "antigravity",
            scenario: "answer-write-signoff",
            runtime: .antigravityCLI,
            executableName: "agy",
            model: "Gemini 3.5 Flash",
            knownIssues: [:]
        )
    ]
}

/// What the provider actually said, read straight from the fixture frames.
struct ProviderStreamTruth {
    private(set) var messages: [String] = []
    private(set) var toolCallCount = 0
    private(set) var answerMarkers: [String] = []

    init(fixture: ProviderStreamFixture, frames: [String]) {
        var rawMessages: [String] = []
        var antigravitySteps: [(index: Int, text: String)] = []
        for line in frames {
            guard let data = line.data(using: .utf8),
                  let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch fixture.runtime {
            case .claudeCode:
                // Subagent frames carry a parent_tool_use_id; only the main
                // agent's messages are the user's transcript.
                guard frame["type"] as? String == "assistant",
                      frame["parent_tool_use_id"] is NSNull || frame["parent_tool_use_id"] == nil,
                      let message = frame["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        rawMessages.append(text)
                    } else if block["type"] as? String == "tool_use" {
                        toolCallCount += 1
                    }
                }
            case .copilotCLI:
                let data = frame["data"] as? [String: Any]
                if frame["type"] as? String == "assistant.message", let text = data?["content"] as? String {
                    rawMessages.append(text)
                } else if frame["type"] as? String == "tool.execution_start" {
                    toolCallCount += 1
                }
            case .codexCLI:
                let item = frame["item"] as? [String: Any]
                if frame["type"] as? String == "item.completed",
                   item?["type"] as? String == "agent_message",
                   let text = item?["text"] as? String {
                    rawMessages.append(text)
                } else if frame["type"] as? String == "item.started", item?["type"] as? String == "command_execution" {
                    toolCallCount += 1
                }
            case .cursorCLI:
                // Cursor's last assistant frame repeats the previous message
                // and appends to it, so a frame that extends the previous
                // message's text continues that message.
                if frame["type"] as? String == "assistant",
                   let message = frame["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined()
                    if let previous = rawMessages.last, !previous.isEmpty, text.hasPrefix(previous) {
                        rawMessages[rawMessages.count - 1] = text
                    } else if !text.isEmpty {
                        rawMessages.append(text)
                    }
                } else if frame["type"] as? String == "tool_call", frame["subtype"] as? String == "started" {
                    toolCallCount += 1
                }
            case .antigravityCLI:
                guard frame["event"] as? String == "step_update",
                      let step = frame["step_update"] as? [String: Any],
                      let index = step["step_index"] as? Int else { continue }
                if step["step_type"] as? String == "agent_response" {
                    let delta = step["text_delta"] as? String ?? ""
                    if let position = antigravitySteps.firstIndex(where: { $0.index == index }) {
                        antigravitySteps[position].text += delta
                    } else {
                        antigravitySteps.append((index, delta))
                    }
                } else if step["step_type"] as? String == "tool", step["state"] as? String == "ACTIVE" {
                    toolCallCount += 1
                }
            default:
                continue
            }
        }
        rawMessages += antigravitySteps.map(\.text)
        messages = rawMessages.map(Self.visibleText).filter { !$0.isEmpty }
        if let answer = messages.first(where: { $0.contains("Suggested reply") }) {
            answerMarkers = ["Suggested reply", "All the best"].filter { answer.contains($0) }
        } else if let last = messages.last {
            answerMarkers = [String(last.prefix(60))]
        }
    }

    /// The recorder strips ASTRA protocol marker lines from visible text.
    private static func visibleText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func collapsed(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

private func lineCounts(_ text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in text.components(separatedBy: "\n") {
        let key = collapsed(line)
        guard !key.isEmpty, key != ">" else { continue }
        counts[key, default: 0] += 1
    }
    return counts
}
