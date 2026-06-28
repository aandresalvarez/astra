import Foundation
import ASTRACore

struct AstraPackManifestValidationReport: Sendable, Equatable {
    struct Issue: Sendable, Equatable {
        enum Severity: String, Sendable, Equatable {
            case blocker
            case warning
        }

        enum Code: String, Sendable, Equatable {
            case emptyPackID
            case invalidPackID
            case unsupportedFormatVersion
            case unsupportedCoreAPIVersion
            case duplicateShelfID
            case emptyCapabilityPackageID
            case invalidCapabilityPackageID
            case emptyShelfID
            case invalidShelfID
            case emptyAppTemplateID
            case invalidAppTemplateID
            case emptyTemplateID
            case invalidTemplateID
            case emptyPolicyRestrictionID
            case invalidPolicyRestrictionID
            case policyWidening
            case unknownContributionKind
        }

        var severity: Severity
        var code: Code
        var path: String
        var message: String
    }

    var issues: [Issue]

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var isValid: Bool {
        blockers.isEmpty
    }
}

enum AstraPackManifestValidator {
    static let supportedCoreAPIVersion = "1.0"

    private static let identifierPattern = #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#
    private static let supportedContributionKinds: Set<String> = [
        "capabilityPackage",
        "shelf",
        "workspaceApp"
    ]

    static func validate(_ manifest: AstraPackManifest) -> AstraPackManifestValidationReport {
        var issues: [AstraPackManifestValidationReport.Issue] = []

        if manifest.formatVersion != AstraPackManifest.supportedFormatVersion {
            issues.append(blocker(
                .unsupportedFormatVersion,
                path: "/formatVersion",
                message: "Pack manifest formatVersion \(manifest.formatVersion) is not supported."
            ))
        }

        validateIdentifier(
            manifest.id,
            path: "/id",
            label: "Pack ID",
            emptyCode: .emptyPackID,
            invalidCode: .invalidPackID,
            issues: &issues
        )
        validateCapabilityPackageIDs(
            manifest.capabilityPackageIDs,
            basePath: "/capabilityPackageIDs",
            issues: &issues
        )
        if manifest.coreAPIVersion != supportedCoreAPIVersion {
            issues.append(blocker(
                .unsupportedCoreAPIVersion,
                path: "/coreAPIVersion",
                message: "Pack coreAPIVersion '\(manifest.coreAPIVersion)' is not supported."
            ))
        }

        validateShelfDefaults(manifest.shelfDefaults, issues: &issues)
        validateAppTemplates(manifest.appTemplates, issues: &issues)
        validatePolicyRestrictions(manifest.policyRestrictions, issues: &issues)

        return AstraPackManifestValidationReport(issues: issues)
    }

    private static func validateShelfDefaults(
        _ shelfDefaults: [AstraPackShelfDefault],
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) {
        var seenShelfIDs: Set<String> = []
        for (index, shelf) in shelfDefaults.enumerated() {
            let trimmedID = shelf.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let isValidID = validateIdentifier(
                shelf.id,
                path: "/shelfDefaults/\(index)/id",
                label: "Shelf default ID",
                emptyCode: .emptyShelfID,
                invalidCode: .invalidShelfID,
                issues: &issues
            )
            if isValidID, seenShelfIDs.contains(trimmedID) {
                issues.append(blocker(
                    .duplicateShelfID,
                    path: "/shelfDefaults/\(index)/id",
                    message: "Shelf default ID '\(trimmedID)' is duplicated."
                ))
            }
            if isValidID {
                seenShelfIDs.insert(trimmedID)
            }
            validateCapabilityPackageIDs(
                shelf.capabilityPackageIDs,
                basePath: "/shelfDefaults/\(index)/capabilityPackageIDs",
                issues: &issues
            )
        }
    }

    private static func validateAppTemplates(
        _ appTemplates: [AstraPackAppTemplate],
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) {
        for (index, template) in appTemplates.enumerated() {
            validateIdentifier(
                template.id,
                path: "/appTemplates/\(index)/id",
                label: "App template ID",
                emptyCode: .emptyAppTemplateID,
                invalidCode: .invalidAppTemplateID,
                issues: &issues
            )
            validateIdentifier(
                template.templateID,
                path: "/appTemplates/\(index)/templateID",
                label: "Template ID",
                emptyCode: .emptyTemplateID,
                invalidCode: .invalidTemplateID,
                issues: &issues
            )
            validateCapabilityPackageIDs(
                template.capabilityPackageIDs,
                basePath: "/appTemplates/\(index)/capabilityPackageIDs",
                issues: &issues
            )
            validateContributionKind(
                template.contributionKind,
                path: "/appTemplates/\(index)/contributionKind",
                issues: &issues
            )
        }
    }

    private static func validatePolicyRestrictions(
        _ restrictions: [AstraPackPolicyRestriction],
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) {
        for (index, restriction) in restrictions.enumerated() {
            validateIdentifier(
                restriction.id,
                path: "/policyRestrictions/\(index)/id",
                label: "Policy restriction ID",
                emptyCode: .emptyPolicyRestrictionID,
                invalidCode: .invalidPolicyRestrictionID,
                issues: &issues
            )
            validateContributionKind(
                restriction.contributionKind,
                path: "/policyRestrictions/\(index)/contributionKind",
                issues: &issues
            )
            if restriction.effect != "restrict" {
                issues.append(blocker(
                    .policyWidening,
                    path: "/policyRestrictions/\(index)/effect",
                    message: "Pack policy restrictions are restrict-only; '\(restriction.effect)' would widen policy."
                ))
            }
        }
    }

    @discardableResult
    private static func validateIdentifier(
        _ value: String,
        path: String,
        label: String,
        emptyCode: AstraPackManifestValidationReport.Issue.Code,
        invalidCode: AstraPackManifestValidationReport.Issue.Code,
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            issues.append(blocker(emptyCode, path: path, message: "\(label) is required."))
            return false
        }
        if trimmedValue != value || matchesIdentifier(trimmedValue) == false {
            issues.append(blocker(
                invalidCode,
                path: path,
                message: "\(label) must use lowercase ASCII segments separated by dots or hyphens."
            ))
            return false
        }
        return true
    }

    private static func validateCapabilityPackageIDs(
        _ capabilityPackageIDs: [String],
        basePath: String,
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) {
        for (index, capabilityPackageID) in capabilityPackageIDs.enumerated() {
            validateIdentifier(
                capabilityPackageID,
                path: "\(basePath)/\(index)",
                label: "Capability package ID",
                emptyCode: .emptyCapabilityPackageID,
                invalidCode: .invalidCapabilityPackageID,
                issues: &issues
            )
        }
    }

    private static func validateContributionKind(
        _ contributionKind: String,
        path: String,
        issues: inout [AstraPackManifestValidationReport.Issue]
    ) {
        guard supportedContributionKinds.contains(contributionKind) else {
            issues.append(blocker(
                .unknownContributionKind,
                path: path,
                message: "Unknown pack contribution kind '\(contributionKind)'."
            ))
            return
        }
    }

    private static func matchesIdentifier(_ value: String) -> Bool {
        value.range(of: identifierPattern, options: .regularExpression) != nil
    }

    private static func blocker(
        _ code: AstraPackManifestValidationReport.Issue.Code,
        path: String,
        message: String
    ) -> AstraPackManifestValidationReport.Issue {
        AstraPackManifestValidationReport.Issue(
            severity: .blocker,
            code: code,
            path: path,
            message: message
        )
    }
}
