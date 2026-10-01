import Testing
@testable import ASTRA

@Suite("Git polling log policy")
struct GitPollingLogPolicyTests {
    @Test("The panel's read-only status queries are not logged per poll", arguments: [
        ["worktree", "list", "--porcelain"],
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        ["rev-list", "--left-right", "--count", "@{u}...HEAD"],
        ["rev-list", "--count", "HEAD", "--not", "--remotes"],
        ["remote"],
        ["branch", "--show-current"],
        ["branch", "--format=%(refname:short)"],
        ["--no-optional-locks", "status", "--porcelain=v1", "-z"],
        ["--no-optional-locks", "diff", "--numstat"],
        ["--no-optional-locks", "diff", "--cached", "--numstat"]
    ])
    func readOnlyQueriesAreQuiet(arguments: [String]) {
        #expect(GitPollingLogPolicy.isReadOnlyPollQuery(arguments))
    }

    @Test("Commands that change anything are still logged", arguments: [
        ["commit", "-m", "x"],
        ["push", "origin", "main"],
        ["checkout", "main"],
        ["branch", "-D", "old"],
        ["branch", "new-feature"],
        ["remote", "add", "origin", "url"],
        ["worktree", "add", "../w"],
        ["fetch"]
    ])
    func mutatingCommandsAreLogged(arguments: [String]) {
        #expect(!GitPollingLogPolicy.isReadOnlyPollQuery(arguments))
    }

    @Test("A repeated lookup outcome is quiet and a change is reported")
    func lookupOutcomeLogsOnlyOnChange() {
        let outcomes = GitPollingLogPolicy.LookupOutcomes()
        #expect(outcomes.recordChanged(key: "r|main", outcome: "none"))
        #expect(!outcomes.recordChanged(key: "r|main", outcome: "none"))
        #expect(outcomes.recordChanged(key: "r|main", outcome: "found:12"))
        #expect(!outcomes.recordChanged(key: "r|main", outcome: "found:12"))
        #expect(outcomes.recordChanged(key: "r|other", outcome: "none"))
    }
}

@Suite("Git polling suspension")
@MainActor
struct GitPollingSuspensionTests {
    @Test("Polling resumes only when the last reason clears")
    func resumesOnlyWhenEveryReasonClears() {
        let suspension = GitPollingSuspension(observeSystem: false)
        var resumes = 0
        suspension.onResume = { resumes += 1 }

        suspension.begin(.screenLocked)
        suspension.begin(.displaySleep)
        #expect(suspension.isSuspended)

        suspension.end(.displaySleep)
        #expect(suspension.isSuspended)
        #expect(resumes == 0)

        suspension.end(.screenLocked)
        #expect(!suspension.isSuspended)
        #expect(resumes == 1)

        suspension.end(.screenLocked)
        #expect(resumes == 1)
    }
}
