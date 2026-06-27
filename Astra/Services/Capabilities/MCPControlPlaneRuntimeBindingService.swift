import Foundation
import ASTRACore

struct MCPControlPlaneAuthProfileHandle: Codable, Equatable, Sendable, Identifiable {
    var id: String { refID }
    var refID: String
    var providerID: String
    var profileID: String
    var displayName: String

    init(refID: String, providerID: String, profileID: String, displayName: String = "") {
        self.refID = refID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPControlPlaneSecretHandle: Codable, Equatable, Sendable, Identifiable {
    var id: String { refID }
    var refID: String
    var entityID: String
    var key: String
    var label: String

    init(refID: String, entityID: String, key: String, label: String = "") {
        self.refID = refID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entityID = entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPControlPlaneConfigHandle: Codable, Equatable, Sendable, Identifiable {
    var id: String { refID }
    var refID: String
    var sourceID: String
    var displayName: String

    init(refID: String, sourceID: String, displayName: String = "") {
        self.refID = refID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol MCPControlPlaneRuntimeBindingResolver {
    func authProfileHandle(for ref: MCPAuthProfileRef) -> MCPControlPlaneAuthProfileHandle?
    func secretHandle(for ref: MCPSecretRef) -> MCPControlPlaneSecretHandle?
    func configHandle(for ref: MCPConfigRef) -> MCPControlPlaneConfigHandle?
}

struct SecretStoreMCPControlPlaneRuntimeBindingResolver: MCPControlPlaneRuntimeBindingResolver {
    private let secretStore: any SecretStore
    private let authProfileHandles: [String: MCPControlPlaneAuthProfileHandle]
    private let secretHandles: [String: MCPControlPlaneSecretHandle]
    private let configHandles: [String: MCPControlPlaneConfigHandle]

    init(
        secretStore: any SecretStore = KeychainSecretStore(),
        authProfileHandles: [MCPControlPlaneAuthProfileHandle] = [],
        secretHandles: [MCPControlPlaneSecretHandle] = [],
        configHandles: [MCPControlPlaneConfigHandle] = []
    ) {
        self.secretStore = secretStore
        self.authProfileHandles = Self.indexByRefID(authProfileHandles)
        self.secretHandles = Self.indexByRefID(secretHandles)
        self.configHandles = Self.indexByRefID(configHandles)
    }

    func authProfileHandle(for ref: MCPAuthProfileRef) -> MCPControlPlaneAuthProfileHandle? {
        let refID = Self.canonicalID(ref.id)
        guard let handle = authProfileHandles[refID],
              handle.providerID == Self.canonicalID(ref.providerID),
              !handle.profileID.isEmpty else {
            return nil
        }
        return handle
    }

    func secretHandle(for ref: MCPSecretRef) -> MCPControlPlaneSecretHandle? {
        let refID = Self.canonicalID(ref.id)
        guard let handle = secretHandles[refID],
              !handle.entityID.isEmpty,
              !handle.key.isEmpty,
              secretStore.exists(key: handle.key, entityID: handle.entityID) else {
            return nil
        }
        return handle
    }

    func configHandle(for ref: MCPConfigRef) -> MCPControlPlaneConfigHandle? {
        let refID = Self.canonicalID(ref.id)
        guard let handle = configHandles[refID],
              !handle.sourceID.isEmpty else {
            return nil
        }
        return handle
    }

    private static func canonicalID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func indexByRefID<Value: MCPControlPlaneHandle>(
        _ handles: [Value]
    ) -> [String: Value] {
        var indexed: [String: Value] = [:]
        for handle in handles {
            let refID = canonicalID(handle.refID)
            guard !refID.isEmpty, indexed[refID] == nil else { continue }
            indexed[refID] = handle
        }
        return indexed
    }
}

enum MCPControlPlaneRuntimeBindingReadinessStatus: String, Codable, Equatable, Sendable {
    case ready
    case readyWithWarnings
    case blocked
}

enum MCPControlPlaneRuntimeBindingIssueSeverity: String, Codable, Equatable, Sendable {
    case failure
    case warning
}

enum MCPControlPlaneRuntimeBindingReadinessIssue: Equatable, Sendable {
    case invalidControlPlane(reason: String)
    case invalidRuntimeBinding(bindingID: String)
    case missingRequiredAuthProfile(refID: String, providerID: String)
    case missingOptionalAuthProfile(refID: String, providerID: String)
    case missingRequiredSecret(refID: String)
    case missingOptionalSecret(refID: String)
    case missingRequiredConfig(refID: String)
    case missingOptionalConfig(refID: String)

    var severity: MCPControlPlaneRuntimeBindingIssueSeverity {
        switch self {
        case .invalidControlPlane, .invalidRuntimeBinding, .missingRequiredAuthProfile, .missingRequiredSecret, .missingRequiredConfig:
            return .failure
        case .missingOptionalAuthProfile, .missingOptionalSecret, .missingOptionalConfig:
            return .warning
        }
    }
}

struct MCPControlPlaneRuntimeBindingPreview: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var destination: MCPRuntimeBindingDestination
    var name: String
    var redactedValue: String
    var isReady: Bool
    var referencedAuthProfileRefs: [String]
    var referencedSecretRefs: [String]
    var referencedConfigRefs: [String]
}

struct MCPControlPlaneRuntimeBindingReadiness: Equatable, Sendable {
    var status: MCPControlPlaneRuntimeBindingReadinessStatus
    var issues: [MCPControlPlaneRuntimeBindingReadinessIssue]
    var authProfileHandles: [MCPControlPlaneAuthProfileHandle]
    var secretHandles: [MCPControlPlaneSecretHandle]
    var configHandles: [MCPControlPlaneConfigHandle]
    var bindingPreviews: [MCPControlPlaneRuntimeBindingPreview]

    init(
        issues: [MCPControlPlaneRuntimeBindingReadinessIssue],
        authProfileHandles: [MCPControlPlaneAuthProfileHandle],
        secretHandles: [MCPControlPlaneSecretHandle],
        configHandles: [MCPControlPlaneConfigHandle],
        bindingPreviews: [MCPControlPlaneRuntimeBindingPreview]
    ) {
        self.status = Self.status(for: issues)
        self.issues = issues
        self.authProfileHandles = authProfileHandles
        self.secretHandles = secretHandles
        self.configHandles = configHandles
        self.bindingPreviews = bindingPreviews
    }

    private static func status(
        for issues: [MCPControlPlaneRuntimeBindingReadinessIssue]
    ) -> MCPControlPlaneRuntimeBindingReadinessStatus {
        if issues.contains(where: { $0.severity == .failure }) {
            return .blocked
        }
        if issues.contains(where: { $0.severity == .warning }) {
            return .readyWithWarnings
        }
        return .ready
    }
}

struct MCPControlPlaneRuntimeBindingService {
    private let resolver: any MCPControlPlaneRuntimeBindingResolver

    init(resolver: any MCPControlPlaneRuntimeBindingResolver) {
        self.resolver = resolver
    }

    func readiness(for metadata: MCPControlPlaneMetadata) -> MCPControlPlaneRuntimeBindingReadiness {
        let resolved = resolveRefs(in: metadata)
        let bindingPreviews = metadata.runtimeBindings.map {
            bindingPreview(for: $0, resolved: resolved)
        }
        let bindingIssues = bindingPreviews
            .filter { !$0.isReady }
            .map { MCPControlPlaneRuntimeBindingReadinessIssue.invalidRuntimeBinding(bindingID: $0.id) }
        let invariantIssues = controlPlaneInvariantIssues(for: metadata)
        return MCPControlPlaneRuntimeBindingReadiness(
            issues: uniqueIssues(resolved.issues + bindingIssues + invariantIssues),
            authProfileHandles: Array(resolved.authProfileHandles.values).sorted { $0.refID < $1.refID },
            secretHandles: Array(resolved.secretHandles.values).sorted { $0.refID < $1.refID },
            configHandles: Array(resolved.configHandles.values).sorted { $0.refID < $1.refID },
            bindingPreviews: bindingPreviews
        )
    }

    private func controlPlaneInvariantIssues(
        for metadata: MCPControlPlaneMetadata
    ) -> [MCPControlPlaneRuntimeBindingReadinessIssue] {
        metadata.invariantViolations().map { violation in
            switch violation {
            case .duplicateRuntimeBinding(let bindingID),
                 .runtimeBinding(let bindingID, _):
                return .invalidRuntimeBinding(bindingID: Self.canonicalID(bindingID))
            default:
                return .invalidControlPlane(reason: "\(violation)")
            }
        }
    }

    private func resolveRefs(in metadata: MCPControlPlaneMetadata) -> ResolvedControlPlaneRefs {
        var issues: [MCPControlPlaneRuntimeBindingReadinessIssue] = []
        var authProfileHandles: [String: MCPControlPlaneAuthProfileHandle] = [:]
        var secretHandles: [String: MCPControlPlaneSecretHandle] = [:]
        var configHandles: [String: MCPControlPlaneConfigHandle] = [:]

        for ref in metadata.authProfileRefs {
            let refID = Self.canonicalID(ref.id)
            let providerID = Self.canonicalID(ref.providerID)
            if let handle = resolver.authProfileHandle(for: ref) {
                authProfileHandles[refID] = handle
            } else if ref.required {
                issues.append(.missingRequiredAuthProfile(refID: refID, providerID: providerID))
            } else {
                issues.append(.missingOptionalAuthProfile(refID: refID, providerID: providerID))
            }
        }

        for ref in metadata.secretRefs {
            let refID = Self.canonicalID(ref.id)
            if let handle = resolver.secretHandle(for: ref) {
                secretHandles[refID] = handle
            } else if ref.required {
                issues.append(.missingRequiredSecret(refID: refID))
            } else {
                issues.append(.missingOptionalSecret(refID: refID))
            }
        }

        for ref in metadata.configRefs {
            let refID = Self.canonicalID(ref.id)
            if let handle = resolver.configHandle(for: ref) {
                configHandles[refID] = handle
            } else if ref.required {
                issues.append(.missingRequiredConfig(refID: refID))
            } else {
                issues.append(.missingOptionalConfig(refID: refID))
            }
        }

        return ResolvedControlPlaneRefs(
            issues: issues,
            authProfileHandles: authProfileHandles,
            secretHandles: secretHandles,
            configHandles: configHandles
        )
    }

    private func bindingPreview(
        for binding: MCPRuntimeBindingTemplate,
        resolved: ResolvedControlPlaneRefs
    ) -> MCPControlPlaneRuntimeBindingPreview {
        var parts: [String] = []
        var isReady = true

        for segment in binding.template {
            switch segment.kind {
            case .literal:
                let literal = segment.literal ?? ""
                if MCPRuntimeBindingTemplate.literalLooksLikeRawSecretValue(literal) {
                    parts.append("[redacted-literal]")
                    isReady = false
                } else {
                    parts.append(literal)
                }
            case .reference:
                guard let reference = segment.reference else {
                    parts.append("[missing-reference]")
                    isReady = false
                    continue
                }
                let referenceID = Self.canonicalID(reference.id)
                switch reference.kind {
                case .authProfileRef:
                    if resolved.authProfileHandles[referenceID] != nil {
                        parts.append("[authProfile:\(referenceID)]")
                    } else {
                        parts.append("[missing-authProfile:\(referenceID)]")
                        isReady = false
                    }
                case .secretRef:
                    if resolved.secretHandles[referenceID] != nil {
                        parts.append("[secret:\(referenceID)]")
                    } else {
                        parts.append("[missing-secret:\(referenceID)]")
                        isReady = false
                    }
                case .configRef:
                    if resolved.configHandles[referenceID] != nil {
                        parts.append("[config:\(referenceID)]")
                    } else {
                        parts.append("[missing-config:\(referenceID)]")
                        isReady = false
                    }
                }
            }
        }

        return MCPControlPlaneRuntimeBindingPreview(
            id: Self.canonicalID(binding.id),
            destination: binding.destination,
            name: binding.name.trimmingCharacters(in: .whitespacesAndNewlines),
            redactedValue: parts.joined(),
            isReady: isReady,
            referencedAuthProfileRefs: binding.referencedAuthProfileRefs,
            referencedSecretRefs: binding.referencedSecretRefs,
            referencedConfigRefs: binding.referencedConfigRefs
        )
    }

    private static func canonicalID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueIssues(
        _ issues: [MCPControlPlaneRuntimeBindingReadinessIssue]
    ) -> [MCPControlPlaneRuntimeBindingReadinessIssue] {
        var result: [MCPControlPlaneRuntimeBindingReadinessIssue] = []
        for issue in issues where !result.contains(issue) {
            result.append(issue)
        }
        return result
    }
}

private struct ResolvedControlPlaneRefs {
    var issues: [MCPControlPlaneRuntimeBindingReadinessIssue]
    var authProfileHandles: [String: MCPControlPlaneAuthProfileHandle]
    var secretHandles: [String: MCPControlPlaneSecretHandle]
    var configHandles: [String: MCPControlPlaneConfigHandle]
}

private protocol MCPControlPlaneHandle {
    var refID: String { get }
}

extension MCPControlPlaneAuthProfileHandle: MCPControlPlaneHandle {}
extension MCPControlPlaneSecretHandle: MCPControlPlaneHandle {}
extension MCPControlPlaneConfigHandle: MCPControlPlaneHandle {}
