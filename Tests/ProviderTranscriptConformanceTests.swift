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
            ("", "run ended \(run.status) with stopReason=\(run.stopReason)")
        ])

        report(.eachMessageOnce, of: fixture, failures: truth.messages.compactMap { message in
            let occurrences = collapsedOutput.components(separatedBy: collapsed(message)).count - 1
            return occurrences == 1 ? nil : (message, "recorded \(occurrences)x: \(message.prefix(80))")
        })

        // Messages that are lost or split belong to eachMessageOnce; every
        // message that is present must sit after the one before it.
        let positions = truth.messages.compactMap { message in
            collapsedOutput.range(of: collapsed(message)).map {
                collapsedOutput.distance(from: collapsedOutput.startIndex, to: $0.lowerBound)
            }
        }
        report(.messagesInOrder, of: fixture, failures: zip(positions, positions.dropFirst()).allSatisfy(<) ? [] : [
            ("", "messages recorded out of provider order: \(positions)")
        ])

        // Lines two messages glued together are not the provider's lines, so
        // only lines the provider actually sent are counted.
        let sent = lineCounts(truth.messages.joined(separator: "\n"))
        report(.noExtraLines, of: fixture, failures: lineCounts(output).sorted { $0.key < $1.key }.compactMap { line, count in
            guard let expected = sent[line], count > expected else { return nil }
            return (line, "line recorded \(count)x, sent \(expected)x: \(line.prefix(80))")
        })

        let rawFrameInOutput = output.contains(#"{"type":""#) || output.contains(#"{"event":""#)
        report(.noRawProviderJSON, of: fixture, failures: rawFrameInOutput ? [("", "raw provider frame in run output")] : [])

        let recordedToolCalls = events.filter { $0.type == TaskEventTypes.Tool.use.rawValue }.count
        report(.toolCallsRecorded, of: fixture, failures: recordedToolCalls >= truth.toolCallCount ? [] : [
            ("", "recorded \(recordedToolCalls) of \(truth.toolCallCount) tool calls")
        ])

        let recordedFileNames = Set(run.fileChanges.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        report(.fileChangesRecorded, of: fixture, failures: truth.writtenFileNames.sorted().compactMap { fileName in
            recordedFileNames.contains(fileName)
                ? nil
                : (fileName, "write to \(fileName) not recorded; recorded \(recordedFileNames.sorted())")
        })

        report(.noSpuriousErrors, of: fixture, failures: events
            .filter { $0.type == TaskEventTypes.System.error.rawValue }
            .map { ($0.payload, "a successful turn recorded an error: \($0.payload.prefix(80))") })

        let snapshot = TaskThreadSnapshot(task: task)
        let displayed = collapsed(
            snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))).displayText
        )
        report(.answerVisible, of: fixture, failures: truth.answerExcerpts.compactMap { excerpt in
            displayed.contains(excerpt) ? nil : (excerpt, "answer bubble is missing: \(excerpt)")
        })
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

    /// The per-line echo check re-appends only lines under its 80-character
    /// floor; a duplicated longer line is a new defect.
    static func shortLines(_ reason: String) -> Self {
        items(reason) { $0.count < 80 }
    }
}

struct ProviderStreamFixture: CustomTestStringConvertible, Sendable {
    enum Check: String, Sendable {
        case runCompletes
        case eachMessageOnce
        case messagesInOrder
        case noExtraLines
        case noRawProviderJSON
        case toolCallsRecorded
        case fileChangesRecorded
        case noSpuriousErrors
        case answerVisible
    }

