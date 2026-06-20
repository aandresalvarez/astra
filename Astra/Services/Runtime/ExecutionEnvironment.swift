import Foundation
import ASTRACore

enum ExecutionEnvironmentKind: String, Codable, CaseIterable, Sendable {
    case host
    case dockerImage = "docker_image"
    case dockerfile
    case dockerCompose = "docker_compose"
    case devcontainer
    case dockerContainer = "docker_container"

    var isContainerized: Bool { self != .host }
}

enum ExecutionEnvironmentProviderPlacement: String, Codable, Sendable {
    case host
    case container
}

enum ExecutionEnvironmentMountAccess: String, Codable, Sendable {
    case readWrite = "rw"
    case readOnly = "ro"
}

enum ExecutionEnvironmentMountRole: String, Codable, Sendable {
    case workspace
    case taskFolder = "task_folder"
    case additionalPath = "additional_path"
    case input
    case credential
}

struct ExecutionEnvironmentMount: Codable, Equatable, Hashable, Sendable {
    var hostPath: String
    var containerPath: String
    var access: ExecutionEnvironmentMountAccess
    var role: ExecutionEnvironmentMountRole

    init(
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

enum ExecutionEnvironmentCredentialProjectionKind: String, Codable, Sendable {
    case gcpADC = "gcp_adc"
    case serviceAccountFile = "service_account_file"
    case genericDirectory = "generic_directory"
    case genericFile = "generic_file"
}

struct ExecutionEnvironmentCredentialProjection: Codable, Equatable, Hashable, Sendable {
    static let gcpADCID = "gcp_adc"
    static let gcpADCContainerPath = "/root/.config/gcloud"
    static let gcpADCFileName = "application_default_credentials.json"

    var id: String
    var kind: ExecutionEnvironmentCredentialProjectionKind
    var displayName: String
    var hostPath: String
    var containerPath: String
    var access: ExecutionEnvironmentMountAccess
    var environment: [String: String]

    init(
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

    static func defaultGCPADCHostPath(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        (WorkspacePathPresentation.standardizedPath(homeDirectory) as NSString)
            .appendingPathComponent(".config/gcloud")
    }

    static func gcpADC(
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

    var mount: ExecutionEnvironmentMount {
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
}

struct WorkspaceExecutionEnvironment: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var version: Int
    var id: String
    var kind: ExecutionEnvironmentKind
    var displayName: String
    var sourcePath: String?
    var image: String?
    var imageDigest: String?
    var dockerfilePath: String?
    var composeFilePath: String?
    var composeService: String?
    var containerName: String?
    var runtimeExecutablePath: String?
    var providerPlacement: ExecutionEnvironmentProviderPlacement?
    var containerWorkingDirectory: String
    var mounts: [ExecutionEnvironmentMount]
    var environmentKeyAllowlist: [String]
    var networkMode: String
    var user: String?
    var privileged: Bool
    var allowCredentialEnvironment: Bool
    var credentialProjections: [ExecutionEnvironmentCredentialProjection]?
    var configFingerprint: String?

    init(
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

    static var host: WorkspaceExecutionEnvironment {
        WorkspaceExecutionEnvironment(
            id: "host",
            kind: .host,
            displayName: "Host",
            containerWorkingDirectory: ""
        )
    }

    var isHost: Bool { kind == .host }
    var isContainerized: Bool { kind.isContainerized }
    var effectiveProviderPlacement: ExecutionEnvironmentProviderPlacement {
        guard isContainerized else { return .host }
        return providerPlacement ?? .host
    }
    var providerRunsInsideContainer: Bool {
        isContainerized && effectiveProviderPlacement == .container
    }
    var workspaceCommandsRunInsideContainer: Bool {
        isContainerized && effectiveProviderPlacement == .host
    }
    var effectiveCredentialProjections: [ExecutionEnvironmentCredentialProjection] {
        Self.normalizedCredentialProjections(credentialProjections ?? []) ?? []
    }

    var signatureFingerprint: String {
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

    mutating func setCredentialProjections(_ projections: [ExecutionEnvironmentCredentialProjection]) {
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
        for projection in projections where !projection.id.isEmpty && !projection.hostPath.isEmpty && !projection.containerPath.isEmpty {
            byID[projection.id] = projection
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

enum ExecutionEnvironmentStore {
    static func encode(_ environment: WorkspaceExecutionEnvironment?) -> String? {
        guard let environment, !environment.isHost else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(environment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> WorkspaceExecutionEnvironment {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: data) else {
            return .host
        }
        return decoded
    }
}

struct ExecutionEnvironmentPathMapper: Equatable, Sendable {
    var mounts: [ExecutionEnvironmentMount]

    init(mounts: [ExecutionEnvironmentMount]) {
        self.mounts = mounts
            .filter { !$0.hostPath.isEmpty && !$0.containerPath.isEmpty }
            .sorted { $0.containerPath.count > $1.containerPath.count }
    }

    var isEmpty: Bool { mounts.isEmpty }

    func hostPath(forContainerPath path: String) -> String? {
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

    func containerPath(forHostPath path: String) -> String? {
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

struct DockerWorkspaceCandidate: Identifiable, Equatable, Sendable {
    var id: String { environment.id }
    var environment: WorkspaceExecutionEnvironment
    var isRunnable: Bool
    var issue: String?
}

enum DockerWorkspaceDiscoveryService {
    static func candidates(
        primaryPath: String,
        additionalPaths: [String],
        fileManager: FileManager = .default
    ) -> [DockerWorkspaceCandidate] {
        var results: [DockerWorkspaceCandidate] = []
        for descriptor in WorkspacePathPresentation.descriptors(primaryPath: primaryPath, additionalPaths: additionalPaths) {
            let root = descriptor.path
            guard directoryExists(root, fileManager: fileManager) else { continue }
            let dockerfile = firstExisting(
                ["Dockerfile", "Containerfile"].map { (root as NSString).appendingPathComponent($0) },
                fileManager: fileManager
            )
            if let dockerfile {
                let id = "dockerfile:\(dockerfile)"
                results.append(DockerWorkspaceCandidate(
                    environment: WorkspaceExecutionEnvironment(
                        id: id,
                        kind: .dockerfile,
                        displayName: "\(descriptor.title) Dockerfile",
                        sourcePath: root,
                        image: generatedImageName(for: root),
                        dockerfilePath: dockerfile,
                        runtimeExecutablePath: nil,
                        configFingerprint: fileFingerprint(at: dockerfile, fileManager: fileManager)
                    ),
                    isRunnable: false,
                    issue: "Dockerfile discovery is inert until an image has been built or loaded."
                ))
            }

            let compose = firstExisting(
                ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].map {
                    (root as NSString).appendingPathComponent($0)
                },
                fileManager: fileManager
            )
            if let compose {
                results.append(DockerWorkspaceCandidate(
                    environment: WorkspaceExecutionEnvironment(
                        id: "compose:\(compose)",
                        kind: .dockerCompose,
                        displayName: "\(descriptor.title) Compose",
                        sourcePath: root,
                        composeFilePath: compose,
                        configFingerprint: fileFingerprint(at: compose, fileManager: fileManager)
                    ),
                    isRunnable: false,
                    issue: "Compose discovery is inert until ASTRA validates service volumes, network, and hooks."
                ))
            }

            let devcontainer = (root as NSString)
                .appendingPathComponent(".devcontainer/devcontainer.json")
            if fileManager.fileExists(atPath: devcontainer) {
                results.append(DockerWorkspaceCandidate(
                    environment: WorkspaceExecutionEnvironment(
                        id: "devcontainer:\(devcontainer)",
                        kind: .devcontainer,
                        displayName: "\(descriptor.title) Dev Container",
                        sourcePath: root,
                        configFingerprint: fileFingerprint(at: devcontainer, fileManager: fileManager)
                    ),
                    isRunnable: false,
                    issue: "Dev container discovery is inert until ASTRA validates lifecycle hooks and mounts."
                ))
            }
        }
        return results
    }

    private static func directoryExists(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func firstExisting(_ paths: [String], fileManager: FileManager) -> String? {
        paths.first { fileManager.fileExists(atPath: $0) }
    }

    static func generatedImageName(for root: String) -> String {
        let base = URL(fileURLWithPath: root).lastPathComponent
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
            }
        let name = String(base).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "astra-\(name.isEmpty ? "workspace" : name)"
    }

    private static func fileFingerprint(at path: String, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let size = attributes[.size] as? NSNumber
        let modified = attributes[.modificationDate] as? Date
        return "\(WorkspacePathPresentation.standardizedPath(path)):\(size?.int64Value ?? 0):\(modified?.timeIntervalSince1970 ?? 0)"
    }
}

struct DockerRuntimeReadiness: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case ready
        case unavailable
        case unsafeRemoteContext = "unsafe_remote_context"
        case composeUnavailable = "compose_unavailable"
    }

    var state: State
    var dockerPath: String?
    var version: String?
    var contextName: String?
    var issue: String?
}

enum DockerReadinessService {
    static func evaluate(
        dockerStatus: HealthStatus,
        dockerContext: String?,
        dockerHost: String?,
        composeVersion: String? = nil,
        requiresCompose: Bool = false,
        allowRemoteContext: Bool = false
    ) -> DockerRuntimeReadiness {
        guard case let .healthy(path, version) = dockerStatus else {
            return DockerRuntimeReadiness(
                state: .unavailable,
                dockerPath: nil,
                version: nil,
                contextName: clean(dockerContext),
                issue: "Docker CLI or daemon is unavailable."
            )
        }

        let host = clean(dockerHost)
        let context = clean(dockerContext)
        if !allowRemoteContext,
           isRemoteContext(context: context, dockerHost: host) {
            return DockerRuntimeReadiness(
                state: .unsafeRemoteContext,
                dockerPath: path,
                version: version,
                contextName: context,
                issue: "ASTRA container execution requires an explicit approval before using a remote Docker context."
            )
        }

        if requiresCompose,
           clean(composeVersion) == nil {
            return DockerRuntimeReadiness(
                state: .composeUnavailable,
                dockerPath: path,
                version: version,
                contextName: context,
                issue: "Docker Compose support was not detected."
            )
        }

        return DockerRuntimeReadiness(
            state: .ready,
            dockerPath: path,
            version: version,
            contextName: context,
            issue: nil
        )
    }

    private static func isRemoteContext(context: String?, dockerHost: String?) -> Bool {
        if let host = dockerHost?.lowercased(),
           !host.isEmpty,
           !host.hasPrefix("unix://"),
           !host.hasPrefix("npipe://") {
            return true
        }
        if let context = context?.lowercased(),
           !context.isEmpty,
           context != "default",
           context != "desktop-linux" {
            return true
        }
        return false
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DockerExecutionPlanningError: LocalizedError, Equatable {
    case unsupportedEnvironment(String)
    case missingImage(String)
    case missingRuntimeExecutable
    case forbiddenMount(String)
    case privilegedDenied
    case hostNetworkDenied
    case dockerSocketDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedEnvironment(let kind):
            return "Execution environment \(kind) is discovered but not runnable yet."
        case .missingImage(let id):
            return "Docker environment \(id) has no image configured."
        case .missingRuntimeExecutable:
            return "Docker environment must declare the provider executable path inside the image."
        case .forbiddenMount(let path):
            return "Docker environment tried to mount a forbidden host path: \(path)."
        case .privilegedDenied:
            return "Privileged Docker containers are not allowed for ASTRA task execution."
        case .hostNetworkDenied:
            return "Docker host networking is not allowed for ASTRA task execution."
        case .dockerSocketDenied:
            return "Mounting the Docker socket into task containers is not allowed."
        }
    }
}

enum DockerExecutionPlanner {
    static let defaultDockerExecutable = "/usr/bin/env"

    static func resolveEnvironment(for task: AgentTask) -> WorkspaceExecutionEnvironment {
        if let snapshot = task.executionEnvironmentSnapshotJSON,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExecutionEnvironmentStore.decode(snapshot)
        }
        if let workspace = task.workspace {
            return ExecutionEnvironmentStore.decode(workspace.activeExecutionEnvironmentJSON)
        }
        return .host
    }

    static func plan(
        base: AgentRuntimeProcessLaunchPlan,
        environment: WorkspaceExecutionEnvironment,
        task: AgentTask,
        runID: UUID?,
        dockerExecutablePath: String = defaultDockerExecutable
    ) -> Result<AgentRuntimeProcessLaunchPlan, DockerExecutionPlanningError> {
        guard environment.isContainerized else { return .success(base) }
        guard environment.kind == .dockerImage || environment.kind == .dockerfile else {
            return .failure(.unsupportedEnvironment(environment.kind.rawValue))
        }
        guard !environment.privileged else { return .failure(.privilegedDenied) }
        guard environment.networkMode != "host" else { return .failure(.hostNetworkDenied) }
        guard let image = environment.image, !image.isEmpty else {
            return .failure(.missingImage(environment.id))
        }
        let mounts = mountPlan(base: base, environment: environment, task: task)
        for mount in mounts {
            let canonical = ExecutionSandbox.canonicalize(mount.hostPath) ?? mount.hostPath
            if isDockerSocketMount(rawPath: mount.hostPath, canonicalPath: canonical) {
                return .failure(.dockerSocketDenied)
            }
            if ExecutionSandbox.isForbiddenWritableRoot(canonical) || ExecutionSandbox.isOverlyBroadRoot(canonical) {
                return .failure(.forbiddenMount(mount.hostPath))
            }
        }

        let mapper = ExecutionEnvironmentPathMapper(mounts: mounts)
        let containerCurrentDirectory = mapper.containerPath(forHostPath: base.currentDirectory)
            ?? environment.containerWorkingDirectory
        let name = "astra-\(task.id.uuidString.prefix(8).lowercased())-\((runID?.uuidString.prefix(8).lowercased()) ?? "run")"
        var resolvedEnvironment = environment
        resolvedEnvironment.mounts = mounts

        guard environment.providerRunsInsideContainer else {
            return .success(hostProviderWorkspaceContainerPlan(
                base: base,
                environment: resolvedEnvironment,
                image: image,
                containerName: name,
                containerCurrentDirectory: containerCurrentDirectory,
                mounts: mounts,
                mapper: mapper
            ))
        }

        let explicitExecutable = environment.runtimeExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerExecutable = URL(fileURLWithPath: base.executablePath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let containerExecutable = explicitExecutable?.isEmpty == false ? explicitExecutable! : providerExecutable
        guard !containerExecutable.isEmpty else { return .failure(.missingRuntimeExecutable) }
        var dockerArgs = [
            "docker", "run", "--rm", "-i",
            "--name", name,
            "--label", "com.coral.astra.task=\(task.id.uuidString)",
            "--label", "com.coral.astra.environment=\(environment.id)",
            "--workdir", containerCurrentDirectory,
            "--network", environment.networkMode
        ]
        if let user = environment.user, !user.isEmpty {
            dockerArgs += ["--user", user]
        }
        for mount in mounts {
            dockerArgs += ["--volume", "\(mount.hostPath):\(mount.containerPath):\(mount.access.rawValue)"]
        }

        let allowedEnv = containerEnvironment(baseEnvironment: base.environment, environment: environment)
        for key in allowedEnv.keys.sorted() {
            dockerArgs += ["--env", key]
        }
        dockerArgs.append(image)
        dockerArgs.append(containerExecutable)
        dockerArgs.append(contentsOf: base.arguments)

        var commandFields = base.commandPlannedFields
        commandFields["execution_environment_kind"] = environment.kind.rawValue
        commandFields["execution_environment_id"] = environment.id
        commandFields["execution_environment_fingerprint"] = environment.signatureFingerprint
        commandFields["execution_environment_provider_placement"] = environment.effectiveProviderPlacement.rawValue
        commandFields["workspace_executor"] = "docker"
        commandFields["workspace_executor_mode"] = "provider_inside_container"
        commandFields["container_image"] = image
        commandFields["container_image_digest"] = environment.imageDigest ?? ""
        commandFields["container_name"] = name
        commandFields["container_workdir"] = containerCurrentDirectory
        commandFields["container_executable"] = containerExecutable
        commandFields["container_mount_count"] = String(mounts.count)
        commandFields["container_mount_summary"] = mountSummary(mounts)
        commandFields["container_network_mode"] = environment.networkMode
        commandFields["container_privileged"] = String(environment.privileged)
        commandFields["container_env_key_count"] = String(allowedEnv.count)
        commandFields["container_credential_projection_count"] = String(environment.effectiveCredentialProjections.count)
        commandFields["container_credential_projection_summary"] = credentialProjectionSummary(environment)
        commandFields["container_executable_source"] = explicitExecutable == nil ? "provider_basename" : "environment"
        commandFields["docker_argument_count"] = String(dockerArgs.count)
        commandFields["os_sandbox_claim"] = "false"

        var processEnvironment: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        for (key, value) in allowedEnv {
            processEnvironment[key] = value
        }

        return .success(AgentRuntimeProcessLaunchPlan(
            runtime: base.runtime,
            executablePath: dockerExecutablePath,
            arguments: dockerArgs,
            currentDirectory: base.currentDirectory,
            environment: processEnvironment,
            browserShimDirectory: base.browserShimDirectory,
            providerVersion: base.providerVersion,
            parsesJSONLines: base.parsesJSONLines,
            directoriesToCreate: base.directoriesToCreate,
            sandboxReadablePaths: [],
            sandboxProtectedWriteDenyPaths: [],
            providerDetectedFields: base.providerDetectedFields,
            commandPlannedFields: commandFields,
            interactiveAsk: base.interactiveAsk,
            pathMapper: mapper,
            executionEnvironment: resolvedEnvironment
        ))
    }

    private static func hostProviderWorkspaceContainerPlan(
        base: AgentRuntimeProcessLaunchPlan,
        environment: WorkspaceExecutionEnvironment,
        image: String,
        containerName: String,
        containerCurrentDirectory: String,
        mounts: [ExecutionEnvironmentMount],
        mapper: ExecutionEnvironmentPathMapper
    ) -> AgentRuntimeProcessLaunchPlan {
        let containerEnv = credentialProjectionEnvironment(environment: environment)
        var commandFields = base.commandPlannedFields
        commandFields["execution_environment_kind"] = environment.kind.rawValue
        commandFields["execution_environment_id"] = environment.id
        commandFields["execution_environment_fingerprint"] = environment.signatureFingerprint
        commandFields["execution_environment_provider_placement"] = environment.effectiveProviderPlacement.rawValue
        commandFields["workspace_executor"] = "docker"
        commandFields["workspace_executor_mode"] = "host_provider_container_workspace"
        commandFields["container_image"] = image
        commandFields["container_image_digest"] = environment.imageDigest ?? ""
        commandFields["container_name"] = containerName
        commandFields["container_workdir"] = containerCurrentDirectory
        commandFields["container_mount_count"] = String(mounts.count)
        commandFields["container_mount_summary"] = mountSummary(mounts)
        commandFields["container_network_mode"] = environment.networkMode
        commandFields["container_privileged"] = String(environment.privileged)
        commandFields["container_env_key_count"] = String(containerEnv.count)
        commandFields["container_credential_projection_count"] = String(environment.effectiveCredentialProjections.count)
        commandFields["container_credential_projection_summary"] = credentialProjectionSummary(environment)
        commandFields["container_executable_source"] = "astra_workspace_mcp"
        commandFields["os_sandbox_claim"] = "true"

        return AgentRuntimeProcessLaunchPlan(
            runtime: base.runtime,
            executablePath: base.executablePath,
            arguments: base.arguments,
            currentDirectory: base.currentDirectory,
            environment: base.environment,
            browserShimDirectory: base.browserShimDirectory,
            providerVersion: base.providerVersion,
            parsesJSONLines: base.parsesJSONLines,
            directoriesToCreate: base.directoriesToCreate,
            sandboxReadablePaths: base.sandboxReadablePaths,
            sandboxProtectedWriteDenyPaths: base.sandboxProtectedWriteDenyPaths,
            providerDetectedFields: base.providerDetectedFields,
            commandPlannedFields: commandFields,
            interactiveAsk: base.interactiveAsk,
            pathMapper: mapper,
            executionEnvironment: environment
        )
    }

    static func isDockerSocketMount(rawPath: String, canonicalPath: String? = nil) -> Bool {
        let raw = WorkspacePathPresentation.standardizedPath(rawPath)
        let canonical = canonicalPath ?? ExecutionSandbox.canonicalize(rawPath) ?? raw
        return [raw, canonical].contains { path in
            path == "/var/run/docker.sock"
                || path == "/private/var/run/docker.sock"
                || path.hasSuffix("/.docker/run/docker.sock")
        }
    }

    static func mountPlan(
        base: AgentRuntimeProcessLaunchPlan,
        environment: WorkspaceExecutionEnvironment,
        task: AgentTask
    ) -> [ExecutionEnvironmentMount] {
        mountPlan(currentDirectory: base.currentDirectory, environment: environment, task: task)
    }

    static func mountPlan(
        currentDirectory: String,
        environment: WorkspaceExecutionEnvironment,
        task: AgentTask
    ) -> [ExecutionEnvironmentMount] {
        var mounts = environment.mounts
        func appendMount(_ mount: ExecutionEnvironmentMount, avoidContainerCollision: Bool = false) {
            let standardized = WorkspacePathPresentation.standardizedPath(mount.hostPath)
            guard !standardized.isEmpty else { return }
            guard !mounts.contains(where: { $0.hostPath == standardized }) else { return }
            if avoidContainerCollision,
               mounts.contains(where: { $0.containerPath == mount.containerPath }) {
                return
            }
            mounts.append(mount)
        }
        func append(_ hostPath: String, _ containerPath: String, _ role: ExecutionEnvironmentMountRole) {
            let standardized = WorkspacePathPresentation.standardizedPath(hostPath)
            guard !standardized.isEmpty else { return }
            appendMount(ExecutionEnvironmentMount(
                hostPath: standardized,
                containerPath: containerPath,
                access: .readWrite,
                role: role
            ))
        }

        append(currentDirectory, environment.containerWorkingDirectory, .workspace)
        let taskAccess = TaskWorkspaceAccess(task: task)
        append(taskAccess.taskFolder, "/astra/task", .taskFolder)
        var index = 1
        for path in AgentRuntimeProcessRunner.runtimeAdditionalPaths(for: task) {
            let standardized = WorkspacePathPresentation.standardizedPath(path)
            guard standardized != WorkspacePathPresentation.standardizedPath(currentDirectory),
                  standardized != WorkspacePathPresentation.standardizedPath(taskAccess.taskFolder) else {
                continue
            }
            append(standardized, "/mnt/astra/path-\(index)", .additionalPath)
            index += 1
        }
        for projection in environment.effectiveCredentialProjections {
            appendMount(projection.mount, avoidContainerCollision: true)
        }
        return mounts
    }

    static func snapshotForRun(
        task: AgentTask,
        currentDirectory: String
    ) -> WorkspaceExecutionEnvironment {
        var environment = resolveEnvironment(for: task)
        guard environment.isContainerized else { return environment }
        environment.mounts = mountPlan(
            currentDirectory: currentDirectory,
            environment: environment,
            task: task
        )
        return environment
    }

    private static func containerEnvironment(
        baseEnvironment: [String: String],
        environment: WorkspaceExecutionEnvironment
    ) -> [String: String] {
        let allowed = Set(environment.environmentKeyAllowlist)
        var result: [String: String] = allowed.isEmpty
            ? [:]
            : baseEnvironment.filter { allowed.contains($0.key) }
        for (key, value) in credentialProjectionEnvironment(environment: environment) {
            result[key] = value
        }
        return result
    }

    static func credentialProjectionEnvironment(
        environment: WorkspaceExecutionEnvironment
    ) -> [String: String] {
        var result: [String: String] = [:]
        for projection in environment.effectiveCredentialProjections {
            for (key, value) in projection.environment {
                result[key] = value
            }
        }
        return result
    }

    static func credentialProjectionSummary(_ environment: WorkspaceExecutionEnvironment) -> String {
        environment.effectiveCredentialProjections
            .map { "\($0.displayName):\($0.access.rawValue):\($0.containerPath)" }
            .sorted()
            .joined(separator: ",")
    }

    static func mountSummary(_ mounts: [ExecutionEnvironmentMount]) -> String {
        mounts
            .map { "\($0.role.rawValue):\($0.access.rawValue):\($0.hostPath)=\($0.containerPath)" }
            .sorted()
            .joined(separator: ",")
    }
}

struct DockerRuntimeFailureDiagnostic: Equatable, Sendable {
    var stopReason: String
    var message: String
    var auditFields: [String: String]
}

enum DockerRuntimeFailureDiagnostics {
    static func diagnose(
        exitCode: Int,
        error: String,
        plan: AgentRuntimeProcessLaunchPlan
    ) -> DockerRuntimeFailureDiagnostic? {
        guard plan.executionEnvironment.isContainerized else { return nil }
        let cleanedError = oneLine(error)
        guard !cleanedError.isEmpty else { return nil }

        let lower = cleanedError.lowercased()
        guard looksLikeDockerLaunchFailure(lower) else { return nil }

        let environment = plan.executionEnvironment
        let image = clean(plan.commandPlannedFields["container_image"]) ?? environment.image ?? "selected image"
        let executable = clean(plan.commandPlannedFields["container_executable"])
            ?? clean(environment.runtimeExecutablePath)
            ?? URL(fileURLWithPath: plan.executablePath).lastPathComponent
        var fields = baseFields(
            exitCode: exitCode,
            error: cleanedError,
            image: image,
            executable: executable,
            plan: plan
        )

        if let missingExecutable = missingExecutable(in: cleanedError) {
            fields["docker_failure_kind"] = "provider_executable_missing"
            fields["missing_executable"] = missingExecutable
            return DockerRuntimeFailureDiagnostic(
                stopReason: TaskRunStopReason.dockerProviderExecutableMissing.rawValue,
                message: """
                Missing provider executable "\(missingExecutable)" inside Docker image \(image). ASTRA started Docker, but Docker could not exec the provider command in the container. Build or select an ASTRA-ready image that includes the provider CLI on PATH, or set the container runtime executable to a valid path.
                """,
                auditFields: fields
            )
        }

        if dockerDaemonUnavailable(lower) {
            fields["docker_failure_kind"] = "daemon_unavailable"
            return DockerRuntimeFailureDiagnostic(
                stopReason: TaskRunStopReason.dockerDaemonUnavailable.rawValue,
                message: "Docker is not available to run image \(image). Start Docker Desktop, verify the local Docker context, then retry the task.",
                auditFields: fields
            )
        }

        if imageUnavailable(lower) {
            fields["docker_failure_kind"] = "image_unavailable"
            return DockerRuntimeFailureDiagnostic(
                stopReason: TaskRunStopReason.dockerImageUnavailable.rawValue,
                message: "Docker could not load image \(image). Build or pull the image, then retry the task.",
                auditFields: fields
            )
        }

        if mountFailed(lower) {
            fields["docker_failure_kind"] = "mount_failed"
            return DockerRuntimeFailureDiagnostic(
                stopReason: TaskRunStopReason.dockerMountFailed.rawValue,
                message: "Docker could not mount one of the ASTRA workspace paths into image \(image). Review the Docker failure diagnostic, fix the mount or sharing permission, then retry.",
                auditFields: fields
            )
        }

        fields["docker_failure_kind"] = "launch_failed"
        return DockerRuntimeFailureDiagnostic(
            stopReason: TaskRunStopReason.dockerLaunchFailed.rawValue,
            message: "Docker could not start image \(image). Review the Docker failure diagnostic for the daemon error, then retry the task.",
            auditFields: fields
        )
    }

    private static func baseFields(
        exitCode: Int,
        error: String,
        image: String,
        executable: String,
        plan: AgentRuntimeProcessLaunchPlan
    ) -> [String: String] {
        var fields = plan.commandPlannedFields
        fields["reason"] = "docker_runtime_launch_failed"
        fields["runtime"] = plan.runtime.rawValue
        fields["docker_exit_code"] = String(exitCode)
        fields["container_image"] = image
        fields["container_executable"] = executable
        fields["docker_error"] = clipped(error, limit: 1_400)
        return fields
    }

    private static func looksLikeDockerLaunchFailure(_ lower: String) -> Bool {
        [
            "docker:",
            "cannot connect to the docker daemon",
            "failed to connect to the docker api",
            "runc create failed",
            "failed to create shim task",
            "error during container init",
            "unable to start container process",
            "invalid mount config",
            "mounts denied",
            "no such image",
            "unable to find image",
            "pull access denied"
        ].contains { lower.contains($0) }
    }

    private static func missingExecutable(in error: String) -> String? {
        let lower = error.lowercased()
        guard lower.contains("exec: \""),
              lower.contains("error during container init"),
              lower.contains("unable to start container process"),
              lower.contains("executable file not found in $path")
                || lower.contains("no such file or directory") else {
            return nil
        }
        let marker = "exec: \""
        guard let start = error.range(of: marker) else { return nil }
        let tail = error[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let executable = tail[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return executable.isEmpty ? nil : String(executable)
    }

    private static func dockerDaemonUnavailable(_ lower: String) -> Bool {
        lower.contains("cannot connect to the docker daemon")
            || lower.contains("failed to connect to the docker api")
            || lower.contains("is the docker daemon running")
            || lower.contains("docker daemon is not running")
    }

    private static func imageUnavailable(_ lower: String) -> Bool {
        lower.contains("no such image")
            || lower.contains("unable to find image")
            || lower.contains("pull access denied")
            || lower.contains("repository does not exist")
            || lower.contains("manifest unknown")
    }

    private static func mountFailed(_ lower: String) -> Bool {
        lower.contains("invalid mount config")
            || lower.contains("mounts denied")
            || lower.contains("mount denied")
    }

    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + " [truncated]"
    }
}

enum DockerWorkspaceMCPProjection {
    static let serverID = "astra_workspace"
    static let toolName = "workspace_shell"
    static let providerToolPermission = "mcp__\(serverID)__\(toolName)"

    static func isEnabled(for environment: WorkspaceExecutionEnvironment) -> Bool {
        environment.workspaceCommandsRunInsideContainer
    }

    static func supportsHostProviderWorkspaceExecutor(runtime: AgentRuntimeID) -> Bool {
        runtime == .claudeCode
    }

    static func resolvedServer(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        currentDirectory: String,
        runID: UUID?
    ) -> MCPRuntimeProjection.ResolvedServer? {
        guard isEnabled(for: environment) else { return nil }
        return MCPRuntimeProjection.ResolvedServer(
            packageID: "astra-builtin",
            server: PluginMCPServer(
                id: serverID,
                displayName: "ASTRA Workspace Shell",
                transport: .stdio,
                command: astraWorkspaceToolPath(),
                arguments: [],
                environmentKeys: environmentKeys,
                allowedTools: [toolName],
                trustLevel: .high
            ),
            permittedEnvironmentKeys: Set(environmentKeys)
        )
    }

    static func environmentVariables(
        task: AgentTask,
        environment: WorkspaceExecutionEnvironment,
        currentDirectory: String,
        runID: UUID?
    ) -> [String: String] {
        guard isEnabled(for: environment),
              let image = environment.image,
              !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let mounts = DockerExecutionPlanner.mountPlan(
            currentDirectory: currentDirectory,
            environment: environment,
            task: task
        )
        let mapper = ExecutionEnvironmentPathMapper(mounts: mounts)
        let workdir = mapper.containerPath(forHostPath: currentDirectory) ?? environment.containerWorkingDirectory
        let containerName = containerName(taskID: task.id, runID: runID)
        let containerEnv = DockerExecutionPlanner.credentialProjectionEnvironment(environment: environment)
        return [
            "ASTRA_WORKSPACE_DOCKER_EXECUTABLE": "docker",
            "ASTRA_WORKSPACE_DOCKER_IMAGE": image,
            "ASTRA_WORKSPACE_DOCKER_CONTAINER": containerName,
            "ASTRA_WORKSPACE_DOCKER_WORKDIR": workdir,
            "ASTRA_WORKSPACE_DOCKER_NETWORK": environment.networkMode,
            "ASTRA_WORKSPACE_DOCKER_MOUNTS": mountsJSON(mounts),
            "ASTRA_WORKSPACE_DOCKER_ENV": containerEnvironmentJSON(containerEnv),
            "ASTRA_WORKSPACE_TASK_ID": task.id.uuidString,
            "ASTRA_WORKSPACE_RUN_ID": runID?.uuidString ?? "run"
        ]
    }

    static func removingNativeShellTools(_ tools: [String]) -> [String] {
        tools.filter { !isNativeShellTool($0) }
    }

    static func containerName(taskID: UUID, runID: UUID?) -> String {
        "astra-\(taskID.uuidString.prefix(8).lowercased())-\((runID?.uuidString.prefix(8).lowercased()) ?? "run")"
    }

    private static let environmentKeys = [
        "ASTRA_WORKSPACE_DOCKER_EXECUTABLE",
        "ASTRA_WORKSPACE_DOCKER_IMAGE",
        "ASTRA_WORKSPACE_DOCKER_CONTAINER",
        "ASTRA_WORKSPACE_DOCKER_WORKDIR",
        "ASTRA_WORKSPACE_DOCKER_NETWORK",
        "ASTRA_WORKSPACE_DOCKER_MOUNTS",
        "ASTRA_WORKSPACE_DOCKER_ENV",
        "ASTRA_WORKSPACE_TASK_ID",
        "ASTRA_WORKSPACE_RUN_ID"
    ]

    private struct MountPayload: Codable {
        var hostPath: String
        var containerPath: String
        var access: String
        var role: String
    }

    private static func astraWorkspaceToolPath() -> String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent("astra-workspace")
    }

    private static func mountsJSON(_ mounts: [ExecutionEnvironmentMount]) -> String {
        let payload = mounts.map {
            MountPayload(
                hostPath: $0.hostPath,
                containerPath: $0.containerPath,
                access: $0.access.rawValue,
                role: $0.role.rawValue
            )
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func containerEnvironmentJSON(_ environment: [String: String]) -> String {
        guard !environment.isEmpty,
              let data = try? JSONEncoder().encode(environment),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func isNativeShellTool(_ tool: String) -> Bool {
        let base = tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .lowercased() ?? ""
        return base == "bash" || base == "shell"
    }
}
