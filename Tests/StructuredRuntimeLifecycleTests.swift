import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

private func makeStructuredRuntimeLifecycleContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [configuration]
    )
}

@Suite("Structured runtime lifecycle parsing")
struct StructuredRuntimeLifecycleTests {
    @Test("Known lifecycle frames are transient controls across structured runtimes")
    func knownLifecycleFramesAreTransientControls() {
        let claudeLine = #"{"type":"system","subtype":"status","status":"requesting","uuid":"74b4705c-e0ac-45f0-9693-26d184a40c32","session_id":"f6c2c835-49a4-4141-9bfd-68f07f4ebcc7"}"#
        let cursorLine = #"{"type":"stream_event","event":{"type":"message_stop"}}"#
        let fixtures: [(name: String, line: String, parsed: [ParsedEvent], agent: [AgentEvent])] = [
            (
                "copilot",
                #"{"type":"assistant.turn_end","data":{},"ephemeral":true}"#,
                CopilotStreamEventParser.parseAll(line: #"{"type":"assistant.turn_end","data":{},"ephemeral":true}"#),
                CopilotStreamEventParser.parseAgentEvents(line: #"{"type":"assistant.turn_end","data":{},"ephemeral":true}"#)
            ),
            (
                "codex",
                #"{"type":"turn.completed"}"#,
                CodexStreamEventParser.parseAll(line: #"{"type":"turn.completed"}"#),
                CodexStreamEventParser.parseAgentEvents(line: #"{"type":"turn.completed"}"#)
            ),
            (
                "claude",
                claudeLine,
                StreamEventParser.parseAll(line: claudeLine),
                StreamEventParser.parseAll(line: claudeLine).flatMap(AgentEventRecorder.agentEvents(from:))
            ),
            (
                "cursor",
                cursorLine,
                CursorStreamEventParser.parseAll(line: cursorLine),
                CursorStreamEventParser.parseAgentEvents(line: cursorLine)
            ),
            (
                "opencode",
                #"{"type":"session.status","status":"idle"}"#,
                OpenCodeStreamEventParser.parseAll(line: #"{"type":"session.status","status":"idle"}"#),
                OpenCodeStreamEventParser.parseAgentEvents(line: #"{"type":"session.status","status":"idle"}"#)
            )
        ]

        for fixture in fixtures {
            #expect(fixture.parsed.count == 1, "\(fixture.name) should emit one parsed lifecycle control")
            #expect(fixture.agent.count == 1, "\(fixture.name) should emit one agent lifecycle control")
            #expect(fixture.parsed.allSatisfy(Self.isParsedControl))
            #expect(fixture.agent.allSatisfy(Self.isAgentControl))

            let telemetry = AgentRuntimeStreamTelemetry()
            telemetry.recordRawLine(parsesJSONLines: true)
            telemetry.recordParsed(fixture.agent)
            #expect(telemetry.snapshot().unknownEventCount == 0)

            let capture = AgentRuntimeStreamDebugCapture()
            capture.recordLine(fixture.line, parsesJSONLines: true)
            capture.recordParsed(fixture.agent, rawLine: fixture.line)
            #expect(capture.snapshot().unknownJSONShapes.isEmpty)

            let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max)
            for event in fixture.parsed {
                #expect(AgentRuntimeWorker.ProcessMonitor.progressKind(for: event) == .providerLiveness)
                #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(event) == nil)
                #expect(monitor.processEvent(event, process: nil) == false)
            }
            #expect(monitor.estimatedTokens == 0)
            #expect(monitor.turnCount == 0)
        }
    }

    @MainActor
    @Test("Claude status frames do not establish a session or durable start")
    func claudeStatusDoesNotEstablishSessionOrStart() throws {
        let line = #"{"type":"system","subtype":"status","status":"requesting","uuid":"74b4705c-e0ac-45f0-9693-26d184a40c32","session_id":"f6c2c835-49a4-4141-9bfd-68f07f4ebcc7"}"#
        let container = try makeStructuredRuntimeLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Status", goal: "Keep provider status transient")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let events = StreamEventParser.parseAll(line: line)
            .flatMap(AgentEventRecorder.agentEvents(from:))
        #expect(events.count == 1)
        #expect(events.allSatisfy(Self.isAgentControl))
        for event in events {
            AgentEventRecorder.recordClaudeEvent(
                event,
                to: task,
                run: run,
                modelContext: context,
                recordingState: AgentEventRecordingState()
            )
        }

        #expect(task.sessionId == nil)
        #expect(run.providerSessionId == nil)
        #expect(task.events.isEmpty)
    }

    @Test("Valid structured JSON never falls back to transcript text")
    func structuredJSONNeverFallsBackToTranscriptText() {
        let missingType = #"{"status":"idle"}"#
        let unknownType = #"{"type":"provider.future_event"}"#
        let claudeEvents = StreamEventParser.parseAll(line: missingType)
            .flatMap(AgentEventRecorder.agentEvents(from:))
        let fixtures: [(name: String, events: [AgentEvent])] = [
            ("copilot", CopilotStreamEventParser.parseAgentEvents(line: missingType)),
            ("codex", CodexStreamEventParser.parseAgentEvents(line: unknownType)),
            ("claude", claudeEvents),
            ("cursor", CursorStreamEventParser.parseAgentEvents(line: missingType)),
            ("opencode", OpenCodeStreamEventParser.parseAgentEvents(line: missingType))
        ]

        for fixture in fixtures {
            #expect(fixture.events.count == 1, "\(fixture.name) should preserve one unknown structured event")
            #expect(fixture.events.allSatisfy(Self.isUnknown))
            #expect(!fixture.events.contains(where: Self.isText))
        }

        let nonObjectJSON = "[]"
        let nonObjectFixtures: [(name: String, events: [AgentEvent])] = [
            ("copilot", CopilotStreamEventParser.parseAgentEvents(line: nonObjectJSON)),
            ("codex", CodexStreamEventParser.parseAgentEvents(line: nonObjectJSON)),
            (
                "claude",
                StreamEventParser.parseAll(line: nonObjectJSON)
                    .flatMap(AgentEventRecorder.agentEvents(from:))
            ),
            ("cursor", CursorStreamEventParser.parseAgentEvents(line: nonObjectJSON)),
            ("opencode", OpenCodeStreamEventParser.parseAgentEvents(line: nonObjectJSON))
        ]
        for fixture in nonObjectFixtures {
            #expect(fixture.events.count == 1, "\(fixture.name) should not render JSON arrays as text")
            #expect(fixture.events.allSatisfy(Self.isUnknown))
            #expect(!fixture.events.contains(where: Self.isText))
        }
    }

    @Test("Malformed known shapes remain unknown instead of lifecycle or text")
    func malformedKnownShapesRemainUnknown() {
        let malformedClaude = #"{"type":"stream_event"}"#
        let fixtures: [(name: String, events: [AgentEvent])] = [
            ("copilot", CopilotStreamEventParser.parseAgentEvents(line: #"{"type":"agent_message_chunk"}"#)),
            ("codex", CodexStreamEventParser.parseAgentEvents(line: #"{"type":"item.started"}"#)),
            (
                "claude",
                StreamEventParser.parseAll(line: malformedClaude)
                    .flatMap(AgentEventRecorder.agentEvents(from:))
            ),
            ("cursor", CursorStreamEventParser.parseAgentEvents(line: #"{"type":"thinking"}"#)),
            ("opencode", OpenCodeStreamEventParser.parseAgentEvents(line: #"{"type":"text"}"#))
        ]

        for fixture in fixtures {
            #expect(fixture.events.count == 1, "\(fixture.name) should expose one malformed event")
            #expect(fixture.events.allSatisfy(Self.isUnknown))
            #expect(!fixture.events.contains(where: Self.isText))
            #expect(!fixture.events.contains(where: Self.isAgentControl))
        }
    }

    @MainActor
    @Test("Lifecycle controls never enter durable task history for any runtime")
    func lifecycleControlsNeverPersist() throws {
        let container = try makeStructuredRuntimeLifecycleContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Lifecycle", goal: "Keep provider metadata transient")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        let control = AgentEvent.control(type: "provider.lifecycle")

        AgentEventRecorder.recordClaudeEvent(control, to: task, run: run, modelContext: context)
        AgentEventRecorder.recordCopilotEvent(control, to: task, run: run, modelContext: context)
        AgentEventRecorder.recordAntigravityEvent(control, to: task, run: run, modelContext: context)
        AgentEventRecorder.recordCodexEvent(control, to: task, run: run, modelContext: context)
        AgentEventRecorder.recordCursorEvent(control, to: task, run: run, modelContext: context)
        AgentEventRecorder.recordOpenCodeEvent(control, to: task, run: run, modelContext: context)

        #expect(task.events.isEmpty)
        #expect(run.output.isEmpty)
        #expect(run.tokensUsed == 0)
    }

    private static func isParsedControl(_ event: ParsedEvent) -> Bool {
        if case .control = event { return true }
        return false
    }

    private static func isAgentControl(_ event: AgentEvent) -> Bool {
        if case .control = event { return true }
        return false
    }

    private static func isUnknown(_ event: AgentEvent) -> Bool {
        if case .unknown = event { return true }
        return false
    }

    private static func isText(_ event: AgentEvent) -> Bool {
        if case .text = event { return true }
        return false
    }
}
