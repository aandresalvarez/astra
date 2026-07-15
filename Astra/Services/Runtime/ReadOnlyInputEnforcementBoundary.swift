import Foundation
import CryptoKit
import ASTRACore

/// The single launch-time owner for filesystem resources granted with read-only
/// access. Policy/UI projections may describe a subset of these resources, but
/// every execution surface must enforce this complete contract before a provider
/// is allowed to start.
struct ReadOnlyResourceContract: Sendable, Equatable {
    struct Resource: Sendable, Equatable {
        let canonicalPath: String
        let requestedPaths: [String]
        let sources: [TaskLaunchResourceSource]
        let isDirectory: Bool
    }

    enum ValidationFailure: Sendable, Equatable, CustomStringConvertible {
        case invalidPath(String)
        case missingPath(String)
        case multipleHardLinks(path: String, count: Int)
        case directoryScanFailed(String)
        case writableDescendant(readOnlyPath: String, writablePath: String)

        var description: String {
            switch self {
            case .invalidPath(let path):
                "invalid_path:\(path)"
            case .missingPath(let path):
                "missing_path:\(path)"
            case .multipleHardLinks(let path, let count):
                "multiple_hard_links:\(path):\(count)"
            case .directoryScanFailed(let path):
                "directory_scan_failed:\(path)"
            case .writableDescendant(let readOnlyPath, let writablePath):
                "read_write_conflict:\(readOnlyPath):\(writablePath)"
            }
        }
    }

    let resources: [Resource]
    let failures: [ValidationFailure]
    let requestedResourceCount: Int
    private let requestDescriptors: [String]

    init(
        grants: [RuntimePathGrant],
        fileManager: FileManager = .default
    ) {
        let readGrants = grants.filter { $0.access == .read }
        requestedResourceCount = readGrants.count
        requestDescriptors = readGrants.map { grant in
            "\(WorkspacePathPresentation.standardizedPath(grant.path))|\(grant.source.rawValue)|\(grant.exists)"
        }.sorted()

        struct Accumulator {
            var requestedPaths: Set<String>
            var sources: Set<String>
            var isDirectory: Bool
        }

        var byCanonicalPath: [String: Accumulator] = [:]
        var failures: [ValidationFailure] = []
        for grant in readGrants {
            let requestedPath = WorkspacePathPresentation.standardizedPath(grant.path)
            guard let canonicalPath = ExecutionSandbox.canonicalize(requestedPath) else {
                failures.append(.invalidPath(grant.path))
                continue
            }
            var isDirectory = ObjCBool(false)
            guard grant.exists,
                  fileManager.fileExists(atPath: requestedPath, isDirectory: &isDirectory) else {
                failures.append(.missingPath(requestedPath))
                continue
            }
            if isDirectory.boolValue {
                failures.append(contentsOf: Self.directoryValidationFailures(
                    at: requestedPath,
                    fileManager: fileManager
                ))
            } else if let attributes = try? fileManager.attributesOfItem(atPath: requestedPath),
                      let count = (attributes[.referenceCount] as? NSNumber)?.intValue,
                      count > 1 {
                failures.append(.multipleHardLinks(path: requestedPath, count: count))
            }
            var value = byCanonicalPath[canonicalPath] ?? Accumulator(
                requestedPaths: [],
                sources: [],
                isDirectory: isDirectory.boolValue
            )
            value.requestedPaths.insert(requestedPath)
            value.sources.insert(grant.source.rawValue)
            value.isDirectory = value.isDirectory || isDirectory.boolValue
            byCanonicalPath[canonicalPath] = value
        }

        resources = byCanonicalPath.map { path, value in
            Resource(
                canonicalPath: path,
                requestedPaths: value.requestedPaths.sorted(),
                sources: value.sources.sorted().compactMap(TaskLaunchResourceSource.init(rawValue:)),
                isDirectory: value.isDirectory
            )
        }.sorted { $0.canonicalPath < $1.canonicalPath }

        let writablePaths = grants.compactMap { grant -> String? in
            guard grant.access == .write || grant.access == .readWrite else { return nil }
            return ExecutionSandbox.canonicalize(grant.path)
        }
        for resource in resources where resource.isDirectory {
            for writablePath in writablePaths where
                writablePath == resource.canonicalPath
                    || writablePath.hasPrefix(resource.canonicalPath + "/") {
                failures.append(.writableDescendant(
                    readOnlyPath: resource.canonicalPath,
                    writablePath: writablePath
                ))
            }
        }
        for resource in resources where !resource.isDirectory {
            for writablePath in writablePaths where writablePath == resource.canonicalPath {
                failures.append(.writableDescendant(
                    readOnlyPath: resource.canonicalPath,
                    writablePath: writablePath
                ))
            }
        }

        self.failures = Array(Set(failures.map(\.description))).sorted().compactMap { description in
            failures.first { $0.description == description }
        }
    }

