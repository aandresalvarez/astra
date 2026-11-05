import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

extension HeadlessChatScenarioTests {
    @Test("An existing Codex task receives the host review read after completion or an auth failure", arguments: [false, true])
    func existingCodexTaskReceivesReviewRead(previousAuthenticationFailure: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let argsFile = harness.rootURL.appendingPathComponent("review-read-args.txt")
        let executable = try harness.writeExecutable(named: "codex", script: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s\\n' '{"type":"thread.started","thread_id":"review-read-session"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"Review discussion preserved"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}'
        exit 0
        """)
        let task = harness.makeTask(runtime: .codexCLI, goal: "Review GitHub PR 7 in example/project", model: "gpt-5.5")
        let taskID = task.id
        task.workspace?.testEnabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let skill = Skill(name: "GitHub Agent", allowedTools: ["Read"],
                          behaviorInstructions: "Use ASTRA's GitHub tool to inspect pull requests.")
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        skill.workspace = task.workspace
        task.skills = [skill]
        harness.context.insert(skill)
        let worker = harness.makeWorker(runtime: .codexCLI, executablePath: executable)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "review-read-session")
        let firstPrompt = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(firstPrompt.contains(#"["pr","review-threads","NUMBER","--repo","OWNER/REPO"]"#))
        let priorRun = try #require(task.runs.first)
        let priorOutput = priorRun.output
        if previousAuthenticationFailure {
            // Reconstruct the persisted failure from the reported shell-login
            // incident, after its provider process has stopped.
            priorRun.status = .failed
            priorRun.stopReason = TaskRunStopReason.capabilitySessionExpired.rawValue
            task.status = .failed
            harness.context.insert(TaskEvent(
                task: task, eventType: TaskEventTypes.System.runtimeRepairContext,
                payload: RuntimeRepairContext.manualReview(message: "Authentication failed in a shell context").encoded(),
                run: priorRun
            ))
            try harness.context.save()
        }
        let followUp = previousAuthenticationFailure
            ? "Read the inline comments here"
            : "Read the inline comments on GitHub PR 7 in example/project here"
        _ = await harness.continueTask(task: task, message: followUp, worker: worker)

        let resumedPrompt = try String(contentsOf: argsFile, encoding: .utf8)
        let resumedArguments = resumedPrompt.split(separator: "\n").map(String.init)
        if !previousAuthenticationFailure {
            let resumeIndex = try #require(resumedArguments.firstIndex(of: "resume"))
            let sessionIndex = try #require(resumedArguments.firstIndex(of: "review-read-session"))
            #expect(sessionIndex > resumeIndex)
        }
        #expect(resumedPrompt.contains(followUp))
        #expect(resumedPrompt.contains(#"["pr","review-threads","NUMBER","--repo","OWNER/REPO"]"#))
        #expect(resumedPrompt.contains("Git panel's host GitHub login"))
        #expect(!resumedPrompt.contains("astra-host-control github -- pr review-threads"))
        #expect(task.id == taskID)
        #expect(task.runs.count == 2)
        #expect(task.runs.sorted { $0.startedAt < $1.startedAt }.first?.output == priorOutput)
        #expect(task.sessionId == "review-read-session")
        #expect(task.status == .completed)
    }
}
