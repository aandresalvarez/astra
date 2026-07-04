import Foundation
import Testing
@testable import ASTRA

/// Regression coverage for the `.git/config` corruption incident: a `git push`
/// (which runs `.githooks/pre-push` -> `script/prepush.sh` -> `swift test`)
/// reproducibly left `core.bare = true` in the shared repository's config.
///
/// Root cause: git exports repo-scoping variables (`GIT_DIR`, `GIT_WORK_TREE`,
/// etc.) into every hook's environment. Test fixture helpers spawn `git`/a
/// shell against a throwaway temp directory via `currentDirectoryURL`/`-C`, but
/// if they inherit the ambient process environment verbatim, a leaked
/// `GIT_DIR` overrides that path — so e.g. `GitPushEnablementTests`'
/// `git init --bare` (meant to create a disposable fake remote) actually
/// reinitializes whatever repository `GIT_DIR` points to as bare instead,
/// which is exactly how the real repo's `.git/config` got corrupted.
///
/// `GitLocalEnvironment.scrubbing` strips those variables before every fixture
/// subprocess launches. These tests prove both halves: the leak is real
/// without scrubbing, and scrubbing neutralizes it.
@Suite("Git Local Environment Scrubbing")
struct GitLocalEnvironmentScrubbingTests {

    // MARK: - Helpers

    private func makeTempDir(_ prefix: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    private func run(_ command: String, in directory: String, environment: [String: String]) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return Int(process.terminationStatus)
        } catch {
            return -1
        }
    }

    private func isBare(gitDir: String) -> Bool {
        let config = (try? String(contentsOfFile: "\(gitDir)/config", encoding: .utf8)) ?? ""
        return config.contains("bare = true")
    }

    // MARK: - Tests

    @Test("scrubbing removes every git repo-scoping variable")
    func scrubbingRemovesLocalVars() {
        var polluted = ProcessInfo.processInfo.environment
        for name in GitLocalEnvironment.variableNames {
            polluted[name] = "/tmp/should-not-survive"
        }

        let scrubbed = GitLocalEnvironment.scrubbing(polluted)

        for name in GitLocalEnvironment.variableNames {
            #expect(scrubbed[name] == nil)
        }
    }

    @Test("scrubbing leaves unrelated environment variables untouched")
    func scrubbingPreservesOtherVariables() {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment["GIT_DIR"] = "/tmp/leaked"

        let scrubbed = GitLocalEnvironment.scrubbing(environment)

        #expect(scrubbed["PATH"] == "/usr/bin:/bin")
        #expect(scrubbed["GIT_DIR"] == nil)
    }

    @Test("an unscrubbed leaked GIT_DIR lets `git init --bare` corrupt the real repo instead of the intended fixture (documents the incident)")
    func unscrubbedAmbientGitDirCorruptsTheRealRepo() throws {
        let realRepo = try makeTempDir("astra-env-scrub-real")
        let fixture = try makeTempDir("astra-env-scrub-fixture")
        defer {
            try? FileManager.default.removeItem(atPath: realRepo)
            try? FileManager.default.removeItem(atPath: fixture)
        }

        #expect(run("git init -q", in: realRepo, environment: ProcessInfo.processInfo.environment) == 0)
        #expect(isBare(gitDir: "\(realRepo)/.git") == false)

        var leaked = ProcessInfo.processInfo.environment
        leaked["GIT_DIR"] = "\(realRepo)/.git"

        // This mirrors GitPushEnablementTests.makeBareRemote(): the caller
        // believes it is initializing a disposable bare remote at `fixture`,
        // but an unscrubbed ambient GIT_DIR silently redirects git there.
        #expect(run("git init --bare -q", in: fixture, environment: leaked) == 0)

        #expect(isBare(gitDir: "\(realRepo)/.git"), "leaked GIT_DIR should have flipped the real repo's core.bare to true")
        #expect(!FileManager.default.fileExists(atPath: "\(fixture)/config"), "fixture never actually received the bare init")
    }

    @Test("GitLocalEnvironment.scrubbing neutralizes the leaked GIT_DIR so `git init --bare` targets only the intended fixture")
    func scrubbedFixtureInitIgnoresLeakedGitDir() throws {
        let realRepo = try makeTempDir("astra-env-scrub-real")
        let fixture = try makeTempDir("astra-env-scrub-fixture")
        defer {
            try? FileManager.default.removeItem(atPath: realRepo)
            try? FileManager.default.removeItem(atPath: fixture)
        }

        #expect(run("git init -q", in: realRepo, environment: GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)) == 0)
        #expect(isBare(gitDir: "\(realRepo)/.git") == false)

        var leaked = ProcessInfo.processInfo.environment
        leaked["GIT_DIR"] = "\(realRepo)/.git"
        leaked["GIT_WORK_TREE"] = fixture

        #expect(run("git init --bare -q", in: fixture, environment: GitLocalEnvironment.scrubbing(leaked)) == 0)

        #expect(isBare(gitDir: "\(realRepo)/.git") == false, "the real repo must stay untouched")
        #expect(isBare(gitDir: fixture), "the fixture directory itself should have received the bare init")
    }
}
