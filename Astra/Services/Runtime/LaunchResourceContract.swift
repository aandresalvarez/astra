import Foundation
import ASTRACore

struct LaunchResourceContract: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var taskID: UUID
    var runID: UUID?
    var runtime: String
    var phase: RunPhase
    var generatedAt: Date
    var resources: [Resource]

    init(plan: TaskLaunchResourcePlan) {
        version = Self.currentVersion
        taskID = plan.taskID
        runID = plan.runID
        runtime = plan.runtime
        phase = plan.phase
        generatedAt = plan.generatedAt
        resources = Self.resources(from: plan)
    }

    var providerVisibleSensitiveResources: [Resource] {
        resources.filter { resource in
            resource.isSensitive && resource.isProviderVisible
        }
    }

    var providerEnvironmentSecretResources: [Resource] {
        providerVisibleSensitiveResources.filter { resource in
            resource.deliveryChannel == .environment
        }
    }

    var providerFileCredentialResources: [Resource] {
        providerVisibleSensitiveResources.filter { resource in
            resource.deliveryChannel == .file
        }
    }
}

extension LaunchResourceContract {
    struct Resource: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var source: TaskLaunchResourceSource
        var consumer: Consumer
        var deliveryChannel: DeliveryChannel
        var sensitivity: TaskLaunchResourceSensitivity
        var enforcementBoundary: EnforcementBoundary
        var visibility: Visibility
        var redactionAssumption: RedactionAssumption
        var reason: String
        var credentialLabel: String?
        var environmentKey: String?
        var path: String?
        var access: TaskLaunchResourceAccess?
        var capability: String?
        var placement: String?
        var readiness: RuntimeControlPlaneResource.Readiness?
        var valueProjected: Bool?

        init(
            id: String,
            source: TaskLaunchResourceSource,
            consumer: Consumer,
            deliveryChannel: DeliveryChannel,
            sensitivity: TaskLaunchResourceSensitivity,
            enforcementBoundary: EnforcementBoundary,
            visibility: Visibility,
            redactionAssumption: RedactionAssumption,
            reason: String,
            credentialLabel: String? = nil,
            environmentKey: String? = nil,
            path: String? = nil,
            access: TaskLaunchResourceAccess? = nil,
            capability: String? = nil,
            placement: String? = nil,
            readiness: RuntimeControlPlaneResource.Readiness? = nil,
            valueProjected: Bool? = nil
        ) {
            self.id = id
            self.source = source
            self.consumer = consumer
            self.deliveryChannel = deliveryChannel
            self.sensitivity = sensitivity
            self.enforcementBoundary = enforcementBoundary
            self.visibility = visibility
            self.redactionAssumption = redactionAssumption
            self.reason = reason
            self.credentialLabel = credentialLabel
            self.environmentKey = environmentKey
            self.path = path
            self.access = access
            self.capability = capability
            self.placement = placement
            self.readiness = readiness
            self.valueProjected = valueProjected
        }

        var isSensitive: Bool {
            sensitivity != .normal
        }

        var isProviderVisible: Bool {
            switch visibility {
            case .providerEnvironmentValue, .providerReadableFile, .providerMetadata:
                true
            case .hostControlPlaneOnly, .containerOnly, .astraRuntimeOnly:
                false
            }
        }
    }

    enum Consumer: String, Codable, Sendable {
        case providerProcess = "provider_process"
        case workspaceCommand = "workspace_command"
        case hostControlPlane = "host_control_plane"
        case containerRuntime = "container_runtime"
        case astraRuntime = "astra_runtime"
    }

    enum DeliveryChannel: String, Codable, Sendable {
        case environment
        case file
        case containerMount = "container_mount"
        case providerRequirement = "provider_requirement"
        case hostControlPlane = "host_control_plane"
    }

    enum EnforcementBoundary: String, Codable, Sendable {
        case launchResourceProjection = "launch_resource_projection"
        case providerPolicy = "provider_policy"
        case hostControlPlane = "host_control_plane"
        case containerBoundary = "container_boundary"
        case astraRuntime = "astra_runtime"
    }

    enum Visibility: String, Codable, Sendable {
        case providerEnvironmentValue = "provider_environment_value"
        case providerReadableFile = "provider_readable_file"
        case providerMetadata = "provider_metadata"
        case hostControlPlaneOnly = "host_control_plane_only"
        case containerOnly = "container_only"
        case astraRuntimeOnly = "astra_runtime_only"
    }

    enum RedactionAssumption: String, Codable, Sendable {
        case notSensitive = "not_sensitive"
        case providerSecretEnvironmentRedaction = "provider_secret_environment_redaction"
        case fileContentsNotProviderRedacted = "file_contents_not_provider_redacted"
        case astraManagedBoundary = "astra_managed_boundary"
        case containerBoundary = "container_boundary"
    }
}
