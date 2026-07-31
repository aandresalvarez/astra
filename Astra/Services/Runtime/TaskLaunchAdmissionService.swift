import CryptoKit
import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct TaskRuntimeAdmissionCandidate {
    let runtime: AgentRuntimeID
    let capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    let launchResourcePlan: TaskLaunchResourcePlan
    let requirements: TaskRuntimeRequirementSet
    let incompatibilities: [TaskRuntimeIncompatibility]
    let policyDiagnostics: [PolicyDiagnostic]
    let runtimeEvidence: [String]
    let contractDigest: String

    var isEligible: Bool {
        incompatibilities.isEmpty
            && !policyDiagnostics.contains { $0.severity == .blocked }
    }

    var blockingReason: String? {
        if let incompatibility = incompatibilities.first {
            return incompatibility.userFacingName
        }
        return policyDiagnostics.first {
            $0.severity == PolicyDiagnosticSeverity.blocked
        }?.message
    }
}

struct TaskRuntimeEligibilitySnapshot {
    let taskID: UUID
    let intent: TaskTurnIntentSnapshot
    let requestedRuntime: AgentRuntimeID
    let selectedRuntime: AgentRuntimeID
    let candidates: [AgentRuntimeID: TaskRuntimeAdmissionCandidate]
    let launchBlock: TaskRuntimeCompatibilityLaunchBlock?

    var selectedCandidate: TaskRuntimeAdmissionCandidate {
        candidates[selectedRuntime] ?? candidates[requestedRuntime]!
    }

    var suggestedRuntime: AgentRuntimeID? {
        launchBlock?.suggestedRuntime
    }
}

@MainActor
enum TaskLaunchAdmissionService {
    typealias RuntimeProfileProvider = (
        AgentRuntimeID,
        AgentRuntimeLaunchSettings
    ) -> AgentRuntimeCapabilityProfile
    typealias RuntimeUsabilityProvider = (
        AgentRuntimeID,
        AgentRuntimeLaunchSettings
    ) -> Bool
    typealias HostControlBrokerAvailabilityProvider = () -> Bool

