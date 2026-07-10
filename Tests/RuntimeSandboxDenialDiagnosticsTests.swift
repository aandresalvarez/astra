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
