import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Runtime Remediation Catalog")
struct RuntimeRemediationCatalogTests {

    @Test("Every registered runtime has a complete remediation entry")
    func everyRuntimeHasRemediation() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let remediation = RuntimeRemediationCatalog.remediation(for: runtime)
            #expect(!remediation.auth.terminalCommand.isEmpty, "\(runtime.rawValue) needs a terminal command")
            #expect(!remediation.auth.displayCommand.isEmpty, "\(runtime.rawValue) needs a copyable command")
            if case .linkOnly(let url) = remediation.install {
                #expect(url != nil, "\(runtime.rawValue) is link-only but has no install URL")
            }
        }
    }

    @Test("No remediation command pipes remote scripts into a shell")
    func noRemoteShellExecution() {
        var commands = AgentRuntimeAdapterRegistry.runtimeIDs.flatMap { runtime -> [String] in
            let auth = RuntimeRemediationCatalog.remediation(for: runtime).auth
            return [auth.terminalCommand, auth.displayCommand]
        }
        let vertexAuth = RuntimeRemediationCatalog.remediation(for: .claudeCode, claudeProvider: .vertex).auth
        commands += [vertexAuth.terminalCommand, vertexAuth.displayCommand]
        commands += [RuntimeRemediationCatalog.githubAuth.terminalCommand]

        for command in commands {
            #expect(!command.contains("curl"), "remediation must not download scripts: \(command)")
            #expect(!command.contains("| bash"), "remediation must not pipe to bash: \(command)")
            #expect(!command.contains("| sh"), "remediation must not pipe to sh: \(command)")
            #expect(!command.contains("sudo"), "remediation must not escalate privileges: \(command)")
        }
    }

    @Test("Runtimes whose vendor installer is curl|bash stay link-only")
    func curlBashVendorsAreLinkOnly() {
        let antigravity = RuntimeRemediationCatalog.remediation(for: .antigravityCLI)
        let cursor = RuntimeRemediationCatalog.remediation(for: .cursorCLI)
        guard case .linkOnly = antigravity.install else {
            Issue.record("Antigravity must not get an in-app installer")
            return
        }
        guard case .linkOnly = cursor.install else {
            Issue.record("Cursor must not get an in-app installer")
            return
        }
    }

    @Test("Copilot sign-in uses the normal terminal state")
    func copilotSignInUsesNormalTerminalState() {
        let auth = RuntimeRemediationCatalog.remediation(for: .copilotCLI).auth
        #expect(auth.terminalCommand == "copilot")
        #expect(auth.instruction?.contains("same Copilot state as Terminal") == true)
        guard case .deferredToTaskStart = auth.verification else {
            Issue.record("Copilot has no safe local auth probe; verification must defer")
            return
        }
    }

    @Test("Claude sign-in follows the configured provider route")
    func claudeSignInFollowsProviderRoute() {
        let anthropic = RuntimeRemediationCatalog.remediation(for: .claudeCode, claudeProvider: .anthropic).auth
        #expect(anthropic.terminalCommand == "claude /login")
        #expect(anthropic.verification == .probe(binary: nil, args: ["auth", "status"], semantic: .authenticatedSession))

        let vertex = RuntimeRemediationCatalog.remediation(for: .claudeCode, claudeProvider: .vertex).auth
        #expect(vertex.terminalCommand == "gcloud auth application-default login")
        #expect(vertex.verification == .probe(
            binary: "gcloud",
            args: ["auth", "application-default", "print-access-token", "--quiet"],
            semantic: .nonEmptyStdout
        ))
    }

    @Test("Verification probes are read-only status commands")
    func verificationProbesAreReadOnly() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let auth = RuntimeRemediationCatalog.remediation(for: runtime).auth
            guard case .probe(_, let args, _) = auth.verification else { continue }
            let probe = args.joined(separator: " ")
            #expect(
                probe.contains("status") || probe.contains("list") || probe.contains("print-access-token"),
                "\(runtime.rawValue) verification '\(probe)' does not look read-only"
            )
            #expect(!probe.contains("login") || probe.contains("status"),
                    "\(runtime.rawValue) verification must not re-trigger an interactive login")
        }
    }

    @Test("Antigravity never auto-spends its live diagnostic")
    func antigravityVerificationIsManual() {
        let auth = RuntimeRemediationCatalog.remediation(for: .antigravityCLI).auth
        guard case .manualRecheck = auth.verification else {
            Issue.record("Antigravity verification must stay on-demand")
            return
        }
    }

    @Test("Shell quoting survives spaces and embedded quotes")
    func shellQuoting() {
        #expect(RuntimeRemediationCatalog.shellQuoted("plain") == "'plain'")
        #expect(RuntimeRemediationCatalog.shellQuoted("/Users/x/Application Support/Copilot")
                == "'/Users/x/Application Support/Copilot'")
        #expect(RuntimeRemediationCatalog.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test("GitHub capability sign-in probes gh auth status")
    func githubAuthRemediation() {
        let auth = RuntimeRemediationCatalog.githubAuth
        #expect(auth.terminalCommand == "gh auth login")
        #expect(auth.verification == .probe(
            binary: "gh",
            args: ["auth", "status", "--hostname", "github.com"],
            semantic: .authenticatedSession
        ))
    }
}
