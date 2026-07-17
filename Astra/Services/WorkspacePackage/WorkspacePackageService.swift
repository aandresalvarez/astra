import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

// Not Equatable: `WorkspaceConfigManager.WorkspaceConfig` itself isn't (its
// v11 schema and ~15 nested config types were never made Equatable, and
// retrofitting that is out of scope here) — callers compare individual
// fields (`canInstall`, `blockers`, `manifest`, `workspaceConfig`) instead.
struct WorkspacePackageValidationReport: Sendable {
    var manifest: WorkspacePackageManifest?
    var workspaceConfig: WorkspaceConfigManager.WorkspaceConfig?
    var appReports: [String: WorkspaceAppPackageValidationReport]
    var issues: [PortablePackageValidationIssue]

    var blockers: [PortablePackageValidationIssue] {
        issues.filter { $0.severity == .blocker }
    }

    var canInstall: Bool {
        blockers.isEmpty && manifest != nil && workspaceConfig != nil
    }
}

/// Reads and validates a `.astra-share` portable workspace package. Every
/// byte read here is treated as untrusted — the package may have come from
/// anywhere — so reads go through `PortablePackageSafeFileReader`'s
/// O_NOFOLLOW-safe path walk rather than an unguarded raw file read.
struct WorkspacePackageService {
    var appPackageService = WorkspaceAppPackageService()

    func validatePackage(at packageURL: URL) -> WorkspacePackageValidationReport {
        var issues: [PortablePackageValidationIssue] = []

        let manifest: WorkspacePackageManifest? = decode(
            WorkspacePackageManifest.self,
            rootURL: packageURL,
            relativePath: "manifest.json",
            issuePath: "/manifest.json",
            issues: &issues
        )
        let workspaceConfig: WorkspaceConfigManager.WorkspaceConfig? = decode(
            WorkspaceConfigManager.WorkspaceConfig.self,
            rootURL: packageURL,
            relativePath: "workspace-config.json",
            issuePath: "/workspace-config.json",
            issues: &issues
        )
        let declaredChecksums: [WorkspacePackageChecksum]? = decode(
            [WorkspacePackageChecksum].self,
            rootURL: packageURL,
            relativePath: "checksums.json",
            issuePath: "/checksums.json",
            issues: &issues
        )

        if let manifest {
            let actualConfigDigest = (try? PortablePackageSafeFileReader.digest(
                rootURL: packageURL,
                relativePath: "workspace-config.json"
            )) ?? ""
            if workspaceConfig != nil, manifest.sourceConfigDigest != actualConfigDigest {
                issues.append(blocker("/manifest.json/sourceConfigDigest", "Manifest digest does not match workspace-config.json."))
            }
            validateVersionGate(
                minimumASTRAVersion: manifest.minimumASTRAVersion,
                path: "/manifest.json/minimumASTRAVersion",
                issues: &issues
            )
        }

        if let declaredChecksums {
            validateChecksums(declaredChecksums, packageURL: packageURL, issues: &issues)
            validateAllFilesAreChecksummed(declaredChecksums, packageURL: packageURL, issues: &issues)
        } else {
            issues.append(blocker("/checksums.json", "Package is missing checksums.json."))
        }

        validateNoForbiddenContent(
            checksums: declaredChecksums,
            manifest: manifest,
            packageURL: packageURL,
            issues: &issues
        )
        if let workspaceConfig {
            validateConfigFreeTextContent(workspaceConfig, issues: &issues)
        }

        var appReports: [String: WorkspaceAppPackageValidationReport] = [:]
        for entry in manifest?.appEntries ?? [] {
            validateEmbeddedApp(entry, packageURL: packageURL, appReports: &appReports, issues: &issues)
        }
        for entry in manifest?.capabilityEntries ?? [] {
            validateEmbeddedCapability(entry, packageURL: packageURL, issues: &issues)
        }

        return WorkspacePackageValidationReport(
            manifest: manifest,
            workspaceConfig: workspaceConfig,
            appReports: appReports,
            issues: issues
        )
    }

    // MARK: - Embedded package cross-validation