    let provider: String
    let scenario: String
    let runtime: AgentRuntimeID
    let executableName: String
    let model: String
    let knownIssues: [Check: ProviderStreamKnownIssue]

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
                .fileChangesRecorded: .whole("apply_patch writes are not recorded as file changes (plan phase 4)"),
                .answerVisible: .whole("the answer precedes the apply_patch call, so only the sign-off is shown (plan phase 3)")
            ]
        ),
        ProviderStreamFixture(
            provider: "codex",
            scenario: "answer-write-signoff",
            runtime: .codexCLI,
            executableName: "codex",
            model: "gpt-5.5",
            knownIssues: [
                .runCompletes: .whole("config-warning items of type error fail the run as agent_reported_error (plan phase 2)"),
                .eachMessageOnce: .items("last-completed-wins keeps only the final agent_message (plan phase 2)") {
                    !$0.hasPrefix("The draft is saved")
                },
                .fileChangesRecorded: .whole("file_change paths nest under changes[] and are dropped (plan phase 2)"),
                .noSpuriousErrors: .items("config-warning items of type error are recorded as agent errors (plan phase 2)") {
                    $0.hasPrefix("Configured value for")
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
                .toolCallsRecorded: .whole("tool_call frames are not parsed (plan phase 4)"),
                .fileChangesRecorded: .whole("editToolCall writes are not parsed (plan phase 4)")
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

/// What the provider actually said and did, read straight from the fixture
/// frames.
struct ProviderStreamTruth {
    private(set) var messages: [String] = []
    private(set) var toolCallCount = 0
    private(set) var writtenFileNames: Set<String> = []
    /// Collapsed excerpts of the answer's substantive lines, so a bubble that
    /// shows only a hollow skeleton of headings and greetings fails.
    private(set) var answerExcerpts: [String] = []

    init(fixture: ProviderStreamFixture, frames: [String]) {
        var rawMessages: [String] = []
        var antigravitySteps: [(index: Int, text: String)] = []
        var writtenPaths: [String] = []
        for line in frames {
            guard let data = line.data(using: .utf8),
                  let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = frame["type"] as? String
            switch fixture.runtime {
            case .claudeCode:
                // Subagent frames carry a parent_tool_use_id; only the main
                // agent's messages are the user's transcript.
                guard type == "assistant",
                      frame["parent_tool_use_id"] is NSNull || frame["parent_tool_use_id"] == nil,
                      let message = frame["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        rawMessages.append(text)
                    } else if block["type"] as? String == "tool_use" {
                        toolCallCount += 1
                        if ["Write", "Edit", "MultiEdit"].contains(block["name"] as? String ?? ""),
                           let path = (block["input"] as? [String: Any])?["file_path"] as? String {
                            writtenPaths.append(path)
                        }
                    }
                }
            case .copilotCLI:
                let data = frame["data"] as? [String: Any]
                if type == "assistant.message", let text = data?["content"] as? String {
                    rawMessages.append(text)
                } else if type == "tool.execution_start" {
                    toolCallCount += 1
                    if data?["toolName"] as? String == "apply_patch", let patch = data?["arguments"] as? String {
                        writtenPaths += Self.patchedPaths(in: patch)
                    }
                }
            case .codexCLI:
                let item = frame["item"] as? [String: Any]
                if type == "item.completed", item?["type"] as? String == "agent_message",
                   let text = item?["text"] as? String {
                    rawMessages.append(text)
                } else if type == "item.started", item?["type"] as? String == "command_execution" {
                    toolCallCount += 1
                } else if type == "item.completed", item?["type"] as? String == "file_change",
                          let changes = item?["changes"] as? [[String: Any]] {
                    writtenPaths += changes.compactMap { $0["path"] as? String }
                }
            case .cursorCLI:
                // Cursor's last assistant frame repeats the previous message
                // and appends to it, so a frame that extends the previous
                // message's text continues that message.
                if type == "assistant",
                   let message = frame["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined()
                    if let previous = rawMessages.last, !previous.isEmpty, text.hasPrefix(previous) {
                        rawMessages[rawMessages.count - 1] = text
                    } else if !text.isEmpty {
                        rawMessages.append(text)
                    }
                } else if type == "tool_call", frame["subtype"] as? String == "started" {
                    toolCallCount += 1
                    let edit = (frame["tool_call"] as? [String: Any])?["editToolCall"] as? [String: Any]
                    if let path = (edit?["args"] as? [String: Any])?["path"] as? String {
                        writtenPaths.append(path)
                    }
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
        writtenFileNames = Set(writtenPaths.map { URL(fileURLWithPath: $0).lastPathComponent })

        if let answer = messages.first(where: { $0.contains("Suggested reply") }) {
            answerExcerpts = Self.substantiveExcerpts(of: answer)
        } else if let last = messages.last {
            answerExcerpts = [String(collapsed(last).prefix(60))]
        }
    }

    /// The recorder strips ASTRA protocol marker lines from visible text.
    private static func visibleText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ASTRA_EVENT ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The opening 40 characters of every prose line of 60+ characters, with
    /// quote and bullet markers removed. Table rows and short lines are left
    /// out, because the echo defect keeps exactly those.
    private static func substantiveExcerpts(of answer: String) -> [String] {
        answer.components(separatedBy: "\n").compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("|") else { return nil }
            for marker in ["> ", "- ", "* "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
            }
            let words = collapsed(text)
            return words.count >= 60 ? String(words.prefix(40)) : nil
        }
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

private func lineCounts(_ text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in text.components(separatedBy: "\n") {
        let key = collapsed(line)
        guard !key.isEmpty, key != ">" else { continue }
        counts[key, default: 0] += 1
    }
    return counts
}