    private static func directoryValidationFailures(
        at directoryPath: String,
        fileManager: FileManager
    ) -> [ValidationFailure] {
        var failures: [ValidationFailure] = []
        let root = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { url, _ in
                failures.append(.directoryScanFailed(url.path))
                return false
            }
        ) else {
            return [.directoryScanFailed(directoryPath)]
        }
        for case let url as URL in enumerator {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                if let count = (attributes[.referenceCount] as? NSNumber)?.intValue,
                   count > 1 {
                    failures.append(.multipleHardLinks(path: url.path, count: count))
                }
            } catch {
                failures.append(.directoryScanFailed(url.path))
            }
        }
        return failures
    }

    /// Convenience for narrow boundary unit tests. Production launch planning
    /// always constructs the contract from typed `RuntimePathGrant` values.
    init(uncheckedPaths paths: [String]) {
        var seen: Set<String> = []
        resources = paths.compactMap { rawPath in
            guard let canonicalPath = ExecutionSandbox.canonicalize(rawPath),
                  seen.insert(canonicalPath).inserted else { return nil }
            return Resource(
                canonicalPath: canonicalPath,
                requestedPaths: [WorkspacePathPresentation.standardizedPath(rawPath)],
                sources: [.taskInput],
                isDirectory: false
            )
        }.sorted { $0.canonicalPath < $1.canonicalPath }
        failures = []
        requestedResourceCount = paths.count
        requestDescriptors = paths.map {
            "\(WorkspacePathPresentation.standardizedPath($0))|\(TaskLaunchResourceSource.taskInput.rawValue)|true"
        }.sorted()
    }

    var isRequired: Bool { requestedResourceCount > 0 }
    var isValid: Bool { failures.isEmpty && (!isRequired || !resources.isEmpty) }
    var paths: [String] { resources.map(\.canonicalPath) }

    var digest: String {
        let resolved = resources.map { resource in
            let sources = resource.sources.map(\.rawValue).sorted().joined(separator: ",")
            return "\(resource.canonicalPath)|\(resource.isDirectory)|\(sources)"
        }.joined(separator: "\n")
        let value = [
            requestDescriptors.joined(separator: "\n"),
            resolved,
            failures.map(\.description).sorted().joined(separator: "\n")
        ].joined(separator: "\n--\n")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ReadOnlyBoundarySurface: String, Sendable, Equatable, Hashable, Codable {
    case hostSeatbelt = "host_seatbelt"
    case providerContainer = "provider_container"
    case workspaceContainer = "workspace_container"
}

struct ReadOnlyBoundaryEvidence: Sendable, Equatable, Codable {
    enum Status: String, Sendable, Equatable, Codable {
        case applied
        case unavailable
    }

    let status: Status
    let contractDigest: String
    let resourceCount: Int
    let requiredSurfaces: [String]
    let appliedSurfaces: [String]
    let failureReason: String?
}

/// Typed proof produced only after every required enforcement surface has been
/// compiled and validated. Preflight manifests intentionally cannot create one.
struct ReadOnlyResourceBoundaryReceipt: Sendable, Equatable {
    struct ProtectedRoot: Sendable, Equatable {
        let path: String
        let isDirectory: Bool
    }

    let contractDigest: String
    let resourceCount: Int
    let surfaces: Set<ReadOnlyBoundarySurface>
    let protectedRoots: [ProtectedRoot]

    var evidence: ReadOnlyBoundaryEvidence {
        ReadOnlyBoundaryEvidence(
            status: .applied,
            contractDigest: contractDigest,
            resourceCount: resourceCount,
            requiredSurfaces: surfaces.map(\.rawValue).sorted(),
            appliedSurfaces: surfaces.map(\.rawValue).sorted(),
            failureReason: nil
        )
    }

    func protects(_ rawPath: String) -> Bool {
        let standardized = WorkspacePathPresentation.standardizedPath(rawPath)
        let canonical = ExecutionSandbox.canonicalize(rawPath) ?? standardized
        return protectedRoots.contains { root in
            let candidates = [standardized, canonical]
            return candidates.contains { path in
                path == root.path || (root.isDirectory && path.hasPrefix(root.path + "/"))
            }
        }
    }
}

/// Compiles a read-only resource contract into the enforcement surfaces used by
/// this run. Host providers inherit Seatbelt; provider containers and the
/// host-provider Docker workspace executor require independently validated
/// read-only mounts.
struct ReadOnlyInputEnforcementBoundary: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable {
        case none
        case hostSeatbelt = "host_seatbelt"
        case containerReadOnlyMounts = "container_read_only_mounts"
        case hostSeatbeltAndContainerReadOnlyMounts = "host_seatbelt_and_container_read_only_mounts"
    }

    let contract: ReadOnlyResourceContract
    let requiredSurfaces: Set<ReadOnlyBoundarySurface>

    init(
        contract: ReadOnlyResourceContract,
        executionEnvironment: WorkspaceExecutionEnvironment
    ) {
        self.contract = contract
        guard contract.isRequired else {
            requiredSurfaces = []
            return
        }
        var surfaces: Set<ReadOnlyBoundarySurface> = []
        if executionEnvironment.providerRunsInsideContainer {
            surfaces.insert(.providerContainer)
        } else {
            surfaces.insert(.hostSeatbelt)
        }
        if executionEnvironment.workspaceCommandsRunInsideContainer {
            surfaces.insert(.workspaceContainer)
        }
        requiredSurfaces = surfaces
    }

    init(paths: [String], executionEnvironment: WorkspaceExecutionEnvironment) {
        self.init(
            contract: ReadOnlyResourceContract(uncheckedPaths: paths),
            executionEnvironment: executionEnvironment
        )
    }

    var paths: [String] { contract.paths }
    var isRequired: Bool { contract.isRequired }
    var requiresHostSeatbelt: Bool { requiredSurfaces.contains(.hostSeatbelt) }
    var requiresContainerReadOnlyMounts: Bool {
        requiredSurfaces.contains(.providerContainer) || requiredSurfaces.contains(.workspaceContainer)
    }
    var mode: Mode {
        if requiredSurfaces.isEmpty { return .none }
        if requiresHostSeatbelt && requiresContainerReadOnlyMounts {
            return .hostSeatbeltAndContainerReadOnlyMounts
        }
        return requiresHostSeatbelt ? .hostSeatbelt : .containerReadOnlyMounts
    }

    func enforcingHostBoundary(
        in base: ExecutionSandboxSettings,
        runtime: AgentRuntimeID
    ) -> ExecutionSandboxSettings {
        guard requiresHostSeatbelt else { return base }
        var wrappedRuntimes = base.wrappedRuntimes
        wrappedRuntimes.insert(runtime)
        return ExecutionSandboxSettings(
            enforcement: .strict,
            wrappedRuntimes: wrappedRuntimes,
            allowNetwork: base.allowNetwork,
            readScope: base.readScope
        )
    }

    func enforcingHostBoundary(
        in base: ExecutionSandboxResolution,
        runtime: AgentRuntimeID
    ) -> ExecutionSandboxResolution {
        guard requiresHostSeatbelt else { return base }
        let effective = enforcingHostBoundary(in: base.effectiveSettings, runtime: runtime)
        let changed = effective != base.effectiveSettings
        return ExecutionSandboxResolution(
            storedEnforcement: base.storedEnforcement,
            effectiveSettings: effective,
            reason: changed ? .readOnlyInputBoundary : base.reason
        )
    }

    /// Returns every protected host resource that is still reachable through a
    /// writable container spelling. A read-only overlay must cover each alias;
    /// merely finding one read-only mount for the same host path is insufficient.
    func unprotectedContainerPaths(in mounts: [ExecutionEnvironmentMount]) -> [String] {
        guard requiresContainerReadOnlyMounts else { return [] }
        var unprotected: Set<String> = []

        for resource in contract.resources {
            let exposures = containerExposures(for: resource, mounts: mounts)
            if exposures.isEmpty {
                unprotected.insert(resource.canonicalPath)
                continue
            }
            for exposure in exposures where exposure.access == .readWrite {
                let covered = mounts.contains { overlay in
                    guard overlay.access == .readOnly,
                          let overlayHost = ExecutionSandbox.canonicalize(overlay.hostPath) else {
                        return false
                    }
                    let protectsHostResource = overlayHost == resource.canonicalPath
                        || (resource.isDirectory && overlayHost.hasPrefix(resource.canonicalPath + "/"))
                    guard protectsHostResource else { return false }
                    let overlayContainer = WorkspacePathPresentation.standardizedPath(overlay.containerPath)
                    return exposure.containerPath == overlayContainer
                        || exposure.containerPath.hasPrefix(overlayContainer + "/")
                }
                if !covered {
                    unprotected.insert(resource.canonicalPath)
                }
            }
        }
        return unprotected.sorted()
    }

    func receipt(
        appliedSurfaces: Set<ReadOnlyBoundarySurface>,
        mounts: [ExecutionEnvironmentMount] = []
    ) -> ReadOnlyResourceBoundaryReceipt? {
        guard contract.isValid,
              appliedSurfaces.isSuperset(of: requiredSurfaces) else { return nil }
        var roots = contract.resources.map {
            ReadOnlyResourceBoundaryReceipt.ProtectedRoot(
                path: $0.canonicalPath,
                isDirectory: $0.isDirectory
            )
        }
        for resource in contract.resources {
            for exposure in containerExposures(for: resource, mounts: mounts) where exposure.access == .readOnly {
                roots.append(ReadOnlyResourceBoundaryReceipt.ProtectedRoot(
                    path: exposure.containerPath,
                    isDirectory: resource.isDirectory
                ))
            }
        }
        var seen: Set<String> = []
        roots = roots.filter { seen.insert("\($0.path)|\($0.isDirectory)").inserted }
        return ReadOnlyResourceBoundaryReceipt(
            contractDigest: contract.digest,
            resourceCount: contract.resources.count,
            surfaces: appliedSurfaces,
            protectedRoots: roots
        )
    }

    func unavailableResult(reason: String) -> AgentProcessResult {
        let message = "ASTRA could not establish the required read-only resource boundary (\(reason)), so the provider was not launched. Read-only grants are never downgraded to advisory protection."
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: "read_only_input_boundary_unavailable",
            runtimeStopMessage: message,
            readOnlyBoundaryEvidence: ReadOnlyBoundaryEvidence(
                status: .unavailable,
                contractDigest: contract.digest,
                resourceCount: contract.requestedResourceCount,
                requiredSurfaces: requiredSurfaces.map(\.rawValue).sorted(),
                appliedSurfaces: [],
                failureReason: reason
            )
        )
    }

    private struct ContainerExposure {
        let containerPath: String
        let access: ExecutionEnvironmentMountAccess
    }

    private func containerExposures(
        for resource: ReadOnlyResourceContract.Resource,
        mounts: [ExecutionEnvironmentMount]
    ) -> [ContainerExposure] {
        mounts.compactMap { mount in
            guard let mountHost = ExecutionSandbox.canonicalize(mount.hostPath) else { return nil }
            let containerRoot = WorkspacePathPresentation.standardizedPath(mount.containerPath)
            if resource.canonicalPath == mountHost {
                return ContainerExposure(containerPath: containerRoot, access: mount.access)
            }
            if resource.canonicalPath.hasPrefix(mountHost + "/") {
                let suffix = String(resource.canonicalPath.dropFirst(mountHost.count + 1))
                return ContainerExposure(
                    containerPath: (containerRoot as NSString).appendingPathComponent(suffix),
                    access: mount.access
                )
            }
            if resource.isDirectory && mountHost.hasPrefix(resource.canonicalPath + "/") {
                return ContainerExposure(containerPath: containerRoot, access: mount.access)
            }
            return nil
        }
    }
}
