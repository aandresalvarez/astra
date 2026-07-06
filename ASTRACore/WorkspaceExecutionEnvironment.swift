import Foundation

// Moved from `Astra/Services/Runtime/ExecutionEnvironment.swift` as part of
// Track A2 (breaking the Models↔Runtime cycle documented in
// docs/architecture/swiftpm-target-extraction-models-persistence.md, Finding 2):
// `Astra/Models/AgentTask.swift` and `Astra/Models/TaskRun.swift` construct and
// decode these types directly. Everything here is a pure value type
// (Codable/Equatable/Sendable, Foundation-only) with one narrow exception —
// `ExecutionEnvironmentCredentialProjection`'s GCP-ADC host-path check, which
// needs `ExecutionSandbox`'s broad-root denylist and cannot duplicate or pull
// in that ~1,070-line security policy file. That one check goes through the
// `ExecutionPathSafety` seam declared in `RuntimeSeams.swift`; the app
// target's `ExecutionSandbox` conforms and registers via
// `RuntimeSeamRegistration.swift`. No other logic changed: `Codable`
// conformance is still fully synthesized (no custom `CodingKeys`/
// `init(from:)`/`encode(to:)` before or after this move), so persisted JSON
// (`AgentTask.executionEnvironmentSnapshotJSON`,
// `TaskRun.executionEnvironmentSnapshotJSON`,
// `Workspace.activeExecutionEnvironmentJSON`) is byte-identical.

public enum ExecutionEnvironmentKind: String, Codable, CaseIterable, Sendable {
    case host
    case dockerImage = "docker_image"
    case dockerfile
    case dockerCompose = "docker_compose"
    case devcontainer
    case dockerContainer = "docker_container"

    public var isContainerized: Bool { self != .host }
}

public enum ExecutionEnvironmentProviderPlacement: String, Codable, Sendable {
    case host
    case container
}

public enum ExecutionEnvironmentMountAccess: String, Codable, Sendable {
    case readWrite = "rw"
    case readOnly = "ro"
}

public enum ExecutionEnvironmentMountRole: String, Codable, Sendable {
    case workspace
    case taskFolder = "task_folder"
    case additionalPath = "additional_path"
    case input
    case credential
}

public struct ExecutionEnvironmentMount: Codable, Equatable, Hashable, Sendable {
    public var hostPath: String
    public var containerPath: String
    public var access: ExecutionEnvironmentMountAccess
    public var role: ExecutionEnvironmentMountRole

    public init(
        hostPath: String,
        containerPath: String,
        access: ExecutionEnvironmentMountAccess,
        role: ExecutionEnvironmentMountRole
    ) {
        self.hostPath = WorkspacePathPresentation.standardizedPath(hostPath)
        self.containerPath = Self.normalizedContainerPath(containerPath)
        self.access = access
        self.role = role
    }

    private static func normalizedContainerPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(fileURLWithPath: prefixed).standardizedFileURL.path
    }
}

public enum ExecutionEnvironmentCredentialProjectionKind: String, Codable, Sendable {
    case gcpADC = "gcp_adc"
    case serviceAccountFile = "service_account_file"
    case genericDirectory = "generic_directory"
    case genericFile = "generic_file"
}

public struct ExecutionEnvironmentCredentialProjection: Codable, Equatable, Hashable, Sendable {
    public static let gcpADCID = "gcp_adc"
    public static let gcpADCContainerPath = "/root/.config/gcloud"
    public static let gcpADCFileName = "application_default_credentials.json"

    public var id: String
    public var kind: ExecutionEnvironmentCredentialProjectionKind
    public var displayName: String
    public var hostPath: String
    public var containerPath: String
    public var access: ExecutionEnvironmentMountAccess
    public var environment: [String: String]

    public init(
        id: String,
        kind: ExecutionEnvironmentCredentialProjectionKind,
        displayName: String,
        hostPath: String,
        containerPath: String,
        access: ExecutionEnvironmentMountAccess = .readOnly,
        environment: [String: String] = [:]
    ) {
        self.id = Self.cleanString(id) ?? kind.rawValue
        self.kind = kind
        self.displayName = Self.cleanString(displayName) ?? kind.rawValue
        self.hostPath = WorkspacePathPresentation.standardizedPath(hostPath)
        self.containerPath = Self.normalizedContainerPath(containerPath)
        self.access = access
        self.environment = Self.normalizedEnvironment(environment)
    }

