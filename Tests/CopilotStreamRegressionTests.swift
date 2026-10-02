import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot Stream Regressions")
struct CopilotStreamRegressionTests {
    @Test("Captured Copilot quota frames parse as provider failure output")
    func capturedQuotaFailuresParseAsProviderFailures() throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "quota-failure",
            withExtension: "jsonl",
            subdirectory: "ProviderStreams/copilot"
        ))
        let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let events = lines.flatMap(CopilotStreamEventParser.parseAgentEvents(line:))
        let failures = events.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        let processFailures = lines.flatMap(CopilotStreamEventParser.parseAll(line:)).compactMap { event -> String? in
            if case .result(let text, _, _, _, _, _, let isError) = event, isError {
                return text
            }
            return nil
        }

        #expect(failures.count == 7)
        #expect(failures.filter { $0.contains("HTTP 402") }.count == 6)
        #expect(failures.allSatisfy { $0.localizedCaseInsensitiveContains("quota") })
        #expect(processFailures == failures)
    }

    @Test("Model call bookends are control metadata, not unknown provider shapes", arguments: ["model.call_start", "model.call_finished"])
    func modelCallBookendsAreControlMetadata(type: String) throws {
        let line = try jsonLine([
            "type": type,
            "data": ["turnId": "0"],
            "ephemeral": true
        ])

        let agentEvents = CopilotStreamEventParser.parseAgentEvents(line: line)
        #expect(agentEvents.count == 1)
        if case .control(let parsed) = agentEvents.first {
            #expect(parsed == type)
        } else {
            Issue.record("Expected \(type) to parse as control metadata")
        }

        let telemetry = AgentRuntimeStreamTelemetry()
        telemetry.recordParsed(agentEvents)
        #expect(telemetry.snapshot().unknownEventCount == 0)
    }

    @Test("Assistant idle remains transient", arguments: [false, true])
    func assistantIdleRemainsTransient(aborted: Bool) throws {
        let line = try jsonLine([
            "type": "assistant.idle",
            "data": aborted ? ["aborted": true] : [:],
            "ephemeral": true
        ])

        let agentEvents = CopilotStreamEventParser.parseAgentEvents(line: line)
        #expect(agentEvents.count == 1)
        if case .control(let type) = agentEvents.first {
            #expect(type == "assistant.idle")
        } else {
            Issue.record("Expected assistant.idle to remain transient control metadata")
        }

        let telemetry = AgentRuntimeStreamTelemetry()
        telemetry.recordParsed(agentEvents)
        #expect(telemetry.snapshot().unknownEventCount == 0)

        let processEvents = CopilotStreamEventParser.parseAll(line: line)
        #expect(processEvents.count == 1)
        let processEvent = try #require(processEvents.first)
        if case .control(let type) = processEvent {
            #expect(type == "assistant.idle")
        } else {
            Issue.record("Expected parsed assistant.idle control metadata")
        }

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        #expect(monitor.processEvent(processEvent, process: nil) == false)
        #expect(monitor.estimatedTokens == 0)
        #expect(monitor.turnCount == 0)
    }

    @Test("Ephemeral tool progress stays transient until final completion")
    func ephemeralToolProgressStaysTransientUntilFinalCompletion() throws {
        let toolCallID = "toolu_long_poll"
        let lines = try [
            jsonLine([
                "type": "tool.execution_start",
                "data": [
                    "toolCallId": toolCallID,
                    "toolName": "bash",
                    "arguments": ["command": "run-long-poll"]
                ]
            ]),
            jsonLine([
                "type": "tool.execution_partial_result",
                "ephemeral": true,
                "data": [
                    "toolCallId": toolCallID,
                    "partialOutput": "first chunk"
                ]
            ]),
            jsonLine([
                "type": "tool.execution_progress",
                "ephemeral": true,
                "data": [
                    "toolCallId": toolCallID,
                    "progressMessage": "still running"
                ]
            ]),
            jsonLine([
                "type": "tool.execution_partial_result",
                "ephemeral": true,
                "data": [
                    "toolCallId": toolCallID,
                    "partialOutput": "second chunk"
                ]
            ]),
            jsonLine([
                "type": "tool.execution_complete",
                "data": [
                    "toolCallId": toolCallID,
                    "success": true,
                    "result": ["content": "final output"]
                ]
            ])
        ]

        let agentEvents = lines.flatMap(CopilotStreamEventParser.parseAgentEvents(line:))
        #expect(agentEvents.filter(Self.isToolUse).count == 1)
        #expect(agentEvents.filter(Self.isToolResult).count == 1)
        #expect(agentEvents.filter(Self.isControl).count == 3)

        let processEvents = lines.flatMap(CopilotStreamEventParser.parseAll(line:))
        #expect(processEvents.filter(Self.isParsedToolUse).count == 1)
        #expect(processEvents.filter(Self.isParsedToolResult).count == 1)
        #expect(processEvents.filter(Self.isParsedControl).count == 3)

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for event in processEvents {
            #expect(monitor.processEvent(event, process: nil) == false)
        }
        #expect(monitor.estimatedTokens == 300)
    }

    @Test("Streamed tool arguments produce one action without tripping repetition")
    func streamedToolArgumentsProduceOneAction() throws {
        let toolCallID = "toolu_create_report"
        let deltas = [
            #"{"path":"#,
            "/Users/alvaro1/Documents/AgentFlow/Workspaces/jsl/",
            ".astra/tasks/3A7C4EC4/",
            "report.md",
            #"","file_text":"#,
            "# Jira report\\n",
            "29 open issues",
            #""}"#
        ]
        let deltaLines = try deltas.enumerated().map { index, delta in
            try jsonLine([
                "type": "assistant.tool_call_delta",
                "data": [
                    "toolCallId": toolCallID,
                    "toolName": "create",
                    "inputDelta": delta
                ],
                "id": "delta-\(index)"
            ])
        }
        let toolEnvelopeLine = try jsonLine([
            "type": "assistant.message",
            "data": [
                "content": "",
                "toolRequests": [[
                    "toolCallId": toolCallID,
                    "name": "create",
                    "arguments": ["path": "/Users/alvaro1/Documents/AgentFlow/Workspaces/jsl/.astra/tasks/3A7C4EC4/report.md"]
                ]]
            ]
        ])
        let textToolEnvelopeLine = try jsonLine([
            "type": "assistant.message",
            "data": [
                "content": "Preparing the Jira report.",
                "toolRequests": [[
                    "toolCallId": toolCallID,
                    "name": "create",
                    "arguments": ["path": "/Users/alvaro1/Documents/AgentFlow/Workspaces/jsl/.astra/tasks/3A7C4EC4/report.md"]
                ]]
            ]
        ])
        let executionStartLine = try jsonLine([
            "type": "tool.execution_start",
            "data": [
                "toolCallId": toolCallID,
                "toolName": "create",
                "arguments": [
                    "path": "/Users/alvaro1/Documents/AgentFlow/Workspaces/jsl/.astra/tasks/3A7C4EC4/report.md",
                    "file_text": "# Jira report\n29 open issues"
                ]
            ]
        ])
        let executionCompleteLine = try jsonLine([
            "type": "tool.execution_complete",
            "data": [
                "toolCallId": toolCallID,
                "success": true,
                "result": ["content": "Created report.md"]
            ]
        ])

        for line in deltaLines {
            let events = CopilotStreamEventParser.parseAll(line: line)
            #expect(events.count == 1)
            #expect(events.allSatisfy(Self.isParsedControl))
        }
        let toolEnvelopeEvents = CopilotStreamEventParser.parseAll(line: toolEnvelopeLine)
        #expect(toolEnvelopeEvents.count == 1)
        #expect(toolEnvelopeEvents.allSatisfy(Self.isParsedControl))

        let textEnvelopeEvents = CopilotStreamEventParser.parseAll(line: textToolEnvelopeLine)
        #expect(textEnvelopeEvents.count == 1)
        if case .text(let text) = textEnvelopeEvents.first {
            #expect(text == "Preparing the Jira report.")
        } else {
            Issue.record("Expected tool-request message content to remain nonterminal text")
        }
        let envelopeMonitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for event in textEnvelopeEvents {
            #expect(envelopeMonitor.processEvent(event, process: nil) == false)
        }
        #expect(envelopeMonitor.turnCount == 0)

        let startEvents = CopilotStreamEventParser.parseAll(line: executionStartLine)
        #expect(startEvents.count == 1)
        let startIsToolUse: Bool
        if case .toolUse = startEvents.first {
            startIsToolUse = true
        } else {
            startIsToolUse = false
        }
        #expect(startIsToolUse)

        let completeEvents = CopilotStreamEventParser.parseAll(line: executionCompleteLine)
        #expect(completeEvents.count == 1)
        let completionIsToolResult: Bool
        if case .toolResult = completeEvents.first {
            completionIsToolResult = true
        } else {
            completionIsToolResult = false
        }
        #expect(completionIsToolResult)

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        var toolUseCount = 0
        var toolResultCount = 0
        for line in deltaLines + [toolEnvelopeLine, executionStartLine, executionCompleteLine] {
            for event in CopilotStreamEventParser.parseAll(line: line) {
                if case .toolUse = event {
                    toolUseCount += 1
                }
                if case .toolResult = event {
                    toolResultCount += 1
                }
                #expect(monitor.processEvent(event, process: nil) == false)
            }
        }

        #expect(toolUseCount == 1)
        #expect(toolResultCount == 1)
        #expect(monitor.repetitionKilled == false)
    }

    @Test("A parallel batch of distinct edits to one file is not a repetition loop")
    func parallelEditsToOneFileDoNotTripRepetition() throws {
        // One assistant message asked for nine different edits to the same
        // file (task 5C892B2E, 2026-10-02). Copilot starts them together and
        // each answers "File <path> updated with changes.", so the monitor
        // saw nine identical-looking starts, then nine identical results.
        let path = "/Users/alvaro1/Documents/Astra/Workspaces/starrdocs/.astra/tasks/5C892B2E/plan.md"
        let ids = (1...9).map { "toolu_edit_\($0)" }
        let startLines = try ids.enumerated().map { index, id in
            try jsonLine([
                "type": "tool.execution_start",
                "data": [
                    "toolCallId": id,
                    "toolName": "edit",
                    "arguments": [
                        "path": path,
                        "old_str": "section \(index) before",
                        "new_str": "section \(index) after, rewritten"
                    ]
                ]
            ])
        }
        let completeLines = try ids.map { id in
            try jsonLine([
                "type": "tool.execution_complete",
                "data": [
                    "toolCallId": id,
                    "success": true,
                    "result": ["content": "File \(path) updated with changes."]
                ]
            ])
        }

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        var toolUseCount = 0
        var toolResultCount = 0
        for line in startLines + completeLines {
            for event in CopilotStreamEventParser.parseAll(line: line) {
                if case .toolUse = event { toolUseCount += 1 }
                if case .toolResult = event { toolResultCount += 1 }
                #expect(monitor.processEvent(event, process: nil) == false)
            }
        }

        #expect(toolUseCount == 9)
        #expect(toolResultCount == 9)
        #expect(monitor.repetitionKilled == false)
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func isToolUse(_ event: AgentEvent) -> Bool {
        if case .toolUse = event { return true }
        return false
    }

    private static func isToolResult(_ event: AgentEvent) -> Bool {
        if case .toolResult = event { return true }
        return false
    }

    private static func isControl(_ event: AgentEvent) -> Bool {
        if case .control = event { return true }
        return false
    }

    private static func isParsedToolUse(_ event: ParsedEvent) -> Bool {
        if case .toolUse = event { return true }
        return false
    }

    private static func isParsedToolResult(_ event: ParsedEvent) -> Bool {
        if case .toolResult = event { return true }
        return false
    }

    private static func isParsedControl(_ event: ParsedEvent) -> Bool {
        if case .control = event { return true }
        return false
    }
}
