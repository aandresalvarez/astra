import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Git pull request publication intent")
struct GitPullRequestPublicationIntentTests {
    @Test(
        "explicit PR authoring verbs request publication",
        arguments: [
            "Create a pull request for the fix",
            "Draft a PR for this change",
            "Drafting the pull request now",
            "Open a draft PR after the tests pass",
            "Publish the GitHub PR",
            "Raise a new pull request",
            "Submit the PR for review",
            "Create a PR with no reviewers assigned",
            "Review the changes and open a PR"
        ]
    )
    func explicitAuthoringIntent(text: String) {
        #expect(detect(text))
    }

    @Test(
        "PR metadata work does not request publication",
        arguments: [
            "Review pull request #42",
            "Review my open PRs",
            "Summarize the PR checks",
            "List open pull requests",
            "Inspect the GitHub PR metadata"
        ]
    )
    func metadataIntentDoesNotPublish(text: String) {
        #expect(!detect(text))
    }

    @Test(
        "negated PR authoring does not request publication",
        arguments: [
            "Do not create a pull request",
            "Implement the fix without opening a PR",
            "Never publish the pull request",
            "Do not draft a PR",
            "No PR should be submitted"
        ]
    )
    func negatedAuthoringIntentDoesNotPublish(text: String) {
        #expect(!detect(text))
    }

    private func detect(_ text: String) -> Bool {
        let task = AgentTask(title: "GitHub task", goal: text)
        return GitOperationIntentDetector.detectsPullRequestPublicationIntent(
            prompt: text,
            task: task,
            contextText: text
        )
    }
}