    public static func defaultGCPADCHostPath(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        (WorkspacePathPresentation.standardizedPath(homeDirectory) as NSString)
            .appendingPathComponent(".config/gcloud")
    }

    public static func gcpADC(
        hostPath: String = defaultGCPADCHostPath(),
        containerPath: String = gcpADCContainerPath
    ) -> ExecutionEnvironmentCredentialProjection {
        ExecutionEnvironmentCredentialProjection(
            id: gcpADCID,
            kind: .gcpADC,
            displayName: "GCP Application Default Credentials",
            hostPath: hostPath,
            containerPath: containerPath,
            access: .readOnly,
            environment: [
                "CLOUDSDK_CONFIG": containerPath,
                "GOOGLE_APPLICATION_CREDENTIALS": (containerPath as NSString)
                    .appendingPathComponent(gcpADCFileName)
            ]
        )
    }

    public func sanitizedForRuntime() -> ExecutionEnvironmentCredentialProjection? {
        switch kind {
        case .gcpADC:
            guard id == Self.gcpADCID,
                  Self.isApprovedGCPADCHostPath(hostPath),
                  !hostPath.isEmpty else {
                return nil
            }
            return Self.gcpADC(hostPath: hostPath)
        case .serviceAccountFile, .genericDirectory, .genericFile:
            return nil
        }
    }

    public var mount: ExecutionEnvironmentMount {
        ExecutionEnvironmentMount(
            hostPath: hostPath,
            containerPath: containerPath,
            access: access,
            role: .credential
        )
    }

    private static func cleanString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedContainerPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(fileURLWithPath: prefixed).standardizedFileURL.path
    }

    private static func normalizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let (key, value) = pair
            let cleanedKey = cleanEnvironmentKey(key)
            guard !cleanedKey.isEmpty else { return }
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else { return }
            result[cleanedKey] = cleanedValue
        }
    }

    private static func cleanEnvironmentKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }

    /// Goes through the `ExecutionPathSafety` seam rather than calling
    /// `ExecutionSandbox` directly — see this file's header comment.
    private static func isApprovedGCPADCHostPath(_ path: String) -> Bool {
        let standardized = WorkspacePathPresentation.standardizedPath(path)
        guard !standardized.isEmpty else { return false }
        let nsPath = standardized as NSString
        guard nsPath.lastPathComponent == "gcloud",
              (nsPath.deletingLastPathComponent as NSString).lastPathComponent == ".config" else {
            return false
        }
        let checker = ExecutionPathSafety.required
        // `canonicalize` returns nil only for input it judges unsafe to even
        // resolve (empty, an interior newline, or a relative path that can't
        // anchor a sandbox rule) — never because the directory doesn't exist
        // yet. Fail closed rather than silently skipping the root checks.
        guard let canonical = checker.canonicalize(standardized) else {
            return false
        }
        guard !checker.isForbiddenReadableRoot(canonical),
              !checker.isForbiddenWritableRoot(canonical),
              !checker.isOverlyBroadRoot(canonical) else {
            return false
        }
        return true
    }
}

