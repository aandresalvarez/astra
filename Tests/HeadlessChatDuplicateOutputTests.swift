import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    /// Mirrors the real Claude CLI stream shape with `--include-partial-messages`:
    /// the final text arrives first as `stream_event` deltas, then again inside
    /// the complete `assistant` envelope. The recorder must keep exactly one copy
    /// in the run output — including when the text is prefixed by an ASTRA_EVENT
    /// protocol marker that the pipeline buffers and flushes.
    @Test("Claude partial-message deltas plus final envelope record output once")
    func claudePartialMessageDeltasRecordOutputOnce() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let marker = #"ASTRA_EVENT {\"v\":1,\"type\":\"complete\",\"summary\":\"Created the notes file\"}"#
        let answer = "The notes file has been created with three facts."
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            IFS= read -r first_line
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"dup-sess","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let"}}}'
            printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" me write the file."}}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"thinking","thinking":"Let me write the file."}]}}'
            printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\(marker)\\n\\n"}}}'
            printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\(answer)"}}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"\(marker)\\n\\n\(answer)"}]}}'
            printf '%s\\n' '{"type":"system","subtype":"post_turn_summary","summarizes_uuid":"u1","status_category":"completed"}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":2,"result":"\(marker)\\n\\n\(answer)","usage":{"input_tokens":5,"output_tokens":9}}'
            while IFS= read -r _; do :; done
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Summarize the current notes status", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            liveApprovals: true
        )

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        // The fake never creates the artifact, so the task pauses for review;
        // the run itself must complete cleanly.
        #expect(run.status == .completed, "stopReason=\(run.stopReason ?? "nil")")
        let occurrences = run.output.components(separatedBy: answer).count - 1
        #expect(occurrences == 1, "run.output recorded the answer \(occurrences)x: \(run.output)")
        let completeEvents = task.events.filter { $0.type == "astra.complete" }
        #expect(completeEvents.count == 1, "astra.complete recorded \(completeEvents.count)x")
        let responseChunks = task.events.filter { $0.type == "conversation.agent_response" }
        #expect(responseChunks.count <= 2)
    }
}
