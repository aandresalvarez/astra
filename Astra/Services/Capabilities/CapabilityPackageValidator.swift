import Foundation
import ASTRACore

struct CapabilityPackageValidationIssue: Equatable, Identifiable {
    enum Severity: String {
        case blocker
        case warning
    }

    enum Code: String {
        case malformedJSON
        case unreadableFile
        case invalidPackageID
        case duplicatePackageID
        case duplicatePackageFilename
        case invalidVersion
        case localSourceNormalized
        case missingGovernance
        case approvalReset
        case unsafeLocalTool
        case unsafeConnector
        case unknownBrowserAdapter
        case unsafeMCPServer
        case missingPrerequisite
        case emptyPayload
        case packageUpdate
        case invalidIconAsset
        case missingIconAsset
    }

    var severity: Severity
    var code: Code
    var title: String
    var message: String
    var component: String?

    var id: String {
        [
            severity.rawValue,
            code.rawValue,
            component ?? "",
            title,
            message
        ].joined(separator: ":")
    }
}

struct CapabilityPackageValidationReport {
    var package: PluginPackage?
    var sourceURL: URL?
    var source: CapabilityPackageSource? = nil
    var issues: [CapabilityPackageValidationIssue]

    var blockers: [CapabilityPackageValidationIssue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [CapabilityPackageValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    var canInstall: Bool {
        package != nil && blockers.isEmpty
    }

    var summary: String {
        let messages = issues.map { "\($0.title): \($0.message)" }
        return messages.isEmpty ? "Package is ready to import." : messages.joined(separator: "\n")
    }
}

enum CapabilityPackageValidator {
    static func validate(
        data: Data,
        sourceURL: URL? = nil,
        installedPackages: [PluginPackage] = [],
        allowReplacingExistingPackageID: Bool = false,
        checkPrerequisites: Bool = true,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> CapabilityPackageValidationReport {
        let governanceWasOmitted = governanceWasOmitted(from: data)
        let decoder = JSONDecoder()
        let decoded: PluginPackage
        do {
            decoded = try decoder.decode(PluginPackage.self, from: data)
        } catch {
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: sourceURL,
                issues: [
                    issue(
                        .blocker,
                        .malformedJSON,
                        "Malformed JSON",
                        "ASTRA could not decode this file as a PluginPackage: \(error.localizedDescription)"
                    )
                ]
            )
        }

        return validate(
            package: decoded,
            sourceURL: sourceURL,
            installedPackages: installedPackages,
            governanceWasOmitted: governanceWasOmitted,
            allowReplacingExistingPackageID: allowReplacingExistingPackageID,
            checkPrerequisites: checkPrerequisites,
            detectExecutable: detectExecutable
        )
    }

    static func validateSource(
        at url: URL,
        installedPackages: [PluginPackage] = [],
        allowReplacingExistingPackageID: Bool = false,
        checkPrerequisites: Bool = true,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> CapabilityPackageValidationReport {
        do {
            let source = try CapabilityPackageSourceReader.read(at: url)
            return validate(
                source: source,
                installedPackages: installedPackages,
                allowReplacingExistingPackageID: allowReplacingExistingPackageID,
                checkPrerequisites: checkPrerequisites,
                detectExecutable: detectExecutable
            )
        } catch let error as CapabilityPackageSourceReadError {
            return unreadableSourceReport(url: url, error: error)
        } catch {
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: url,
                issues: [
                    issue(
                        .blocker,
                        .unreadableFile,
                        "Unreadable package",
                        "ASTRA could not read \(url.path): \(error.localizedDescription)",
                        component: url.lastPathComponent
                    )
                ]
            )
        }
    }

    static func validate(
        source: CapabilityPackageSource,
        installedPackages: [PluginPackage] = [],
        allowReplacingExistingPackageID: Bool = false,
        checkPrerequisites: Bool = true,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> CapabilityPackageValidationReport {
        let governanceWasOmitted = source.manifestData.map(governanceWasOmitted(from:)) ?? false
        var report = validate(
            package: source.package,
            sourceURL: source.manifestURL,
            installedPackages: installedPackages,
            governanceWasOmitted: governanceWasOmitted,
            allowReplacingExistingPackageID: allowReplacingExistingPackageID,
            checkPrerequisites: checkPrerequisites,
            detectExecutable: detectExecutable
        )
        var normalizedSource = source
        if let package = report.package {
            normalizedSource.package = package
        }
        report.source = normalizedSource
        return report
    }

    static func validate(
        package rawPackage: PluginPackage,
        sourceURL: URL? = nil,
        installedPackages: [PluginPackage] = [],
        governanceWasOmitted: Bool = false,
        allowReplacingExistingPackageID: Bool = false,
        checkPrerequisites: Bool = true,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> CapabilityPackageValidationReport {
        var issues: [CapabilityPackageValidationIssue] = []
        var package = rawPackage

        normalizeForLocalImport(&package, governanceWasOmitted: governanceWasOmitted, issues: &issues)
        validateIdentity(
            package,
            installedPackages: installedPackages,
            allowReplacingExistingPackageID: allowReplacingExistingPackageID,
            issues: &issues
        )
        validatePayload(package, issues: &issues)
        validateIconDescriptor(package.iconDescriptor, sourceURL: sourceURL, issues: &issues)
        validateLocalTools(package.localTools, issues: &issues)
        validateConnectors(package.connectors, issues: &issues)
        validateBrowserAdapters(package.browserAdapters, issues: &issues)
        validateMCPServers(in: package, issues: &issues)
        validatePrerequisites(
            package.prerequisites,
            checkPrerequisites: checkPrerequisites,
            detectExecutable: detectExecutable,
            issues: &issues
        )

        return CapabilityPackageValidationReport(
            package: package,
            sourceURL: sourceURL,
            issues: uniqueIssues(issues)
        )
    }

    private static func normalizeForLocalImport(
        _ package: inout PluginPackage,
        governanceWasOmitted: Bool,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        if package.sourceMetadata != .localLibrary() {
            package.sourceMetadata = .localLibrary()
            issues.append(issue(
                .warning,
                .localSourceNormalized,
                "Source set to local",
                "Imported capability files are treated as local packages, even if the JSON declares another source."
            ))
        }

        if governanceWasOmitted {
            package.governance = .localDraft()
            issues.append(issue(
                .warning,
                .missingGovernance,
                "Governance missing",
                "This package will be imported as draft, admin-only, and requiring explicit local review."
            ))
            return
        }

        if package.governance.approvalStatus != .draft ||
            package.governance.visibility != .adminOnly ||
            !package.governance.requiresAdminApproval {
            issues.append(issue(
                .warning,
                .approvalReset,
                "Approval reset",
                "Local imports cannot approve themselves. The package will be imported as draft until reviewed in ASTRA."
            ))
        }

        CapabilityGovernanceNormalizer.clampToLocalDraft(&package)
        if package.governance.policyNotes == CapabilityGovernanceNormalizer.defaultDraftPolicyNote {
            package.governance.policyNotes = "Local capability package imported from JSON and pending review."
        }
    }

    private static func validateIdentity(
        _ package: PluginPackage,
        installedPackages: [PluginPackage],
        allowReplacingExistingPackageID: Bool,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        let rawID = package.id
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            issues.append(issue(.blocker, .invalidPackageID, "Missing package ID", "Package ID cannot be empty."))
            return
        }

        if !isValidPackageIDLiteral(rawID) {
            issues.append(issue(
                .blocker,
                .invalidPackageID,
                "Unsafe package ID",
                "Package ID must start with a letter or number and contain only ASCII letters, numbers, dots, hyphens, and underscores.",
                component: id
            ))
        }

        let safeName = CapabilityLibrary.safeFileName(for: id)
        if safeName == "capability" {
            issues.append(issue(
                .blocker,
                .invalidPackageID,
                "Unsafe package filename",
                "Package ID does not produce a usable capability filename.",
                component: id
            ))
        }

        let normalizedID = package.id.lowercased()
        if let duplicate = installedPackages.first(where: { $0.id.lowercased() == normalizedID }),
           !allowReplacingExistingPackageID || duplicate.id != package.id {
            // A strictly newer version of an installed local package imports
            // as an update: the file is replaced, the digest changes, and the
            // package returns to draft until re-approved. Built-ins and
            // same-or-older versions stay blocked.
            let incomingVersion = SemanticVersion(string: package.version)
            let installedVersion = SemanticVersion(string: duplicate.version)
            let isNewerVersionOfSamePackage = duplicate.id == package.id
                && duplicate.sourceMetadata?.kind != "built-in"
                && incomingVersion != nil
                && installedVersion != nil
                && incomingVersion! > installedVersion!
            if isNewerVersionOfSamePackage {
                issues.append(issue(
                    .warning,
                    .packageUpdate,
                    "Updates installed capability",
                    "Replaces \(duplicate.id) \(duplicate.version) with \(package.version). The update imports as draft and needs review before it can run again.",
                    component: package.id
                ))
            } else {
                issues.append(issue(
                    .blocker,
                    .duplicatePackageID,
                    "Package already installed",
                    "A capability with ID \(duplicate.id) already exists. Remove it before importing a replacement.",
                    component: package.id
                ))
            }
        }

        if let collision = installedPackages.first(where: {
            $0.id.lowercased() != normalizedID
                && CapabilityLibrary.safeFileName(for: $0.id).lowercased() == safeName.lowercased()
        }) {
            issues.append(issue(
                .blocker,
                .duplicatePackageFilename,
                "Package filename collision",
                "Package ID \(package.id) maps to the same filename as installed package \(collision.id).",
                component: package.id
            ))
        }

        if !isValidSemanticVersionLiteral(package.version) {
            issues.append(issue(
                .blocker,
                .invalidVersion,
                "Invalid version",
                "Package version \(package.version) is not a semantic version like 1.0.0.",
                component: package.version
            ))
        }
    }

    private static func isValidPackageIDLiteral(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 128,
              let first = value.unicodeScalars.first,
              isASCIIAlphanumeric(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private static func isValidSemanticVersionLiteral(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || (48...57).contains(scalar.value)
    }

    private static func validatePayload(
        _ package: PluginPackage,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        if package.skills.isEmpty &&
            package.connectors.isEmpty &&
            package.localTools.isEmpty &&
            package.mcpServers.isEmpty &&
            package.templates.isEmpty &&
            package.browserAdapters.isEmpty {
            issues.append(issue(
                .warning,
                .emptyPayload,
                "No installable payload",
                "This package does not declare skills, connectors, tools, MCP servers, browser adapters, or templates."
            ))
        }
    }

    private static func validateIconDescriptor(
        _ descriptor: CapabilityIconDescriptor,
        sourceURL: URL?,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        guard descriptor.kind == .asset else { return }
        if let reason = CapabilityIconAssetPolicy.invalidReason(for: descriptor) {
            issues.append(issue(
                .blocker,
                .invalidIconAsset,
                "Invalid icon asset",
                reason,
                component: descriptor.value
            ))
            return
        }

        guard let sourceURL else { return }
        let assetRoot = ((try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            ? sourceURL
            : sourceURL.deletingLastPathComponent()
        do {
            _ = try CapabilityIconAssetPolicy.validatedAssetURL(
                relativePath: descriptor.value,
                rootURL: assetRoot
            )
        } catch CapabilityIconAssetValidationError.missing {
            issues.append(issue(
                .blocker,
                .missingIconAsset,
                "Missing icon asset",
                "\(descriptor.value) was declared but was not found in the package assets.",
                component: descriptor.value
            ))
        } catch {
            issues.append(issue(
                .blocker,
                .invalidIconAsset,
                "Invalid icon asset",
                "\(descriptor.value) could not be loaded as a safe package asset.",
                component: descriptor.value
            ))
        }
    }

    private static func validateLocalTools(
        _ tools: [PluginLocalTool],
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        for tool in tools {
            let name = displayName(tool.name, fallback: tool.command)
            if let reason = LocalToolSecurityPolicy.unsafeCommandReason(tool.command) {
                issues.append(issue(
                    .blocker,
                    .unsafeLocalTool,
                    "Unsafe local tool",
                    "\(name) has an unsafe command: \(reason).",
                    component: name
                ))
            }
            if let reason = LocalToolSecurityPolicy.unsafeArgumentsReason(tool.arguments) {
                issues.append(issue(
                    .blocker,
                    .unsafeLocalTool,
                    "Unsafe local tool arguments",
                    "\(name) has unsafe default arguments: \(reason).",
                    component: name
                ))
            }
        }
    }

    private static func validateConnectors(
        _ connectors: [PluginConnector],
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        for connector in connectors {
            guard let reason = ConnectorSecurityPolicy.credentialTransportViolation(
                baseURL: connector.baseURL,
                authMethod: connector.authMethod,
                credentialKeys: connector.credentialHints.map(\.key)
            ) else {
                continue
            }
            let name = displayName(connector.name, fallback: connector.serviceType)
            issues.append(issue(
                .blocker,
                .unsafeConnector,
                "Unsafe connector",
                "\(name) cannot use credentials over an unsafe transport. \(reason)",
                component: name
            ))
        }
    }

    private static func validateBrowserAdapters(
        _ adapters: [String],
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        for adapter in adapters where BrowserSiteAdapterID.normalized(adapter) == nil {
            issues.append(issue(
                .blocker,
                .unknownBrowserAdapter,
                "Unknown browser adapter",
                "\(adapter) is not a known ASTRA browser adapter ID.",
                component: adapter
            ))
        }
    }

    private static func validateMCPServers(
        in package: PluginPackage,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        for server in package.mcpServers {
            if let nameReason = MCPEnvironmentKeyPolicy.invalidNameReason(server: server) {
                let name = displayName(server.displayName, fallback: server.id)
                issues.append(issue(
                    .blocker,
                    .unsafeMCPServer,
                    "Unsafe MCP server name",
                    "\(name): \(nameReason).",
                    component: name
                ))
            }
            let undeclared = MCPEnvironmentKeyPolicy.undeclaredKeys(server: server, package: package)
            if !undeclared.isEmpty {
                let name = displayName(server.displayName, fallback: server.id)
                issues.append(issue(
                    .blocker,
                    .unsafeMCPServer,
                    "MCP server requests undeclared environment keys",
                    "\(name) requests \(undeclared.joined(separator: ", ")), which this package does not declare via its connectors or skills. A server may only receive environment keys its own package configures.",
                    component: name
                ))
            }
            if let reason = unsafeMCPServerReason(server) {
                let name = displayName(server.displayName, fallback: server.id)
                issues.append(issue(
                    .blocker,
                    .unsafeMCPServer,
                    "Unsafe MCP server",
                    "\(name) is unsafe: \(reason).",
                    component: name
                ))
            }
        }
    }

    private static func validatePrerequisites(
        _ prerequisites: [CLIPrerequisite],
        checkPrerequisites: Bool,
        detectExecutable: (String) -> String,
        issues: inout [CapabilityPackageValidationIssue]
    ) {
        for prerequisite in prerequisites {
            if let reason = LocalToolSecurityPolicy.unsafeCommandReason(prerequisite.binary) {
                issues.append(issue(
                    .blocker,
                    .unsafeLocalTool,
                    "Unsafe prerequisite",
                    "\(prerequisite.displayName) declares an unsafe binary name: \(reason).",
                    component: prerequisite.displayName
                ))
                continue
            }
            if let reason = LocalToolSecurityPolicy.unsafeArgumentsReason(prerequisite.livenessArgs.joined(separator: " ")) {
                issues.append(issue(
                    .blocker,
                    .unsafeLocalTool,
                    "Unsafe prerequisite arguments",
                    "\(prerequisite.displayName) declares unsafe liveness arguments: \(reason).",
                    component: prerequisite.displayName
                ))
                continue
            }
            guard checkPrerequisites else { continue }
            if detectExecutable(prerequisite.binary).isEmpty {
                issues.append(issue(
                    .warning,
                    .missingPrerequisite,
                    "Prerequisite missing",
                    "\(prerequisite.displayName) is not currently installed or executable. \(prerequisite.installHint)",
                    component: prerequisite.displayName
                ))
            }
        }
    }

    private static func unsafeMCPServerReason(_ server: PluginMCPServer) -> String? {
        switch server.transport {
        case .stdio:
            let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = LocalToolSecurityPolicy.unsafeCommandReason(command) {
                return reason
            }
            if let reason = LocalToolSecurityPolicy.unsafeArgumentsReason(server.arguments.joined(separator: " ")) {
                return reason
            }
        case .http, .sse:
            guard let url = server.url,
                  let scheme = url.scheme?.lowercased() else {
                return "remote MCP URL is missing or invalid"
            }
            if scheme == "https" {
                return nil
            }
            if scheme == "http", isLoopbackHost(url.host) {
                return nil
            }
            return "remote MCP URL must use HTTPS, except loopback HTTP for local development"
        }
        return nil
    }

    private static func governanceWasOmitted(from data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["governance"] == nil || object["governance"] is NSNull
    }

    private static func unreadableSourceReport(
        url: URL,
        error: CapabilityPackageSourceReadError
    ) -> CapabilityPackageValidationReport {
        switch error {
        case .malformedManifest(let manifestURL, let decodeError):
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: manifestURL,
                issues: [
                    issue(
                        .blocker,
                        .malformedJSON,
                        "Malformed JSON",
                        "ASTRA could not decode this file as a PluginPackage: \(decodeError.localizedDescription)"
                    )
                ]
            )
        case .missingManifest(let manifestURL):
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: manifestURL,
                issues: [
                    issue(
                        .blocker,
                        .unreadableFile,
                        "Unreadable package",
                        "ASTRA could not find \(CapabilityPackageSourceReader.manifestFileName) at \(manifestURL.path).",
                        component: url.lastPathComponent
                    )
                ]
            )
        case .unreadable(let manifestURL, let readError):
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: manifestURL,
                issues: [
                    issue(
                        .blocker,
                        .unreadableFile,
                        "Unreadable package",
                        "ASTRA could not read \(manifestURL.path): \(readError.localizedDescription)",
                        component: url.lastPathComponent
                    )
                ]
            )
        }
    }

    private static func issue(
        _ severity: CapabilityPackageValidationIssue.Severity,
        _ code: CapabilityPackageValidationIssue.Code,
        _ title: String,
        _ message: String,
        component: String? = nil
    ) -> CapabilityPackageValidationIssue {
        CapabilityPackageValidationIssue(
            severity: severity,
            code: code,
            title: title,
            message: message,
            component: component
        )
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func uniqueIssues(_ issues: [CapabilityPackageValidationIssue]) -> [CapabilityPackageValidationIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }
}