public struct WorkspaceExecutionEnvironment: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var version: Int
    public var id: String
    public var kind: ExecutionEnvironmentKind
    public var displayName: String
    public var sourcePath: String?
    public var image: String?
    public var imageDigest: String?
    public var dockerfilePath: String?
    public var composeFilePath: String?
    public var composeService: String?
    public var containerName: String?
    public var runtimeExecutablePath: String?
    public var providerPlacement: ExecutionEnvironmentProviderPlacement?
    public var containerWorkingDirectory: String
    public var mounts: [ExecutionEnvironmentMount]
    public var environmentKeyAllowlist: [String]
    public var networkMode: String
    public var user: String?
    public var privileged: Bool
    public var allowCredentialEnvironment: Bool
    public var credentialProjections: [ExecutionEnvironmentCredentialProjection]?
    public var configFingerprint: String?

    public init(
        version: Int = WorkspaceExecutionEnvironment.currentSchemaVersion,
        id: String,
        kind: ExecutionEnvironmentKind,
        displayName: String,
        sourcePath: String? = nil,
        image: String? = nil,
        imageDigest: String? = nil,
        dockerfilePath: String? = nil,
        composeFilePath: String? = nil,
        composeService: String? = nil,
        containerName: String? = nil,
        runtimeExecutablePath: String? = nil,
        providerPlacement: ExecutionEnvironmentProviderPlacement? = nil,
        containerWorkingDirectory: String = "/workspace",
        mounts: [ExecutionEnvironmentMount] = [],
        environmentKeyAllowlist: [String] = [],
        networkMode: String = "bridge",
        user: String? = nil,
        privileged: Bool = false,
        allowCredentialEnvironment: Bool = false,
        credentialProjections: [ExecutionEnvironmentCredentialProjection] = [],
        configFingerprint: String? = nil
    ) {
        self.version = version
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "host" : id
        self.kind = kind
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.rawValue : displayName
        self.sourcePath = Self.cleanPath(sourcePath)
        self.image = Self.cleanString(image)
        self.imageDigest = Self.cleanString(imageDigest)
        self.dockerfilePath = Self.cleanPath(dockerfilePath)
        self.composeFilePath = Self.cleanPath(composeFilePath)
        self.composeService = Self.cleanString(composeService)
        self.containerName = Self.cleanString(containerName)
        self.runtimeExecutablePath = Self.cleanString(runtimeExecutablePath)
        self.providerPlacement = providerPlacement
        self.containerWorkingDirectory = Self.normalizedContainerPath(containerWorkingDirectory)
        self.mounts = mounts
        self.environmentKeyAllowlist = Array(Set(environmentKeyAllowlist.map(Self.cleanEnvironmentKey).filter { !$0.isEmpty })).sorted()
        self.networkMode = Self.cleanString(networkMode) ?? "bridge"
        self.user = Self.cleanString(user)
        self.privileged = privileged
        self.allowCredentialEnvironment = allowCredentialEnvironment
        self.credentialProjections = Self.normalizedCredentialProjections(credentialProjections)
        self.configFingerprint = Self.cleanString(configFingerprint)
    }

    public static var host: WorkspaceExecutionEnvironment {
        WorkspaceExecutionEnvironment(
            id: "host",
            kind: .host,
            displayName: "Host",
            containerWorkingDirectory: ""
        )
    }

    public var isHost: Bool { kind == .host }
    public var isContainerized: Bool { kind.isContainerized }
    public var effectiveProviderPlacement: ExecutionEnvironmentProviderPlacement {
        guard isContainerized else { return .host }
        return providerPlacement ?? .host
    }
    public var providerRunsInsideContainer: Bool {
        isContainerized && effectiveProviderPlacement == .container
    }
    public var workspaceCommandsRunInsideContainer: Bool {
        isContainerized && effectiveProviderPlacement == .host
    }
    public var workspaceCommandPlacement: String {
        isContainerized ? "docker" : "host"
    }
    public var workspaceShellRoute: String {
        guard isContainerized else { return "native_host" }
        return workspaceCommandsRunInsideContainer ? "astra_workspace_mcp" : "provider_inside_container"
    }
    public var effectiveCredentialProjections: [ExecutionEnvironmentCredentialProjection] {
        Self.normalizedCredentialProjections(credentialProjections ?? []) ?? []
    }

    public var signatureFingerprint: String {
        [
            "v=\(version)",
            "id=\(id)",
            "kind=\(kind.rawValue)",
            "source=\(sourcePath ?? "")",
            "image=\(image ?? "")",
            "digest=\(imageDigest ?? "")",
            "dockerfile=\(dockerfilePath ?? "")",
            "compose=\(composeFilePath ?? "")",
            "service=\(composeService ?? "")",
            "container=\(containerName ?? "")",
            "exe=\(runtimeExecutablePath ?? "")",
            "provider=\(effectiveProviderPlacement.rawValue)",
            "workdir=\(containerWorkingDirectory)",
            "mounts=\(mounts.map { "\($0.role.rawValue):\($0.access.rawValue):\($0.hostPath)=\($0.containerPath)" }.sorted().joined(separator: ","))",
            "env=\(environmentKeyAllowlist.joined(separator: ","))",
            "network=\(networkMode)",
            "user=\(user ?? "")",
            "privileged=\(privileged)",
            "credentials=\(allowCredentialEnvironment)",
            "credential_projections=\(credentialProjectionFingerprint)",
            "config=\(configFingerprint ?? "")"
        ].joined(separator: "\u{1f}")
    }

    public mutating func setCredentialProjections(_ projections: [ExecutionEnvironmentCredentialProjection]) {
        credentialProjections = Self.normalizedCredentialProjections(projections)
    }

    private static func cleanString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanPath(_ value: String?) -> String? {
        guard let value = cleanString(value) else { return nil }
        return WorkspacePathPresentation.standardizedPath(value)
    }

    private static func cleanEnvironmentKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }

    private static func normalizedContainerPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(fileURLWithPath: prefixed).standardizedFileURL.path
    }

    private static func normalizedCredentialProjections(
        _ projections: [ExecutionEnvironmentCredentialProjection]
    ) -> [ExecutionEnvironmentCredentialProjection]? {
        var byID: [String: ExecutionEnvironmentCredentialProjection] = [:]
        for projection in projections {
            guard let sanitized = projection.sanitizedForRuntime(),
                  !sanitized.id.isEmpty,
                  !sanitized.hostPath.isEmpty,
                  !sanitized.containerPath.isEmpty else {
                continue
            }
            byID[sanitized.id] = sanitized
        }
        let normalized = byID.values.sorted { $0.id < $1.id }
        return normalized.isEmpty ? nil : normalized
    }

    private var credentialProjectionFingerprint: String {
        effectiveCredentialProjections
            .map {
                let envKeys = $0.environment.keys.sorted().joined(separator: "|")
                return "\($0.id):\($0.kind.rawValue):\($0.access.rawValue):\($0.hostPath)=\($0.containerPath):env=\(envKeys)"
            }
            .joined(separator: ",")
    }
}

