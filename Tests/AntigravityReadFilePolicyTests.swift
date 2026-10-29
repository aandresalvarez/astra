import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Antigravity read-file policy")
struct AntigravityReadFilePolicyTests {
    private let workspace = "/tmp/astra-policy-guard"

    @Test("A real read_file frame obeys the rendered read-only policy", arguments: [AgentPolicyLevel.review, .locked, .custom])
    func workspaceRead(level: AgentPolicyLevel) throws {
        let event = try frame(parameters: ["Path": workspace + "/preserved.txt"])
        let observed = try #require(PolicyObservedEvent(providerEvent: event))
        #expect(observed.path == workspace + "/preserved.txt")
        #expect(ProviderToolSemantics.normalizedName("read_file") == "read")
        let manifest = manifest(policy: .preset(level))
        #expect(manifest.providerRender.allowedTools.contains("Read"))
        #expect(manifest.providerRender.cliArgumentsSummary == ["--sandbox"])
        #expect(!manifest.providerRender.allowedTools.contains("Write"))
        #expect(!manifest.providerRender.allowedTools.contains("Bash"))
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max,
            taskID: manifest.taskID, policyGuard: AgentRuntimePolicyGuard(manifest: manifest))
        #expect(!monitor.processEvent(event, process: nil))
        #expect(!monitor.policyViolation)
        #expect(!monitor.policyApprovalRequired)
    }

    @Test("Missing or ambiguous native paths fail closed", arguments: [
        "{}", #"{"Path":null}"#, #"{"Path":123}"#, #"{"Path":{}}"#,
        #"{"Path":[]}"#, #"{"Path":""}"#, #"{"Path":"  "}"#,
        #"{"Path":"bad\u0000path"}"#, #"{"path":"/tmp/astra-policy-guard/a"}"#,
        #"{"Path":"/tmp/outside","file_path":"/tmp/astra-policy-guard/a"}"#,
        #"{"Path":"/tmp/astra-policy-guard/a","path":"/tmp/outside"}"#,
        #"{"input":{"Path":"/tmp/astra-policy-guard/a"}}"#,
        #"{"Path":"/tmp/astra-policy-guard/a","arguments":{"Path":"/tmp/outside"}}"#,
        #"{"Path":"unterminated"#, "not a structured path"
    ])
    func invalidNativePath(summary: String) {
        let event = ParsedEvent.toolUse(name: "read_file", id: "read", input: ["summary": summary])
        #expect(PolicyObservedEvent(providerEvent: event)?.path == nil)
        let violation = AgentRuntimePolicyGuard(manifest: manifest()).violation(for: event)
        #expect(violation != nil)
        #expect(violation?.requiresApproval == false)
    }

    @Test("An external read asks for its actual path", arguments: [
        "/tmp/outside/read.txt", "../outside/read.txt"
    ])
    func externalRead(path: String) throws {
        let event = try frame(parameters: ["Path": path])
        let violation = try #require(AgentRuntimePolicyGuard(manifest: manifest()).violation(for: event))
        #expect(violation.requiresApproval)
        #expect(violation.violationCategory == "out_of_boundary_read")
        #expect(violation.permissionRequest == .sandboxPath(path: path, access: "read", toolName: "read_file"))
    }

    @Test("Read-only attachment grants do not grant neighboring files")
    func attachmentRead() throws {
        var manifest = manifest()
        manifest.additionalReadOnlyPaths = ["/tmp/attached/spec.txt"]
        let guardrail = AgentRuntimePolicyGuard(manifest: manifest)
        #expect(guardrail.violation(for: try frame(parameters: ["Path": "/tmp/attached/spec.txt"])) == nil)
        #expect(guardrail.violation(for: try frame(parameters: ["Path": "/tmp/attached/other.txt"]))?.requiresApproval == true)
    }

    @Test("Symlinks do not turn an external read into a workspace read")
    func symlinkRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("outside.txt")
        try "private fixture".write(to: external, atomically: true, encoding: .utf8)
        let link = workspaceURL.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        var manifest = manifest()
        manifest.workspacePath = workspaceURL.path
        let violation = AgentRuntimePolicyGuard(manifest: manifest).violation(for: try frame(parameters: ["Path": link.path]))
        #expect(violation?.requiresApproval == true)
    }

    @Test("Custom policy does not acquire read permission implicitly")
    func customWithoutRead() throws {
        let manifest = manifest(policy: AgentPolicy(level: .custom, allowedTools: []))
        #expect(manifest.providerRender.allowedTools.isEmpty)
        #expect(AgentRuntimePolicyGuard(manifest: manifest).violation(for:
            try frame(parameters: ["Path": workspace + "/a"])) != nil)
    }

    @Test("Explicit read denial wins over an allowed alias", arguments: ["Read", "read_file"])
    func deniedRead(denied: String) throws {
        let policy = AgentPolicy(level: .custom, allowedTools: ["Read"], deniedTools: [denied])
        let violation = AgentRuntimePolicyGuard(manifest: manifest(policy: policy)).violation(for:
            try frame(parameters: ["Path": workspace + "/a"]))
        #expect(violation?.reason.contains("explicitly denied") == true)
    }

    @Test("A direct native path and its stream summary share the same boundary")
    func directInput() {
        let guardrail = AgentRuntimePolicyGuard(manifest: manifest())
        #expect(guardrail.violation(for: .toolUse(name: "read_file", id: "r",
            input: ["Path": workspace + "/a"])) == nil)
        #expect(guardrail.disposition(toolName: "read_file", command: nil, path: nil) == .denied)
        #expect(guardrail.disposition(toolName: "read_file", command: nil, path: workspace + "/a") == .allowed)
        #expect(guardrail.disposition(toolName: "read_file", command: nil, path: "/tmp/outside/a") == .ask)
    }

    @Test("Interactive input uses the same native path contract")
    func interactiveInput() {
        func request(_ input: [String: Any]) -> ClaudeControlProtocol.ControlRequest {
            .init(requestID: "read", subtype: "can_use_tool", toolName: "read_file", inputJSON: input, inputSummary: nil)
        }
        #expect(request(["Path": workspace + "/a"]).pathText == workspace + "/a")
        #expect(request(["Path": NSNull()]).pathText == nil)
        #expect(request(["Path": "/tmp/outside/a", "path": workspace + "/a"]).pathText == nil)
    }

    @Test("Fingerprint metadata does not hide a valid native path")
    func fingerprintMetadata() {
        let event = ParsedEvent.toolUse(name: "read_file", id: "read", input: [
            "summary": #"{"Path":"/tmp/astra-policy-guard/a"}"#, ToolInputFingerprint.key: "fingerprint"
        ])
        #expect(PolicyObservedEvent(providerEvent: event)?.path == workspace + "/a")
        #expect(AgentRuntimePolicyGuard(manifest: manifest()).violation(for: event) == nil)
    }

    @Test("Native and summary argument containers cannot disagree")
    func mixedContainers() {
        let event = ParsedEvent.toolUse(name: "read_file", id: "read", input: [
            "summary": #"{"Path":"/tmp/outside/a"}"#, "Path": workspace + "/a"
        ])
        #expect(PolicyObservedEvent(providerEvent: event)?.path == nil)
        #expect(AgentRuntimePolicyGuard(manifest: manifest()).violation(for: event)?.requiresApproval == false)
    }

    private func frame(parameters: [String: Any]) throws -> ParsedEvent {
        let object: [String: Any] = ["event": "step_update", "step_update": [
            "step_index": 1, "state": "ACTIVE", "step_type": "tool", "tool_name": "read_file",
            "tool_info": ["parameters": parameters]
        ]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(AntigravityCLIRuntime.parseEvents(line: String(decoding: data, as: UTF8.self), parsesJSONLines: true).first)
    }

    private func manifest(policy: AgentPolicy = .preset(.review)) -> RunPermissionManifest {
        let adapter = AntigravityPolicyAdapter()
        let context = PolicyRenderContext(runtimeID: .antigravityCLI, model: "gemini-3.8-flash",
            workspacePath: workspace, additionalPaths: [], requestedAllowedTools: [],
            localToolCommands: [], environmentKeyNames: [], credentialLabels: [],
            providerFeatures: adapter.supportedFeatures)
        var manifest = runtimePolicyManifest(allowedTools: [], workspacePath: workspace, providerID: .antigravityCLI)
        manifest.providerRender = adapter.render(policy: policy, context: context)
        manifest.policyLevel = policy.level
        return manifest
    }
}
