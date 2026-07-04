import Foundation

extension LaunchResourceContract {
    static func resources(from plan: TaskLaunchResourcePlan) -> [Resource] {
        var contractResources: [Resource] = []
        contractResources += plan.hostPathGrants.map { resource(from: $0, plan: plan) }
        contractResources += plan.environmentGrants.map { resource(from: $0, plan: plan) }
        contractResources += plan.credentialGrants.flatMap { resources(from: $0, plan: plan) }
        contractResources += plan.containerMounts.map { resource(from: $0) }
        contractResources += plan.providerRequirements.map { resource(from: $0) }
        contractResources += plan.controlPlaneResources.map { resource(from: $0) }
        return unique(contractResources)
    }
}

private extension LaunchResourceContract {
    static func resource(from grant: RuntimePathGrant, plan: TaskLaunchResourcePlan) -> Resource {
        let consumer = fileConsumer(for: grant.source, plan: plan)
        let visibility = fileVisibility(for: consumer)
        return Resource(
            id: "path:\(grant.source.rawValue):\(grant.access.rawValue):\(grant.path)",
            source: grant.source,
            consumer: consumer,
            deliveryChannel: .file,
            sensitivity: grant.sensitivity,
            enforcementBoundary: fileBoundary(for: grant.source, consumer: consumer),
            visibility: visibility,
            redactionAssumption: redactionAssumption(sensitivity: grant.sensitivity, visibility: visibility),
            reason: grant.reason,
            path: grant.path,
            access: grant.access
        )
    }

    static func resource(from grant: RuntimeEnvironmentGrant, plan: TaskLaunchResourcePlan) -> Resource {
        let consumer = environmentConsumer(for: grant.source, plan: plan)
        let visibility = environmentVisibility(for: consumer)
        return Resource(
            id: "environment:\(grant.source.rawValue):\(grant.key)",
            source: grant.source,
            consumer: consumer,
            deliveryChannel: .environment,
            sensitivity: grant.sensitivity,
            enforcementBoundary: environmentBoundary(for: consumer),
            visibility: visibility,
            redactionAssumption: redactionAssumption(sensitivity: grant.sensitivity, visibility: visibility),
            reason: grant.reason,
            environmentKey: grant.key,
            valueProjected: grant.valueProjected
        )
    }

    static func resources(from grant: RuntimeCredentialGrant, plan: TaskLaunchResourcePlan) -> [Resource] {
        var resources: [Resource] = []
        let sensitivity = credentialSensitivity(for: grant.source)
        let consumer = credentialConsumer(for: grant.source, plan: plan)
        if grant.projectedAsEnvironment {
            let visibility = environmentVisibility(for: consumer)
            resources.append(Resource(
                id: "credential-environment:\(grant.source.rawValue):\(grant.label)",
                source: grant.source,
                consumer: consumer,
                deliveryChannel: .environment,
                sensitivity: sensitivity,
                enforcementBoundary: environmentBoundary(for: consumer),
                visibility: visibility,
                redactionAssumption: redactionAssumption(sensitivity: sensitivity, visibility: visibility),
                reason: grant.reason,
                credentialLabel: grant.label,
                valueProjected: true
            ))
        }
        if grant.projectedAsFile {
            let visibility = fileVisibility(for: consumer)
            resources.append(Resource(
                id: "credential-file:\(grant.source.rawValue):\(grant.label)",
                source: grant.source,
                consumer: consumer,
                deliveryChannel: .file,
                sensitivity: sensitivity,
                enforcementBoundary: fileBoundary(for: grant.source, consumer: consumer),
                visibility: visibility,
                redactionAssumption: redactionAssumption(sensitivity: sensitivity, visibility: visibility),
                reason: grant.reason,
                credentialLabel: grant.label,
                valueProjected: true
            ))
        }
        return resources
    }

    static func resource(from mount: RuntimeContainerMountGrant) -> Resource {
        let sensitivity: TaskLaunchResourceSensitivity = mount.role == "credential" ? .credential : .normal
        return Resource(
            id: "container-mount:\(mount.role):\(mount.access):\(mount.hostPath):\(mount.containerPath)",
            source: mount.role == "credential" ? .dockerCredential : .workspace,
            consumer: .containerRuntime,
            deliveryChannel: .containerMount,
            sensitivity: sensitivity,
            enforcementBoundary: .containerBoundary,
            visibility: .containerOnly,
            redactionAssumption: sensitivity == .normal ? .notSensitive : .containerBoundary,
            reason: "Container mount \(mount.role) exposes \(mount.hostPath) at \(mount.containerPath).",
            path: mount.hostPath,
            access: contractAccess(forContainerMountAccess: mount.access),
            placement: mount.containerPath
        )
    }

    static func contractAccess(forContainerMountAccess rawValue: String) -> TaskLaunchResourceAccess? {
        switch ExecutionEnvironmentMountAccess(rawValue: rawValue) {
        case .readOnly:
            return .read
        case .readWrite:
            return .readWrite
        case nil:
            return TaskLaunchResourceAccess(rawValue: rawValue)
        }
    }