    private func validateEmbeddedApp(
        _ entry: WorkspacePackageAppEntry,
        packageURL: URL,
        appReports: inout [String: WorkspaceAppPackageValidationReport],
        issues: inout [PortablePackageValidationIssue]
    ) {
        // `relativeBundlePath` is untrusted manifest data. Unlike capability
        // paths (which flow through the O_NOFOLLOW safe reader), it is handed
        // straight to `WorkspaceAppPackageService.validatePackage` as a package
        // ROOT, so a value like `../existing.astra-app` or a symlinked bundle
        // would let an outer package — whose checksums cover only its own
        // files — validate and import a bundle outside the `.astra-share`
        // directory, defeating containment. Reject anything that isn't a
        // portable relative path staying inside the package root.
        guard let bundleURL = Self.containedBundleURL(
            packageURL: packageURL,
            relativePath: entry.relativeBundlePath
        ) else {
            issues.append(blocker(
                "/manifest.json/appEntries/\(entry.logicalID)",
                "Embedded app bundle path must stay inside the package."
            ))
            return
        }
        let report = appPackageService.validatePackage(at: bundleURL)
        appReports[entry.logicalID] = report
        if !report.canInstall {
            issues.append(blocker("/\(entry.relativeBundlePath)", "Embedded workspace app package did not validate."))
        }
        // The outer package's own version gate can't mask an embedded app's
        // — check both, so a recipient on an old build can't pass the outer
        // gate and only then discover an inner one silently can't run.
        if let embeddedMinVersion = report.package?.minimumASTRAVersion {
            validateVersionGate(
                minimumASTRAVersion: embeddedMinVersion,
                path: "/\(entry.relativeBundlePath)/package.json/minimumASTRAVersion",
                issues: &issues
            )
        }
        let actualDigest = (try? PortablePackageSafeFileReader.digest(
            rootURL: bundleURL,
            relativePath: "checksums.json"
        )) ?? ""
        if entry.packageDigest != actualDigest {
            issues.append(blocker("/\(entry.relativeBundlePath)", "Embedded app package digest does not match the manifest entry."))
        }
    }

    /// Returns the bundle URL only when `relativePath` is a portable relative
    /// path that stays inside `packageURL` even after symlink resolution;
    /// otherwise `nil`. Root and candidate are resolved identically so a
    /// `/private`-alias collapse (see `WorkspaceFileLayout.appDirectoryURL`)
    /// applies to both and can't produce a false mismatch.
    private static func containedBundleURL(packageURL: URL, relativePath: String) -> URL? {
        guard PortablePackageSafeFileReader.isPortableRelativePath(relativePath) else { return nil }
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = packageURL.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else { return nil }
        return packageURL.appendingPathComponent(relativePath)
    }

