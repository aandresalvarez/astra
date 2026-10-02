import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Repetition signature for path-only file tools")
struct RepetitionSignatureTests {
    @Test("Distinct file-tool calls with the same path summary are not a repetition")
    func distinctToolCallsWithTheSameSummaryAreNotRepeats() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        // A provider that keeps only a path for an edit gives every edit to one
        // file the same input; the call ids are what tell them apart.
        for index in 1...6 {
            let shouldKill = monitor.processEvent(
                .toolUse(name: "edit", id: "call_\(index)", input: ["summary": "/tmp/plan.md"]),
                process: nil
            )
            #expect(shouldKill == false)
        }
        for index in 1...6 {
            let shouldKill = monitor.processEvent(
                .toolResult(toolId: "call_\(index)", content: "File /tmp/plan.md updated with changes."),
                process: nil
            )
            #expect(shouldKill == false)
        }

        #expect(monitor.repetitionKilled == false)
    }

    @Test("A command repeated under fresh ids is still a repetition when only its summary is kept")
    func repeatedCommandUnderFreshIDsStillRepeats() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for index in 1...2 {
            #expect(monitor.processEvent(.toolUse(name: "bash", id: "call_\(index)", input: ["summary": "pwd"]), process: nil) == false)
        }
        #expect(monitor.processEvent(.toolUse(name: "bash", id: "call_3", input: ["summary": "pwd"]), process: nil) == true)
        #expect(monitor.repetitionKilled == true)
    }

    @Test("The same file-tool call and result repeated under one id still trip the breaker")
    func sameIDToolEventsStillRepeat() {
        let use = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for _ in 1...2 {
            #expect(use.processEvent(.toolUse(name: "edit", id: "call_1", input: ["summary": "/tmp/plan.md"]), process: nil) == false)
        }
        #expect(use.processEvent(.toolUse(name: "edit", id: "call_1", input: ["summary": "/tmp/plan.md"]), process: nil) == true)
        #expect(use.repetitionKilled == true)

        let result = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for _ in 1...2 {
            #expect(result.processEvent(.toolResult(toolId: "call_1", content: "same output"), process: nil) == false)
        }
        #expect(result.processEvent(.toolResult(toolId: "call_1", content: "same output"), process: nil) == true)
        #expect(result.repetitionKilled == true)

    }

    // MARK: - Results carry their call id

    @Test("Identical result text from different calls is not a repetition, whatever the tool")
    func identicalResultTextFromDifferentCallsIsNotARepeat() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for index in 1...6 {
            #expect(monitor.processEvent(.toolUse(name: "Grep", id: "call_\(index)", input: ["pattern": "term\(index)"]), process: nil) == false)
        }
        for index in 1...6 {
            #expect(monitor.processEvent(.toolResult(toolId: "call_\(index)", content: "No matches found"), process: nil) == false)
        }
        #expect(monitor.repetitionKilled == false)
    }

    // MARK: - Calls carry a fingerprint of their whole input

    @Test("Commands that differ only after the readable prefix are not a repetition")
    func commandsDifferingPastThePrefixAreNotARepeat() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        let base = "cd /Users/alvaro1/Documents/Astra/Workspaces/starrdocs/.astra/tasks/5C892B2E && python3 scripts/check.py --case "

        for index in 1...6 {
            #expect(monitor.processEvent(.toolUse(name: "Bash", id: "call_\(index)", input: ["command": base + "\(index)"]), process: nil) == false)
        }
        // The same long command under fresh ids is still a loop.
        let repeated = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for index in 1...2 {
            #expect(repeated.processEvent(.toolUse(name: "Bash", id: "call_\(index)", input: ["command": base + "1"]), process: nil) == false)
        }
        #expect(repeated.processEvent(.toolUse(name: "Bash", id: "call_3", input: ["command": base + "1"]), process: nil) == true)
        #expect(monitor.repetitionKilled == false)
    }

    @Test("A provider-supplied fingerprint separates edits and still joins identical ones")
    func suppliedFingerprintSeparatesEditsAndJoinsIdenticalOnes() {
        let key = ToolInputFingerprint.key
        let different = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for index in 1...6 {
            let input: [String: Any] = ["summary": "/tmp/plan.md", key: "fingerprint-\(index)"]
            #expect(different.processEvent(.toolUse(name: "edit", id: "call_\(index)", input: input), process: nil) == false)
        }
        #expect(different.repetitionKilled == false)

        // Genuinely identical calls repeat even though every call has its own id.
        let identical = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        let same: [String: Any] = ["summary": "/tmp/plan.md", key: "same-fingerprint"]
        for index in 1...2 {
            #expect(identical.processEvent(.toolUse(name: "edit", id: "call_\(index)", input: same), process: nil) == false)
        }
        #expect(identical.processEvent(.toolUse(name: "edit", id: "call_3", input: same), process: nil) == true)
        #expect(identical.repetitionKilled == true)
    }

    @Test("The fingerprint is stable, ignores key order, and sees every character")
    func fingerprintIsStableAndSensitive() {
        let long = String(repeating: "x", count: 500)
        #expect(ToolInputFingerprint.of(["a": long, "b": 1]) == ToolInputFingerprint.of(["b": 1, "a": long]))
        #expect(ToolInputFingerprint.of(["a": long + "1"]) != ToolInputFingerprint.of(["a": long + "2"]))
        #expect(ToolInputFingerprint.of(["a": ["x", "y"]]) != ToolInputFingerprint.of(["a": ["y", "x"]]))
        #expect(ToolInputFingerprint.of(nil) == ToolInputFingerprint.of(nil))
        #expect(ToolInputFingerprint.of(["a": "bc"]) != ToolInputFingerprint.of(["ab": "c"]))
    }

    @Test("A JSON boolean is not the number it would print as")
    func fingerprintSeparatesBooleansFromNumbers() throws {
        func parsed(_ json: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(json.utf8))
        }
        #expect(try ToolInputFingerprint.of(parsed(#"{"force":true}"#)) != ToolInputFingerprint.of(parsed(#"{"force":1}"#)))
        #expect(try ToolInputFingerprint.of(parsed(#"{"force":false}"#)) != ToolInputFingerprint.of(parsed(#"{"force":0}"#)))
        #expect(try ToolInputFingerprint.of(parsed(#"{"force":true}"#)) == ToolInputFingerprint.of(parsed(#"{"force":true}"#)))
        #expect(ToolInputFingerprint.of(["force": true]) != ToolInputFingerprint.of(["force": 1]))
    }

    @Test("Policy does not see the fingerprint as an input key the provider sent")
    func policyIgnoresTheFingerprintKey() throws {
        let plain = try #require(PolicyObservedEvent(providerEvent: .toolUse(
            name: "edit", id: "t1", input: ["summary": "/tmp/plan.md"]
        )))
        let fingerprinted = try #require(PolicyObservedEvent(providerEvent: .toolUse(
            name: "edit", id: "t1", input: ["summary": "/tmp/plan.md", ToolInputFingerprint.key: "abc123"]
        )))
        #expect(fingerprinted.inputKeys == plain.inputKeys)
        #expect(fingerprinted.path == plain.path)
    }

    // MARK: - Provider parsers

    private func line(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func copilotStart(id: String, tool: String, arguments: [String: Any]) throws -> String {
        try line(["type": "tool.execution_start", "data": ["toolCallId": id, "toolName": tool, "arguments": arguments]])
    }

    @Test("Copilot attaches a fingerprint of the raw arguments to a tool call")
    func copilotAttachesAFingerprint() throws {
        let path = "/w/plan.md"
        func fingerprint(_ arguments: [String: Any]) throws -> String? {
            let event = try #require(CopilotStreamEventParser.parseAll(line: try copilotStart(id: "a", tool: "edit", arguments: arguments)).first)
            guard case .toolUse(_, _, let input) = event else { return nil }
            return input?[ToolInputFingerprint.key] as? String
        }
        let one = try fingerprint(["path": path, "old_str": "a", "new_str": "b"])
        let again = try fingerprint(["path": path, "old_str": "a", "new_str": "b"])
        let other = try fingerprint(["path": path, "old_str": "a", "new_str": "c"])
        #expect(one != nil)
        #expect(one == again)
        #expect(one != other)
    }

    @Test("Copilot: nine identical file calls still stop the run, nine different ones do not")
    func copilotIdenticalCallsStillRepeat() throws {
        let identical = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for index in 1...9 {
            let start = try copilotStart(id: "call_\(index)", tool: "view", arguments: ["path": "/w/plan.md"])
            for event in CopilotStreamEventParser.parseAll(line: start) { _ = identical.processEvent(event, process: nil) }
        }
        #expect(identical.repetitionKilled == true)

        let different = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for index in 1...9 {
            let start = try copilotStart(id: "call_\(index)", tool: "view", arguments: ["path": "/w/plan.md", "view_range": [index, index + 10]])
            for event in CopilotStreamEventParser.parseAll(line: start) {
                #expect(different.processEvent(event, process: nil) == false)
            }
        }
        #expect(different.repetitionKilled == false)
    }

    @Test("Cursor: edits that differ only in the dropped file body are different calls")
    func cursorEditsDifferingInTheirBodyAreDifferentCalls() throws {
        func frames(body: (Int) -> String) throws -> [String] {
            try (1...9).map { index in
                try line([
                    "type": "tool_call", "subtype": "started", "call_id": "call_\(index)",
                    "tool_call": ["editToolCall": ["args": ["path": "/w/answer.md", "streamContent": body(index)]]]
                ])
            }
        }
        let different = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for frame in try frames(body: { "rewritten section \($0)" }) {
            for event in CursorStreamEventParser.parseAll(line: frame) {
                #expect(different.processEvent(event, process: nil) == false)
            }
        }
        #expect(different.repetitionKilled == false)

        let identical = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
        for frame in try frames(body: { _ in "the same body" }) {
            for event in CursorStreamEventParser.parseAll(line: frame) { _ = identical.processEvent(event, process: nil) }
        }
        #expect(identical.repetitionKilled == true)
    }

    // MARK: - Provider-sent arguments named like the fingerprint key

    private func fingerprintKeyInput(_ event: ParsedEvent?) -> Any? {
        guard case .toolUse(_, _, let input)? = event else { return nil }
        return input?[ToolInputFingerprint.key]
    }

    @Test("Claude replaces a provider argument named like the fingerprint key")
    func claudeReplacesAProviderArgumentNamedLikeTheKey() {
        let line = #"{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"m1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","astra_args_fingerprint":"forged"}}]}}"#
        let event = StreamEventParser.parse(line: line)
        guard case .toolUse(_, _, let input)? = event else {
            Issue.record("Expected a tool use")
            return
        }
        #expect(input?["command"] as? String == "ls")
        #expect(fingerprintKeyInput(event) as? String != nil)
        #expect(fingerprintKeyInput(event) as? String != "forged")
    }

    @Test("OpenCode replaces a provider argument named like the fingerprint key")
    func openCodeReplacesAProviderArgumentNamedLikeTheKey() {
        let line = #"{"type":"tool_use","part":{"id":"c1","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"ls","astra_args_fingerprint":"forged"}}}}"#
        let event = OpenCodeStreamEventParser.parse(line: line)
        guard case .toolUse(_, _, let input)? = event else {
            Issue.record("Expected a tool use")
            return
        }
        #expect(input?["command"] as? String == "ls")
        #expect(fingerprintKeyInput(event) as? String != nil)
        #expect(fingerprintKeyInput(event) as? String != "forged")
    }

    @Test("Cursor replaces a provider argument named like the key with the real fingerprint")
    func cursorReplacesAProviderArgumentNamedLikeTheKey() throws {
        func fingerprint(_ forged: String, body: String) throws -> String? {
            let frame = try line([
                "type": "tool_call", "subtype": "started", "call_id": "c1",
                "tool_call": ["editToolCall": ["args": [
                    "path": "/w/a.md", "streamContent": body, ToolInputFingerprint.key: forged
                ]]]
            ])
            return fingerprintKeyInput(CursorStreamEventParser.parseAll(line: frame).first) as? String
        }
        let first = try fingerprint("forged-1", body: "one")
        // The forged value is never the fingerprint, and calls that differ only
        // in the body still differ.
        #expect(first != nil)
        #expect(first != "forged-1")
        #expect(first != (try fingerprint("forged-1", body: "two")))
    }

    @Test("A forged fingerprint cannot group calls that differ past the readable prefix")
    func forgedFingerprintCannotGroupDifferentCalls() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        let base = String(repeating: "x", count: 120)
        for index in 1...6 {
            let line = #"{"type":"tool_use","part":{"id":"c\#(index)","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"\#(base)\#(index)","astra_args_fingerprint":"forged"}}}}"#
            let event = OpenCodeStreamEventParser.parse(line: line)
            #expect(event.map { monitor.processEvent($0, process: nil) } == false)
        }
        #expect(monitor.repetitionKilled == false)
    }

    @Test("Calls that differ only in a provider argument named like the key stay different")
    func callsDifferingOnlyInTheReservedArgumentStayDifferent() {
        func fingerprint(_ value: String) -> String? {
            let line = #"{"type":"tool_use","part":{"id":"c1","type":"tool","tool":"custom","state":{"status":"running","input":{"astra_args_fingerprint":"\#(value)"}}}}"#
            return fingerprintKeyInput(OpenCodeStreamEventParser.parse(line: line)) as? String
        }
        #expect(fingerprint("A") != nil)
        #expect(fingerprint("A") != fingerprint("B"))
        #expect(fingerprint("A") == fingerprint("A"))

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for value in ["A", "B", "C", "D", "E"] {
            let line = #"{"type":"tool_use","part":{"id":"c\#(value)","type":"tool","tool":"custom","state":{"status":"running","input":{"astra_args_fingerprint":"\#(value)"}}}}"#
            let event = OpenCodeStreamEventParser.parse(line: line)
            #expect(event.map { monitor.processEvent($0, process: nil) } == false)
        }
        #expect(monitor.repetitionKilled == false)
    }

    @Test("A provider-sent argument named like the key stays visible to policy under its own name")
    func policyStillSeesAProviderSentArgumentNamedLikeTheKey() throws {
        let line = #"{"type":"tool_use","part":{"id":"c1","type":"tool","tool":"custom","state":{"status":"running","input":{"astra_args_fingerprint":"forged","path":"/w/a.md"}}}}"#
        let event = try #require(OpenCodeStreamEventParser.parse(line: line))
        guard case .toolUse(_, _, let input) = event else {
            Issue.record("Expected a tool use")
            return
        }
        // The provider's value is kept, apart from the real fingerprint.
        #expect(input?[ToolInputFingerprint.providerValueKey] as? String == "forged")
        #expect(input?[ToolInputFingerprint.key] as? String != "forged")

        let observed = try #require(PolicyObservedEvent(providerEvent: event))
        // Policy hides ASTRA's key but still validates the provider-supplied one.
        #expect(!observed.inputKeys.contains(ToolInputFingerprint.key))
        #expect(observed.inputKeys.contains(ToolInputFingerprint.providerValueKey))
    }

    @Test("Cursor keeps a provider-sent argument named like the key apart from the fingerprint")
    func cursorKeepsAProviderSentArgumentApart() throws {
        let frame = try line([
            "type": "tool_call", "subtype": "started", "call_id": "c1",
            "tool_call": ["editToolCall": ["args": ["path": "/w/a.md", ToolInputFingerprint.key: "forged"]]]
        ])
        let event = try #require(CursorStreamEventParser.parseAll(line: frame).first)
        guard case .toolUse(_, _, let input) = event else {
            Issue.record("Expected a tool use")
            return
        }
        #expect(input?[ToolInputFingerprint.providerValueKey] as? String == "forged")
        #expect(input?[ToolInputFingerprint.key] as? String != "forged")
    }
}