public enum ExecutionEnvironmentStore {
    public static func encode(_ environment: WorkspaceExecutionEnvironment?) -> String? {
        guard let environment, !environment.isHost else { return nil }
        return encodeRaw(environment)
    }

    public static func encodeSnapshot(_ environment: WorkspaceExecutionEnvironment?) -> String? {
        encodeRaw(environment ?? .host)
    }

    private static func encodeRaw(_ environment: WorkspaceExecutionEnvironment) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(environment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> WorkspaceExecutionEnvironment {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: data) else {
            return .host
        }
        return decoded
    }
}

public struct ExecutionEnvironmentPathMapper: Equatable, Sendable {
    public var mounts: [ExecutionEnvironmentMount]

    public init(mounts: [ExecutionEnvironmentMount]) {
        self.mounts = mounts
            .filter { !$0.hostPath.isEmpty && !$0.containerPath.isEmpty }
            .sorted { $0.containerPath.count > $1.containerPath.count }
    }

    public var isEmpty: Bool { mounts.isEmpty }

    public func hostPath(forContainerPath path: String) -> String? {
        let normalized = normalizedAbsolutePath(path)
        guard !normalized.isEmpty else { return nil }
        for mount in mounts {
            if normalized == mount.containerPath {
                return mount.hostPath
            }
            let prefix = mount.containerPath + "/"
            if normalized.hasPrefix(prefix) {
                let suffix = String(normalized.dropFirst(prefix.count))
                return (mount.hostPath as NSString).appendingPathComponent(suffix)
            }
        }
        return nil
    }

    public func containerPath(forHostPath path: String) -> String? {
        let normalized = WorkspacePathPresentation.standardizedPath(path)
        guard !normalized.isEmpty else { return nil }
        let hostSorted = mounts.sorted { $0.hostPath.count > $1.hostPath.count }
        for mount in hostSorted {
            if normalized == mount.hostPath {
                return mount.containerPath
            }
            let prefix = mount.hostPath + "/"
            if normalized.hasPrefix(prefix) {
                let suffix = String(normalized.dropFirst(prefix.count))
                return (mount.containerPath as NSString).appendingPathComponent(suffix)
            }
        }
        return nil
    }

    private func normalizedAbsolutePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
