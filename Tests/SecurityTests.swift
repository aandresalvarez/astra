import Testing
import Foundation
@testable import ASTRA
import ASTRACore
import CryptoKit

@Suite("Permission Policy")
struct PermissionPolicyTests {

    @Test("Autonomous policy returns skip-permissions flag")
    func autonomousCLI() {
        let args = PermissionPolicy.autonomous.cliArguments
        #expect(args == ["--dangerously-skip-permissions"])
    }

    @Test("Restricted policy returns no CLI flags")
    func restrictedCLI() {
        #expect(PermissionPolicy.restricted.cliArguments.isEmpty)
    }

    @Test("Interactive policy returns no CLI flags")
    func interactiveCLI() {
        #expect(PermissionPolicy.interactive.cliArguments.isEmpty)
    }

    @Test("Autonomous sub-agent permissions include Bash(*)")
    func autonomousSubAgent() {
        let perms = PermissionPolicy.autonomous.subAgentPermissions(allowedTools: [])
        #expect(perms.count == 1)
        let allow = perms[0]["allow"] as? [String] ?? []
        #expect(allow.contains("Bash(*)"))
    }

    @Test("Restricted sub-agent permissions use only allowed tools")
    func restrictedSubAgent() {
        let perms = PermissionPolicy.restricted.subAgentPermissions(allowedTools: ["Read", "Grep"])
        #expect(perms.count == 1)
        let allow = perms[0]["allow"] as? [String] ?? []
        #expect(allow.contains("Read(*)"))
        #expect(allow.contains("Grep(*)"))
        #expect(!allow.contains("Bash(*)"))
    }

    @Test("Restricted sub-agent permissions preserve scoped tool grants")
    func restrictedSubAgentPreservesScopedToolGrants() {
        let perms = PermissionPolicy.restricted.subAgentPermissions(
            allowedTools: ["Read", "Bash(gh:*)"]
        )
        let allow = perms[0]["allow"] as? [String] ?? []

        #expect(allow.contains("Read(*)"))
        #expect(allow.contains("Bash(gh:*)"))
        #expect(!allow.contains("Bash(gh:*)(*)"))
    }

    @Test("Interactive sub-agent returns empty permissions")
    func interactiveSubAgent() {
        let perms = PermissionPolicy.interactive.subAgentPermissions(allowedTools: ["Read"])
        #expect(perms.isEmpty)
    }
}

@Suite("Path Validator")
struct PathValidatorTests {

    @Test("Normal absolute path passes validation")
    func normalPath() throws {
        try PathValidator.validate("/Users/foo/projects/bar")
    }

    @Test("Empty path is rejected")
    func emptyPath() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.validate("")
        }
    }

    @Test("Path with .. traversal is rejected")
    func traversalPath() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.validate("../../etc/passwd")
        }
    }

    @Test("Path with embedded .. is rejected")
    func embeddedTraversal() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.validate("/Users/foo/../../../etc/passwd")
        }
    }

    @Test("Whitespace-only path is rejected")
    func whitespacePath() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.validate("   ")
        }
    }

    @Test("Root-bounded validation passes for valid path")
    func withinRoot() throws {
        let root = NSTemporaryDirectory()
        let path = (root as NSString).appendingPathComponent("test-workspace")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try PathValidator.validate(path, withinRoot: root)
    }

    @Test("Root-bounded validation rejects sibling prefix escape")
    func siblingPrefixEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-root-\(UUID().uuidString)", isDirectory: true)
        let sibling = URL(fileURLWithPath: root.path + "-evil", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        #expect(throws: PathValidationError.self) {
            try PathValidator.validate(sibling.path, withinRoot: root.path)
        }
    }

    @Test("Root-bounded validation rejects symlink escape")
    func symlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-outside-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("linked-outside", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: PathValidationError.self) {
            try PathValidator.validate(link.path, withinRoot: root.path)
        }
    }
}

@Suite("Secret Redaction Inputs")
struct SecretRedactionInputTests {
    @Test("Agent redaction values trim, deduplicate, and omit blanks")
    func redactionValuesAreNormalized() {
        let task = AgentTask(title: "Redact", goal: "Do not leak")
        let skill = Skill(
            name: "Canary",
            allowedTools: ["Read"],
            environmentVariables: [
                "CANARY_ONE": " ASTRA_TEST_SECRET_123 ",
                "CANARY_TWO": "ASTRA_TEST_SECRET_123",
                "EMPTY_CANARY": " "
            ]
        )
        task.skills = [skill]

        #expect(AgentSensitiveRedactions.values(for: task) == ["ASTRA_TEST_SECRET_123"])
    }
}

@Suite("Plugin Signing")
struct PluginSigningTests {

