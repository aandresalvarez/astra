import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Permission warning can recover when later provider output arrives")
    func permissionWarningCanRecover() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Bash","message":"approval needed for Bash"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recovered after the warning"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Recover after warning", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.output == "Recovered after the warning")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("Bash") })
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Recovered after the warning" })
    }

    @Test("Permission mode is passed to the provider command")
    func permissionModeIsPassedToProviderCommand() async throws {
        let reviewHarness = try HeadlessChatHarness()
        defer { reviewHarness.cleanup() }
        let reviewArgsURL = reviewHarness.rootURL.appendingPathComponent("review-args.txt")
        let reviewCopilotPath = try reviewHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review mode"}}'
                exit 0
                """,
                argsFile: reviewArgsURL
            )
        )
        let reviewTask = reviewHarness.makeTask(runtime: .copilotCLI, goal: "Run in review mode", model: "gpt-5")
        let reviewWorker = reviewHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: reviewCopilotPath,
            permissionPolicy: .restricted
        )

        _ = await reviewHarness.execute(task: reviewTask, worker: reviewWorker)

        let reviewArgs = try String(contentsOf: reviewArgsURL, encoding: .utf8)
        #expect(reviewArgs.contains("--allow-tool"))
        #expect(!reviewArgs.contains("--allow-all-tools"))
        let reviewArgList = reviewArgs
            .split(separator: "\n")
            .map(String.init)
        let reviewAllowedEntries = Set(Self.argumentValues(after: "--allow-tool", in: reviewArgList))
        let reviewAvailableEntries = Set(Self.argumentValues(after: "--available-tools", in: reviewArgList))
        let reviewExcludedEntries = Set(Self.argumentValues(after: "--excluded-tools", in: reviewArgList))
        #expect(!reviewAllowedEntries.contains("write"))
        #expect(!reviewAllowedEntries.contains("create"))
        #expect(!reviewAllowedEntries.contains("edit"))
        #expect(reviewAvailableEntries.contains("create"))
        #expect(reviewAvailableEntries.contains("edit"))
        #expect(reviewExcludedEntries.contains("task"))

        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("auto-args.txt")
        let autoCopilotPath = try autoHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto mode"}}'
                exit 0
                """,
                argsFile: autoArgsURL
            )
        )
        let autoTask = autoHarness.makeTask(runtime: .copilotCLI, goal: "Run in auto mode", model: "gpt-5")
        let autoWorker = autoHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: autoCopilotPath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--allow-all-tools"))

        let skipHarness = try HeadlessChatHarness()
        defer { skipHarness.cleanup() }
        let skipArgsURL = skipHarness.rootURL.appendingPathComponent("skip-args.txt")
        let skipClaudePath = try skipHarness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"skip-session","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"skip mode"}}]}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"skip mode","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: skipArgsURL
            )
        )
        let skipTask = skipHarness.makeTask(
            runtime: .claudeCode,
            goal: "Run with skipPermissions",
            model: "claude-sonnet-4-6"
        )
        let skipWorker = skipHarness.makeWorker(
            runtime: .claudeCode,
            executablePath: skipClaudePath,
            permissionPolicy: .restricted
        )
        skipWorker.skipPermissions = true

        _ = await skipHarness.execute(task: skipTask, worker: skipWorker)

        let skipArgs = try String(contentsOf: skipArgsURL, encoding: .utf8)
        #expect(skipArgs.contains("--dangerously-skip-permissions"))
    }

    @Test("Copilot autonomous provider denial fails without approval loop")
    func copilotAutonomousProviderDenialFailsWithoutApprovalLoop() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"toolu_denied","toolName":"bash","input":{"command":"cat ~/.zsh_history"}}}'
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_denied","success":false,"error":{"message":"Permission denied and could not request permission from user","code":"denied"}}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Read shell history",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_permission_denied_broad_permissions")
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(task.events.contains {
            $0.type == "error"
                && $0.payload.contains("--allow-all-tools")
                && $0.payload.contains("cat ~/.zsh_history")
        })
    }

    @Test("Copilot hidden permission prompt pauses for user approval and can continue")
    func copilotHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
                script: Self.copilotScript(
                body: """
                allowed_write=0
                mode=""
                for arg in "$@"; do
                  if [ "$arg" = "--allow-tool" ]; then
                    mode="allow"
                    continue
                  fi
                  case "$arg" in
                    --*) mode="" ;;
                  esac
                  if [ "$mode" = "allow" ] && [ "$arg" = "write" ]; then
                    allowed_write=1
                  fi
                done
                if [ "$allowed_write" = "1" ]; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Wrote the approved story"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '● I will write the story to the task folder.'
                printf '%s\\n' '✗ Create .astra/tasks/BAD5D673/warriors_story.md'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .copilotCLI, allowedTools: ["Write"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(args.contains("create"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Wrote the approved story")
    }

    @Test("UI approval resumes a Copilot runtime permission pause")
    func uiApprovalResumesCopilotRuntimePermissionPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
                script: Self.copilotScript(
                body: """
                allowed_write=0
                mode=""
                for arg in "$@"; do
                  if [ "$arg" = "--allow-tool" ]; then
                    mode="allow"
                    continue
                  fi
                  case "$arg" in
                    --*) mode="" ;;
                  esac
                  if [ "$mode" = "allow" ] && [ "$arg" = "write" ]; then
                    allowed_write=1
                  fi
                done
                if [ "$allowed_write" = "1" ]; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Approved through UI path"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Write","message":"Permission denied and could not request permission from user"}}'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(args.contains("create"))
        #expect(runs.last?.output == "Approved through UI path")
        #expect(task.events.contains { $0.type == "task.approved" && $0.payload.contains("Runtime permission approved") })
    }

    @Test("UI approval repairs Copilot wrapper shell grants")
    func uiApprovalRepairsCopilotWrapperShellGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-wrapper-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(#:*)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(echo:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after repaired approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        # Check gh auth before running the search
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        echo "Fetching open PRs"
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [
                    .shellCommand(executable: "#", pattern: "*"),
                    .shellCommand(executable: "echo", pattern: "*")
                ]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(#:*)"))
        #expect(!args.contains("shell(echo:*)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("Start shell calls with the approved executable"))
        #expect(runs.last?.output == "Reviewed open PRs after repaired approval")
    }

    @Test("UI approve similar records task-scoped command grant")
    func uiApproveSimilarRecordsTaskScopedCommandGrant() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-similar-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after task-scoped approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "gh", pattern: "*")]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        let continuation = coordinator.approveSimilarRuntimePermissionForTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("task-scoped runtime permission"))
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType })
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task) == [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ])
        #expect(runs.last?.output == "Reviewed open PRs after task-scoped approval")
    }

    @Test("UI approval resumes a Claude ASTRA ask-first shell pause")
    func uiApprovalResumesClaudeAstraAskFirstShellPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-claude-policy-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-approved","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Approved curl completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Approved curl completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-needs-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_curl","input":{"command":"curl https://redcap.stanford.edu/api/"}}]}}'
                /bin/sleep 20
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Read REDCap project info",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        let approvalEvent = try #require(task.events.first {
            $0.type == "permission.approval.requested" && $0.payload.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)")
        })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .claudeCode)
        #expect(approvalPayload.grants.contains(.shellCommand(executable: "curl", pattern: "*redcap.stanford.edu*")))
        #expect(approvalPayload.displayMessage.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)"))

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
        let settingsURL = harness.workspaceURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let settingsData = try Data(contentsOf: settingsURL)
        let settingsJSON = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let permissions = try #require(settingsJSON["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(runs.last?.output == "Approved curl completed")
    }

    @Test("UI approval permits repeated Claude shell path request after resume")
    func uiApprovalPermitsRepeatedClaudeShellPathRequestAfterResume() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-claude-path-approval-args.txt")
        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "createa web page wit a masterball with a solver in javascript",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(ls dev/workspaces/test/.astra/tasks/bf0b91bc/ *)'; then
                  mkdir -p \(Self.shQuote(taskFolder))
                  printf '%s\\n' '<!doctype html><html><body><h1>Approved ls completed</h1></body></html>' > \(Self.shQuote("\(taskFolder)/index.html"))
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-path-approved","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_ls_approved","input":{"command":"ls /Users/alvaro1/Documents/Astra\\\\ Dev/Workspaces/test/.astra/tasks/BF0B91BC/"}}]}}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Approved ls completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Approved ls completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-path-needs-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_ls","input":{"command":"ls /Users/alvaro1/Documents/Astra\\\\ Dev/Workspaces/test/.astra/tasks/BF0B91BC/"}}]}}'
                /bin/sleep 20
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        let approvalEvent = try #require(task.events.first {
            $0.type == "permission.approval.requested" && $0.payload.contains("Runtime grant: Bash(ls dev/workspaces/test/.astra/tasks/bf0b91bc/ *)")
        })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.grants.contains(.shellCommand(
            executable: "ls",
            pattern: "dev/workspaces/test/.astra/tasks/bf0b91bc/ *"
        )))

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }
        await continuation?.value

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(runs.last?.stopReason == "completed")
        #expect(runs.last?.output.contains("Approved ls completed") == true)
        #expect(!task.events.contains {
            $0.type == "permission.approval.requested"
                && $0.run?.id == runs.last?.id
        })
    }

    @Test("Claude Ask mode artifact write request pauses for approval instead of timing out")
    func claudeAskModeArtifactWriteRequestPausesForApprovalInsteadOfTimingOut() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-ask-write-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if ! printf '%s\\n' "$@" | grep -Fxq -- 'Write'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-write-not-visible","model":"claude-sonnet-4-6"}'
                  sleep 60
                  exit 0
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-write-visible","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Write","id":"toolu_write","input":{"file_path":".astra/tasks/requestable/index.html","content":"<html></html>"}}]}}'
                sleep 20
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "create a web page with a masterball solver in javascript",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.timeoutSeconds = 3

        _ = await harness.execute(task: task, worker: worker)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let run = try #require(task.runs.first)
        let approvalEvent = try #require(task.events.first { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))

        #expect(args.split(separator: "\n").contains { $0 == "Write" })
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "permission_approval_required")
        #expect(run.stopReason != "provider_no_semantic_progress")
        #expect(approvalPayload.providerID == .claudeCode)
        #expect(approvalPayload.grants.contains(.filePath(path: ".astra/tasks/requestable/index.html", access: "write")))
        #expect(approvalPayload.grants.contains(.providerTool(name: "Write")))
    }

    @Test("UI approval ignores stale broad shell runtime grants")
    func uiApprovalIgnoresStaleBroadShellRuntimeGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-stale-broad-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-sanitized-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Sanitized approval completed"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Sanitized approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after an old permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: """
            Permission requested for tool: Bash.
            Runtime grant: Bash(*)
            """,
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(completed)
        #expect(!args.contains("Bash(*)"))
        #expect(args.contains("Bash"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("UI approval replays structured permission grants")
    func uiApprovalReplaysStructuredPermissionGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-structured-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-structured-approval","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Structured approval completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Structured approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Missing structured grant","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after a structured permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        let request = PermissionRequest.shell(command: "curl https://redcap.stanford.edu/api/", toolName: "Bash")
        let grants = [PermissionGrant.shellCommand(executable: "curl", pattern: "*")]
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: request,
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: grants
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(completed)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("UI approval replays only latest runtime permission request")
    func uiApprovalReplaysOnlyLatestRuntimePermissionRequest() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-latest-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'Bash(gh search prs *)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-latest-approval","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Latest approval completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Latest approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Stale grant was replayed","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after the latest permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser

        let oldRun = TaskRun(task: task)
        oldRun.status = .failed
        oldRun.stopReason = "permission_approval_required"
        harness.context.insert(oldRun)
        let oldEvent = TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: .shell(command: "gh search prs --author @me --state open", toolName: "Bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "gh", pattern: "search prs *")]
            ),
            run: oldRun
        )
        oldEvent.timestamp = Date(timeIntervalSince1970: 1)
        harness.context.insert(oldEvent)

        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        let latestEvent = TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: .shell(command: "curl https://redcap.stanford.edu/api/", toolName: "Bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "curl", pattern: "*redcap.stanford.edu*")]
            ),
            run: blockedRun
        )
        latestEvent.timestamp = Date(timeIntervalSince1970: 2)
        harness.context.insert(latestEvent)
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        let continuation = coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }
        await continuation?.value

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(completed)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("Bash(gh search prs *)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("Claude hidden permission prompt pauses for user approval and can continue")
    func claudeHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-permission-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Agent'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-approved-session","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude continued after approval"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude continued after approval","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Permission denied for tool: Agent. approval required"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Permission denied for tool: Agent","usage":{"input_tokens":3,"output_tokens":5}}'
                printf '%s\\n' 'Permission denied for tool: Agent. approval required' >&2
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "use the write tool after approval",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .claudeCode, allowedTools: ["Agent"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(args.contains("Agent"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Claude continued after approval")
    }
}
