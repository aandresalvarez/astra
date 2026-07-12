import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

private final class SnapshotBuildCancellationBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func checkpoint() {
        entered.signal()
        release.wait()
    }

    func waitUntilEntered() { entered.wait() }
    func releaseBuild() { release.signal() }
}

extension TaskThreadSnapshotTests {
    @Test("Snapshot precomputes privacy-safe transcript shape metrics")
    func snapshotPrecomputesTranscriptMetrics() {
        let task = makeTask(goal: "Goal\n```swift\nlet value = 1\n```\n| Name |")
        let run = TaskRun(task: task)
        run.output = "| Result |\n| --- |\n| done |"

        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: [], runs: [run])

        #expect(snapshot.transcriptMetrics.textBytes > 0)
        #expect(snapshot.transcriptMetrics.agentResponseCount == 1)
        #expect(snapshot.transcriptMetrics.codeFenceCount == 2)
        #expect(snapshot.transcriptMetrics.tableRowCount == 4)
    }

    @Test("Conversation snapshot preserves chronological run and message behavior")
    func conversationSnapshotOrdering() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal")
        task.createdAt = createdAt

        let firstRun = TaskRun(task: task)
        firstRun.startedAt = Date(timeIntervalSince1970: 110)
        firstRun.completedAt = Date(timeIntervalSince1970: 130)
        firstRun.output = "First run output"

        let secondRun = TaskRun(task: task)
        secondRun.startedAt = Date(timeIntervalSince1970: 140)
        secondRun.output = "Second run output"

        let userFollowUp = makeEvent(
            task: task,
            type: "user.message",
            payload: "Continue",
            timestamp: Date(timeIntervalSince1970: 150)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [userFollowUp],
            runs: [secondRun, firstRun]
        )

        #expect(snapshot.conversationItems.count == 4)

        if case .userMessage(let text, _) = snapshot.conversationItems[0] {
            #expect(text == "Original goal")
        } else {
            Issue.record("Expected original goal as first conversation item")
        }

        if case .agentResponse(let run) = snapshot.conversationItems[1] {
            #expect(run.id == firstRun.id)
        } else {
            Issue.record("Expected completed first run before the follow-up")
        }

        if case .userMessage(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Continue")
        } else {
            Issue.record("Expected follow-up user message")
        }

        if case .agentResponse(let run) = snapshot.conversationItems[3] {
            #expect(run.id == secondRun.id)
        } else {
            Issue.record("Expected remaining run output at the end")
        }
    }

    @Test("Completed empty provider run stays visible in the transcript")
    func completedEmptyProviderRunStaysVisibleInTranscript() {
        let task = makeTask(goal: "cerate a html slide deck about agents lanscape in the 2030")
        task.createdAt = Date(timeIntervalSince1970: 100)

        let run = TaskRun(task: task)
        run.status = .completed
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.completedAt = Date(timeIntervalSince1970: 111)
        run.stopReason = "completed"
        run.output = ""

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected an empty completed run to remain visible")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(responseRun.completedWithoutUserFacingResult)
    }

    @Test("Plan conversation events appear inline")
    func planConversationEventsAppearInline() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let planUser = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Plan this first",
            timestamp: Date(timeIntervalSince1970: 110)
        )
        let planAssistant = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.assistantMessage,
            payload: "Here is the plan",
            timestamp: Date(timeIntervalSince1970: 120)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [planAssistant, planUser],
            runs: []
        )

        #expect(snapshot.conversationItems.count == 3)
        if case .planUserMessage(let text, _) = snapshot.conversationItems[1] {
            #expect(text == "Plan this first")
        } else {
            Issue.record("Expected plan user message")
        }
        if case .planAssistantMessage(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Here is the plan")
        } else {
            Issue.record("Expected plan assistant message")
        }
    }

    @Test("Routine lifecycle events are hidden from the default chat transcript")
    func systemLifecycleEventsHiddenFromDefaultChatTranscript() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let approved = makeEvent(
            task: task,
            type: TaskPlanEventTypes.approved,
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 110)
        )
        let restarted = makeEvent(
            task: task,
            type: "task.started",
            payload: "Moved back to draft for editing.",
            timestamp: Date(timeIntervalSince1970: 120)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [restarted, approved],
            runs: []
        )

        #expect(snapshot.conversationItems.count == 1)
        if case .userMessage(let text, _) = snapshot.conversationItems[0] {
            #expect(text == "Original goal")
        } else {
            Issue.record("Expected only the original user message")
        }
    }

    @Test("Actionable transcript events remain visible")
    func actionableTranscriptEventsRemainVisible() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let planFailed = makeEvent(
            task: task,
            type: TaskPlanEventTypes.executionFailed,
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 110)
        )
        let scheduleFailed = makeEvent(
            task: task,
            type: "schedule.result",
            payload: "Failed to create routine: invalid schedule.",
            timestamp: Date(timeIntervalSince1970: 120)
        )
        let memorySaved = makeEvent(
            task: task,
            type: "system.info",
            payload: #"Memory saved: "Use Python 3.11.""#,
            timestamp: Date(timeIntervalSince1970: 130)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [memorySaved, scheduleFailed, planFailed],
            runs: []
        )

        #expect(snapshot.conversationItems.count == 4)
        if case .systemInfo(let text, _, _) = snapshot.conversationItems[1] {
            #expect(text == "Plan execution stopped.")
        } else {
            Issue.record("Expected plan failure notice")
        }
        if case .scheduleResult(let text, _) = snapshot.conversationItems[2] {
            #expect(text.contains("Failed to create routine"))
        } else {
            Issue.record("Expected schedule failure notice")
        }
        if case .systemInfo(let text, _, _) = snapshot.conversationItems[3] {
            #expect(text.contains("Memory saved"))
        } else {
            Issue.record("Expected memory confirmation notice")
        }
    }

    @Test("Repeated permission approvals coalesce into one counted notice")
    func repeatedPermissionApprovalsCoalesceIntoOneCountedNotice() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let liveText = "Live permission approved for Bash; the provider continues in the same session."
        let events = [
            makeEvent(task: task, type: "system.info", payload: liveText, timestamp: Date(timeIntervalSince1970: 110)),
            makeEvent(task: task, type: "task.approved", payload: "Runtime permission approved for Bash", timestamp: Date(timeIntervalSince1970: 111)),
            makeEvent(task: task, type: "system.info", payload: liveText, timestamp: Date(timeIntervalSince1970: 120)),
            makeEvent(task: task, type: "task.approved", payload: "Runtime permission approved for Bash", timestamp: Date(timeIntervalSince1970: 121))
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: []
        )

        // Two approvals used to paint four rows (live narration + generic echo,
        // twice). They coalesce into the goal plus ONE counted notice.
        #expect(snapshot.conversationItems.count == 2)
        guard case .systemInfo(let text, _, let count) = snapshot.conversationItems[1] else {
            Issue.record("Expected a coalesced system notice")
            return
        }
        #expect(text == liveText)
        #expect(count == 2)
    }

    @Test("Approval echo merges into the richer live line regardless of order")
    func approvalEchoMergesIntoTheRicherLiveLineRegardlessOfOrder() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let liveText = "Live permission approved for WebFetch; the provider continues in the same session."
        let events = [
            makeEvent(task: task, type: "task.approved", payload: "Runtime permission approved for WebFetch", timestamp: Date(timeIntervalSince1970: 110)),
            makeEvent(task: task, type: "system.info", payload: liveText, timestamp: Date(timeIntervalSince1970: 111)),
            makeEvent(task: task, type: "system.info", payload: "Memory saved: keep using Python 3.11.", timestamp: Date(timeIntervalSince1970: 120))
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: []
        )

        #expect(snapshot.conversationItems.count == 3)
        guard case .systemInfo(let text, _, let count) = snapshot.conversationItems[1] else {
            Issue.record("Expected the merged live approval notice")
            return
        }
        #expect(text == liveText)
        #expect(count == 1)
        guard case .systemInfo(let unrelatedText, _, let unrelatedCount) = snapshot.conversationItems[2] else {
            Issue.record("Expected the unrelated notice to stay separate")
            return
        }
        #expect(unrelatedText.contains("Memory saved"))
        #expect(unrelatedCount == 1)
    }

    @Test("Task run snapshot precomputes VPN warning markers")
    func taskRunSnapshotPrecomputesVPNWarningMarkers() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.output = #"API Error: 403 {"message":"Request is prohibited by organization's policy.","details":[{"reason":"SECURITY_POLICY_VIOLATED","metadata":{"vpcServiceControlsUniqueIdentifier":"abc123"}}]}"#

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        #expect(snapshot.latestRun?.hasVPNWarning == true)
    }

    @Test("Oversized file-change payload is not decoded on the serial snapshot executor")
    func oversizedFileChangesStayBounded() throws {
        let task = makeTask()
        let run = TaskRun(task: task)
        let change = StoredFileChange(
            path: "large.txt",
            changeType: "Write",
            content: String(repeating: "x", count: 300_000)
        )
        run.fileChangesJSON = String(decoding: try JSONEncoder().encode([change]), as: UTF8.self)

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        #expect(snapshot.latestRun?.fileChangesJSONLength == run.fileChangesJSON.count)
        #expect(snapshot.latestRun?.fileChanges.isEmpty == true)
    }

    @Test("Oversized final answer skips unbounded markdown presentation")
    func oversizedFinalAnswerUsesBoundedPresentation() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.status = .completed
        let events = [
            makeEvent(task: task, type: "tool.result", payload: "done", timestamp: .now, run: run),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: String(repeating: "# Large response\n", count: 20_000),
                timestamp: .now.addingTimeInterval(1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )

        let latestRun = try! #require(snapshot.latestRun)
        #expect(snapshot.outputPresentation(for: latestRun).displayText.contains("Open Diagnostics"))
    }

    @Test("Network access technical details parse Google Cloud policy response")
    func networkAccessTechnicalDetailsParseGoogleCloudPolicyResponse() {
        let output = """
        Failed to authenticate. API Error: 403 [{"error":{"code":403,"message":"Request is prohibited by organization's policy. vpcServiceControlsUniqueIdentifier: uid-from-message","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.PreconditionFailure","violations":[{"type":"VPC_SERVICE_CONTROLS","description":"uid-from-violation"}]},{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SECURITY_POLICY_VIOLATED","domain":"googleapis.com","metadata":{"uid":"uid-from-metadata","service":"aiplatform.googleapis.com","troubleshootToken":"troubleshoot-token-value"}}]}}]
        """

        let presentation = NetworkAccessTechnicalDetailsPresentation(output: output)

        #expect(presentation.subtitle == "403 Permission Denied - aiplatform.googleapis.com")
        #expect(presentation.summary.contains("VPC Service Controls"))
        #expect(presentation.facts.contains(RunFactPresentation(title: "Status", value: "403 Permission Denied")))
        #expect(presentation.facts.contains(RunFactPresentation(title: "Reason", value: "Security Policy Violated")))
        #expect(presentation.facts.contains(RunFactPresentation(title: "Service", value: "aiplatform.googleapis.com", isMonospaced: true)))
        #expect(presentation.facts.contains(RunFactPresentation(title: "Control", value: "VPC Service Controls")))
        #expect(presentation.facts.contains(RunFactPresentation(title: "Identifier", value: "uid-from-violation", isMonospaced: true)))
        #expect(presentation.copyText.contains("Troubleshoot token: troubleshoot-token-value"))
        #expect(presentation.rawPayload.contains("\"service\" : \"aiplatform.googleapis.com\""))
    }

    @Test("Task run snapshot hides persisted ASTRA protocol marker fragments")
    func taskRunSnapshotHidesProtocolMarkerFragments() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.output = """
        ● I'll build a clean page.
           tepID":"step-1","status":"running"}
        ✓ Create .astra/tasks/3BAB3C9D/index.html (+124)
        ● ASTRA_EVENT {"v":1,"type":"complete","summary":"Verified both files created successfully
           with index.html and styles.css in black and white design. All placeholder content is clearly
           marked for customization.","verifiedBy":"File system verification"}
        Final response.
        """

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        let output = snapshot.latestRun?.output ?? ""
        #expect(!output.contains("ASTRA_EVENT"))
        #expect(!output.contains("tepID"))
        #expect(!output.contains("verifiedBy"))
        #expect(!output.contains("marked for customization"))
        #expect(output.contains("I'll build a clean page."))
        #expect(output.contains("Create .astra/tasks/3BAB3C9D/index.html"))
        #expect(output.contains("Final response."))
    }

    @Test("Tool activity is grouped once per run")
    func toolActivityGrouping() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Read", timestamp: Date(timeIntervalSince1970: 1), run: run),
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Bash", timestamp: Date(timeIntervalSince1970: 2), run: run),
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Read", timestamp: Date(timeIntervalSince1970: 3), run: run),
            makeEvent(task: task, type: "tool.result", payload: "result", timestamp: Date(timeIntervalSince1970: 4), run: run),
            makeEvent(task: task, type: "tool.result", payload: "", timestamp: Date(timeIntervalSince1970: 5), run: run)
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.tools == [
            TaskToolSummary(name: "Read", count: 2),
            TaskToolSummary(name: "Bash", count: 1)
        ])
        #expect(activity.toolResults.count == 1)
        #expect(activity.toolResults.first?.payload == "result")
    }

    @Test("Tool activity presentation parses tool details")
    func toolActivityPresentationParsesDetails() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Bash: astra-browser google-docs-read-document",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read: /tmp/notes.md",
                timestamp: Date(timeIntervalSince1970: 2),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Running validation tests...",
                timestamp: Date(timeIntervalSince1970: 3),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using Glob",
                timestamp: Date(timeIntervalSince1970: 4),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.toolCalls.map(\.toolName) == ["Bash", "Read", "Validation tests", "Glob"])
        #expect(activity.toolCalls[0].detail == "astra-browser google-docs-read-document")
        #expect(activity.toolCalls[0].detailKind == .command)
        #expect(activity.toolCalls[1].detailKind == .path)
        #expect(activity.tools == [
            TaskToolSummary(name: "Bash", count: 1),
            TaskToolSummary(name: "Read", count: 1),
            TaskToolSummary(name: "Validation tests", count: 1),
            TaskToolSummary(name: "Glob", count: 1)
        ])
    }

    @Test("Permission summary presentation formats compact facts")
    func permissionSummaryPresentationFormatsFacts() {
        let payload = """
        {
          "status": "failed",
          "stopReason": "google_docs_safe_edit_unavailable",
          "toolUseCount": 1,
          "deniedCount": 0,
          "fileChangeCount": 0,
          "toolsUsed": ["Bash"],
          "commandsRun": ["astra-browser google-docs-read-document"],
          "externalDomains": ["docs.google.com"],
          "environmentKeyNames": ["GCP_PROJECT", "GCP_REGION"],
          "usedBroadProviderPermissions": true,
          "exceededInitialPermissionLevel": false
        }
        """

        let facts = PolicySummaryPresentation.permissionSummaryFacts(from: payload)

        #expect(facts.contains(RunFactPresentation(title: "Status", value: "failed")))
        #expect(facts.contains(RunFactPresentation(title: "Stop reason", value: "google_docs_safe_edit_unavailable")))
        #expect(facts.contains(RunFactPresentation(title: "Tools used", value: "1")))
        #expect(facts.contains(RunFactPresentation(title: "Broad provider mode", value: "Yes")))
        #expect(facts.contains(RunFactPresentation(title: "Commands", value: "astra-browser google-docs-read-document", isMonospaced: true)))
        #expect(facts.contains(RunFactPresentation(title: "Env keys", value: "GCP_PROJECT, GCP_REGION", isMonospaced: true)))
    }

    @Test("Permission summary presentation includes MCP server facts")
    func permissionSummaryPresentationIncludesMCPServerFacts() {
        let render = ProviderPolicyRender(
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: .restricted,
            allowedTools: ["Read"],
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "test",
            providerID: .claudeCode,
            providerVersion: nil,
            model: "claude-sonnet-4-6",
            policyLevel: .review,
            policyScope: .taskOverride,
            providerRender: render,
            workspacePath: "/tmp/mcp-summary",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            mcpServers: [
                .init(
                    id: "github",
                    packageID: "github-workflow",
                    displayName: "GitHub MCP",
                    transport: "stdio",
                    allowedTools: ["issues.list"],
                    excludedTools: ["repo.delete"],
                    resourcesEnabled: true,
                    promptsEnabled: false,
                    trustLevel: "high"
                )
            ],
            approvalsGranted: []
        )

        let summary = PolicySummaryPresentation(
            manifest: manifest,
            permissionSummaryPayload: nil
        )

        #expect(summary?.facts.contains(RunFactPresentation(
            title: "MCP servers",
            value: "github-workflow/github stdio tools:1"
        )) == true)
    }

    @Test("Runtime permission approval copy explains the decision")
    func runtimePermissionApprovalCopyExplainsDecision() {
        let payload = """
        Permission requested for tool: Bash. ASTRA paused before allowing this run to continue.
        What ASTRA observed: Bash command: bq ls --project_id=upo-nero-phi-su-deid-jsl --format=prettyjson
        Why approval is needed: The tool or command is configured as ask-first by the effective ASTRA policy.
        What allowing does: Grants Bash(bq ls --project_id=upo-nero-phi-su-deid-jsl *) one time for this run, then restarts the provider from the stopped point.
        What to check: Allow only if this BigQuery command matches the task and should use the signed-in Google Cloud account and project.
        Detail: bq ls --project_id=upo-nero-phi-su-deid-jsl --format=prettyjson
        Runtime grant: Bash(bq ls --project_id=upo-nero-phi-su-deid-jsl *)
        """

        let presentation = RuntimePermissionApprovalText(payload: payload)

        #expect(presentation.compactSummary.contains("Bash"))
        #expect(presentation.decisionTitle == "BigQuery command needs permission")
        #expect(presentation.decisionSummary.contains("ASTRA wants to run a BigQuery command"))
        #expect(!presentation.decisionSummary.contains("Bash(bq"))
        #expect(presentation.noticeBody.contains("Requested: bq ls"))
        #expect(presentation.noticeBody.contains("Check: allow only if this BigQuery command matches the task"))
    }

    @Test("Runtime permission decision presentation keeps technical grant out of visible copy")
    func runtimePermissionDecisionPresentationHidesRawGrant() {
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .copilotCLI,
            request: .shell(
                command: "gh search prs --author @me --state open --limit 200 --json number,title,url",
                toolName: "bash"
            ),
            reason: "The tool or command is configured as ask-first by the effective ASTRA policy.",
            grants: [.shellCommand(executable: "gh", pattern: "search prs *")]
        )

        let presentation = RuntimePermissionDecisionPresentation(payload: payload)

        #expect(presentation.title == "GitHub PR command needs permission")
        #expect(presentation.summary == "ASTRA wants to use your GitHub CLI login for this task.")
        #expect(presentation.scope == "Scope: one time for this run.")
        #expect(presentation.commandPreview?.contains("gh search prs") == true)
        #expect(presentation.grantSummary == "shell(gh:search prs *)")
        #expect(!presentation.summary.contains("shell(gh"))
    }

    @Test("Runtime permission approval copy treats provider file write aliases as file changes")
    func runtimePermissionApprovalCopyTreatsProviderFileWriteAliasesAsFileChanges() {
        for toolName in ["create", "multi_edit"] {
            let payload = PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .fileWrite(path: ".astra/tasks/123/index.html", toolName: toolName),
                reason: "The file change requires user approval by the effective ASTRA policy.",
                grants: [.filePath(path: ".astra/tasks/123/index.html", access: "write")]
            )

            let presentation = RuntimePermissionApprovalText(payload: payload)

            #expect(presentation.decisionTitle == "File change needs permission")
            #expect(presentation.decisionSummary.contains("ASTRA wants to change"))
            #expect(presentation.noticeBody.contains("Check: allow only if the provider should change that path"))
        }
    }

    @Test("Run activity presentation suppresses duplicated actionable notices")
    func runActivityPresentationSuppressesActionableNotices() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        let events = [
            makeEvent(
                task: task,
                type: "error",
                payload: "Copilot exited with code 1.\n\nProvider error:\nraw stack output",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!
        let activity = snapshot.activity(for: visibleRun)
        let notice = activity.notices.first!

        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices,
            suppressedNoticeIDs: [notice.id]
        )

        // The inline banner already carries the summary and raw payload;
        // the disclosure must not repeat the notice in any form.
        #expect(presentation.issues.isEmpty)
        #expect(presentation.technicalOutputs.isEmpty)

        let issue = RunIssuePresentation(notice: notice)
        #expect(issue.rawPayload?.contains("raw stack output") == true)
    }

    @Test("Run activity presentation keeps actionable notices when not rendered separately")
    func runActivityPresentationKeepsActionableIssuesWithoutSuppression() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        let events = [
            makeEvent(
                task: task,
                type: "budget.exceeded",
                payload: "Browser action budget was exceeded.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!
        let activity = snapshot.activity(for: visibleRun)

        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices
        )

        #expect(presentation.issues.count == 1)
        #expect(presentation.issues.first?.title == "Budget exceeded")
        #expect(presentation.technicalOutputs.isEmpty)
    }

    @Test("Task thread status chrome avoids neutral gray fills")
    func taskThreadStatusChromeAvoidsNeutralGrayFills() {
        #expect(TaskThreadStatusChrome.runActivityBackgroundOpacity == 0)
        #expect(TaskThreadStatusChrome.runActivityDetailBackgroundOpacity == 0)
        #expect(TaskThreadStatusChrome.runNoticeBackgroundOpacity == 0)
    }

    @Test("Long tool results are summarized while preserving raw output")
    func longToolResultsAreSummarizedWithRawOutput() {
        let payload = String(repeating: "x", count: 6_000)
        let summary = PayloadFormatter.summary(for: payload)

        #expect(summary.summary.count <= 243)
        #expect(summary.summary.hasSuffix("..."))
        #expect(summary.rawPayload.count == 6_000)
    }

    @Test("Budget warning is visible in run activity")
    func budgetWarningCreatesRunNotice() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(
                task: task,
                type: "budget.warning",
                payload: "Budget exceeded in warning mode (147124/10000).",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "budget.warning")
        #expect(activity.notices.first?.payload.contains("147124/10000") == true)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Budget warning is promoted to an inline run notice")
    func budgetWarningPromotesToInlineRunNotice() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(
                task: task,
                type: "budget.warning",
                payload: "Budget exceeded in warning mode (110638/10000).",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!
        let activity = snapshot.activity(for: visibleRun)
        let notice = activity.notices.first!

        #expect(TaskRunNoticePresentationRules.shouldShowInline(notice, for: visibleRun))

        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices,
            suppressedNoticeIDs: [notice.id]
        )

        #expect(presentation.issues.isEmpty)
        #expect(presentation.technicalOutputs.isEmpty)
    }

    @Test("Inline notice rules keep warning budget visible")
    func inlineNoticeRulesKeepWarningBudgetVisible() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 2)
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!

        let visibleTypes = [
            "budget.warning",
            "budget.exceeded",
            "error"
        ]
        for type in visibleTypes {
            let notice = TaskRunNotice(id: UUID(), type: type, payload: "payload")
            #expect(TaskRunNoticePresentationRules.shouldShowInline(notice, for: visibleRun))
        }

        for type in ["task.stats", "astra.permission_summary", "tool.result", "permission.approval.requested"] {
            let notice = TaskRunNotice(id: UUID(), type: type, payload: "payload")
            #expect(!TaskRunNoticePresentationRules.shouldShowInline(notice, for: visibleRun))
        }
    }

    @Test("Provider error event is visible in run activity")
    func providerErrorCreatesRunNotice() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        run.output = ""
        let events = [
            makeEvent(
                task: task,
                type: "error",
                payload: "Copilot exited with code 1. GitHub Copilot failed before ASTRA received a visible assistant response.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "error")
        #expect(activity.notices.first?.payload.contains("Copilot exited") == true)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Permission approval request is visible in run activity")
    func permissionApprovalCreatesRunNotice() {
        let task = makeTask(status: .pendingUser)
        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "permission_approval_required"
        let events = [
            makeEvent(
                task: task,
                type: "permission.approval.requested",
                payload: "Approve to continue with Write access.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)
        let visibleRun = snapshot.latestRun!
        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices
        )

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "permission.approval.requested")
        #expect(activity.notices.first?.payload.contains("Approve to continue") == true)
        #expect(presentation.approvals.count == 1)
        #expect(presentation.issues.isEmpty)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Runtime permission resume prompt is hidden behind compact approval row")
    func runtimePermissionResumePromptIsHiddenBehindCompactApprovalRow() {
        let task = makeTask(status: .running)
        let events = [
            makeEvent(
                task: task,
                type: "task.approved",
                payload: "Runtime permission approved by user. Continuing with one-time expanded provider permissions.",
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            makeEvent(
                task: task,
                type: "user.message",
                payload: "ASTRA approved one-time runtime permission for this run: shell(gh:search prs *). Continue the original task from where it stopped.",
                timestamp: Date(timeIntervalSince1970: 2)
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: []
        )

        #expect(snapshot.conversationItems.contains {
            if case .systemInfo(let text, _, _) = $0 {
                return text == "Permission approved. Continuing."
            }
            return false
        })
        #expect(!snapshot.conversationItems.contains {
            if case .userMessage(let text, _) = $0 {
                return text.contains("ASTRA approved one-time runtime permission")
            }
            return false
        })
    }

    @Test("Conversation includes running run with tool activity before output")
    func toolActivityCreatesLiveConversationItemBeforeOutput() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal", status: .running)
        task.createdAt = createdAt

        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.status = .running
        run.output = ""

        let toolUse = makeEvent(
            task: task,
            type: "tool.use",
            payload: "Using tool: Bash",
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [toolUse],
            runs: [run]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected live agent response for tool-only running run")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.activity(for: responseRun).tools == [TaskToolSummary(name: "Bash", count: 1)])
    }

    @Test("Completed run separates progress narration from final answer")
    func completedRunSeparatesProgressNarrationFromFinalAnswer() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal", status: .completed)
        task.createdAt = createdAt

        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.completedAt = Date(timeIntervalSince1970: 150)
        run.status = .completed
        run.output = [
            "Reading the saved Spanish letter.",
            "Translating the Spanish letter and saving the Portuguese version.",
            "Traduzida e guardada.\n\nPortuguês (texto):\nQuerida Rosa"
        ].joined()

        let events = [
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "Reading the saved Spanish letter.",
                timestamp: Date(timeIntervalSince1970: 120),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: view",
                timestamp: Date(timeIntervalSince1970: 121),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.result",
                payload: "File contents",
                timestamp: Date(timeIntervalSince1970: 122),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "Translating the Spanish letter and saving the Portuguese version.",
                timestamp: Date(timeIntervalSince1970: 130),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: create",
                timestamp: Date(timeIntervalSince1970: 131),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.result",
                payload: "Created file",
                timestamp: Date(timeIntervalSince1970: 132),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "Traduzida e guardada.\n\nPortuguês (texto):\nQuerida Rosa",
                timestamp: Date(timeIntervalSince1970: 140),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText == "Traduzida e guardada.\n\nPortuguês (texto):\nQuerida Rosa")
        #expect(output.rawText == run.output)
        #expect(output.progressMessages.map(\.text) == [
            "Reading the saved Spanish letter.",
            "Translating the Spanish letter and saving the Portuguese version."
        ])
    }

    @Test("Completed direct answer keeps raw output as final answer")
    func completedDirectAnswerKeepsRawOutputAsFinalAnswer() {
        let task = makeTask(goal: "Original goal", status: .completed)
        let run = TaskRun(task: task)
        run.completedAt = Date(timeIntervalSince1970: 120)
        run.status = .completed
        run.output = "Direct final answer"
        let event = makeEvent(
            task: task,
            type: "agent.response",
            payload: "Direct final answer",
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [event],
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText == "Direct final answer")
        #expect(output.progressMessages.isEmpty)
    }

    @Test("Completed response chunks join with markdown-safe separators")
    func completedResponseChunksJoinWithMarkdownSafeSeparators() {
        let task = makeTask(goal: "Original goal", status: .completed)
        let run = TaskRun(task: task)
        run.completedAt = Date(timeIntervalSince1970: 130)
        run.status = .completed
        run.output = "I checked death.Now the results are ready."

        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Bash",
                timestamp: Date(timeIntervalSince1970: 110),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "I checked death.",
                timestamp: Date(timeIntervalSince1970: 120),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "Now the results are ready.",
                timestamp: Date(timeIntervalSince1970: 121),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText == "I checked death. Now the results are ready.")
        #expect(!output.displayText.contains("death.Now"))
    }

    @Test("Completed response chunks preserve heading table boundary")
    func completedResponseChunksPreserveHeadingTableBoundary() {
        let task = makeTask(goal: "Original goal", status: .completed)
        let run = TaskRun(task: task)
        run.completedAt = Date(timeIntervalSince1970: 130)
        run.status = .completed
        run.output = """
        ### What passed across all runs (death-specific)

        | Model/Test | Status | Details |
        |---|---|---|
        | `lpch_deaths` | PASS | 15.1k rows (prod) |
        """

        let events = [
            makeEvent(
                task: task,
                type: "tool.result",
                payload: "Done",
                timestamp: Date(timeIntervalSince1970: 110),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: "### What passed across all runs (death-specific)\n",
                timestamp: Date(timeIntervalSince1970: 120),
                run: run
            ),
            makeEvent(
                task: task,
                type: "agent.response",
                payload: """
                | Model/Test | Status | Details |
                |---|---|---|
                | `lpch_deaths` | PASS | 15.1k rows (prod) |
                """,
                timestamp: Date(timeIntervalSince1970: 121),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText.contains("death-specific)\n\n| Model/Test | Status | Details |"))
        #expect(!output.displayText.contains("death-specific) | Model/Test"))
        #expect(MarkdownTextView.parse(output.displayText).contains { $0.kind == .table })
    }

    @Test("Raw-only long monitoring output compacts progress chatter")
    func rawOnlyLongMonitoringOutputCompactsProgressChatter() {
        let task = makeTask(goal: "Original goal", status: .completed)
        let run = TaskRun(task: task)
        run.completedAt = Date(timeIntervalSince1970: 130)
        run.status = .completed
        run.output = """
        Let me check initial progress after a moment. Let me check initial progress after a moment. Build is running and already at model 296/2476. Let me wait and check progress again. Good progress at ~548/2476. Let me continue monitoring. Now at ~716/2476. Let me keep polling. Good progress, tests are passing. Let me continue monitoring. The final death model built successfully and all tests passed.
        """ + String(repeating: " Let me continue monitoring. Good progress.", count: 20)

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText.contains("Open Diagnostics"))
        #expect(!output.displayText.contains("Last update:"))
        #expect(output.displayText.count < run.output.count)
        #expect(!output.displayText.contains("Let me check initial progress after a moment. Let me check initial progress after a moment."))
        #expect(!output.displayText.contains("Let me continue monitoring"))
        #expect(!output.progressMessages.isEmpty)
    }

    @Test("Prod-scale monitoring tail does not render as final answer")
    func prodScaleMonitoringTailDoesNotRenderAsFinalAnswer() {
        let task = makeTask(goal: "Original goal", status: .completed)
        let run = TaskRun(task: task)
        run.completedAt = Date(timeIntervalSince1970: 130)
        run.status = .completed
        run.output = """
        New output just appeared at 16:06:20. New output just appeared at 16:06:20. `stg_common__flowsheets` completed — **10.2 billion rows**, 3.3 TiB processed in 23 minutes. Now `observation_1_src_prepped` and a measurement unit test are starting. The build is progressing through the remaining upstream models. Still need `person_4_filtered` before `death_4_filtered` can run. Good progress — measurement unit tests are passing. `observation_1_src_prepped` is building in parallel. Let me keep monitoring. Measurement unit tests are all passing sequentially. `observation_1_src_prepped` is still building in parallel. Let me keep polling. All measurement unit tests passed. Now `tmp__meas_1_src_prepped` is starting to build (the actual table, very large). `tmp__observation_1_src_prepped` is still running in parallel. These are deep upstream models — still several stages before `person_4_filtered` → `death_4_filtered`. Let me keep waiting. Both `tmp__meas_1_src_prepped` and `tmp__observation_1_src_prepped` are still building — these are massive tables with prod data. Let me check the latest tail. `tmp__meas_1_src_prepped` has been building for ~7 minutes — measurement tables are among the largest in the pipeline. Continuing to wait. 12 minutes on `tmp__meas_1_src_prepped` and `tmp__observation_1_src_prepped` — these are the two largest tables in the pipeline. Heartbeat alive at 16:20. 16 minutes on `tmp__meas_1_src_prepped` / `tmp__observation_1_src_prepped`. These are the biggest models in the whole pipeline — measurement alone can be 1B+ rows at prod scale. Heartbeat alive at 16:24. 18 minutes on `tmp__meas_1_src_prepped` — still building. This model processes the full measurement staging table which was 955M rows. At prod scale with BigQuery joins and transformations, this can easily take 20-30 minutes. Heartbeat is still alive. 22+ minutes on `tmp__meas_1_src_prepped` — this is the single largest model in the pipeline. Let me check for any new output. Still building. Let me continue polling. Still building. Let me continue polling. New output at 16:37:43! New output at 16:37:43! `tmp__observation_1_src_prepped` completed — **7.2 billion rows**, 2.1 TiB, took ~31 minutes. `tmp__observation_2_src_mapped` is now starting. `tmp__meas_1_src_prepped` is still building (~29 min so far). Progress is moving — once these complete, the pipeline will move through the `_2_src_mapped` → `_3_all_with_keys` → `_4_filtered` stages, eventually reaching `person_4_filtered` → `death_4_filtered`.
        """ + String(repeating: " Let me keep monitoring. Heartbeat is alive.", count: 12)

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText == "This run produced a long progress log. Open Diagnostics for the raw output.")
        #expect(!output.displayText.contains("Last update:"))
        #expect(!output.displayText.contains("observation_1_src_prepped"))
        #expect(!output.displayText.contains("3.3 TiB"))
        #expect(!output.displayText.contains("Let me keep monitoring"))
        #expect(!output.displayText.contains("**10.2"))
    }

    @Test("Running output is treated as progress until the run completes")
    func runningOutputIsTreatedAsProgressUntilCompletion() {
        let task = makeTask(goal: "Original goal", status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        run.output = "Reading the file before answering."
        let event = makeEvent(
            task: task,
            type: "agent.response",
            payload: "Reading the file before answering.",
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [event],
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText.isEmpty)
        #expect(output.progressMessages.map(\.text) == ["Reading the file before answering."])
    }

    @Test("Progress messages dedupe adjacent normalized events while preserving source IDs")
    func progressMessagesDedupeAdjacentNormalizedEventsWhilePreservingSourceIDs() {
        let task = makeTask(goal: "Original goal", status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        run.output = "Reading the file before answering."

        let first = makeEvent(
            task: task,
            type: "agent.response",
            payload: "Reading the file before answering.",
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )
        let duplicate = makeEvent(
            task: task,
            type: "agent.response",
            payload: "\nReading the file before answering.\n",
            timestamp: Date(timeIntervalSince1970: 116),
            run: run
        )
        let next = makeEvent(
            task: task,
            type: "agent.response",
            payload: "Now checking the generated report.",
            timestamp: Date(timeIntervalSince1970: 117),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [first, duplicate, next],
            runs: [run]
        )

        let output = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))
        #expect(output.displayText.isEmpty)
        #expect(output.progressMessages.map(\.text) == [
            "Reading the file before answering.",
            "Now checking the generated report."
        ])
        #expect(output.progressMessages.map(\.id) == [first.id, next.id])
        #expect(output.progressMessages.map(\.timestamp) == [first.timestamp, next.timestamp])
    }

    @Test("Latest agent plan derives from newest ARP todo.replace event")
    func latestAgentPlanDerivesFromProtocolEvents() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let firstPayload = AstraRunProtocolParsedEvent.valid(.todoReplace(items: [
            AstraRunProtocolEvent.TodoItem(text: "Old step", status: .pending)
        ])).normalizedPayload
        let secondPayload = AstraRunProtocolParsedEvent.valid(.todoReplace(items: [
            AstraRunProtocolEvent.TodoItem(text: "Inspect", status: .done),
            AstraRunProtocolEvent.TodoItem(text: "Test", status: .pending)
        ])).normalizedPayload

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [
                makeEvent(task: task, type: "astra.todo.replace", payload: firstPayload, timestamp: Date(timeIntervalSince1970: 1), run: run),
                makeEvent(task: task, type: "astra.todo.replace", payload: secondPayload, timestamp: Date(timeIntervalSince1970: 2), run: run)
            ],
            runs: [run]
        )

        #expect(snapshot.latestAgentPlanItems.map(\.text) == ["Inspect", "Test"])
        #expect(snapshot.latestAgentPlanItems.map(\.isDone) == [true, false])
        #expect(snapshot.protocolState(for: run).todoItems.map(\.text) == ["Inspect", "Test"])
    }

    @Test("Latest agent plan survives the transcript event window")
    func latestAgentPlanSurvivesTranscriptEventWindow() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let planPayload = AstraRunProtocolParsedEvent.valid(.todoReplace(items: [
            AstraRunProtocolEvent.TodoItem(text: "Keep this plan", status: .pending)
        ])).normalizedPayload
        var events = [makeEvent(
            task: task,
            type: "astra.todo.replace",
            payload: planPayload,
            timestamp: Date(timeIntervalSince1970: 1),
            run: run
        )]

        for index in 0...1_200 {
            events.append(makeEvent(
                task: task,
                type: "agent.response",
                payload: "Later transcript event \(index)",
                timestamp: Date(timeIntervalSince1970: Double(index + 2)),
                run: run
            ))
        }
        task.runs = [run]
        task.events = events

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.events.count == 1_201)
        #expect(snapshot.latestAgentPlanItems.map(\.text) == ["Keep this plan"])
        #expect(snapshot.protocolState(for: run).todoItems.map(\.text) == ["Keep this plan"])
    }

    @Test("Conversation includes run with ARP completion even when output is empty")
    func protocolCompletionCreatesConversationItem() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal")
        task.createdAt = createdAt
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.completedAt = Date(timeIntervalSince1970: 120)
        run.output = ""

        let payload = AstraRunProtocolParsedEvent.valid(.complete(
            summary: "Implementation complete.",
            verifiedBy: "swift test"
        )).normalizedPayload
        let event = makeEvent(
            task: task,
            type: "astra.complete",
            payload: payload,
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [event],
            runs: [run]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected agent response for protocol-only completion")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.protocolState(for: run).completionSummary == "Implementation complete.")
        #expect(snapshot.protocolState(for: run).verifiedBy == "swift test")
    }

    @Test("Large snapshot fixture preserves per-run activity grouping")
    func largeSnapshotFixture() {
        let task = makeTask()
        let runCount = 750
        var runs: [TaskRun] = []
        var events: [TaskEvent] = []
        runs.reserveCapacity(runCount)
        events.reserveCapacity(runCount * 4)

        for index in 0..<runCount {
            let baseTimestamp = Double(index * 10)
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: baseTimestamp)
            run.completedAt = Date(timeIntervalSince1970: baseTimestamp + 5)
            run.output = "Run output \(index)"
            runs.append(run)

            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 1),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Bash",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 2),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 3),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.result",
                payload: "result \(index)",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 4),
                run: run
            ))
        }

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events.reversed(),
            runs: runs.reversed()
        )

        #expect(snapshot.sortedRuns.count == runCount)
        #expect(snapshot.sortedEvents.count == runCount * 4)
        #expect(snapshot.conversationItems.count == runCount + 1)

        for index in stride(from: 0, to: runCount, by: 125) {
            let activity = snapshot.activity(for: runs[index])
            #expect(activity.tools == [
                TaskToolSummary(name: "Read", count: 2),
                TaskToolSummary(name: "Bash", count: 1)
            ])
            #expect(activity.toolResults.count == 1)
            #expect(activity.toolResults.first?.payload == "result \(index)")
        }
    }

    @Test("Async snapshot builder preserves conversation and activity")
    func asyncSnapshotBuilder() async throws {
        let task = makeTask(goal: "Original goal")
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 10)
        run.completedAt = Date(timeIntervalSince1970: 20)
        run.output = "Done"

        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: 11),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.result",
                payload: "read result",
                timestamp: Date(timeIntervalSince1970: 12),
                run: run
            )
        ]

        let snapshot = try await TaskThreadSnapshot.buildAsync(
            input: TaskThreadSnapshotInput(
                goal: task.goal,
                createdAt: task.createdAt,
                events: events,
                runs: [run]
            ),
            fields: [:]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected async snapshot to include the run response")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.activity(for: responseRun).tools == [
            TaskToolSummary(name: "Read", count: 1)
        ])
        #expect(snapshot.activity(for: responseRun).toolResults.first?.payload == "read result")
    }

    @Test("Production snapshot builder cancels obsolete CPU work before serial replacement")
    func productionSnapshotBuilderCancellationIsBounded() async throws {
        await TaskThreadSnapshot.resetBuildConcurrencyStatsForTesting()
        let task = makeTask(goal: "Obsolete transcript")
        let payload = String(repeating: "streaming markdown | value | ```swift\n", count: 1_024)
        let events = (0..<1_200).map { index in
            makeEvent(
                task: task,
                type: "user.message",
                payload: "\(index) \(payload)",
                timestamp: Date(timeIntervalSince1970: Double(index)),
                run: nil
            )
        }
        let obsoleteInput = TaskThreadSnapshotInput(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: []
        )
        let obsolete = Task {
            try await TaskThreadSnapshot.buildAsync(input: obsoleteInput, fields: [:])
        }

        try await Task.sleep(for: .milliseconds(2))
        obsolete.cancel()
        let replacement = try await TaskThreadSnapshot.buildAsync(
            input: TaskThreadSnapshotInput(goal: "Latest", createdAt: .now, events: [], runs: []),
            fields: [:]
        )

        do {
            _ = try await obsolete.value
            Issue.record("The obsolete production snapshot build should terminate with cancellation")
        } catch is CancellationError {
            // Expected: the coordinator's cancellation reached CPU construction.
        }
        let stats = await TaskThreadSnapshot.buildConcurrencyStatsForTesting()
        #expect(replacement.conversationItems.count == 1)
        #expect(stats.active == 0)
        #expect(stats.maximum == 1)
        #expect(stats.cancelled == 1)
    }

    @Test("Huge single item in one window does not block another window executor")
    func productionSnapshotExecutorsAreWindowIsolated() async throws {
        let barrier = SnapshotBuildCancellationBarrier()
        let blockedWindow = TaskThreadSnapshotBuildExecutor {
            barrier.checkpoint()
        }
        let otherWindow = TaskThreadSnapshotBuildExecutor()
        let task = makeTask(goal: "Huge transcript")
        let hugePayload = String(repeating: "| cell | ```swift\n", count: 1_000_000)
        let hugeEvent = makeEvent(
            task: task,
            type: "user.message",
            payload: hugePayload,
            timestamp: .now,
            run: nil
        )
        let obsolete = Task {
            try await blockedWindow.build(
                input: TaskThreadSnapshotInput(
                    goal: task.goal,
                    createdAt: task.createdAt,
                    events: [hugeEvent],
                    runs: []
                ),
                fields: [:],
                responsivenessContext: nil,
                admittedAt: DispatchTime.now().uptimeNanoseconds
            )
        }

        await Task.detached { barrier.waitUntilEntered() }.value
        // Executor A is synchronously held inside its admitted build. Executor
        // B must remain independently runnable while A cannot make progress.
        let replacement = try await otherWindow.build(
            input: TaskThreadSnapshotInput(goal: "Other window", createdAt: .now, events: [], runs: []),
            fields: [:],
            responsivenessContext: nil,
            admittedAt: DispatchTime.now().uptimeNanoseconds
        )

        #expect(replacement.conversationItems.count == 1)
        obsolete.cancel()
        barrier.releaseBuild()
        do {
            _ = try await obsolete.value
            Issue.record("The obsolete huge-item build should observe cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("Huge obsolete run output yields promptly to its serial replacement")
    func hugeRunOutputCancellationYieldsToReplacement() async throws {
        let executor = TaskThreadSnapshotBuildExecutor()
        let task = makeTask(goal: "Huge run output")
        let run = TaskRun(task: task)
        run.output = String(repeating: "ordinary streamed output without protocol markers\n", count: 1_000_000)
        task.runs.append(run)
        let obsolete = Task {
            try await executor.build(
                input: TaskThreadSnapshotInput(task: task),
                fields: [:],
                responsivenessContext: nil,
                admittedAt: DispatchTime.now().uptimeNanoseconds
            )
        }

        try await Task.sleep(for: .milliseconds(2))
        obsolete.cancel()
        let replacementStartedAt = ContinuousClock.now
        let replacement = try await executor.build(
            input: TaskThreadSnapshotInput(goal: "Latest", createdAt: .now, events: [], runs: []),
            fields: [:],
            responsivenessContext: nil,
            admittedAt: DispatchTime.now().uptimeNanoseconds
        )
        let replacementDuration = replacementStartedAt.duration(to: .now)

        #expect(replacement.conversationItems.count == 1)
        #expect(replacementDuration < .milliseconds(250))
        do {
            _ = try await obsolete.value
            Issue.record("The obsolete huge run-output build should observe cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("Task snapshot input windows long histories for app rendering")
    func taskSnapshotInputWindowsLongHistories() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for runIndex in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(runIndex * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(runIndex * 100 + 90))
            run.output = "run \(runIndex)"
            task.runs.append(run)

            for resultIndex in 0..<20 {
                task.events.append(makeEvent(
                    task: task,
                    type: "tool.result",
                    payload: "result \(runIndex)-\(resultIndex)",
                    timestamp: Date(timeIntervalSince1970: Double(runIndex * 100 + resultIndex)),
                    run: run
                ))
            }
        }

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.totalRunCount == 100)
        #expect(input.omittedRunCount > 0)
        #expect(input.runs.count < 100)
        #expect(input.totalEventCount == 2_000)
        #expect(input.omittedEventCount > 0)
        #expect(snapshot.latestRun?.output == "run 99")
        #expect(!snapshot.sortedRuns.contains { $0.output == "run 0" })

        let latestActivity = snapshot.latestRun.map { snapshot.activity(for: $0) } ?? .empty
        #expect(latestActivity.toolResults.count <= 12)
        #expect(latestActivity.toolResults.last?.payload == "result 99-19")
    }
}

extension TaskThreadSnapshotTests {
    @Test("Plan-created task does not render the goal bubble twice")
    func planCreatedTaskDoesNotDuplicateGoalBubble() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Create a report page")
        task.createdAt = createdAt

        let planUser = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Create a report page",
            timestamp: Date(timeIntervalSince1970: 101)
        )
        let planAssistant = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.assistantMessage,
            payload: "Two quick questions before you approve",
            timestamp: Date(timeIntervalSince1970: 102)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [planUser, planAssistant],
            runs: []
        )

        let userBubbles = snapshot.conversationItems.filter {
            switch $0 {
            case .userMessage, .planUserMessage: return true
            default: return false
            }
        }
        #expect(userBubbles.count == 1)
        if let firstBubble = userBubbles.first, case .planUserMessage(let text, _) = firstBubble {
            #expect(text == "Create a report page")
        } else {
            Issue.record("expected the plan user message to be the only user bubble")
        }
    }

    @Test("Distinct goal keeps the synthesized goal bubble alongside plan messages")
    func distinctGoalKeepsGoalBubble() {
        let task = makeTask(goal: "Broader objective")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let planUser = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "A narrower refinement",
            timestamp: Date(timeIntervalSince1970: 101)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [planUser],
            runs: []
        )

        let userBubbles = snapshot.conversationItems.filter {
            switch $0 {
            case .userMessage, .planUserMessage: return true
            default: return false
            }
        }
        #expect(userBubbles.count == 2)
    }
}
