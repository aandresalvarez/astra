import Foundation
import CryptoKit
import ASTRACore

/// Bridges ENABLED capabilities into the Workspace App contract registry so "enable a capability → apps
/// can read it" works with NO per-connector Swift. A capability exposes a read to apps by declaring a
/// `localTool` whose `toolType` is the sentinel `workspaceAppRead`; this deriver maps each such enabled
/// tool to a contract FAMILY (`capability.<pkg>.<tool>.read`) + an IMPLEMENTATION carrying a `.cli`
/// `readExecution` spec. The registry is then extended with these at publish (so bindings auto-map) and
/// at execution (so the resolver finds the spec and runs it via the generic CLI client).
///
/// This is opt-in by the capability author (the sentinel toolType) — enabling a capability does NOT
/// expose its agent-facing tools to apps, and an app still must DECLARE the requirement + get a `.mapped`
/// binding (the per-app least-privilege boundary is unchanged).
enum WorkspaceAppCapabilityContractDeriver {
    /// A capability sets this `toolType` on a `localTool` to expose it as an app-readable connector read.
    static let appReadToolType = "workspaceAppRead"
    /// The single operation a derived CLI read exposes (one tool = one read op).
    static let defaultOperation = "default"

    /// Derived families + implementations for a workspace's enabled capabilities (filesystem-backed).
    static func derived(for workspace: Workspace?) -> (families: [WorkspaceAppContractFamily], implementations: [WorkspaceAppContractImplementation]) {
        derived(from: CapabilityRuntimeResourceMatcher.enabledPackages(for: workspace))
    }

    /// Pure mapping from packages → (families, implementations); injectable for tests.
    static func derived(from packages: [PluginPackage]) -> (families: [WorkspaceAppContractFamily], implementations: [WorkspaceAppContractImplementation]) {
        var families: [String: WorkspaceAppContractFamily] = [:]
        var implementations: [String: WorkspaceAppContractImplementation] = [:]
        for package in packages {
            for tool in package.localTools where tool.toolType == appReadToolType {
                let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                // Collision-resistant id: a slug for readability PLUS a hash of the EXACT (package id,
                // tool name) so two distinct tools can never slug-collide and silently swap commands (one
                // package's binding must never be satisfied by another package's implementation).
                let fingerprint = hash("\(package.id)\u{0}\(tool.name)")
                let familyID = "capability." + slug("\(package.id)-\(tool.name)") + "-" + fingerprint + ".read"
                let implID = familyID + ".cli"
                let argv = [command] + splitArguments(tool.arguments)
                families[familyID] = WorkspaceAppContractFamily(
                    id: familyID,
                    displayName: tool.name.isEmpty ? "Capability Read" : tool.name,
                    operations: [WorkspaceAppContractOperation(name: defaultOperation, effect: .read)]
                )
                implementations[implID] = WorkspaceAppContractImplementation(
                    id: implID,
                    familyID: familyID,
                    provider: "cli",
                    transport: .cli,
                    operations: [defaultOperation],
                    dataAccess: ["externalService"],
                    externalEffects: ["readOnly"],
                    readExecution: WorkspaceAppCapabilityReadExecution(
                        transport: .cli,
                        // rowsPath nil ⇒ the CLI must output a top-level JSON array (e.g. `gh ... --json`).
                        // A nested-output convention can be added later (would need a localTool field).
                        operations: [defaultOperation: WorkspaceAppCapabilityReadExecution.Operation(command: argv, rowsPath: nil)]
                    )
                )
            }
        }
        return (Array(families.values), Array(implementations.values))
    }

    /// Split a localTool's `arguments` string into argv tokens. Whitespace-separated; the deriver does NOT
    /// substitute params here — placeholders like `{limit}` survive as whole tokens for the generic CLI
    /// client to fill + validate at read time. (Quoting/multi-word values are out of scope for the CLI
    /// read pattern, which uses flag-style args.)
    static func splitArguments(_ arguments: String) -> [String] {
        arguments.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Stable fingerprint (first 16 hex / 64 bits of SHA-256) of an exact key, for collision-resistant
    /// ids (so two distinct tools can't slug-collide and swap commands, even adversarially).
    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
