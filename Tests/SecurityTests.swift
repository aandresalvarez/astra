import Testing
import Foundation
import Security
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Privacy-sensitive path policy")
struct PrivacySensitivePathPolicyTests {
    @Test("Implicit scans skip protected home media roots")
    func implicitScansSkipProtectedHomeMediaRoots() {
        let home = URL(fileURLWithPath: "/tmp/astra-fake-home", isDirectory: true)

        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: home.appendingPathComponent("Pictures", isDirectory: true),
            homeDirectory: home
        ))
        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: home.appendingPathComponent("Music/Music Library.musiclibrary", isDirectory: true),
            homeDirectory: home
        ))
        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: URL(fileURLWithPath: "/tmp/workspace/Pictures", isDirectory: true),
            homeDirectory: home
        ) == false)
        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: URL(fileURLWithPath: "/Volumes/SharedDrive", isDirectory: true),
            homeDirectory: home
        ))
        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: URL(fileURLWithPath: "/Network/Servers/SharedDrive", isDirectory: true),
            homeDirectory: home
        ))
    }

    @Test("Implicit scans allow descendants inside the selected scan root")
    func implicitScansAllowDescendantsInsideSelectedScanRoot() {
        let home = URL(fileURLWithPath: "/tmp/astra-fake-home", isDirectory: true)
        let scanRoot = home.appendingPathComponent("Pictures/project", isDirectory: true)
        let descendant = scanRoot.appendingPathComponent("notes.md")

        #expect(PrivacySensitivePathPolicy.shouldSkipImplicitScan(
            of: descendant,
            scanRoot: scanRoot,
            homeDirectory: home
        ) == false)
    }
}

