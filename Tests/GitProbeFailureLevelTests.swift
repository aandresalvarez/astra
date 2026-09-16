import Foundation
import Testing
@testable import ASTRA

/// Some git commands are questions, not orders. A branch with no upstream, a
/// ref that does not exist, a directory that is not a repository — git exits
/// non-zero and that *is* the answer. The process transport logged every
/// non-zero exit at ERROR anyway, so the caller three frames up recorded the
/// outcome at `.debug` while the log recorded a failure.
/// `failureLogLevel` lets the caller's judgment reach the log line.
@Suite("Git probe failure level")
struct GitProbeFailureLevelTests {

    @Test("A probe's expected non-zero exit is not an error")
    func probeFailuresAreNotErrors() async throws {
        let entries = try await failureEntries(failureLogLevel: .debug)

        #expect(!entries.isEmpty, "The command must actually have failed for this to prove anything")
        #expect(entries.allSatisfy { $0.logLevel == .debug })
    }

    /// The default is unchanged: a command whose failure is genuinely a failure
    /// still reaches the channel people read.
    @Test("Commands that did not opt out still log at error")
    func defaultFailuresRemainErrors() async throws {
        let entries = try await failureEntries(failureLogLevel: nil)

        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.logLevel == .error })
    }

    /// The state the change is actually for, reproduced end to end rather than
    /// asserted about the transport in isolation: a real repository on a branch
    /// with no upstream, which every branch is until it is first pushed. Three
    /// of the converted call sites ask git about that upstream, git exits 128
    /// with "no upstream configured", and each of them turns that into an
    /// ordinary `false`/`nil` — while the transport underneath filed an ERROR.
    @Test("Upstream probes on an unpublished branch answer without filing errors")
    func unpublishedBranchProbesAreQuiet() async throws {
        // The branch name is the marker: git echoes it into the stderr the
        // transport logs, which is what isolates these lines from any other
        // suite's git output.
        let branch = "astra-noupstream-\(UUID().uuidString.prefix(8).lowercased())"
        let repository = try makeTemporaryRepository(onBranch: branch)
        defer { try? FileManager.default.removeItem(atPath: repository) }

        // Opened before the probes run: it collects what it is sent, so
        // anything logged earlier is not in it.
        let capture = LogCapture()

        let hasUpstream = await GitService.shared.hasUpstream(at: repository)
        let upstreamRef = await GitService.shared.getUpstreamBranchRef(at: repository)
        let aheadBehind = await GitService.shared.getAheadBehind(at: repository)

        #expect(hasUpstream == false)
        #expect(upstreamRef == nil)
        #expect(aheadBehind == nil)

        let entries = capture.entries { $0.category == "Git" && $0.message.contains(branch) }
        #expect(!entries.isEmpty, "git must actually have refused for this to prove anything")
        #expect(entries.allSatisfy { $0.logLevel == .debug })
    }

    /// A repository whose only commit is empty, on a branch that was never
    /// published. `GitLocalEnvironment.scrubbing` is not optional here: the test
    /// suite can run from a git hook, and an inherited `GIT_DIR` would point
    /// `git init` at the real repository instead of this fixture.
    private func makeTemporaryRepository(onBranch branch: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-probe-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
        git init -b \(branch) && \
        git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' \
        commit --allow-empty -m 'init'
        """]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitProbeFailureLevelTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize temp git repo at \(path)"
            ])
        }
        return path
    }

    /// Runs a git command guaranteed to exit non-zero and returns only the
    /// transport's own failure lines for *this* invocation.
    ///
    /// The marker rides in the arguments, which the transport echoes into the
    /// message, so the assertions never see a concurrently-running suite's git
    /// output — and this suite never has to reset the shared log buffer out
    /// from under one.
    private func failureEntries(failureLogLevel: LogLevel?) async throws -> [LogEntry] {
        // Short on purpose: `LogSanitizer` redacts any 40+ character run of
        // word characters, which a full UUID in this position would trip.
        let marker = "astra-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(marker)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = LogCapture()

        // Not a repository, so this exits 128 whatever the ref is.
        let arguments = ["rev-parse", "--verify", "--quiet", marker]
        await #expect(throws: (any Error).self) {
            if let failureLogLevel {
                _ = try await GitService.shared.runGit(
                    at: directory.path,
                    arguments: arguments,
                    failureLogLevel: failureLogLevel
                )
            } else {
                _ = try await GitService.shared.runGit(at: directory.path, arguments: arguments)
            }
        }

        return capture.entries {
            $0.category == "Git"
                && $0.message.contains("git command failed")
                && $0.message.contains(marker)
        }
    }
}

/// Collects log entries as they are emitted instead of reading them back out
/// of `AppLogger.entries` afterwards.
///
/// `entries` is a 2000-line ring buffer shared by the entire process, and the
/// test binary is one process running hundreds of suites in parallel. Between
/// the probe and the read-back, other suites can emit 2000 lines and evict the
/// ones being asserted on — a marker in the message keeps this suite from
/// reading *someone else's* line, but nothing keeps its own line from being
/// dropped. `unpublishedBranchProbesAreQuiet` lost that race in a full run
/// while passing in isolation, which is the signature; it runs a `git init`
/// and three probes, so it holds the widest window of the three.
///
/// `appLoggerDidAppendEntry` is what `LogViewerView` already listens to, so
/// this needs no test-only seam in `AppLogger`. It is posted synchronously
/// from `emit`, on the thread that logged: `GitProcessState.consumeOutcome`
/// logs the failure and then returns it to the awaiting caller, so every line
/// a probe produced is already collected by the time `await` resumes. Nothing
/// here is bounded, so nothing can be evicted.
private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [LogEntry] = []
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .appLoggerDidAppendEntry,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let entry = notification.userInfo?["entry"] as? LogEntry else { return }
            // The post is synchronous on the logging thread, and every suite in
            // the binary logs, so this runs concurrently and needs the lock.
            self.lock.lock()
            defer { self.lock.unlock() }
            self.collected.append(entry)
        }
    }

    func entries(matching isIncluded: (LogEntry) -> Bool) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return collected.filter(isIncluded)
    }

    // `[weak self]` above keeps the observer token from retaining this back
    // into a cycle, so the capture really is torn down at end of scope.
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
