import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot Stream Regressions")
struct CopilotStreamRegressionTests {
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
            #expect(CopilotStreamEventParser.parseAll(line: line).isEmpty)
        }
        #expect(CopilotStreamEventParser.parseAll(line: toolEnvelopeLine).isEmpty)

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

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }
}