@Suite("Host File Access Broker")
struct HostFileAccessBrokerTests {
    @Test("Implicit directory scans filter privacy-sensitive children")
    func implicitDirectoryScansFilterPrivacySensitiveChildren() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-host-file-broker-\(UUID().uuidString)", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let music = home.appendingPathComponent("Music", isDirectory: true)
        let project = home.appendingPathComponent("Projects/App", isDirectory: true)

        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let broker = HostFileAccessBroker(homeDirectory: home)
        let children = try broker.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            intent: .implicitScan(root: home)
        )

        let names = Set(children.map(\.lastPathComponent))
        #expect(names == ["Projects"])
    }

    @Test("Implicit directory scans avoid resource-key prefetch before filtering")
    func implicitDirectoryScansAvoidResourceKeyPrefetchBeforeFiltering() throws {
        let home = URL(fileURLWithPath: "/tmp/astra-host-prefetch-home", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let project = home.appendingPathComponent("Projects", isDirectory: true)
        let fileManager = SpyDirectoryFileManager(childrenByPath: [
            home.path: [pictures, project]
        ])
        let broker = HostFileAccessBroker(fileManager: fileManager, homeDirectory: home)

        let children = try broker.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            intent: .implicitScan(root: home)
        )

        #expect(children == [project])
        #expect(fileManager.directoryRequests.map(\.keys) == [nil])
    }

    @Test("Implicit enumerators do not yield privacy-sensitive descendants")
    func implicitEnumeratorsDoNotYieldPrivacySensitiveDescendants() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-host-file-broker-enumerator-\(UUID().uuidString)", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let music = home.appendingPathComponent("Music", isDirectory: true)
        let project = home.appendingPathComponent("Projects/App", isDirectory: true)

        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "photo".write(to: pictures.appendingPathComponent("library.txt"), atomically: true, encoding: .utf8)
        try "music".write(to: music.appendingPathComponent("library.txt"), atomically: true, encoding: .utf8)
        try "swift".write(to: project.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let broker = HostFileAccessBroker(homeDirectory: home)
        let resolvedHome = home
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedHomePrefix = resolvedHome.path.hasSuffix("/") ? resolvedHome.path : resolvedHome.path + "/"
        let enumerator = try #require(broker.enumerator(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            intent: .implicitScan(root: home)
        ))

        var relativePaths: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            let itemURL = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let relativePath = String(itemURL.path.dropFirst(resolvedHomePrefix.count))
            relativePaths.insert(relativePath)
        }

        #expect(relativePaths.contains("Projects"))
        #expect(relativePaths.contains("Projects/App"))
        #expect(relativePaths.contains("Projects/App/App.swift"))
        #expect(!relativePaths.contains("Pictures"))
        #expect(!relativePaths.contains("Pictures/library.txt"))
        #expect(!relativePaths.contains("Music"))
        #expect(!relativePaths.contains("Music/library.txt"))
    }

    @Test("Explicit user selected roots can include privacy-sensitive folders")
    func explicitUserSelectedRootsCanIncludePrivacySensitiveFolders() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-host-file-broker-explicit-\(UUID().uuidString)", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let selectedFile = pictures.appendingPathComponent("selected.txt")

        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try "ok".write(to: selectedFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let broker = HostFileAccessBroker(homeDirectory: home)
        let children = try broker.contentsOfDirectory(
            at: pictures,
            includingPropertiesForKeys: [.isRegularFileKey],
            intent: .explicitUserSelection
        )

        #expect(children.map(\.lastPathComponent) == ["selected.txt"])
        #expect(!broker.shouldSkip(
            pictures,
            intent: .explicitUserSelection
        ))
        #expect(broker.shouldSkip(
            pictures,
            intent: .implicitScan(root: home)
        ))
    }

    @Test("Broker reads explicit user-selected protected files")
    func brokerReadsExplicitUserSelectedProtectedFiles() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-host-file-broker-read-\(UUID().uuidString)", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let selectedFile = pictures.appendingPathComponent("notes.txt")

        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try "selected context".write(to: selectedFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let broker = HostFileAccessBroker(homeDirectory: home)
        let text = try broker.readString(
            at: selectedFile,
            encoding: .utf8,
            intent: .explicitUserSelection
        )

        #expect(text == "selected context")
    }

    @Test("Broker reads use injected file manager")
    func brokerReadsUseInjectedFileManager() throws {
        let fileManager = StubContentFileManager(contents: Data("injected content".utf8))
        let broker = HostFileAccessBroker(fileManager: fileManager)
        let url = URL(fileURLWithPath: "/tmp/astra-injected-file-manager.txt")

        let text = try broker.readString(
            at: url,
            encoding: .utf8,
            intent: .explicitUserSelection
        )

        #expect(text == "injected content")
        #expect(fileManager.requestedPaths == [url.path])
    }

    @Test("Broker read data reports missing injected file manager content")
    func brokerReadDataReportsMissingInjectedFileManagerContent() throws {
        let broker = HostFileAccessBroker(fileManager: StubContentFileManager(contents: nil))

        #expect(throws: CocoaError.self) {
            try broker.readData(
                at: URL(fileURLWithPath: "/tmp/astra-missing-injected-content.txt"),
                intent: .explicitUserSelection
            )
        }
    }

    @Test("ASTRA-managed storage reads stay inside the declared root")
    func astraManagedStorageReadsStayInsideDeclaredRoot() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-host-file-broker-internal-\(UUID().uuidString)", isDirectory: true)
        let taskFolder = base.appendingPathComponent("task", isDirectory: true)
        let inside = taskFolder.appendingPathComponent("current_state.json")
        let outside = base.appendingPathComponent("outside.json")

        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        try "{}".write(to: inside, atomically: true, encoding: .utf8)
        try "leak".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }

        let broker = HostFileAccessBroker()
        #expect(try broker.readString(
            at: inside,
            encoding: .utf8,
            intent: .astraManagedStorage(root: taskFolder)
        ) == "{}")
        #expect(throws: HostFileAccessError.self) {
            try broker.readString(
                at: outside,
                encoding: .utf8,
                intent: .astraManagedStorage(root: taskFolder)
            )
        }
    }
}

private final class StubContentFileManager: FileManager {
    let contents: Data?
    private(set) var requestedPaths: [String] = []

    init(contents: Data?) {
        self.contents = contents
        super.init()
    }

    override func contents(atPath path: String) -> Data? {
        requestedPaths.append(path)
        return contents
    }
}