    private func validateEmbeddedCapability(
        _ entry: WorkspacePackageCapabilityEntry,
        packageURL: URL,
        issues: inout [PortablePackageValidationIssue]
    ) {
        guard let data = try? PortablePackageSafeFileReader.readData(rootURL: packageURL, relativePath: entry.relativePath) else {
            issues.append(blocker("/\(entry.relativePath)", "Embedded capability package is missing or unreadable."))
            return
        }
        let actualDigest = WorkspaceAppService.digest(for: data)
        if entry.sha256 != actualDigest {
            issues.append(blocker("/\(entry.relativePath)", "Embedded capability package digest does not match the manifest entry."))
        }
        // The existing capability-import validator owns the deep checks
        // (malformed JSON, unsafe MCP transport, shell-metacharacter tools,
        // identity/version literals). Prerequisites are deliberately NOT
        // checked here: a missing CLI on the recipient machine is a
        // readiness/review item for the import plan, not a package defect.
        let capabilityReport = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)
        for issue in capabilityReport.blockers {
            issues.append(blocker("/\(entry.relativePath)", "\(issue.title): \(issue.message)"))
        }
        // Package JSON is not a trust boundary (see CapabilityGovernanceNormalizer):
        // an exporter that skipped the local-draft clamp, or a package hand-edited
        // after export, must not be trusted just because it decodes cleanly. This
        // check must use the RAW decode — the validator's returned package is
        // already normalized to draft, so checking that copy would always pass.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rawCapability = try? decoder.decode(PluginPackage.self, from: data) else { return }
        if rawCapability.governance.approvalStatus != .draft {
            issues.append(blocker("/\(entry.relativePath)", "Embedded capability must land as a local draft pending review."))
        }
    }

    // MARK: - Version gate

    /// Mirrors `PluginPackage.installBlockers(appVersion:installedPluginIDs:)`
    /// (`ASTRACore/PluginPackage.swift:433-454`), the one place in this codebase
    /// that actually enforces a minimum-version gate — `.astra-app`'s own
    /// `minimumASTRAVersion` field is stored and displayed but never checked.
    private func validateVersionGate(
        minimumASTRAVersion: String,
        path: String,
        issues: inout [PortablePackageValidationIssue]
    ) {
        // `minimumASTRAVersion` is a required field and the format's only
        // compatibility gate. An unparsable value (malformed export or a
        // hand-edited attempt to slip past the gate) must be a blocker, not a
        // silently-skipped check that would let an incompatible package import.
        guard let required = SemanticVersion(string: minimumASTRAVersion) else {
            issues.append(blocker(path, "Minimum ASTRA version \"\(minimumASTRAVersion)\" is not a valid version string."))
            return
        }
        let current = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0)
        if current < required {
            issues.append(blocker(path, "This package requires ASTRA \(minimumASTRAVersion) or later (running \(current))."))
        }
    }

    // MARK: - Checksums

    private func validateChecksums(
        _ checksums: [WorkspacePackageChecksum],
        packageURL: URL,
        issues: inout [PortablePackageValidationIssue]
    ) {
        for checksum in checksums {
            guard PortablePackageSafeFileReader.isPortableRelativePath(checksum.path) else {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum path must be relative and portable."))
                continue
            }
            guard let actual = try? PortablePackageSafeFileReader.digest(rootURL: packageURL, relativePath: checksum.path) else {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum references a missing or unreadable file."))
                continue
            }
            if actual != checksum.sha256 {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum does not match package file."))
            }
        }
    }

    private func validateAllFilesAreChecksummed(
        _ checksums: [WorkspacePackageChecksum],
        packageURL: URL,
        issues: inout [PortablePackageValidationIssue]
    ) {
        let declared = Set(checksums.map(\.path) + ["checksums.json"])
        for path in PortablePackageSafeFileReader.portableFilePaths(in: packageURL, intent: .explicitUserSelection)
            where !declared.contains(path) {
            issues.append(blocker("/\(path)", "Package file is not listed in checksums.json."))
        }
    }

    // MARK: - Forbidden content

    /// Same substring/absolute-path scan `.astra-app` runs
    /// (`WorkspaceAppPackageService.swift:1019-1043`), reused as a fresh
    /// standalone check here rather than reaching into that file's `private`
    /// implementation. Defense in depth on top of this format's type-level
    /// guarantees (no connector credential values, blanked skill secrets, no
    /// OAuth tokens) — the exporter should never produce a match, but
    /// validation treats the exporter as untrusted too.
    ///
    /// A raw whole-file scan is wrong for the three file groups this format
    /// *understands*, all of which legitimately contain forbidden substrings
    /// as structure, not as secrets — `workspace-config.json` carries
    /// credential key NAMES like "API_TOKEN" and the `googleOAuthAccountProfiles`
    /// key itself (the issue explicitly requires key names/scopes to travel),
    /// capability packages carry `oauthAccount` setup-requirement kinds and
    /// env key names, and embedded `.astra-app` bundles run their own
    /// identical scan inside `WorkspaceAppPackageService.validatePackage`.
    /// Those are excluded here and covered instead by
    /// `validateConfigFreeTextContent` (structural free-text scan),
    /// `CapabilityPackageValidator` + the draft-governance check, and the app
    /// service's own validation respectively. Everything else — unknown
    /// files a tampered package might smuggle in — still gets the raw scan.
    private func validateNoForbiddenContent(
        checksums: [WorkspacePackageChecksum]?,
        manifest: WorkspacePackageManifest?,
        packageURL: URL,
        issues: inout [PortablePackageValidationIssue]
    ) {
        let structurallyValidatedPaths = Set(
            ["workspace-config.json", "manifest.json"]
                + (manifest?.capabilityEntries.map(\.relativePath) ?? [])
        )
        let appBundlePrefixes = (manifest?.appEntries.map { $0.relativeBundlePath + "/" }) ?? []
        let scannedPaths = (
            checksums?.map(\.path) ??
                PortablePackageSafeFileReader.portableFilePaths(in: packageURL, intent: .explicitUserSelection)
        )
        .filter { $0.hasSuffix(".json") || $0.hasSuffix(".md") }
        .filter { path in
            !structurallyValidatedPaths.contains(path)
                && !appBundlePrefixes.contains(where: path.hasPrefix)
        }
        var reported = Set<String>()
        for path in scannedPaths {
            guard let data = try? PortablePackageSafeFileReader.readData(rootURL: packageURL, relativePath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            appendForbiddenContentIssues(in: text, path: "/\(path)", reported: &reported, issues: &issues)
        }
    }

    /// Structural free-text scan of the workspace config: only fields a human
    /// or agent authored (where a secret could realistically be pasted) are
    /// scanned, never key-name inventories (`credentialKeys`,
    /// `environmentKeys`, `configKeys`) or structured account metadata, which
    /// carry credential-adjacent *names* by design. Names of skills/
    /// connectors/tools are also exempt — "GitHub Token Helper" is a
    /// legitimate name, not a leak.
    private func validateConfigFreeTextContent(
        _ config: WorkspaceConfigManager.WorkspaceConfig,
        issues: inout [PortablePackageValidationIssue]
    ) {
        var reported = Set<String>()
        func scan(_ text: String?, _ field: String) {
            guard let text, !text.isEmpty else { return }
            appendForbiddenContentIssues(
                in: text,
                path: "/workspace-config.json/\(field)",
                reported: &reported,
                issues: &issues
            )
        }

        scan(config.instructions, "instructions")
        for (index, memory) in (config.memories ?? []).enumerated() {
            scan(memory, "memories[\(index)]")
        }
        for (index, skill) in config.skills.enumerated() {
            scan(skill.behaviorInstructions, "skills[\(index)].behaviorInstructions")
            scan(skill.description, "skills[\(index)].description")
            for (valueIndex, value) in skill.environmentValues.enumerated() {
                scan(value, "skills[\(index)].environmentValues[\(valueIndex)]")
            }
        }
        for (index, connector) in (config.connectors ?? []).enumerated() {
            scan(connector.description, "connectors[\(index)].description")
            scan(connector.notes, "connectors[\(index)].notes")
            for (valueIndex, value) in connector.configValues.enumerated() {
                scan(value, "connectors[\(index)].configValues[\(valueIndex)]")
            }
        }
        for (index, tool) in (config.localTools ?? []).enumerated() {
            scan(tool.description, "localTools[\(index)].description")
            scan(tool.command, "localTools[\(index)].command")
            scan(tool.arguments, "localTools[\(index)].arguments")
        }
        for (index, template) in (config.templates ?? []).enumerated() {
            scan(template.description, "templates[\(index)].description")
            scan(template.beforeGoal, "templates[\(index)].beforeGoal")
            scan(template.mainGoal, "templates[\(index)].mainGoal")
            scan(template.afterGoal, "templates[\(index)].afterGoal")
            scan(template.variablesJSON, "templates[\(index)].variablesJSON")
            scan(template.hooksJSON, "templates[\(index)].hooksJSON")
        }
        for (index, schedule) in (config.schedules ?? []).enumerated() {
            scan(schedule.goal, "schedules[\(index)].goal")
            scan(schedule.routineDescription, "schedules[\(index)].routineDescription")
            scan(schedule.routineInstructions, "schedules[\(index)].routineInstructions")
            scan(schedule.conversationContext, "schedules[\(index)].conversationContext")
            scan(schedule.templateVariablesJSON, "schedules[\(index)].templateVariablesJSON")
        }
    }

    private func appendForbiddenContentIssues(
        in text: String,
        path: String,
        reported: inout Set<String>,
        issues: inout [PortablePackageValidationIssue]
    ) {
        let lowercased = text.lowercased()
        let forbiddenKeys = ["api_key", "apikey", "oauth", "password", "secret", "token"]
        if forbiddenKeys.contains(where: { lowercased.contains($0) }), reported.insert("\(path)#credential").inserted {
            issues.append(blocker(path, "Package content appears to include credential material."))
        }
        if (text.contains(NSHomeDirectory()) || lowercased.contains("/users/")), reported.insert("\(path)#path").inserted {
            issues.append(blocker(path, "Package content appears to include an absolute local path."))
        }
    }

    // MARK: - Decoding

    private func decode<T: Decodable>(
        _ type: T.Type,
        rootURL: URL,
        relativePath: String,
        issuePath: String,
        issues: inout [PortablePackageValidationIssue]
    ) -> T? {
        do {
            let data = try PortablePackageSafeFileReader.readData(rootURL: rootURL, relativePath: relativePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch PortablePackageFileError.missing {
            issues.append(blocker(issuePath, "Required package file \(relativePath) is missing."))
            return nil
        } catch {
            issues.append(blocker(issuePath, "Could not decode required package file \(relativePath): \(error.localizedDescription)"))
            return nil
        }
    }

    private func blocker(_ path: String, _ message: String) -> PortablePackageValidationIssue {
        PortablePackageValidationIssue(severity: .blocker, path: path, message: message)
    }
}