    @Test("Hash produces consistent SHA-256 hex string")
    func consistentHash() {
        let data = "hello world".data(using: .utf8)!
        let hash1 = PluginSigning.hash(pluginJSON: data)
        let hash2 = PluginSigning.hash(pluginJSON: data)
        #expect(hash1 == hash2)
        #expect(hash1.count == 64)
    }

    @Test("Valid signature verifies successfully")
    func validSignature() {
        let (privateKey, publicKey) = PluginSigning.generateKeyPair()
        let data = "{\"name\": \"test-plugin\"}".data(using: .utf8)!
        let signature = PluginSigning.sign(pluginJSON: data, privateKey: privateKey)
        #expect(PluginSigning.verify(pluginJSON: data, signature: signature, publicKey: publicKey))
    }

    @Test("Tampered data fails verification")
    func tamperedData() {
        let (privateKey, publicKey) = PluginSigning.generateKeyPair()
        let data = "{\"name\": \"test-plugin\"}".data(using: .utf8)!
        let signature = PluginSigning.sign(pluginJSON: data, privateKey: privateKey)
        let tampered = "{\"name\": \"evil-plugin\"}".data(using: .utf8)!
        #expect(!PluginSigning.verify(pluginJSON: tampered, signature: signature, publicKey: publicKey))
    }

    @Test("Wrong key fails verification")
    func wrongKey() {
        let (privateKey, _) = PluginSigning.generateKeyPair()
        let (_, otherPublic) = PluginSigning.generateKeyPair()
        let data = "{\"name\": \"test\"}".data(using: .utf8)!
        let signature = PluginSigning.sign(pluginJSON: data, privateKey: privateKey)
        #expect(!PluginSigning.verify(pluginJSON: data, signature: signature, publicKey: otherPublic))
    }

    @Test("Unsigned plugin has isTrusted false")
    func unsignedPlugin() throws {
        let json = """
        {"formatVersion":2,"id":"test","name":"Test","icon":"star","description":"desc","author":"me","category":"dev","tags":[],"version":"1.0","skills":[],"connectors":[],"localTools":[],"templates":[]}
        """
        let plugin = try JSONDecoder().decode(PluginPackage.self, from: json.data(using: .utf8)!)
        #expect(!plugin.isTrusted)
        #expect(plugin.signature == nil)
    }
}

@Suite("Legacy Credential Removal")
struct LegacyCredentialTests {

    @Test("Credentials only come from SecretStore, not legacy values")
    func noLegacyFallback() {
        let store = MockSecretStore()
        let connector = Connector(name: "Test", serviceType: "custom")
        connector.credentialKeys = ["API_KEY"]
        connector.credentialValues = ["legacy-value"]

        let creds = connector.credentials(store: store)
        #expect(creds["API_KEY"] == nil)
    }

    @Test("Credentials resolve from SecretStore when present")
    func secretStoreResolves() {
        let store = MockSecretStore()
        let connector = Connector(name: "Test", serviceType: "custom")
        connector.credentialKeys = ["API_KEY"]

        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "API_KEY", value: "secure-value", entityID: entityID, label: nil)

        let creds = connector.credentials(store: store)
        #expect(creds["API_KEY"] == "secure-value")
    }

    @Test("Missing credential keys are detected before connector tests")
    func missingCredentialKeysDetected() {
        let store = MockSecretStore()
        let connector = Connector(name: "Jira", serviceType: "jira")
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)

        #expect(connector.missingCredentialKeys(store: store) == ["JIRA_API_TOKEN"])
    }

    @Test("Connector test reports missing Keychain values without making request")
    func testConnectionReportsMissingCredentials() async {
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let result = await connector.testConnection()

        #expect(!result.0)
        #expect(result.1 == "Missing Keychain value: JIRA_EMAIL, JIRA_API_TOKEN")
    }

    @Test("Connector test rejects credentialed remote HTTP before making request")
    func credentialedConnectorRejectsRemoteHTTP() async {
        let store = MockSecretStore()
        let connector = Connector(
            name: "Unsafe API",
            serviceType: "rest_api",
            baseURL: "http://evil.example/api",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["API_TOKEN"]
        store.save(
            key: "API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        let transport = RecordingConnectorHTTPTransport()

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("HTTPS"))
        #expect(transport.requests.isEmpty)
    }

    @Test("Connector credential keys require protected transport even with auth none")
    func credentialKeysRequireProtectedTransportEvenWithAuthNone() async {
        let connector = Connector(
            name: "Misconfigured API",
            serviceType: "rest_api",
            baseURL: "http://evil.example/api",
            authMethod: "none"
        )
        connector.credentialKeys = ["API_TOKEN"]
        let transport = RecordingConnectorHTTPTransport()

        let result = await connector.testConnection(store: MockSecretStore(), transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("HTTPS"))
        #expect(transport.requests.isEmpty)
    }
}

private final class RecordingConnectorHTTPTransport: ConnectorHTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