private final class SpyDirectoryFileManager: FileManager {
    struct DirectoryRequest: Equatable {
        let path: String
        let keys: Set<URLResourceKey>?
    }

    let childrenByPath: [String: [URL]]
    private(set) var directoryRequests: [DirectoryRequest] = []

    init(childrenByPath: [String: [URL]]) {
        self.childrenByPath = childrenByPath
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        directoryRequests.append(DirectoryRequest(path: url.path, keys: keys.map(Set.init)))
        return childrenByPath[url.path] ?? []
    }
}

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

@Suite("Plugin Package Decode Compatibility")
struct PluginPackageDecodeCompatibilityTests {
    @Test("Legacy package JSON with retired signature/isTrusted keys still decodes")
    func legacySigningKeysAreIgnored() throws {
        let json = """
        {"formatVersion":2,"id":"test","name":"Test","icon":"star","description":"desc","author":"me","category":"dev","tags":[],"version":"1.0","skills":[],"connectors":[],"localTools":[],"templates":[],"signature":"ZmFrZQ==","isTrusted":true}
        """
        let plugin = try JSONDecoder().decode(PluginPackage.self, from: json.data(using: .utf8)!)
        #expect(plugin.id == "test")
        // Retired keys must not grant trust: governance falls back to the
        // source-metadata default, which is a local draft for bare JSON.
        #expect(plugin.governance.approvalStatus == .draft)
    }
}

@Suite("Connector Security Policy")
struct ConnectorSecurityPolicyTests {
    @Test("Authenticated connectors require protected transport even when credentials come from env")
    func authenticatedConnectorsRequireProtectedTransportWithoutCredentialKeys() {
        let violation = ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: "http://api.example.com",
            authMethod: "bearer",
            credentialKeys: []
        )

        #expect(violation != nil)
    }

    @Test("Unauthenticated HTTP connectors remain allowed")
    func unauthenticatedHTTPConnectorsRemainAllowed() {
        let violation = ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: "http://api.example.com",
            authMethod: "none",
            credentialKeys: []
        )

        #expect(violation == nil)
    }
}

@Suite("Credential Storage Policy")
struct CredentialStoragePolicyTests {
    @Test("Keychain credentials are device local")
    func keychainCredentialsAreDeviceLocal() {
        #expect(
            KeychainCredentialPolicy.accessibility as String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }
}

@Suite("Session History Redaction")
struct SessionHistoryRedactionTests {
    @Test("Session history redacts short explicit secrets and common token formats")
    func sessionHistoryRedactsShortSecretsAndKnownTokenFormats() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = """
        pin xy
        github ghp_1234567890abcdef1234567890abcdef1234
        fine-grained github_pat_1234567890abcdef_1234567890abcdef
        aws AKIA1234567890ABCDEF
        anthropic sk-ant-api03-1234567890abcdef
        """

        SessionHistoryManager.recordTurn(
            taskFolder: root.path,
            taskTitle: "Redaction",
            turnMessage: "pin xy",
            output: body,
            tokensUsed: 0,
            costUSD: 0,
            fileChanges: [],
            redactions: ["xy"]
        )

        let history = try String(
            contentsOf: root.appendingPathComponent("session_history.md"),
            encoding: .utf8
        )
        let output = try String(
            contentsOf: root.appendingPathComponent("outputs/turn_001.md"),
            encoding: .utf8
        )
        let combined = history + "\n" + output

        #expect(!combined.contains("xy"))
        #expect(!combined.contains("ghp_1234567890abcdef1234567890abcdef1234"))
        #expect(!combined.contains("github_pat_1234567890abcdef_1234567890abcdef"))
        #expect(!combined.contains("AKIA1234567890ABCDEF"))
        #expect(!combined.contains("sk-ant-api03-1234567890abcdef"))
        #expect(combined.contains("[REDACTED]"))
    }
}

