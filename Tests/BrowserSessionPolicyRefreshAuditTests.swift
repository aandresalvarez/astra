import Foundation
import Testing
@testable import ASTRA

/// The browser policy refresh fires on every `AgentTask.updatedAt` move, and in
/// production 98% of those fires resolved to the policy already in force. These
/// tests pin the two things that make the resulting log line worth reading: a
/// no-op has to be identifiable as one, and it has to stay off the info channel.
@Suite("Browser session policy refresh audit")
struct BrowserSessionPolicyRefreshAuditTests {

    private static let github = BrowserSessionPolicy(
        enabledBrowserAdapters: ["github"],
        githubReadOnlyMode: true
    )

    @Test("A refresh that resolves to the policy already in force is a debug no-op")
    func unchangedPolicyIsADebugNoOp() {
        let audit = BrowserSessionPolicyRefreshAudit(
            source: "task_event_inserted",
            previous: Self.github,
            published: Self.github,
            durationMilliseconds: 12.5
        )

        #expect(!audit.changed)
        #expect(audit.level == .debug)
        #expect(audit.fields["changed"] == "false")
    }

    /// The gate resets to `.failClosed` on `begin()`, so the comparison has to
    /// run against the last *published* policy. Nothing published yet is a real
    /// transition — the session's starting policy is worth one info line.
    @Test("The first publish of a session counts as a change")
    func firstPublishIsAChange() {
        let audit = BrowserSessionPolicyRefreshAudit(
            source: "appear",
            previous: nil,
            published: Self.github,
            durationMilliseconds: 3
        )

        #expect(audit.changed)
        #expect(audit.level == .info)
        #expect(audit.fields["changed"] == "true")
    }

    /// Either half of the policy moving is a transition. `githubReadOnlyMode` is
    /// the one a reader is most likely to be hunting for and the one an adapter
    /// list comparison alone would miss.
    @Test("Both halves of the policy are compared")
    func eitherHalfMovingIsAChange() {
        func audit(from previous: BrowserSessionPolicy, to published: BrowserSessionPolicy) -> BrowserSessionPolicyRefreshAudit {
            BrowserSessionPolicyRefreshAudit(
                source: "capability_toggled",
                previous: previous,
                published: published,
                durationMilliseconds: 0
            )
        }

        let writable = BrowserSessionPolicy(enabledBrowserAdapters: ["github"], githubReadOnlyMode: false)
        let extraAdapter = BrowserSessionPolicy(
            enabledBrowserAdapters: ["github", "linear"],
            githubReadOnlyMode: true
        )

        #expect(audit(from: Self.github, to: writable).changed)
        #expect(audit(from: Self.github, to: extraAdapter).changed)
        #expect(audit(from: .failClosed, to: .failClosed).changed == false)
    }

    /// The field names are the log's contract with whoever greps it, and
    /// `duration_ms` is fixed at two decimals so the column sorts as text.
    @Test("The emitted fields describe the published policy")
    func fieldsDescribeThePublishedPolicy() {
        let audit = BrowserSessionPolicyRefreshAudit(
            source: "workspace_changed",
            previous: .failClosed,
            published: BrowserSessionPolicy(
                enabledBrowserAdapters: ["github", "linear"],
                githubReadOnlyMode: false
            ),
            durationMilliseconds: 41.239
        )

        #expect(audit.fields == [
            "event": "browser_session_policy_refreshed",
            "source": "workspace_changed",
            "enabled_browser_adapters": "github,linear",
            "github_read_only_mode": "false",
            "changed": "true",
            "duration_ms": "41.24"
        ])
    }
}

/// "First publish is a change" is a claim about a *session*, and the view that
/// stores the previous policy outlives every session it observes. A bare
/// `BrowserSessionPolicy?` carried across a task switch made the new session's
/// opening line read as agreement with a policy that belonged to the task the
/// user had just left — and only when the two happened to be equal, which is
/// the common case, since most tasks resolve the same adapters. The baseline
/// line for the new session went missing exactly where task-scoped diagnostics
/// need it most.
@Suite("A published browser policy belongs to one session")
struct BrowserSessionPolicyPublicationTests {

    private static let github = BrowserSessionPolicy(
        enabledBrowserAdapters: ["github"],
        githubReadOnlyMode: true
    )
    private static let taskA = UUID()
    private static let taskB = UUID()
    private static let workspace = UUID()

    private static func publication(task: UUID?, workspace: UUID?) -> BrowserSessionPolicyPublication {
        BrowserSessionPolicyPublication(taskID: task, workspaceID: workspace, policy: github)
    }

    @Test("The same session reads back its own policy")
    func sameSessionSeesItsPreviousPolicy() {
        let published = Self.publication(task: Self.taskA, workspace: Self.workspace)

        #expect(published.policyForSession(taskID: Self.taskA, workspaceID: Self.workspace) == Self.github)
    }

    /// The regression, stated directly: an identical policy from another task
    /// must not answer as this task's previous one.
    @Test("Another task's identical policy is not a previous policy")
    func adifferentTaskGetsNoPreviousPolicy() {
        let published = Self.publication(task: Self.taskA, workspace: Self.workspace)

        #expect(published.policyForSession(taskID: Self.taskB, workspaceID: Self.workspace) == nil)
    }

    @Test("A workspace switch also starts a new session")
    func adifferentWorkspaceGetsNoPreviousPolicy() {
        let published = Self.publication(task: Self.taskA, workspace: Self.workspace)

        #expect(published.policyForSession(taskID: Self.taskA, workspaceID: UUID()) == nil)
    }

    /// No task selected is a session too, and it must not inherit from one that
    /// had a task.
    @Test("A session with no task does not inherit from one that had a task")
    func noTaskIsItsOwnSession() {
        let published = Self.publication(task: Self.taskA, workspace: Self.workspace)

        #expect(published.policyForSession(taskID: nil, workspaceID: Self.workspace) == nil)
        #expect(Self.publication(task: nil, workspace: Self.workspace)
            .policyForSession(taskID: nil, workspaceID: Self.workspace) == Self.github)
    }

    /// End to end through the audit, which is what actually reaches the log:
    /// the same policy is a debug no-op within a session and an info line when
    /// the session changed underneath it.
    @Test("A task switch restores the info-level baseline line")
    func taskSwitchIsAChangeEvenWhenThePolicyMatches() {
        let published = Self.publication(task: Self.taskA, workspace: Self.workspace)

        func audit(forTask task: UUID) -> BrowserSessionPolicyRefreshAudit {
            BrowserSessionPolicyRefreshAudit(
                source: "selected_task_changed",
                previous: published.policyForSession(taskID: task, workspaceID: Self.workspace),
                published: Self.github,
                durationMilliseconds: 1
            )
        }

        #expect(audit(forTask: Self.taskA).level == .debug)
        #expect(audit(forTask: Self.taskB).level == .info)
        #expect(audit(forTask: Self.taskB).changed)
    }
}
