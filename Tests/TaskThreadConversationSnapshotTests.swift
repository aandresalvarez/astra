import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

extension TaskThreadSnapshotTests {
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
        if case .systemInfo(let text, _) = snapshot.conversationItems[1] {
            #expect(text == "Plan execution stopped.")
        } else {
            Issue.record("Expected plan failure notice")
        }
        if case .scheduleResult(let text, _) = snapshot.conversationItems[2] {
            #expect(text.contains("Failed to create routine"))
        } else {
            Issue.record("Expected schedule failure notice")
        }
        if case .systemInfo(let text, _) = snapshot.conversationItems[3] {
            #expect(text.contains("Memory saved"))
        } else {
            Issue.record("Expected memory confirmation notice")
        }
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
            permissionMode: PermissionPolicy.restricted.rawValue,
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

        #expect(presentation.issues.isEmpty)
        #expect(presentation.technicalOutputs.count == 1)
        #expect(presentation.technicalOutputs.first?.title == "Run stopped details")
        #expect(presentation.technicalOutputs.first?.rawPayload.contains("raw stack output") == true)
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
        #expect(presentation.technicalOutputs.first?.title == "Budget warning details")
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
            if case .systemInfo(let text, _) = $0 {
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
    func asyncSnapshotBuilder() async {
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

        let snapshot = await TaskThreadSnapshot.buildAsync(
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
