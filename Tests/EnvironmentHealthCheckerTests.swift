import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// MARK: - Stub runner

/// Stub BinaryRunner that returns canned results per (path, args) key.
/// Tests configure expectations up-front; the stub records calls so tests
/// can assert ordering (which → liveness → semantic).
actor StubBinaryRunner: BinaryRunner {
    struct Call: Equatable {
        let path: String
        let args: [String]
    }

    private var responses: [String: RunResult] = [:]
    private var calls: [Call] = []

    func setResponse(forKey key: String, result: RunResult) {
        responses[key] = result
    }

    func recordedCalls() -> [Call] { calls }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await record(path: path, args: args)
        return await response(for: key(path: path, args: args))
    }

    private func record(path: String, args: [String]) {
        calls.append(Call(path: path, args: args))
    }

    private func response(for key: String) -> RunResult {
        responses[key] ?? RunResult(
            outcome: .exited(code: 127),
            stdout: "",
            stderr: "stub: no response configured for \(key)"
        )
    }

    nonisolated private func key(path: String, args: [String]) -> String {
        "\(path) \(args.joined(separator: " "))"
    }
}

private func makeStub(responses: [(String, RunResult)]) async -> StubBinaryRunner {
    let stub = StubBinaryRunner()
    for (key, result) in responses {
        await stub.setResponse(forKey: key, result: result)
    }
    return stub
}

// MARK: - Health checker cases

@Suite("EnvironmentHealthChecker")
struct EnvironmentHealthCheckerTests {

    @Test("Missing binary when which exits non-zero")
    func missingBinary_whichFails() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which fakebin", RunResult(outcome: .exited(code: 1), stdout: "", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "fakebin")
        #expect(status == .missingBinary)
    }

    @Test("Missing binary when which succeeds but stdout is empty")
    func missingBinary_whichEmpty() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which fakebin", RunResult(outcome: .exited(code: 0), stdout: "   \n", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "fakebin")
        #expect(status == .missingBinary)
    }

    @Test("Healthy path + version when liveness exits 0")
    func healthy() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which gcloud",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/homebrew/bin/gcloud\n", stderr: "")),
            ("/opt/homebrew/bin/gcloud --version",
             RunResult(outcome: .exited(code: 0), stdout: "Google Cloud SDK 461.0.0\nbq 2.0.100\n", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "gcloud")
        guard case .healthy(let path, let version) = status else {
            Issue.record("Expected .healthy, got \(status)")
            return
        }
        #expect(path == "/opt/homebrew/bin/gcloud")
        #expect(version == "Google Cloud SDK 461.0.0")
    }

    @Test("Unresponsive when liveness times out")
    func unresponsive_timeout() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which gcloud",
             RunResult(outcome: .exited(code: 0), stdout: "/usr/local/bin/gcloud\n", stderr: "")),
            ("/usr/local/bin/gcloud --version",
             RunResult(outcome: .timedOut, stdout: "", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "gcloud", timeout: 2)
        guard case .unresponsive(let detail) = status else {
            Issue.record("Expected .unresponsive, got \(status)")
            return
        }
        #expect(detail.contains("timed out"))
    }

    @Test("Unresponsive when liveness exits non-zero")
    func unresponsive_nonZeroExit() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which broken",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/broken\n", stderr: "")),
            ("/opt/broken --version",
             RunResult(outcome: .exited(code: 2), stdout: "", stderr: "dylib not found: libfoo"))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "broken")
        guard case .unresponsive(let detail) = status else {
            Issue.record("Expected .unresponsive, got \(status)")
            return
        }
        #expect(detail.contains("exit 2"))
        #expect(detail.contains("dylib not found"))
    }

    @Test("Unresponsive when liveness fails to launch")
    func unresponsive_launchFailed() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which ghost",
             RunResult(outcome: .exited(code: 0), stdout: "/var/tmp/ghost\n", stderr: "")),
            ("/var/tmp/ghost --version",
             RunResult(outcome: .launchFailed("permission denied"), stdout: "", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(binary: "ghost")
        guard case .unresponsive(let detail) = status else {
            Issue.record("Expected .unresponsive, got \(status)")
            return
        }
        #expect(detail.contains("permission denied"))
    }

    @Test("Semantic stdoutNonEmpty: unauthenticated when stdout is blank")
    func semantic_unauthenticated() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which gcloud",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/homebrew/bin/gcloud\n", stderr: "")),
            ("/opt/homebrew/bin/gcloud auth list --format=value(account)",
             RunResult(outcome: .exited(code: 0), stdout: "\n", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(
            binary: "gcloud",
            livenessArgs: ["auth", "list", "--format=value(account)"],
            semantic: .stdoutNonEmpty
        )
        guard case .unauthenticated(let detail) = status else {
            Issue.record("Expected .unauthenticated, got \(status)")
            return
        }
        #expect(detail == "no active account")
    }

    @Test("Semantic stdoutNonEmpty: healthy when stdout has a value")
    func semantic_authenticated() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which gcloud",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/homebrew/bin/gcloud\n", stderr: "")),
            ("/opt/homebrew/bin/gcloud auth list --format=value(account)",
             RunResult(outcome: .exited(code: 0), stdout: "user@example.invalid\n", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(
            binary: "gcloud",
            livenessArgs: ["auth", "list", "--format=value(account)"],
            semantic: .stdoutNonEmpty
        )
        guard case .healthy = status else {
            Issue.record("Expected .healthy, got \(status)")
            return
        }
    }

    @Test("Semantic stderrNoDaemonError catches docker daemon down")
    func semantic_dockerDaemonDown() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which docker",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/homebrew/bin/docker\n", stderr: "")),
            ("/opt/homebrew/bin/docker version --format {{.Client.Version}}",
             RunResult(
                outcome: .exited(code: 0),
                stdout: "24.0.7\n",
                stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock."
             ))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        let status = await checker.check(
            binary: "docker",
            livenessArgs: ["version", "--format", "{{.Client.Version}}"],
            semantic: .stderrNoDaemonError
        )
        guard case .unauthenticated(let detail) = status else {
            Issue.record("Expected .unauthenticated, got \(status)")
            return
        }
        #expect(detail == "daemon unreachable")
    }

    @Test("PATH override is passed to which")
    func overridePATH() async {
        let stub = StubBinaryRunner()
        await stub.setResponse(
            forKey: "/usr/bin/env which tool",
            result: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "")
        )
        let checker = EnvironmentHealthChecker(runner: stub, overridePath: "/custom/bin")
        _ = await checker.check(binary: "tool")
        // We can't inspect the environment from the recorded call in this
        // stub, but we can at least confirm `which` was invoked.
        let calls = await stub.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.args == ["which", "tool"])
    }

    @Test("Call ordering: which first, then liveness")
    func callOrdering() async {
        let stub = await makeStub(responses: [
            ("/usr/bin/env which gcloud",
             RunResult(outcome: .exited(code: 0), stdout: "/opt/homebrew/bin/gcloud\n", stderr: "")),
            ("/opt/homebrew/bin/gcloud --version",
             RunResult(outcome: .exited(code: 0), stdout: "Google Cloud SDK 461.0.0\n", stderr: ""))
        ])
        let checker = EnvironmentHealthChecker(runner: stub)
        _ = await checker.check(binary: "gcloud")
        let calls = await stub.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls[0].args == ["which", "gcloud"])
        #expect(calls[1].args == ["--version"])
    }
}

