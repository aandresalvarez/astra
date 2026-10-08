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
            (#"{"command":"gh pr create --draft --title 'A very long title that the recorder cut"#, .pullRequest(verb: "create"))
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
            #"printf '%s\n' "git push origin main""#, #"{"command":"rg -n 'gh release create' scripts"}"#
        ]
    )
    func readsAreNotActions(command: String) {
        #expect(AgentExternalActionObserver.classify(command) == nil)
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