    static func resource(from requirement: RuntimeProviderRequirement) -> Resource {
        let consumer: Consumer = requirement.source == .controlPlane ? .hostControlPlane : .providerProcess
        let visibility: Visibility = consumer == .hostControlPlane ? .hostControlPlaneOnly : .providerMetadata
        return Resource(
            id: "provider-requirement:\(requirement.source.rawValue):\(requirement.capability)",
            source: requirement.source,
            consumer: consumer,
            deliveryChannel: .providerRequirement,
            sensitivity: .normal,
            enforcementBoundary: consumer == .hostControlPlane ? .hostControlPlane : .providerPolicy,
            visibility: visibility,
            redactionAssumption: .notSensitive,
            reason: requirement.reason,
            capability: requirement.capability
        )
    }

    static func resource(from resource: RuntimeControlPlaneResource) -> Resource {
        Resource(
            id: "control-plane:\(resource.source.rawValue):\(resource.capability):\(resource.placement)",
            source: resource.source,
            consumer: .hostControlPlane,
            deliveryChannel: .hostControlPlane,
            sensitivity: controlPlaneSensitivity(for: resource.source),
            enforcementBoundary: .hostControlPlane,
            visibility: .hostControlPlaneOnly,
            redactionAssumption: .astraManagedBoundary,
            reason: resource.reason,
            capability: resource.capability,
            placement: resource.placement,
            readiness: resource.readiness
        )
    }

    static func fileConsumer(for source: TaskLaunchResourceSource, plan: TaskLaunchResourcePlan) -> Consumer {
        switch source {
        case .dockerEnvironment:
            return plan.workspaceCommandPlacement == "docker" ? .astraRuntime : .containerRuntime
        case .dockerCredential:
            return .containerRuntime
        default:
            return .providerProcess
        }
    }

    static func environmentConsumer(for source: TaskLaunchResourceSource, plan _: TaskLaunchResourcePlan) -> Consumer {
        switch source {
        case .dockerEnvironment:
            return .astraRuntime
        case .dockerCredential:
            return .workspaceCommand
        default:
            return .providerProcess
        }
    }

    static func credentialConsumer(for source: TaskLaunchResourceSource, plan _: TaskLaunchResourcePlan) -> Consumer {
        switch source {
        case .dockerCredential:
            return .workspaceCommand
        default:
            return .providerProcess
        }
    }

    static func credentialSensitivity(for source: TaskLaunchResourceSource) -> TaskLaunchResourceSensitivity {
        switch source {
        case .dockerCredential:
            return .cloudAuth
        case .provider:
            return .token
        case .gitCredential, .remoteWorkspace, .connector, .controlPlane:
            return .credential
        default:
            return .credential
        }
    }

    static func controlPlaneSensitivity(for source: TaskLaunchResourceSource) -> TaskLaunchResourceSensitivity {
        switch source {
        case .connector, .remoteWorkspace, .controlPlane:
            return .credential
        default:
            return .normal
        }
    }

    static func fileBoundary(for source: TaskLaunchResourceSource, consumer: Consumer) -> EnforcementBoundary {
        switch consumer {
        case .hostControlPlane:
            return .hostControlPlane
        case .containerRuntime, .workspaceCommand:
            return .containerBoundary
        case .astraRuntime:
            return .astraRuntime
        case .providerProcess:
            return source == .dockerCredential ? .containerBoundary : .launchResourceProjection
        }
    }

    static func environmentBoundary(for consumer: Consumer) -> EnforcementBoundary {
        switch consumer {
        case .hostControlPlane:
            return .hostControlPlane
        case .containerRuntime, .workspaceCommand:
            return .containerBoundary
        case .astraRuntime:
            return .astraRuntime
        case .providerProcess:
            return .launchResourceProjection
        }
    }

    static func fileVisibility(for consumer: Consumer) -> Visibility {
        switch consumer {
        case .providerProcess:
            return .providerReadableFile
        case .hostControlPlane:
            return .hostControlPlaneOnly
        case .containerRuntime, .workspaceCommand:
            return .containerOnly
        case .astraRuntime:
            return .astraRuntimeOnly
        }
    }

    static func environmentVisibility(for consumer: Consumer) -> Visibility {
        switch consumer {
        case .providerProcess:
            return .providerEnvironmentValue
        case .hostControlPlane:
            return .hostControlPlaneOnly
        case .containerRuntime, .workspaceCommand:
            return .containerOnly
        case .astraRuntime:
            return .astraRuntimeOnly
        }
    }

    static func redactionAssumption(
        sensitivity: TaskLaunchResourceSensitivity,
        visibility: Visibility
    ) -> RedactionAssumption {
        guard sensitivity != .normal else { return .notSensitive }
        switch visibility {
        case .providerEnvironmentValue:
            return .providerSecretEnvironmentRedaction
        case .providerReadableFile:
            return .fileContentsNotProviderRedacted
        case .hostControlPlaneOnly:
            return .astraManagedBoundary
        case .containerOnly:
            return .containerBoundary
        case .astraRuntimeOnly, .providerMetadata:
            return .notSensitive
        }
    }

    static func unique(_ resources: [Resource]) -> [Resource] {
        var seen: Set<String> = []
        return resources.filter { resource in
            seen.insert(resource.id).inserted
        }
    }
}