// MARK: - SemanticCheck unit tests

@Suite("SemanticCheck evaluation")
struct SemanticCheckTests {
    @Test("stdoutNonEmpty passes for any non-whitespace content")
    func stdoutNonEmpty_passes() {
        #expect(SemanticCheck.stdoutNonEmpty.passes(stdout: "foo", stderr: "") == true)
        #expect(SemanticCheck.stdoutNonEmpty.passes(stdout: "  bar  \n", stderr: "") == true)
    }

    @Test("stdoutNonEmpty fails for empty / whitespace")
    func stdoutNonEmpty_fails() {
        #expect(SemanticCheck.stdoutNonEmpty.passes(stdout: "", stderr: "") == false)
        #expect(SemanticCheck.stdoutNonEmpty.passes(stdout: "   \n\t", stderr: "") == false)
    }

    @Test("stderrNoDaemonError catches the three well-known phrases")
    func stderrNoDaemonError_catchesPhrases() {
        #expect(SemanticCheck.stderrNoDaemonError.passes(
            stdout: "", stderr: "Cannot connect to the Docker daemon"
        ) == false)
        #expect(SemanticCheck.stderrNoDaemonError.passes(
            stdout: "", stderr: "The Docker daemon is not running"
        ) == false)
        #expect(SemanticCheck.stderrNoDaemonError.passes(
            stdout: "", stderr: "Is the docker daemon running?"
        ) == false)
    }

    @Test("stderrNoDaemonError passes on unrelated stderr")
    func stderrNoDaemonError_passes() {
        #expect(SemanticCheck.stderrNoDaemonError.passes(
            stdout: "24.0.7", stderr: ""
        ) == true)
        #expect(SemanticCheck.stderrNoDaemonError.passes(
            stdout: "", stderr: "warning: deprecated flag"
        ) == true)
    }
}

// MARK: - CLIPrerequisite

@Suite("CLIPrerequisite")
struct CLIPrerequisiteTests {

    @Test("Id is stable across identical specs")
    func id_stable() {
        let a = CLIPrerequisite(binary: "gcloud", displayName: "GCloud", purpose: "x")
        let b = CLIPrerequisite(binary: "gcloud", displayName: "GCloud (v2)", purpose: "y")
        #expect(a.id == b.id)  // id is derived from binary + livenessArgs, not display
    }

    @Test("Id distinguishes different liveness args")
    func id_distinguishesArgs() {
        let version = CLIPrerequisite(binary: "gcloud", displayName: "a", purpose: "a")
        let auth = CLIPrerequisite(
            binary: "gcloud",
            livenessArgs: ["auth", "list"],
            displayName: "b",
            purpose: "b"
        )
        #expect(version.id != auth.id)
    }

    @Test("Codable round-trip preserves all fields")
    func codable_roundTrip() throws {
        let original = CommonCLIPrerequisites.gcloud
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CLIPrerequisite.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Common Claude prereq is defined with expected fields")
    func common_claude() {
        let p = CommonCLIPrerequisites.claude
        #expect(p.binary == "claude")
        #expect(p.livenessArgs == ["--version"])
        #expect(p.installURL != nil)
        #expect(!p.installHint.isEmpty)
    }
}
