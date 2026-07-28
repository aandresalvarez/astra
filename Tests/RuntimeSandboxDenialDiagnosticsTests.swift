import Testing
@testable import ASTRA

@Suite("Runtime sandbox denial diagnostics")
struct RuntimeSandboxDenialDiagnosticsTests {
    @Test("Fatal write denial uses only the offending line")
    func fatalWriteDenialUsesOffendingLine() {
        let output = """
        From github.com:example/repo
        fatal: Unable to create '/Users/example/repo/.git/index.lock': Operation not permitted
        create mode 100644 /repo/not-the-denied-path.txt
        """
        let denial = RuntimeSandboxDenialDiagnostics.fileDenial(in: output)
        #expect(denial?.operation == .write)
        #expect(denial?.path == "/Users/example/repo/.git/index.lock")
        #expect(denial?.detail.contains("not-the-denied-path") == false)
    }

    @Test("Container read-only filesystem denial is classified as a terminal write")
    func containerReadOnlyFilesystemDenialIsWrite() throws {
        let output = "/bin/rm: /workspace/attached.pdf: Read-only file system"
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(in: output))
        #expect(denial.operation == .write)
        #expect(denial.path == "/workspace/attached.pdf")

        let decision = RuntimeSandboxDenialApproval.resolve(
            denial: denial,
            toolName: "Bash",
            requestText: "",
            approvalWasApplied: false
        )
        guard case .terminal(let reason, let message) = decision else {
            Issue.record("A container write denial must never create an approval")
            return
        }
        #expect(reason == "os_sandbox_file_write_denied")
        #expect(message.contains("sandbox_write_approval_not_supported"))
        #expect(message.contains("ASTRA's execution sandbox"))
        #expect(!message.contains("ASTRA's macOS sandbox"))
    }

    @Test("Shell-prefixed denial reports the denied executable")
    func shellPrefixedDenialReportsExecutable() {
        let output = """
        Exit code 255
        /bin/sh: /Users/example/google-cloud-sdk/bin/gcloud: Operation not permitted
        Connection closed by UNKNOWN port 65535
        """
        let denial = RuntimeSandboxDenialDiagnostics.fileDenial(in: output)
        #expect(denial?.operation == .access)
        #expect(denial?.path == "/Users/example/google-cloud-sdk/bin/gcloud")
    }

    @Test("Paths after the failure marker are ignored")
    func parserUsesNearestPrecedingPath() {
        let output = "/bin/sh: /Users/example/bin/tool: Operation not permitted; report /tmp/unrelated"
        #expect(RuntimeSandboxDenialDiagnostics.fileDenial(in: output)?.path == "/Users/example/bin/tool")
    }

    @Test("Relative Bash denial resolves against the launch directory")
    func relativeBashDenialUsesLaunchDirectory() throws {
        let workspace = "/Users/example/Code/starr-data-lake"
        let output = "touch: dbt/omop_cdm54/macros/test_write.txt: Operation not permitted"
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: output,
            currentDirectory: workspace,
            operationContext: "touch dbt/omop_cdm54/macros/test_write.txt"
        ))

        #expect(denial.path == "\(workspace)/dbt/omop_cdm54/macros/test_write.txt")
        #expect(denial.operation == .write)
    }

    @Test("A filename containing write does not determine the operation")
    func filenameDoesNotDetermineOperation() throws {
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: "/bin/sh: /tmp/test_write.txt: Operation not permitted"
        ))

        #expect(denial.path == "/tmp/test_write.txt")
        #expect(denial.operation == .access)
    }

    @Test("A write word in a command path argument does not imply a write")
    func commandPathArgumentDoesNotDetermineOperation() throws {
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: "cat: /tmp/test_write.txt: Operation not permitted",
            operationContext: "cat /tmp/test_write.txt"
        ))

        #expect(denial.path == "/tmp/test_write.txt")
        #expect(denial.operation == .read)
    }

    @Test("A denied relative basename resolves against the launch directory")
    func relativeBasenameUsesLaunchDirectory() throws {
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: "touch: test_write.txt: Operation not permitted",
            currentDirectory: "/Users/example/Code/project",
            operationContext: "touch test_write.txt"
        ))

        #expect(denial.path == "/Users/example/Code/project/test_write.txt")
        #expect(denial.operation == .write)
    }

    @Test("An ambiguous copy source denial is not treated as a write")
    func copySourceDenialRemainsAmbiguous() throws {
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: "cp: /outside/source.txt: Operation not permitted",
            operationContext: "cp /outside/source.txt ./destination.txt"
        ))

        #expect(denial.operation == .access)
    }

    @Test("A compound command uses the failing diagnostic command")
    func compoundCommandUsesFailingDiagnosticCommand() throws {
        let denial = try #require(RuntimeSandboxDenialDiagnostics.fileDenial(
            in: "cat: /outside/source.txt: Operation not permitted",
            operationContext: "touch output.txt && cat /outside/source.txt"
        ))

        #expect(denial.operation == .read)
    }

    @Test("Ambiguous access denial does not request an ineffective read approval")
    func ambiguousAccessDenialIsTerminal() {
        let decision = RuntimeSandboxDenialApproval.resolve(
            denial: RuntimeSandboxFileDenial(
                operation: .access,
                path: "/tmp/astra-ambiguous-output",
                detail: "/bin/sh: /tmp/astra-ambiguous-output: Operation not permitted"
            ),
            toolName: "Bash",
            requestText: "\nRecent request: printf replacement > /tmp/astra-ambiguous-output",
            approvalWasApplied: false
        )

        guard case .terminal(let reason, let message) = decision else {
            Issue.record("Ambiguous access denial should be terminal")
            return
        }
        #expect(reason == "os_sandbox_file_access_denied")
        #expect(message.contains("sandbox_access_approval_not_supported"))
    }
}
