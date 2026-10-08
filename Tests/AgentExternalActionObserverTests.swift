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
        "Recognised commands with an external effect",
        arguments: [
            ("git push -u origin feature", AgentExternalActionObserver.Action.push),
            (#"{"command":"gh pr create --draft --title Fix","description":"Open PR"}"#, .pullRequest(verb: "create")),
            ("cd repo && gh pr merge 12 --squash", .pullRequest(verb: "merge")),
            ("gh pr comment 12 --body 'Thanks'", .pullRequest(verb: "comment")),
            ("gh issue create --title Bug", .issue(verb: "create")),
            ("gh release create v1.2.0", .release),
            ("gh api repos/acme/widgets/pulls/12/comments -X POST -f body=hi", .api(method: "POST")),
            ("gh api --method=DELETE repos/acme/widgets/git/refs/heads/old", .api(method: "DELETE")),
            ("gh api repos/acme/widgets/issues/3/comments -f body=hi", .api(method: "POST")),
            ("/bin/zsh -lc 'git push origin main'", .push),
            ("env GIT_TRACE=1 git -C repo push", .push),
            (#"echo "pushed: $(git push origin main)""#, .push),
            (#"{"command":"gh pr create --draft --title 'A very long title that the recorder cut"#, .pullRequest(verb: "create")),
            ("gh pr ready 12 --undo", .pullRequest(verb: "draft")),
            ("gh api repos/o/r/issues/1/comments -fbody=hello", .api(method: "POST")),
            ("git send-pack git@github.com:owner/repo.git refs/heads/main", .push),
            ("env -u CI git push origin main", .push),
            ("timeout 30 gh pr create --fill", .pullRequest(verb: "create")),
            ("bash -c 'git push origin main'", .push),
            ("printf 'origin main' | xargs git push", .push),
            ("curl -d x https://hooks.example.test/build", .externalWrite(executable: "curl", destination: "hooks.example.test")),
            ("curl -XPOST https://hooks.example.test/build", .externalWrite(executable: "curl", destination: "hooks.example.test"))
        ]
    )
    func recognisedCommands(command: String, expected: AgentExternalActionObserver.Action) {
        #expect(AgentExternalActionObserver.classify(command) == expected)
    }

    @Test(
        "Reads and local Git are not external actions",
        arguments: [
            "git status", "git commit -m 'push the fix'", "gh pr view 12", "gh pr list",
            "gh api repos/acme/widgets/pulls/12", "gh issue list", "echo gh-pr-create", "git log --grep push",
            "rg 'git push' .", "echo 'gh pr create'", #"grep -n "gh api -X POST" docs/notes.md"#,
            #"printf '%s\n' "git push origin main""#, #"{"command":"rg -n 'gh release create' scripts"}"#,
            "git push --dry-run origin main", "git push -n", "gh api -X GET search/issues -f q=bug",
            "gh api --method=GET search/issues -f q=bug", "curl https://example.test/status"
        ]
    )
    func readsAreNotActions(command: String) {
        #expect(AgentExternalActionObserver.classify(command) == nil)
    }

    @Test("A compound command records every action it ran, in order")
    func compoundCommandsRecordEveryAction() {
        #expect(AgentExternalActionObserver.actions(in: "git push -u origin fix && gh pr create --fill")
            == [.push, .pullRequest(verb: "create")])
        #expect(AgentExternalActionObserver.title(for: .pullRequest(verb: "draft"), url: "https://github.com/a/b/pull/7")
            == "Converted pull request #7 to draft")
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
        ).isEmpty, "the push failed even though the read's success came first")

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

    @Test("A failed or unanswered command is not recorded")
    func failedCommandsAreNotRecorded() throws {
        let fixture = try ObserverFixture()
        fixture.toolCall("Using tool: Bash: gh pr create --title Fix", result: "pull request create failed", failed: true, at: 1)
        fixture.toolCall("Using tool: Bash: git push", result: nil, at: 3)

        #expect(AgentExternalActionObserver.recordObservedActions(
            task: fixture.task, run: fixture.run, modelContext: fixture.context, policyLevel: .autonomous
        ).isEmpty)
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