    static func evaluate(
        task: AgentTask,
        intent: TaskTurnIntentSnapshot,
        requestedRuntime: AgentRuntimeID,
        runtimeConfiguration: AgentRuntimeConfiguration,
        executionPolicy: AgentRuntimeExecutionPolicy,
        fallbackPermissionPolicy: PermissionPolicy,
        defaultPolicyLevelRaw: String,
        phase: RunPhase,
        candidateRuntimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        secretStore: SecretStore = AdmissionMetadataSecretStore(),
        profile: RuntimeProfileProvider = { runtime, settings in
            AgentRuntimeCapabilityProfileService.profile(
                for: runtime,
                executablePath: settings.executablePath
            )
        },
        isRuntimeUsable: RuntimeUsabilityProvider = { _, settings in
            !settings.executablePath.isEmpty
                && FileManager.default.isExecutableFile(atPath: settings.executablePath)
        },
        isHostControlBrokerAvailable: HostControlBrokerAvailabilityProvider = {
            HostControlBrokerReadiness.isAvailable()
        }
    ) -> TaskRuntimeEligibilitySnapshot {
        let runtimes = uniqueRuntimes([requestedRuntime] + candidateRuntimes)
        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
        let contextText = intent.activationText
        let hostControlBrokerAvailable = isHostControlBrokerAvailable()
        var candidates: [AgentRuntimeID: TaskRuntimeAdmissionCandidate] = [:]

        for runtime in runtimes {
            let adapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)
            let settings = adapter.launchSettings(configuration: runtimeConfiguration)
            let runtimeProfile = profile(runtime, settings)
            let executionGrants = executionPolicy.permissionGrantsOverride ?? []
            let capabilitySnapshot = TaskCapabilityResolutionSnapshot.capture(
                for: task,
                providerLaunchContextText: contextText,
                additionalCredentialGrants: executionGrants,
                turnIntentSnapshot: intent,
                runtime: runtime,
                secretStore: secretStore
            )
            let requirements = TaskRuntimeRequirementSet.derive(
                task: task,
                capabilityResolutionSnapshot: capabilitySnapshot,
                executionEnvironment: environment,
                browserBridgeAttached: capabilitySnapshot.providerLaunch.exposesBrowserBridge
            )
            let runtimeGrants = PermissionBroker.sanitizeApprovedGrants(
                TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: runtime)
                    + executionGrants
            )
            let effectivePermissionPolicy = candidatePermissionPolicy(
                task: task,
                runtime: runtime,
                fallbackPermissionPolicy: fallbackPermissionPolicy,
                defaultPolicyLevelRaw: defaultPolicyLevelRaw,
                executionPolicy: executionPolicy
            )
            let resourcePlan = TaskLaunchResourceResolver.resolve(
                task: task,
                runID: nil,
                runtime: runtime,
                phase: phase,
                prompt: contextText,
                contextText: contextText,
                workspacePath: workspacePath,
                executionEnvironment: environment,
                capabilityResolutionSnapshot: capabilitySnapshot,
                runtimePermissionGrants: runtimeGrants,
                permissionPolicy: effectivePermissionPolicy,
                workspaceAccess: executionPolicy.workspaceAccessOverride ?? .exclusive,
                connectorSecretStore: secretStore,
                precomputedRuntimeRequirements: requirements
            )
            let transportIncompatibilities = TaskRuntimeCompatibilityService.incompatibilities(
                runtime: runtime,
                requirements: requirements,
                profile: runtimeProfile,
                isRuntimeUsable: isRuntimeUsable(runtime, settings),
                isHostControlBrokerAvailable: hostControlBrokerAvailable
            )
            let resourceIncompatibilities = resourcePlan.diagnostics.compactMap {
                $0.severity == .error
                    ? TaskRuntimeIncompatibility.invalidLaunchResourceContract(reason: $0.message)
                    : nil
            }
            let providerCapabilities = adapter.policyCapabilities(
                executablePath: settings.executablePath
            )
            let manifest = AgentPolicyManifestService.compilePreflightManifest(
                task: task,
                runID: task.id,
                runtime: runtime,
                model: task.model,
                workspacePath: workspacePath,
                phase: phase,
                permissionPolicy: effectivePermissionPolicy,
                executionPolicy: executionPolicy,
                defaultPolicyLevelRaw: defaultPolicyLevelRaw,
                providerCapabilities: providerCapabilities,
                runtimeCapabilityProfile: runtimeProfile,
                contextText: contextText,
                capabilityResolutionSnapshot: capabilitySnapshot,
                launchResourcePlan: resourcePlan,
                precomputedRuntimeRequirements: requirements
            )
            let blockedPolicyDiagnostics = manifest.providerRender.diagnostics.filter {
                $0.severity == PolicyDiagnosticSeverity.blocked
            }
            let policyIncompatibilities = blockedPolicyDiagnostics.map {
                TaskRuntimeIncompatibility.policyBlocked(reason: $0.message)
            }
            let contract = LaunchResourceContract(plan: resourcePlan)
            candidates[runtime] = TaskRuntimeAdmissionCandidate(
                runtime: runtime,
                capabilityResolutionSnapshot: capabilitySnapshot,
                launchResourcePlan: resourcePlan,
                requirements: requirements,
                incompatibilities: transportIncompatibilities
                    + resourceIncompatibilities
                    + policyIncompatibilities,
                policyDiagnostics: manifest.providerRender.diagnostics,
                runtimeEvidence: runtimeProfile.observedEvidence,
                contractDigest: contractDigest(
                    intent: intent,
                    snapshot: capabilitySnapshot,
                    contract: contract
                )
            )
        }

        let requestedCandidate = candidates[requestedRuntime]!
        let fallback = orderedFallbackRuntimes(
            requestedRuntime: requestedRuntime,
            defaultRuntime: runtimeConfiguration.defaultRuntimeID,
            candidates: runtimes
        ).first { candidates[$0]?.isEligible == true }
        let launchBlock: TaskRuntimeCompatibilityLaunchBlock?
        if requestedCandidate.isEligible {
            launchBlock = nil
        } else {
            launchBlock = makeLaunchBlock(
                runtime: requestedRuntime,
                candidate: requestedCandidate,
                suggestedRuntime: fallback
            )
        }

        return TaskRuntimeEligibilitySnapshot(
            taskID: task.id,
            intent: intent,
            requestedRuntime: requestedRuntime,
            selectedRuntime: requestedRuntime,
            candidates: candidates,
            launchBlock: launchBlock
        )
    }

    private static func candidatePermissionPolicy(
        task: AgentTask,
        runtime: AgentRuntimeID,
        fallbackPermissionPolicy: PermissionPolicy,
        defaultPolicyLevelRaw: String,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> PermissionPolicy {
        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: AgentPolicyLevel.normalized(defaultPolicyLevelRaw),
            fallbackPermissionPolicy: fallbackPermissionPolicy,
            executionPolicy: executionPolicy
        )
        return ProviderPolicyModeResolver.permissionPolicy(
            for: resolution.policy,
            runtime: runtime
        )
    }

    private static func makeLaunchBlock(
        runtime: AgentRuntimeID,
        candidate: TaskRuntimeAdmissionCandidate,
        suggestedRuntime: AgentRuntimeID?
    ) -> TaskRuntimeCompatibilityLaunchBlock {
        let missing = candidate.incompatibilities.map(\.userFacingName)
        let reason = candidate.blockingReason ?? "the launch contract is incompatible"
        let remediation = suggestedRuntime.map { "Switch to \($0.displayName)." }
            ?? candidate.policyDiagnostics.first(where: {
                $0.severity == PolicyDiagnosticSeverity.blocked
            })?.remediation
            ?? "Choose a runtime that supports this turn's ASTRA capability and policy contract."
        return TaskRuntimeCompatibilityLaunchBlock(
            stopReason: TaskRuntimeCompatibilityService.stopReason(
                for: runtime,
                incompatibilities: candidate.incompatibilities
            ),
            title: "Selected runtime is incompatible with this turn",
            message: "\(runtime.displayName) cannot safely launch because \(reason)",
            remediation: remediation,
            missingCapabilities: missing.isEmpty ? [reason] : missing,
            suggestedRuntime: suggestedRuntime
        )
    }

    private static func orderedFallbackRuntimes(
        requestedRuntime: AgentRuntimeID,
        defaultRuntime: AgentRuntimeID,
        candidates: [AgentRuntimeID]
    ) -> [AgentRuntimeID] {
        uniqueRuntimes(
            [defaultRuntime, .codexCLI, .claudeCode, .copilotCLI] + candidates
        ).filter { $0 != requestedRuntime }
    }

    private static func uniqueRuntimes(_ values: [AgentRuntimeID]) -> [AgentRuntimeID] {
        var seen: Set<AgentRuntimeID> = []
        return values.filter { seen.insert($0).inserted }
    }

    private struct DigestPayload: Codable {
        let acceptedTurn: String
        let inheritedTurn: String?
        let runtime: String
        let skillIDs: [String]
        let connectorIDs: [String]
        let localToolIDs: [String]
        let resourceIDs: [String]
    }

    private static func contractDigest(
        intent: TaskTurnIntentSnapshot,
        snapshot: TaskCapabilityResolutionSnapshot,
        contract: LaunchResourceContract
    ) -> String {
        let payload = DigestPayload(
            acceptedTurn: intent.acceptedTurn,
            inheritedTurn: intent.inheritedTurn,
            runtime: contract.runtime,
            skillIDs: snapshot.providerLaunch.behaviorSkills
                .map { $0.id.uuidString }
                .sorted(),
            connectorIDs: snapshot.providerLaunch.connectors
                .map { $0.id.uuidString }
                .sorted(),
            localToolIDs: snapshot.providerLaunch.localTools
                .map { $0.id.uuidString }
                .sorted(),
            resourceIDs: contract.resources.map(\.id).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct AdmissionMetadataSecretStore: SecretStore {
    func load(key _: String, entityID _: String) -> String? {
        "__ASTRA_CREDENTIAL_PRESENT__"
    }

    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool {
        false
    }

    func delete(key _: String, entityID _: String) -> Bool {
        false
    }

    func deleteAll(entityID _: String) {}

    func exists(key _: String, entityID _: String) -> Bool {
        true
    }
}
