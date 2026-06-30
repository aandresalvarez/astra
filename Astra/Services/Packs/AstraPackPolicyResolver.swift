import Foundation
import ASTRACore

struct PackPolicyEvidence: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case coreFloor = "core_floor"
        case packRestriction = "pack_restriction"
    }

    var kind: Kind
    var packID: String?
    var restrictionID: String?
    var contributionKind: String
    var action: String
    var target: String
    var message: String
}

struct PackPolicyDiagnostic: Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case missingTarget
        case policyWideningIgnored
        case unknownShelfID
        case unsupportedAction
    }

    var code: Code
    var packID: String?
    var restrictionID: String
    var message: String
}

struct PackPolicyRule: Equatable, Sendable {
    var targetID: String?
    var targetTag: String?
    var targetMCPServerID: String?
    var targetMCPToolName: String?
    var evidence: PackPolicyEvidence

    func matches(package: PluginPackage) -> Bool {
        if let targetID, normalized(targetID) == normalized(package.id) {
            return true
        }
        if let targetTag {
            let tags = Set(package.tags.map(normalized).filter { !$0.isEmpty })
            return tags.contains(normalized(targetTag))
        }
        return false
    }

    func matches(serverID: String, toolName: String) -> Bool {
        guard let targetMCPServerID, let targetMCPToolName else { return false }
        return normalized(targetMCPServerID) == normalized(serverID)
            && normalized(targetMCPToolName) == normalized(toolName)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct PackResolvedPolicy: Equatable, Sendable {
    static let coreFloorEvidence = PackPolicyEvidence(
        kind: .coreFloor,
        packID: nil,
        restrictionID: nil,
        contributionKind: "core",
        action: "corePolicyFloor",
        target: "all",
        message: "ASTRA Core policy remains the minimum runtime and capability floor."
    )

    static let empty = PackResolvedPolicy(
        hiddenShelfIDs: [],
        hiddenCapabilityPackageIDs: [],
        hiddenCapabilityTags: [],
        disabledCapabilityPackageIDs: [],
        disabledCapabilityTags: [],
        hiddenCapabilityRules: [],
        disabledCapabilityRules: [],
        warningRules: [],
        reviewGateRules: [],
        explicitConsentRules: [],
        evidence: [PackResolvedPolicy.coreFloorEvidence],
        diagnostics: []
    )

    var hiddenShelfIDs: Set<ShelfID>
    var hiddenCapabilityPackageIDs: Set<String>
    var hiddenCapabilityTags: Set<String>
    var disabledCapabilityPackageIDs: Set<String>
    var disabledCapabilityTags: Set<String>
    var hiddenCapabilityRules: [PackPolicyRule]
    var disabledCapabilityRules: [PackPolicyRule]
    var warningRules: [PackPolicyRule]
    var reviewGateRules: [PackPolicyRule]
    var explicitConsentRules: [PackPolicyRule]
    var evidence: [PackPolicyEvidence]
    var diagnostics: [PackPolicyDiagnostic]

    var affectsCapabilityRuntimeExposure: Bool {
        !hiddenCapabilityRules.isEmpty
            || !disabledCapabilityRules.isEmpty
            || !reviewGateRules.isEmpty
    }

    var hasReviewGateRules: Bool {
        !reviewGateRules.isEmpty
    }

    func hiddenEvidence(for package: PluginPackage) -> [PackPolicyEvidence] {
        matchingEvidence(hiddenCapabilityRules, package: package)
    }

    func disabledEvidence(for package: PluginPackage) -> [PackPolicyEvidence] {
        matchingEvidence(disabledCapabilityRules, package: package)
    }

    func warningEvidence(for package: PluginPackage) -> [PackPolicyEvidence] {
        matchingEvidence(warningRules, package: package)
    }

    func reviewGateEvidence(for package: PluginPackage) -> [PackPolicyEvidence] {
        matchingEvidence(reviewGateRules, package: package)
    }

    func explicitConsentEvidence(serverID: String, toolName: String) -> PackPolicyEvidence? {
        explicitConsentRules.first { $0.matches(serverID: serverID, toolName: toolName) }?.evidence
    }

    private func matchingEvidence(
        _ rules: [PackPolicyRule],
        package: PluginPackage
    ) -> [PackPolicyEvidence] {
        rules.filter { $0.matches(package: package) }.map(\.evidence)
    }
}

enum AstraPackPolicyResolver {
    static func resolve(composition: AstraPackCompositionResult) -> PackResolvedPolicy {
        var builder = PolicyBuilder()

        for restriction in composition.policyRestrictions {
            let packID = sourcePackID(for: restriction, in: composition)
            apply(restriction, packID: packID, builder: &builder)
        }

        return builder.resolved()
    }

    private static func apply(
        _ restriction: AstraPackPolicyRestriction,
        packID: String,
        builder: inout PolicyBuilder
    ) {
        let contributionKind = normalized(restriction.contributionKind)
        let action = normalized(restriction.action)
        let evidence = evidence(for: restriction, packID: packID)

        switch (contributionKind, action) {
        case ("capabilitypackage", "hidecapability"):
            guard let rule = capabilityRule(restriction, packID: packID, evidence: evidence, builder: &builder) else { return }
            builder.hiddenCapabilityRules.append(rule)
            if let targetID = rule.targetID { builder.hiddenCapabilityPackageIDs.insert(normalized(targetID)) }
            if let targetTag = rule.targetTag { builder.hiddenCapabilityTags.insert(normalized(targetTag)) }
            builder.appendEvidence(evidence)
        case ("capabilitypackage", "disablecapability"):
            guard let rule = capabilityRule(restriction, packID: packID, evidence: evidence, builder: &builder) else { return }
            builder.disabledCapabilityRules.append(rule)
            if let targetID = rule.targetID { builder.disabledCapabilityPackageIDs.insert(normalized(targetID)) }
            if let targetTag = rule.targetTag { builder.disabledCapabilityTags.insert(normalized(targetTag)) }
            builder.appendEvidence(evidence)
        case ("capabilitypackage", "addwarning"):
            guard let rule = capabilityRule(restriction, packID: packID, evidence: evidence, builder: &builder) else { return }
            builder.warningRules.append(rule)
            builder.appendEvidence(evidence)
        case ("capabilitypackage", "requirereviewgate"):
            guard let rule = capabilityRule(restriction, packID: packID, evidence: evidence, builder: &builder) else { return }
            builder.reviewGateRules.append(rule)
            builder.appendEvidence(evidence)
        case ("workspaceapp", "requireexplicitconsent"):
            guard let rule = mcpConsentRule(restriction, packID: packID, evidence: evidence, builder: &builder) else { return }
            builder.explicitConsentRules.append(rule)
            builder.appendEvidence(evidence)
        case ("shelf", "hideshelf"):
            guard let targetID = trimmed(restriction.targetID) else {
                builder.addMissingTarget(restriction, packID: packID)
                return
            }
            guard let shelfID = shelfID(for: targetID) else {
                builder.diagnostics.append(PackPolicyDiagnostic(
                    code: .unknownShelfID,
                    packID: packID,
                    restrictionID: restriction.id,
                    message: "Pack policy restriction '\(restriction.id)' references unknown shelf '\(targetID)'."
                ))
                return
            }
            builder.hiddenShelfIDs.insert(shelfID)
            builder.appendEvidence(evidence)
        case (_, "lowerrisklevel"), (_, "enablecapability"), (_, "autoapproveexternalwrite"),
             (_, "broadenfileaccess"), (_, "broadennetworkaccess"), (_, "bypassproviderpolicy"):
            builder.diagnostics.append(PackPolicyDiagnostic(
                code: .policyWideningIgnored,
                packID: packID,
                restrictionID: restriction.id,
                message: "Pack policy restriction '\(restriction.id)' attempted to widen Core policy and was ignored."
            ))
        default:
            builder.diagnostics.append(PackPolicyDiagnostic(
                code: .unsupportedAction,
                packID: packID,
                restrictionID: restriction.id,
                message: "Pack policy restriction '\(restriction.id)' uses unsupported action '\(restriction.action)'."
            ))
        }
    }

    private static func capabilityRule(
        _ restriction: AstraPackPolicyRestriction,
        packID: String,
        evidence: PackPolicyEvidence,
        builder: inout PolicyBuilder
    ) -> PackPolicyRule? {
        let targetID = trimmed(restriction.targetID).map(normalized)
        let targetTag = trimmed(restriction.targetTag).map(normalized)
        if targetID == nil && targetTag == nil {
            builder.addMissingTarget(restriction, packID: packID)
            return nil
        }
        return PackPolicyRule(
            targetID: targetID,
            targetTag: targetTag,
            targetMCPServerID: nil,
            targetMCPToolName: nil,
            evidence: evidence
        )
    }

    private static func mcpConsentRule(
        _ restriction: AstraPackPolicyRestriction,
        packID: String,
        evidence: PackPolicyEvidence,
        builder: inout PolicyBuilder
    ) -> PackPolicyRule? {
        guard let serverID = trimmed(restriction.targetMCPServerID),
              let toolName = trimmed(restriction.targetMCPToolName) else {
            builder.addMissingTarget(restriction, packID: packID)
            return nil
        }
        return PackPolicyRule(
            targetID: nil,
            targetTag: nil,
            targetMCPServerID: normalized(serverID),
            targetMCPToolName: normalized(toolName),
            evidence: evidence
        )
    }

    private static func evidence(
        for restriction: AstraPackPolicyRestriction,
        packID: String
    ) -> PackPolicyEvidence {
        PackPolicyEvidence(
            kind: .packRestriction,
            packID: packID,
            restrictionID: restriction.id,
            contributionKind: restriction.contributionKind,
            action: restriction.action,
            target: targetDescription(for: restriction),
            message: message(for: restriction)
        )
    }

    private static func targetDescription(for restriction: AstraPackPolicyRestriction) -> String {
        [
            restriction.targetID.map { "id:\($0)" },
            restriction.targetTag.map { "tag:\($0)" },
            restriction.targetMCPServerID.map { "mcpServer:\($0)" },
            restriction.targetMCPToolName.map { "mcpTool:\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: ",")
    }

    private static func sourcePackID(
        for restriction: AstraPackPolicyRestriction,
        in composition: AstraPackCompositionResult
    ) -> String {
        let key = policyKey(for: restriction)
        for input in composition.orderedInputs.reversed() {
            if input.manifest.policyRestrictions.contains(where: { candidate in
                normalized(candidate.effect) == "restrict" && policyKey(for: candidate) == key
            }) {
                return input.manifest.id
            }
        }
        return "unknown"
    }

    private struct PolicyKey: Hashable {
        var contributionKind: String
        var action: String
        var targetID: String?
        var targetTag: String?
        var targetMCPServerID: String?
        var targetMCPToolName: String?
    }

    private static func policyKey(for restriction: AstraPackPolicyRestriction) -> PolicyKey {
        PolicyKey(
            contributionKind: normalized(restriction.contributionKind),
            action: normalized(restriction.action),
            targetID: normalizedOptional(restriction.targetID),
            targetTag: normalizedOptional(restriction.targetTag),
            targetMCPServerID: normalizedOptional(restriction.targetMCPServerID),
            targetMCPToolName: normalizedOptional(restriction.targetMCPToolName)
        )
    }

    private static func message(for restriction: AstraPackPolicyRestriction) -> String {
        let trimmedMessage = restriction.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            return trimmedMessage
        }
        return "Pack policy restriction '\(restriction.id)' adds a stricter ASTRA policy rule."
    }

    private static func shelfID(for identifier: String) -> ShelfID? {
        CoreShelfRegistry.shelfID(forStableID: identifier)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalized(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct PolicyBuilder {
        var hiddenShelfIDs: Set<ShelfID> = []
        var hiddenCapabilityPackageIDs: Set<String> = []
        var hiddenCapabilityTags: Set<String> = []
        var disabledCapabilityPackageIDs: Set<String> = []
        var disabledCapabilityTags: Set<String> = []
        var hiddenCapabilityRules: [PackPolicyRule] = []
        var disabledCapabilityRules: [PackPolicyRule] = []
        var warningRules: [PackPolicyRule] = []
        var reviewGateRules: [PackPolicyRule] = []
        var explicitConsentRules: [PackPolicyRule] = []
        var evidence: [PackPolicyEvidence] = [PackResolvedPolicy.coreFloorEvidence]
        var diagnostics: [PackPolicyDiagnostic] = []

        mutating func appendEvidence(_ next: PackPolicyEvidence) {
            if !evidence.contains(next) {
                evidence.append(next)
            }
        }

        mutating func addMissingTarget(
            _ restriction: AstraPackPolicyRestriction,
            packID: String? = nil
        ) {
            diagnostics.append(PackPolicyDiagnostic(
                code: .missingTarget,
                packID: packID,
                restrictionID: restriction.id,
                message: "Pack policy restriction '\(restriction.id)' is missing the target required by action '\(restriction.action)'."
            ))
        }

        func resolved() -> PackResolvedPolicy {
            PackResolvedPolicy(
                hiddenShelfIDs: hiddenShelfIDs,
                hiddenCapabilityPackageIDs: hiddenCapabilityPackageIDs,
                hiddenCapabilityTags: hiddenCapabilityTags,
                disabledCapabilityPackageIDs: disabledCapabilityPackageIDs,
                disabledCapabilityTags: disabledCapabilityTags,
                hiddenCapabilityRules: hiddenCapabilityRules,
                disabledCapabilityRules: disabledCapabilityRules,
                warningRules: warningRules,
                reviewGateRules: reviewGateRules,
                explicitConsentRules: explicitConsentRules,
                evidence: evidence,
                diagnostics: diagnostics
            )
        }
    }
}
