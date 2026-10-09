import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// In Auto the agent can push and open pull requests with its own `git` and
/// `gh`. The chat still has to show what was done on the user's behalf, so the
/// run's own successful tool calls are recorded at the boundary. These pin what
/// counts, what does not, and that Ask records nothing (its guard asked first).
@Suite("Agent external action observer")
@MainActor
struct AgentExternalActionObserverTests {
    @Test(
        "One recognised command gets its action's title",
        arguments: [
            ("git push -u origin feature", AgentExternalActionObserver.Action.push),
            (#"{"command":"gh pr create --draft --title Fix","description":"Open PR"}"#, .pullRequest(verb: "create")),
            ("gh pr merge 12 --squash", .pullRequest(verb: "merge")),
            ("gh pr comment 12 --body 'Thanks'", .pullRequest(verb: "comment")),
            ("gh issue create --title Bug", .issue(verb: "create")),
            ("gh release create v1.2.0", .release),
            ("gh api repos/acme/widgets/pulls/12/comments -X POST -f body=hi", .api(method: "POST")),
            ("gh api --method=DELETE repos/acme/widgets/git/refs/heads/old", .api(method: "DELETE")),
            ("gh api repos/acme/widgets/issues/3/comments -f body=hi", .api(method: "POST")),
            ("gh api repos/o/r/issues/1/comments -fbody=hello", .api(method: "POST")),
            ("/bin/zsh -lc 'git push origin main'", .push),
            ("git -C repo push", .push),
            ("gh pr ready 12 --undo", .pullRequest(verb: "draft"))
        ]
    )
    func recognisedCommands(command: String, expected: AgentExternalActionObserver.Action) {
        #expect(AgentExternalActionObserver.recordedAction(in: command) == expected)
    }

    // Auto records what Ask would have asked about (`LocalShellCommands`). A
    // call that is more than one recognised command is recorded as the
    // command it ran: a runner, a pipe, `|| true` or a dry run can mean the
    // action never happened, so the record never claims it did.
    @Test(
        "Anything else that is not known local work is recorded as the command it ran",
        arguments: [
            "cd repo && gh pr merge 12 --squash", "env -u CI git push origin main", "printf 'origin main' | xargs git push",
            "xargs -r git push origin main </dev/null", "git push origin main || true", "git push origin main &",
            #"echo "pushed: $(git push origin main)""#, "git push --dry-run origin main", "bash -c 'git push origin main'",
            "curl -d x https://hooks.example.test/build", "gh gist create notes.md",
            "node --eval='require(\"child_process\").execSync(\"git push origin main\")'", "npm --scope @foo publish",
            "DOCKER_HOST=ssh://deploy@prod docker create alpine", "python3 -c 'print(1)'"
        ]
    )
    func otherCommandsAreRecordedAsRun(command: String) {
        #expect(AgentExternalActionObserver.recordedAction(in: command) == .command(command))
    }

    @Test(
        "Known local work is not recorded",
        arguments: [
            "git status", "git commit -m 'push the fix'", "gh pr view 12", "gh pr list",
            "gh api repos/acme/widgets/pulls/12", "gh issue list", "echo gh-pr-create", "git log --grep push",
            "rg 'git push' .", "echo 'gh pr create'", #"grep -n "gh api -X POST" docs/notes.md"#,
            #"printf '%s\n' "git push origin main""#, #"{"command":"rg -n 'gh release create' scripts"}"#,
            "gh api -X GET search/issues -f q=bug", "gh api --method=GET search/issues -f q=bug",
            "curl https://example.test/status", "swift test --filter Observer", "python3 scripts/report.py"
        ]
    )
    func localWorkIsNotRecorded(command: String) {
        #expect(AgentExternalActionObserver.recordedAction(in: command) == nil)
    }

    @Test("A command's record names it and where it went")
    func commandRecordsNameTheCommand() {
        let curl = AgentExternalActionObserver.Action.command("curl -d x https://hooks.example.test/build")
        #expect(AgentExternalActionObserver.title(for: curl, url: nil) == "Ran `curl`")
        // Only names reach the title: arguments can carry a token or a header.
        let secret = AgentExternalActionObserver.Action.command("curl -H 'Authorization: Bearer SECRET' -X POST https://hooks.example.test")
        #expect(!AgentExternalActionObserver.title(for: secret, url: nil).contains("SECRET"))
        #expect(AgentExternalActionObserver.title(for: .command("gh gist create notes.md"), url: nil) == "Ran `gh gist create`")
        #expect(AgentExternalActionObserver.destination(for: curl, url: nil, result: "") == "hooks.example.test")
        let gist = AgentExternalActionObserver.Action.command("gh gist create notes.md")
        #expect(AgentExternalActionObserver.destination(for: gist, url: nil, result: "") == "gh")
        #expect(AgentExternalActionObserver.title(for: .pullRequest(verb: "draft"), url: "https://github.com/a/b/pull/7")
            == "Converted pull request #7 to draft")
        // A command's row links where it went, without credentials or query.
        let hook = "curl -d x https://bot:secret@hooks.example.test/build?token=abc"
        #expect(AgentExternalActionObserver.actionURLs(for: [.command(hook)], output: "ok", command: hook, host: nil)
            == ["https://hooks.example.test/build"])
        #expect(AgentExternalActionObserver.actionURLs(for: [.command("ssh deploy@host")], output: "", command: "ssh deploy@host", host: nil)
            == [nil])
        // A summary the recorder cut mid-quote cannot be read as one command.
        #expect(AgentExternalActionObserver.recordedAction(
            in: #"{"command":"gh pr create --draft --title 'A very long title that the recorder cut"#
        ) == .command("gh pr create --draft --title 'A very long title that the recorder cut"))
    }

    @Test("Each action of a compound call gets its own link, or none")
    func compoundActionsGetTheirOwnLinks() {
        let output = "https://github.com/acme/widgets/issues/7\nhttps://github.com/acme/widgets/pull/8\n"
        #expect(AgentExternalActionObserver.actionURLs(
            for: [.pullRequest(verb: "create"), .issue(verb: "create")], output: output, command: "", host: nil
        ) == ["https://github.com/acme/widgets/pull/8", "https://github.com/acme/widgets/issues/7"])
        #expect(AgentExternalActionObserver.actionURLs(
            for: [.push, .pullRequest(verb: "create")], output: "https://github.com/acme/widgets/issues/7", command: "", host: nil
        ) == [nil, nil], "no link of its own kind is no link, not another action's")
    }

    @Test("A compound call is one record with the link it printed")
    func compoundCallsAreOneRecord() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: Bash: git push -u origin fix && gh pr create --fill",
                         result: "https://github.com/acme/widgets/pull/34\n", at: 1)
        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.map(\.title) == ["Ran `git push`, `gh pr create`"])
        #expect(observed.map(\.url) == ["https://github.com/acme/widgets/pull/34"])
    }

    @Test("A GitHub Enterprise action names its host, not GitHub")
    func enterpriseActionsNameTheirHost() {
        let api = "gh api --hostname ghe.example --method DELETE repos/acme/widgets/git/refs/heads/old"
        let apiHost = AgentExternalActionObserver.enterpriseGitHub(in: api)
        #expect(apiHost?.host == "ghe.example")
        #expect(AgentExternalActionObserver.destination(for: .api(method: "DELETE"), url: nil, result: "", enterprise: apiHost)
            == "ghe.example")
        let create = "gh pr create -R ghe.example/acme/widgets --fill"
        let printed = "https://ghe.example/acme/widgets/pull/7\n"
        let host = AgentExternalActionObserver.enterpriseGitHub(in: create)
        let url = AgentExternalActionObserver.firstGitHubURL(in: printed, host: host?.host)
        #expect(url == "https://ghe.example/acme/widgets/pull/7")
        #expect(AgentExternalActionObserver.destination(for: .pullRequest(verb: "create"), url: url, result: printed, enterprise: host)
            == "ghe.example/acme/widgets")
        #expect(AgentExternalActionObserver.enterpriseGitHub(in: "gh pr create --fill") == nil)
    }

    // A batch answers calls in its own order. A failure names the call it
    // belongs to, so it is never read as another call's success or failure.
    @Test("A batch's results are matched to their own calls")
    func batchResultsMatchTheirCalls() throws {
        let failedPush = try ObserverFixture()
        failedPush.toolCall("Using tool: Bash: git push origin main", result: nil, at: 1)
        failedPush.toolCall("Using tool: Read: notes.md", result: "notes", at: 2)
        failedPush.failure(of: "Using tool: Bash: git push origin main", message: "rejected", at: 4)
        #expect(AgentExternalActionObserver.recordObservedActions(
            task: failedPush.task, run: failedPush.run, modelContext: failedPush.context, policyLevel: .autonomous
        ).map(\.title) == ["Ran `git push`, which exited with an error"],
                "the push failed even though the read's success came first, and is recorded as failed")

        let pushAfterFailedRead = try ObserverFixture()
        pushAfterFailedRead.toolCall("Using tool: Read: missing.md", result: nil, at: 1)
        pushAfterFailedRead.toolCall("Using tool: Bash: git push origin main", result: nil, at: 2)
        pushAfterFailedRead.failure(of: "Using tool: Read: missing.md", message: "no such file", at: 3)
        let ok = TaskEvent(task: pushAfterFailedRead.task, eventType: TaskEventTypes.Tool.result,
                           payload: "To github.com:acme/widgets.git", run: pushAfterFailedRead.run)
        ok.timestamp = Date(timeIntervalSince1970: 4)
        pushAfterFailedRead.context.insert(ok)
        #expect(AgentExternalActionObserver.recordObservedActions(
            task: pushAfterFailedRead.task, run: pushAfterFailedRead.run,
            modelContext: pushAfterFailedRead.context, policyLevel: .autonomous
        ).map(\.title) == ["Pushed commits"], "the read's failure is not the push's")
    }

    // Successful results carry no call id, so the recorder keeps a marker
    // naming the call; a batch answered out of order, and a write that printed
    // nothing, are each recorded against their own call.
    @Test("Recorded results pair with their own calls, out of order and silent")
    func recordedResultsPairWithTheirCalls() throws {
        let fixture = try ObserverFixture()
        let state = AgentEventRecordingState()
        func record(_ event: AgentEvent) {
            AgentEventRecorder.recordClaudeEvent(event, to: fixture.task, run: fixture.run,
                                                 modelContext: fixture.context, recordingState: state)
        }
        record(.toolUse(name: "Bash", id: "issue", inputSummary: "gh issue create --title Bug"))
        record(.toolUse(name: "Bash", id: "pr", inputSummary: "gh pr create --fill"))
        record(.toolUse(name: "Bash", id: "delete", inputSummary: "gh api -X DELETE repos/acme/widgets/git/refs/heads/old --silent"))
        record(.toolResult(id: "pr", content: "https://github.com/acme/widgets/pull/34\n", isError: false))
        record(.toolResult(id: "issue", content: "https://github.com/acme/widgets/issues/7\n", isError: false))
        record(.toolResult(id: "delete", content: "", isError: false))

        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.map(\.title) == ["Opened issue #7", "Opened pull request #34", "Sent a GitHub API DELETE request"])
        #expect(observed.map(\.url) == [
            "https://github.com/acme/widgets/issues/7", "https://github.com/acme/widgets/pull/34", nil
        ])
    }

    // The event keeps 300 characters; the record reads the whole call.
    @Test("An action past the event's first 300 characters is still recorded")
    func longCommandsAreRecordedWhole() throws {
        let fixture = try ObserverFixture()
        let state = AgentEventRecordingState()
        let long = "echo \(String(repeating: "x ", count: 200)) && git push origin main"
        AgentEventRecorder.recordClaudeEvent(.toolUse(name: "Bash", id: "long", inputSummary: long),
                                             to: fixture.task, run: fixture.run, modelContext: fixture.context, recordingState: state)
        AgentEventRecorder.recordClaudeEvent(.toolResult(id: "long", content: "To github.com:acme/widgets.git", isError: false),
                                             to: fixture.task, run: fixture.run, modelContext: fixture.context, recordingState: state)

        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.count == 1)
        #expect(observed.first?.title == "Ran `git push`")
    }

    @Test("An SSH push links its GitHub repository")
    func sshPushLinksTheRepository() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: Bash: git push origin main", result: "To git@github.com:acme/widgets.git\n   1a..2b  main -> main", at: 1)
        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.map(\.url) == ["https://github.com/acme/widgets"])
        #expect(AgentExternalActionObserver.pushGitHubRepository(in: "To git@gitlab.com:group/project.git") == nil)
    }

    // Auto lets the browser MCP tool change a page without asking; the
    // record says so, as the command the gate would have asked about.
    @Test("A browser page change through the MCP tool is recorded in Auto")
    func browserMCPChangesAreRecorded() throws {
        let tool = BrowserBridgeMCPProjection.providerToolPermission
        let summary = AgentEventRecordingPresentation.toolInputSummary(
            name: tool, input: ["command": "click", "arguments": ["selector": "button.primary"]]
        )
        #expect(summary == "astra-browser click --selector 'button.primary'")
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: \(tool): \(summary ?? "")", result: "clicked", at: 1)
        fixture.toolCall("Using tool: \(tool): astra-browser read-page", result: "page", at: 3)
        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.map(\.title) == ["Ran `astra-browser click`"], "a read is local and not recorded")
    }

    @Test("Only shell tools count; a file that mentions a command did nothing")
    func onlyShellToolsCount() {
        #expect(AgentExternalActionObserver.shellCommandText(fromToolUsePayload: "Using tool: Bash: gh pr create") == "gh pr create")
        #expect(AgentExternalActionObserver.shellCommandText(fromToolUsePayload: "Using tool: command_execution: git push") == "git push")
        #expect(AgentExternalActionObserver.shellCommandText(fromToolUsePayload: "Using tool: Write: docs/release.md gh pr create") == nil)
    }

    @Test("Auto records a successful push and pull request with the printed link, once")
    func autoRecordsSuccessfulActions() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: Bash: git push -u origin fix-login", result: "To github.com:acme/widgets.git", at: 1)
        fixture.toolCall(
            "Using tool: Bash: gh pr create --draft --title 'Fix login'",
            result: "https://github.com/acme/widgets/pull/34\n",
            at: 3
        )

        let observed = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(observed.map(\.title) == ["Pushed commits", "Opened pull request #34"])
        #expect(observed.last?.url == "https://github.com/acme/widgets/pull/34")
        #expect(observed.last?.destination == "acme/widgets")

        let records = TaskThreadSnapshot(goal: "", createdAt: Date(timeIntervalSince1970: 0), events: fixture.task.events, runs: [])
            .conversationItems
            .compactMap { item -> ExternalActionRecord? in
                if case .externalAction(let record) = item { return record }
                return nil
            }
        #expect(records.map(\.authorization) == [.agentObserved, .agentObserved])
        #expect(records.allSatisfy { ExternalActionRecordPresentation.provenancePill(for: $0.authorization) == "Agent" })

        let again = AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )
        #expect(again.isEmpty, "a second pass over the same run records nothing new")
    }

    // `git push` goes to whatever remote it names; only `gh` is GitHub by
    // definition. The row reads Git's own `To <remote>` line.
    @Test(
        "A push names the remote it went to",
        arguments: [
            ("To github.com:acme/widgets.git\n   1a2b..3c4d  main -> main", "acme/widgets"),
            ("To https://gitlab.com/group/project.git\n * [new branch] fix -> fix", "gitlab.com/group/project"),
            ("To ssh://git@git.internal:2222/team/repo.git\n", "git.internal/team/repo"),
            ("Everything up-to-date", "Git remote")
        ]
    )
    func pushNamesItsRemote(result: String, expected: String) {
        #expect(AgentExternalActionObserver.destination(for: .push, url: nil, result: result) == expected)
    }

    @Test("A gh command without a link still names GitHub")
    func ghCommandFallsBackToGitHub() {
        #expect(AgentExternalActionObserver.destination(for: .release, url: nil, result: "v1.2.0") == "GitHub")
    }

    // An Auto-sent Jira issue or an agent-opened PR exists only in its receipt
    // after the turn; the next turn's own context has to carry it.
    @Test("A follow-up prompt carries the actions recorded on the task")
    func followUpPromptCarriesRecordedActions() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall(
            "Using tool: Bash: gh pr create --draft --title 'Fix login'",
            result: "https://github.com/acme/widgets/pull/34\n",
            at: 1
        )
        AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        )

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Comment on the PR you opened", task: fixture.task)
        #expect(prompt.contains("Opened pull request #34 (acme/widgets): https://github.com/acme/widgets/pull/34"))
    }

    // A failed call may have acted partway (`curl -d … ; false`), so it is
    // recorded as failed — never as the action it tried; an unanswered one
    // is not evidence of anything.
    @Test("A failed command is recorded as failed; an unanswered one is not recorded")
    func failedCommandsAreRecordedAsFailed() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: Bash: gh pr create --title Fix", result: "pull request create failed", failed: true, at: 1)
        fixture.toolCall("Using tool: Bash: git push", result: nil, at: 3)

        #expect(AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        ).map(\.title) == ["Ran `gh pr create`, which exited with an error"])

        // With result markers each call pairs only with its own marker, so a
        // failure needs one too, next to a success that has one.
        let marked = try ObserverFixture()
        let state = AgentEventRecordingState()
        AgentEventRecorder.recordClaudeEvent(.toolUse(name: "Bash", id: "pr", inputSummary: "gh pr create --fill"),
            to: marked.task, run: marked.run, modelContext: marked.context, recordingState: state)
        AgentEventRecorder.recordClaudeEvent(.toolResult(id: "pr", content: "https://github.com/acme/widgets/pull/9\n", isError: false),
            to: marked.task, run: marked.run, modelContext: marked.context, recordingState: state)
        AgentEventRecorder.recordClaudeEvent(.toolUse(name: "Bash", id: "hook",
            inputSummary: "curl -d payload https://hooks.example.test/build; false"),
            to: marked.task, run: marked.run, modelContext: marked.context, recordingState: state)
        AgentEventRecorder.recordClaudeEvent(.toolResult(id: "hook", content: "exit 1", isError: true),
            to: marked.task, run: marked.run, modelContext: marked.context, recordingState: state)
        #expect(AgentExternalActionObserver.recordObservedActions(
            task: marked.task, run: marked.run, modelContext: marked.context, policyLevel: .autonomous
        ).map(\.title) == ["Opened pull request #9", "Ran `curl`, which exited with an error"])
    }

    @Test("Ask and Custom record nothing")
    func askRecordsNothing() throws {
        for level in [AgentPolicyLevel.review, .custom] {
            let fixture = try ObserverFixture()
            fixture.toolCall("Using tool: Bash: gh pr create", result: "https://github.com/acme/widgets/pull/1", at: 1)
            #expect(AgentExternalActionObserver.recordObservedActions(
                task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: level
            ).isEmpty, "\(level.rawValue)")
        }
    }
}

@MainActor
private final class ObserverFixture {
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask
    let run: TaskRun

    init() throws {
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        task = AgentTask(title: "Ship it", goal: "Push the fix and open a PR")
        run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
    }

    func failure(of use: String, message: String, at seconds: TimeInterval) {
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.resultFailed,
            payload: TaskEvent.payloadString(ToolResultFailurePayload(toolID: "t", message: message, toolUseEvidence: use)),
            run: run
        )
        event.timestamp = Date(timeIntervalSince1970: seconds)
        context.insert(event)
    }

    func toolCall(_ use: String, result: String?, failed: Bool = false, at seconds: TimeInterval) {
        let useEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: use, run: run)
        useEvent.timestamp = Date(timeIntervalSince1970: seconds)
        context.insert(useEvent)
        guard let result else { return }
        let resultEvent = TaskEvent(
            task: task,
            eventType: failed ? TaskEventTypes.Tool.resultFailed : TaskEventTypes.Tool.result,
            payload: result,
            run: run
        )
        resultEvent.timestamp = Date(timeIntervalSince1970: seconds + 1)
        context.insert(resultEvent)
    }
}
