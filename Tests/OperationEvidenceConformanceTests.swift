import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Issue #477, for all six runtimes: an operation's identity and outcome must
/// survive the whole path a worker drives for every stream line —
/// adapter → event pipeline → recorder → stored events → a fresh context's
/// snapshot → the activity presentation.
///
/// The streams here are synthetic, written in each provider's documented
/// frame shapes (the same shapes the captured fixtures under
/// `Tests/Fixtures/ProviderStreams` and the parser tests use), because no
/// captured stream contains a failing tool call and there is no OpenCode
/// capture at all. They prove ASTRA's handling of those shapes; they are not
/// evidence of what a live CLI emits. No process is launched.
@Suite("Operation evidence conformance", .serialized)
@MainActor
struct OperationEvidenceConformanceTests {
    struct Stream: Sendable, CustomTestStringConvertible {
        let provider: String
        let runtime: AgentRuntimeID
        let lines: [String]
        /// Distinct calls in the stream, however many frames each took.
        let calls: Int
        /// Whether one of the calls ends with no output at all.
        let hasSilentCompletion: Bool
        var hasBackgroundJob = false
        /// The exit code the provider reports for the failing call, if any.
        var failureExitCode: Int?

        var testDescription: String { provider }
    }

    static let streams: [Stream] = [
        Stream(
            provider: "claude",
            runtime: .claudeCode,
            lines: [
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_fail","name":"Bash","input":{"command":"swift test"}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fail","content":"1 test failed","is_error":true}]}}"#,
                #"{"type":"assistant","message":{"id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_quiet","name":"Bash","input":{"command":"true"}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_quiet","content":"","is_error":false}]}}"#
            ],
            calls: 2,
            hasSilentCompletion: true
        ),
        Stream(
            provider: "copilot",
            runtime: .copilotCLI,
            lines: [
                #"{"type":"tool.execution_start","data":{"toolCallId":"call_fail","toolName":"bash","arguments":{"command":"swift test"}}}"#,
                #"{"type":"tool.execution_partial_result","data":{"toolCallId":"call_fail","partialOutput":"test 7 passed"}}"#,
                #"{"type":"tool.execution_complete","data":{"toolCallId":"call_fail","success":false,"error":{"message":"1 test failed"}}}"#,
                #"{"type":"system.notification","data":{"content":"<system_notification>Shell completed</system_notification>","kind":{"type":"shell_completed","shellId":"job-1","exitCode":1}}}"#
            ],
            calls: 1,
            hasSilentCompletion: false,
            hasBackgroundJob: true
        ),
        Stream(
            provider: "codex",
            runtime: .codexCLI,
            lines: [
                #"{"type":"item.started","item":{"id":"cmd_fail","type":"command_execution","command":"swift test","status":"in_progress"}}"#,
                #"{"type":"item.completed","item":{"id":"cmd_fail","type":"command_execution","command":"swift test","exit_code":1,"status":"failed","aggregated_output":"1 test failed"}}"#
            ],
            calls: 1,
            hasSilentCompletion: false,
            failureExitCode: 1
        ),
        Stream(
            provider: "cursor",
            runtime: .cursorCLI,
            lines: [
                #"{"type":"tool_call","subtype":"started","call_id":"tool_fail","tool_call":{"shellToolCall":{"args":{"command":"swift test"}}}}"#,
                #"{"type":"tool_call","subtype":"completed","call_id":"tool_fail","tool_call":{"shellToolCall":{"args":{"command":"swift test"},"result":{"failure":"1 test failed"}}}}"#
            ],
            calls: 1,
            hasSilentCompletion: false
        ),
        Stream(
            provider: "antigravity",
            runtime: .antigravityCLI,
            lines: [
                #"{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"ACTIVE","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"command":"swift test"}}}}"#,
                #"{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"ERROR","tool_name":"run_command","tool_info":{"name":"run_command","error":{"message":"1 test failed"}}}}"#,
                #"{"event":"step_update","step_update":{"step_index":2,"step_type":"tool","state":"ACTIVE","tool_name":"write_file","tool_info":{"name":"write_file","parameters":{"path":"notes.md"}}}}"#,
                #"{"event":"step_update","step_update":{"step_index":2,"step_type":"tool","state":"DONE","tool_name":"write_file","tool_info":{"name":"write_file"}}}"#
            ],
            calls: 2,
            hasSilentCompletion: true
        ),
        Stream(
            provider: "opencode",
            runtime: .openCodeCLI,
            lines: [
                // One call reported as several frames: running, then its error.
                #"{"type":"tool_use","sessionID":"s","part":{"id":"part_fail","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"swift test"}}}}"#,
                #"{"type":"tool_use","sessionID":"s","part":{"id":"part_fail","type":"tool","tool":"bash","state":{"status":"error","input":{"command":"swift test"},"error":"1 test failed"}}}"#,
                #"{"type":"tool_use","sessionID":"s","part":{"id":"part_quiet","type":"tool","tool":"bash","state":{"status":"pending","input":{}}}}"#,
                #"{"type":"tool_use","sessionID":"s","part":{"id":"part_quiet","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"true"},"output":""}}}"#
            ],
            calls: 2,
            hasSilentCompletion: true
        )
    ]

    @Test("Every runtime keeps each operation's identity and outcome from stream to presentation", arguments: streams)
    func operationEvidenceSurvivesTheWholePath(_ stream: Stream) throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let liveTask = AgentTask(title: "Operations", goal: "Run the tests")
        let liveRun = TaskRun(task: liveTask)
        context.insert(liveTask)
        context.insert(liveRun)

        // What the worker does with each line of a provider's stream.
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: stream.runtime)
        let pipeline = AgentRuntimeEventPipelineBox(supportsAstraRunProtocol: adapter.descriptor.supportsAstraRunProtocol)
        let state = AgentEventRecordingState()
        func record(_ events: [AgentRuntimeRecordedEvent]) {
            for event in events {
                adapter.recordWorkerStreamEvent(
                    event, mode: .initial, task: liveTask, run: liveRun, modelContext: context, recordingState: state
                )
            }
        }
        for line in stream.lines {
            record(adapter.parseWorkerStreamEvents(line: line, parsesJSONLines: true).events.flatMap {
                adapter.processWorkerStreamEvent($0, pipeline: pipeline)
            })
        }
        record(adapter.flushWorkerStreamEvents(pipeline: pipeline).events)
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: state, task: liveTask, run: liveRun, modelContext: context, processExitedCleanly: true
        )
        liveRun.status = .completed
        liveRun.completedAt = Date()
        try context.save()

        // Everything below is read back through a fresh context: what
        // reopening the task shows.
        let taskID = liveTask.id
        let durable = ModelContext(container)
        let task = try #require(try durable.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first)
        let run = try #require(task.runs.first)
        let events = task.events
        func rows(_ type: TaskEventType) -> [TaskEvent] { events.filter { $0.type == type.rawValue } }

        // One call is one row, however many frames the provider sent for it.
        #expect(rows(TaskEventTypes.Tool.use).count == stream.calls, "tool.use rows")

        // Every finished call has a record naming its own rows.
        let records = rows(TaskEventTypes.Tool.operation).flatMap { ToolOperationBatch.decode(from: $0.payload)?.operations ?? [] }
        #expect(records.count == stream.calls, "operation records")
        let useIDs = Set(rows(TaskEventTypes.Tool.use).map(\.id))
        #expect(Set(records.compactMap(\.useEventID)) == useIDs, "each record names its call")

        let failure = try #require(records.first { $0.outcome == .failed }, "the failing call has a failed record")
        let failedRow = try #require(rows(TaskEventTypes.Tool.resultFailed).first, "the failure's output is kept")
        #expect(failure.resultEventID == failedRow.id)
        #expect(ToolResultFailurePayload.decodeMessage(from: failedRow.payload).contains("1 test failed"))
        #expect(failure.exitCode == stream.failureExitCode)

        if stream.hasSilentCompletion {
            let silent = try #require(records.first { !$0.hasOutput }, "the silent call still has a record")
            #expect(silent.outcome == .succeeded)
            #expect(silent.resultEventID == nil)
            #expect(silent.useEventID != nil)
        }

        // Nothing the provider said for the model's benefit is recorded as
        // the agent speaking.
        #expect(!rows(TaskEventTypes.Conversation.agentResponse).contains { $0.payload.contains("system_notification") })
        #expect(!run.output.contains("system_notification"))
        if stream.hasBackgroundJob {
            let job = try #require(rows(TaskEventTypes.Tool.backgroundJob).first.flatMap { BackgroundJobRecord.decode(from: $0.payload) })
            #expect(job.jobID == "job-1")
            #expect(job.outcome == .failed)
            // Partial output is liveness: it adds no result and no call.
            #expect(rows(TaskEventTypes.Tool.result).isEmpty)
        }

        // The presentation a reopened task shows.
        let presentation = TaskThreadSnapshot(task: task).activityPresentation(for: run)
        let operations = presentation.operations
        #expect(operations.totalCount == stream.calls)
        #expect(operations.finishedCount == stream.calls)
        #expect(operations.failedCount == 1)
        #expect(operations.inFlightCount == 0)
        #expect(presentation.progressMessages.contains { $0.origin == .observedFailure && $0.text.contains("failed") })
        #expect(presentation.technicalOutputs.contains { $0.title == "Failed tool result" && $0.rawPayload.contains("1 test failed") })
        if stream.hasBackgroundJob {
            #expect(presentation.progressMessages.contains { $0.text.hasPrefix("Background job failed · exit code 1") })
        }
        // The same stored history gives the same presentation again.
        #expect(TaskThreadSnapshot(task: task).activityPresentation(for: run).operations == operations)
        // Nothing about the run is live once its stream has ended.
        #expect(RunLiveActivityStore.shared.activity(for: liveRun.id) == nil)
    }
}
