import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Codex file-change progress through the worker", .serialized)
@MainActor
struct CodexFileChangeProgressTests {
    @Test("Patches keep a real process alive; silence after them still stops it", arguments: [false, true])
    func patchesSurviveTheWatchdog(stallAfterPatches: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        // Seven seconds outlast both two-second watchdog windows. The only
        // progress before the final answer is file_change, and the entire
        // stream stays below the raw-byte progress threshold. The fake runs
        // through the real pipe reader, adapter, monitor and durable recorder.
        let ending = stallAfterPatches ? "sleep 30" : """
            printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"Updated seven notes."}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
            """
        let executable = try harness.writeExecutable(named: "codex", script: """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"patch-progress"}'
            workspace=$(pwd -P)
            i=1
            while [ "$i" -le 7 ]; do
              printf 'note %s\\n' "$i" > "note-$i.txt"
              printf '{"type":"item.completed","item":{"id":"patch-%s","type":"file_change","changes":[{"path":"%s/note-%s.txt","kind":"add","summary":"Provider patch evidence"}],"status":"completed"}}\\n' "$i" "$workspace" "$i"
              sleep 1
              i=$((i + 1))
            done
            \(ending)
            """)
        let task = harness.makeTask(runtime: .codexCLI, goal: "Summarize the workspace", model: "gpt-5.5")
        let worker = harness.makeWorker(runtime: .codexCLI, executablePath: executable)
        worker.timeoutSeconds = 2

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(!worker.isRunning)
        // The worker also infers changes from disk at settlement. Require the
        // provider's own records so inference cannot hide a recorder regression.
        let providerChanges = run.fileChanges.filter { $0.content == "Provider patch evidence" }
        #expect(providerChanges.count == 7)
        #expect(Set(providerChanges.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            == Set((1...7).map { "note-\($0).txt" }))
        for index in 1...7 {
            let file = harness.workspaceURL.appendingPathComponent("note-\(index).txt")
            #expect(try String(contentsOf: file, encoding: .utf8) == "note \(index)\n")
        }
        if stallAfterPatches {
            #expect(run.status == .failed)
            #expect(task.status == .failed)
            #expect(run.stopReason == "provider_semantic_progress_stalled")
        } else {
            #expect(run.status == .completed)
            #expect(task.status == .completed)
            #expect(run.output.contains("Updated seven notes."))
            #expect(run.tokensUsed == 15)
        }
    }
}
