import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Git Credential Context Resolver")
struct GitCredentialContextResolverTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("SSH remotes grant only Git config, host verification, and selected identities")
    func sshRemoteResolvesNarrowCredentialFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        try write("""
        [include]
            path = ~/included.gitconfig
        """, to: home.appendingPathComponent(".gitconfig"))
        try write("[credential]\nhelper = osxkeychain\n", to: home.appendingPathComponent("included.gitconfig"))
        try write("[user]\nname = Astra\n", to: home.appendingPathComponent(".config/git/config"))
        try write("""
        Host github.com
            IdentityFile ~/.ssh/id_ed25519
            UserKnownHostsFile ~/.ssh/github_known_hosts
        Host *
            IdentityFile ~/.ssh/fallback
        """, to: home.appendingPathComponent(".ssh/config"))
        try write("github.com ssh-ed25519 AAAA\n", to: home.appendingPathComponent(".ssh/known_hosts"))
        try write("github.com ssh-ed25519 BBBB\n", to: home.appendingPathComponent(".ssh/github_known_hosts"))
        try write("not-a-key", to: home.appendingPathComponent(".ssh/github_known_hosts.pub"))
        try write("private", to: home.appendingPathComponent(".ssh/id_ed25519"))
        try write("public", to: home.appendingPathComponent(".ssh/id_ed25519.pub"))
        try write("unused", to: home.appendingPathComponent(".ssh/id_rsa"))
        try write("""
        [remote "origin"]
            url = git@github.com:susom/astra.git
        """, to: git.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(context.transports == [.ssh])
        #expect(context.readablePaths.contains(home.appendingPathComponent(".gitconfig").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent("included.gitconfig").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".config/git/config").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/config").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/known_hosts").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/github_known_hosts").path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".ssh/github_known_hosts.pub").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/id_ed25519").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/id_ed25519.pub").path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".ssh/id_rsa").path))
        #expect(!context.readablePaths.contains(git.appendingPathComponent("config").path))
    }

    @Test("SSH global options before the first Host block apply to all remote hosts")
    func sshRemoteResolvesGlobalOptionsBeforeFirstHostBlock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        try write("""
        IdentityFile ~/.ssh/global_ed25519
        UserKnownHostsFile ~/.ssh/global_known_hosts
        Host gitlab.com
            IdentityFile ~/.ssh/gitlab_ed25519
        """, to: home.appendingPathComponent(".ssh/config"))
        try write("github.com ssh-ed25519 BBBB\n", to: home.appendingPathComponent(".ssh/global_known_hosts"))
        try write("private", to: home.appendingPathComponent(".ssh/global_ed25519"))
        try write("public", to: home.appendingPathComponent(".ssh/global_ed25519.pub"))
        try write("private", to: home.appendingPathComponent(".ssh/gitlab_ed25519"))
        try write("""
        [remote "origin"]
            url = git@github.com:susom/astra.git
        """, to: git.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/global_known_hosts").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/global_ed25519").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/global_ed25519.pub").path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".ssh/gitlab_ed25519").path))
        #expect(!context.diagnostics.contains("ssh_default_identities"))
    }

    @Test("HTTPS remotes include credential helper state without SSH files")
    func httpsRemoteResolvesCredentialHelperFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        try write("[credential]\nhelper = osxkeychain\n", to: home.appendingPathComponent(".gitconfig"))
        try write("token", to: home.appendingPathComponent(".git-credentials"))
        try write("hosts.yml", to: home.appendingPathComponent(".config/gh/hosts.yml"))
        try write("keychain", to: home.appendingPathComponent("Library/Keychains/login.keychain-db"))
        try write("ssh", to: home.appendingPathComponent(".ssh/known_hosts"))
        try write("""
        [remote "origin"]
            url = https://github.com/susom/astra.git
        """, to: git.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(context.transports == [.https])
        #expect(context.readablePaths.contains(home.appendingPathComponent(".gitconfig").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".git-credentials").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".config/gh").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent("Library/Keychains/login.keychain-db").path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".ssh/known_hosts").path))
    }

    @Test("Worktrees grant the external git admin directories as writable roots")
    func worktreeResolvesExternalGitAdminWritableRoots() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let main = root.appendingPathComponent("main", isDirectory: true)
        let commonGit = main.appendingPathComponent(".git", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let worktreeGit = commonGit.appendingPathComponent("worktrees/worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try write("gitdir: \(worktreeGit.path)\n", to: worktree.appendingPathComponent(".git"))
        try write("../..\n", to: worktreeGit.appendingPathComponent("commondir"))
        try write("""
        [remote "origin"]
            url = git@github.com:susom/astra.git
        """, to: commonGit.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: worktree.path,
            homeDirectory: home.path
        )

        #expect(context.transports == [.ssh])
        #expect(context.writablePaths.contains(worktreeGit.path))
        #expect(context.writablePaths.contains(commonGit.path))
    }

    @Test("Clone intent resolves credential context before a repository exists")
    func cloneIntentWithoutRepositoryResolvesCredentialContext() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try write("[user]\nname = Astra\n", to: home.appendingPathComponent(".gitconfig"))
        try write("""
        Host github.com
            IdentityFile ~/.ssh/id_ed25519
        """, to: home.appendingPathComponent(".ssh/config"))
        try write("github.com ssh-ed25519 AAAA\n", to: home.appendingPathComponent(".ssh/known_hosts"))
        try write("private", to: home.appendingPathComponent(".ssh/id_ed25519"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: workspace.path,
            intentText: "git clone git@github.com:susom/astra.git",
            homeDirectory: home.path
        )

        #expect(context.transports == [.ssh])
        #expect(context.diagnostics.contains("intent_remotes_without_repository"))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".gitconfig").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/config").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/known_hosts").path))
        #expect(context.readablePaths.contains(home.appendingPathComponent(".ssh/id_ed25519").path))
        #expect(context.writablePaths.isEmpty)
    }

    @Test("includeIf gitdir only loads matching conditional config")
    func includeIfGitdirOnlyLoadsMatchingConfig() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let matchingParent = root.appendingPathComponent("matching", isDirectory: true)
        let otherParent = root.appendingPathComponent("other", isDirectory: true)
        let repo = matchingParent.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        let always = home.appendingPathComponent("always.gitconfig")
        let matching = home.appendingPathComponent("matching.gitconfig")
        let unmatched = home.appendingPathComponent("unmatched.gitconfig")
        try write("""
        [include]
            path = ~/always.gitconfig
        [includeIf "gitdir:\(matchingParent.path)/"]
            path = ~/matching.gitconfig
        [includeIf "gitdir:\(otherParent.path)/"]
            path = ~/unmatched.gitconfig
        """, to: home.appendingPathComponent(".gitconfig"))
        try write("[user]\nname = Always\n", to: always)
        try write("[user]\nemail = matching@example.com\n", to: matching)
        try write("[user]\nemail = unmatched@example.com\n", to: unmatched)
        try write("""
        [remote "origin"]
            url = git@github.com:susom/astra.git
        """, to: git.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(context.readablePaths.contains(always.path))
        #expect(context.readablePaths.contains(matching.path))
        #expect(!context.readablePaths.contains(unmatched.path))
    }

    @Test("includeIf gitdir trailing slash preserves directory boundary")
    func includeIfGitdirTrailingSlashPreservesDirectoryBoundary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let matchingParent = root.appendingPathComponent("matching", isDirectory: true)
        let siblingParent = root.appendingPathComponent("matching-other", isDirectory: true)
        let repo = siblingParent.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        let matching = home.appendingPathComponent("matching.gitconfig")
        try write("""
        [includeIf "gitdir:\(matchingParent.path)/"]
            path = ~/matching.gitconfig
        """, to: home.appendingPathComponent(".gitconfig"))
        try write("[credential]\nhelper = osxkeychain\n", to: matching)
        try write("""
        [remote "origin"]
            url = https://github.com/susom/astra.git
        """, to: git.appendingPathComponent("config"))

        let context = GitCredentialContextResolver.sandboxContext(
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(!context.readablePaths.contains(matching.path))
    }

    @Test("Local Git inspection projects config without credential files")
    func localGitInspectionProjectsConfigOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)

        let included = home.appendingPathComponent("diff-options.gitconfig")
        try write("""
        [include]
            path = ~/diff-options.gitconfig
        """, to: home.appendingPathComponent(".gitconfig"))
        try write("[diff]\nstatGraphWidth = 80\n", to: included)
        try write("[remote \"origin\"]\nurl = git@github.com:susom/astra.git\n", to: git.appendingPathComponent("config"))
        try write("secret", to: home.appendingPathComponent(".ssh/id_ed25519"))
        try write("token", to: home.appendingPathComponent(".git-credentials"))

        let task = AgentTask(title: "Review diff", goal: "Verify no unrelated files")
        let context = GitCredentialContextResolver.runtimeSandboxContext(
            prompt: "git diff --stat",
            task: task,
            contextText: "",
            repositoryPath: repo.path,
            homeDirectory: home.path
        )

        #expect(context.transports.isEmpty)
        #expect(context.diagnostics == ["local_git_config"])
        #expect(context.readablePaths.contains(home.appendingPathComponent(".gitconfig").path))
        #expect(context.readablePaths.contains(included.path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".ssh/id_ed25519").path))
        #expect(!context.readablePaths.contains(home.appendingPathComponent(".git-credentials").path))
        #expect(context.writablePaths.isEmpty)
    }

    @Test("Network Git intent detection handles commands and plain English")
    func gitNetworkIntentDetection() {
        let task = AgentTask(title: "Sync", goal: "Please pull from GitHub before editing.")
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(prompt: "", task: task))
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "run git fetch origin main",
            task: AgentTask(title: "Other", goal: "Other")
        ))
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "git clone git@github.com:susom/astra.git",
            task: AgentTask(title: "Other", goal: "Other")
        ))
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "please clone the repo from GitHub",
            task: AgentTask(title: "Other", goal: "Other")
        ))
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "ok lets pull the latest code from main, then create a new branch",
            task: AgentTask(title: "Other", goal: "Other")
        ))
        #expect(GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "update from main before editing STAR-12262",
            task: AgentTask(title: "Other", goal: "Other")
        ))
        #expect(!GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: "inspect the local diff",
            task: AgentTask(title: "Review", goal: "No network")
        ))
        #expect(GitOperationIntentDetector.detectsLocalGitInspectionOperation(
            prompt: "git diff --stat",
            task: AgentTask(title: "Review", goal: "No network")
        ))
        #expect(GitOperationIntentDetector.detectsRuntimeGitOperation(
            prompt: "inspect the local diff",
            task: AgentTask(title: "Review", goal: "No network")
        ))
    }

    @Test("GitHub metadata intent prefers host control without hiding native transport")
    func githubMetadataIntentPrefersHostControlWithoutHidingNativeTransport() {
        let metadataTask = AgentTask(
            title: "Review PR metadata",
            goal: "Use GitHub to inspect pull request metadata and checks"
        )

        #expect(GitOperationIntentDetector.detectsGitHubMetadataOrAPIIntent(
            prompt: "",
            task: metadataTask,
            contextText: "Use GitHub to list open pull requests and check statuses."
        ))
        #expect(GitOperationIntentDetector.routesGitHubMetadataThroughHostControl(
            prompt: "",
            task: metadataTask,
            contextText: "Use GitHub to list open pull requests and check statuses.",
            hostControlGitHubAvailable: true
        ))
        #expect(!GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "",
            task: metadataTask,
            contextText: "Use GitHub to list open pull requests and check statuses.",
            prefersHostControlGitHub: true
        ))
        #expect(GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "gh pr view 190 --json title",
            task: AgentTask(title: "Native gh", goal: "Use gh"),
            prefersHostControlGitHub: false
        ))
        #expect(!GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "gh pr view 190 --json title",
            task: AgentTask(title: "Host GitHub", goal: "Use GitHub"),
            prefersHostControlGitHub: true
        ))
        #expect(GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "run native gh pr view 190 --json title",
            task: AgentTask(title: "Native gh", goal: "Use native gh"),
            prefersHostControlGitHub: true
        ))
        #expect(GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "gh auth status",
            task: AgentTask(title: "Check auth", goal: "Check GitHub CLI authentication state"),
            prefersHostControlGitHub: true
        ))
        #expect(!GitOperationIntentDetector.routesGitHubMetadataThroughHostControl(
            prompt: "gh auth status",
            task: AgentTask(title: "Check auth", goal: "Check GitHub CLI authentication state"),
            hostControlGitHubAvailable: true
        ))
        #expect(GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "git pull origin main",
            task: AgentTask(title: "Native Git", goal: "Sync branch"),
            prefersHostControlGitHub: true
        ))
        #expect(!GitOperationIntentDetector.routesGitHubMetadataThroughHostControl(
            prompt: "Fix UI issues and run local checks",
            task: AgentTask(title: "Fix UI issues", goal: "Fix UI issues and run local checks"),
            hostControlGitHubAvailable: true
        ))
        #expect(!GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "go through PR comments in the local notes",
            task: AgentTask(title: "Review notes", goal: "Go through PR comments"),
            prefersHostControlGitHub: false
        ))
    }
}
