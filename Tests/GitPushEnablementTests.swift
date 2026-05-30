import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Regression coverage for pushing/publishing from the Repository panel.
///
/// Guards the fix for: a committed branch with a clean working tree (and, in
/// particular, a branch that has never been published) must still be pushable.
/// Previously push enablement depended solely on `ahead`, which is 0 whenever no
/// upstream is configured, so an unpublished branch could never be pushed.
@Suite("Git Push Enablement")
struct GitPushEnablementTests {

    // MARK: - Helpers

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return Int(process.terminationStatus)
    }

    private func makeTempGitRepo() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-push-repo-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let initCommand = """
        git init -b work && \
        git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' \
        commit --allow-empty -m 'init'
        """
        let exitCode = runShell(initCommand, in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitPushEnablementTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize temp git repo at \(path)"
            ])
        }
        return path
    }

    private func makeBareRemote() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-push-remote-\(UUID().uuidString).git", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let exitCode = runShell("git init --bare", in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitPushEnablementTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize bare remote at \(path)"
            ])
        }
        return path
    }

    private func commit(file: String, in repo: String) {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(file)
        try? "content-\(UUID().uuidString)".write(to: url, atomically: true, encoding: .utf8)
        _ = runShell(
            "git add \(file) && git -c commit.gpgsign=false -c user.name='ASTRA Tests' "
            + "-c user.email='astra-tests@example.invalid' commit -m 'change \(file)'",
            in: repo
        )
    }

    // MARK: - ViewModel push-enablement logic

    @MainActor
    @Test("canPush requires a remote and unpushed work")
    func canPushLogic() {
        let vm = WorkspaceGitViewModel()

        // No remote at all → never pushable, regardless of ahead.
        vm.hasRemote = false; vm.hasUpstream = true; vm.ahead = 3
        #expect(vm.canPush == false)

        // Remote + upstream + commits ahead → pushable, count from `ahead`.
        vm.hasRemote = true; vm.hasUpstream = true; vm.ahead = 2; vm.unpushedCount = 0
        #expect(vm.pushableCommitCount == 2)
        #expect(vm.canPush == true)

        // Remote + upstream but in sync → not pushable.
        vm.ahead = 0
        #expect(vm.canPush == false)

        // Remote but no upstream (unpublished) with unpushed commits → pushable,
        // count from `unpushedCount`.
        vm.hasUpstream = false; vm.unpushedCount = 4
        #expect(vm.pushableCommitCount == 4)
        #expect(vm.canPush == true)

        // Remote, no upstream, nothing unpushed → not pushable.
        vm.unpushedCount = 0
        #expect(vm.canPush == false)
    }

    @MainActor
    @Test("Clean unpublished branch can still open the commit/push sheet")
    func canOpenSheetForUnpublishedCleanBranch() {
        let vm = WorkspaceGitViewModel()
        vm.statusFiles = []          // working tree clean
        vm.hasRemote = true
        vm.hasUpstream = false       // never published
        vm.unpushedCount = 1

        #expect(vm.hasChanges == false)
        #expect(vm.canPush == true)
        #expect(vm.canOpenCommitSheet == true)
    }

    @MainActor
    @Test("Clean branch in sync with remote cannot open the sheet")
    func cannotOpenSheetWhenInSync() {
        let vm = WorkspaceGitViewModel()
        vm.statusFiles = []
        vm.hasRemote = true
        vm.hasUpstream = true
        vm.ahead = 0
        vm.unpushedCount = 0

        #expect(vm.canOpenCommitSheet == false)
    }

    // MARK: - GitService integration

    @Test("Unpushed count and remote detection track publish state")
    func unpushedCountTracksPublishState() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let remote = try makeBareRemote()
        defer { try? FileManager.default.removeItem(atPath: remote) }

        // No remote configured yet.
        let hasRemoteBefore = await GitService.shared.hasRemote(at: repo)
        #expect(hasRemoteBefore == false)

        #expect(runShell("git remote add origin '\(remote)'", in: repo) == 0)
        let hasRemoteAfter = await GitService.shared.hasRemote(at: repo)
        #expect(hasRemoteAfter == true)

        // Remote exists but branch not published: there is unpushed work and no upstream.
        let branch = await GitService.shared.getCurrentBranch(at: repo)
        #expect(branch == "work")
        let unpushedBeforePublish = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedBeforePublish >= 1)
        let upstreamBeforePublish = await GitService.shared.hasUpstream(at: repo)
        #expect(upstreamBeforePublish == false)

        // Publishing sets the upstream and clears unpushed work.
        try await GitService.shared.pushSetUpstream(branch: branch, at: repo)
        let upstreamAfterPublish = await GitService.shared.hasUpstream(at: repo)
        #expect(upstreamAfterPublish == true)
        let unpushedAfterPublish = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedAfterPublish == 0)

        // A new local commit becomes unpushed again.
        commit(file: "feature.txt", in: repo)
        let unpushedAfterCommit = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedAfterCommit == 1)
    }
}