@Suite("Legacy Credential Removal")
struct LegacyCredentialTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // testConnection() needs AuditLoggingSeam

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

    @Test("Stable connector namespace normalizes equivalent base URLs")
    func stableConnectorNamespaceNormalizesBaseURL() {
        let first = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "https://StanfordMed.atlassian.net/"
        )
        let second = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "stanfordmed.atlassian.net"
        )

        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Package-owned stable connector namespaces include package identity")
    func packageOwnedStableConnectorNamespaceIncludesPackageIdentity() throws {
        let first = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net",
            originPackageID: "package.a",
            originComponentID: "connector:jira"
        )
        let second = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net",
            originPackageID: "package.b",
            originComponentID: "connector:jira"
        )
        let endpointOnly = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net"
        )

        #expect(first != nil)
        #expect(second != nil)
        #expect(endpointOnly != nil)
        #expect(first != second)
        #expect(first != endpointOnly)
        #expect(second != endpointOnly)
    }

    @Test("Package connector does not claim endpoint-only stable secrets")
    func packageConnectorDoesNotClaimEndpointOnlyStableSecrets() throws {
        let store = MockSecretStore()
        let endpointOnly = try #require(KeychainSecretStore.stableConnectorEntityID(
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net"
        ))
        store.save(key: "JIRA_API_TOKEN", value: "endpoint-secret", entityID: endpointOnly, label: nil)

        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        connector.originPackageID = "untrusted.package"
        connector.originComponentID = "connector:jira"
        connector.credentialKeys = ["JIRA_API_TOKEN"]

        #expect(connector.credentials(store: store)["JIRA_API_TOKEN"] == nil)
        #expect(connector.missingCredentialKeys(store: store) == ["JIRA_API_TOKEN"])
    }

    @Test("Stable connector namespace requires endpoint or package origin")
    func stableConnectorNamespaceRequiresDurableIdentity() {
        let entityID = KeychainSecretStore.stableConnectorEntityID(
            serviceType: "custom",
            baseURL: ""
        )

        #expect(entityID == nil)
    }

    @Test("Recreated connector reuses stable endpoint credentials")
    func recreatedConnectorReusesStableEndpointCredentials() throws {
        let store = MockSecretStore()
        let original = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        original.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        let stableEntityID = try #require(KeychainSecretStore.stableConnectorEntityID(for: original))
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: stableEntityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "secret-token", entityID: stableEntityID, label: nil)

        let recreated = Connector(
            name: "Jira-new",
            serviceType: "jira",
            baseURL: "stanfordmed.atlassian.net/",
            authMethod: "basic"
        )
        recreated.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let credentials = recreated.credentials(store: store)
        #expect(credentials["JIRA_EMAIL"] == "user@example.com")
        #expect(credentials["JIRA_API_TOKEN"] == "secret-token")
        #expect(recreated.missingCredentialKeys(store: store).isEmpty)
    }

    @Test("Connector UUID namespace overrides stable endpoint credentials")
    func uuidNamespaceOverridesStableEndpointCredentials() throws {
        let store = MockSecretStore()
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_API_TOKEN"]
        let stableEntityID = try #require(KeychainSecretStore.stableConnectorEntityID(for: connector))
        let uuidEntityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_API_TOKEN", value: "shared-token", entityID: stableEntityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "specific-token", entityID: uuidEntityID, label: nil)

        #expect(connector.credentials(store: store)["JIRA_API_TOKEN"] == "specific-token")
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

@Suite("Document Reader Security")
struct DocumentReaderSecurityTests {
    @Test("readfile treats Python metacharacters in document paths as data")
    func readfileTreatsPythonMetacharactersInDocumentPathsAsData() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-readfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let basePath = root.appendingPathComponent("safe").path
        try #"{"url":"https://docs.example.com/base"}"#.write(toFile: basePath, atomically: true, encoding: .utf8)
        let markerName = "pwned"
        let markerPath = root.appendingPathComponent(markerName).path
        let injectedLeaf = "safe') as f:\n    pass\nopen('\(markerName)','w').write('pwned')\n# .gdoc"
        let injectedURL = root.appendingPathComponent(injectedLeaf)
        try #"{"url":"https://docs.example.com/safe"}"#.write(to: injectedURL, atomically: true, encoding: .utf8)

        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readfile = repoRoot.appendingPathComponent("Tools/readfile")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [readfile.path, injectedURL.path]
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: error))
        #expect(output.contains("https://docs.example.com/safe"))
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }
}
