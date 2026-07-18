import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// What an embedded capability needs on the recipient machine, surfaced so the
/// pre-import review can say more than "installs as a draft".
struct WorkspacePackageCapabilityRequirements: Sendable, Equatable {
    var cliPrerequisites: [String]
    var accountRequirements: [String]
    var isEmpty: Bool { cliPrerequisites.isEmpty && accountRequirements.isEmpty }
}

struct WorkspacePackageValidationReport: Sendable {
    var manifest: WorkspacePackageManifest?
    var shareDocument: WorkspaceShareDocument?
    var appReports: [String: WorkspaceAppPackageValidationReport]
    var capabilityRequirements: [String: WorkspacePackageCapabilityRequirements] = [:]
    /// Whole-package fingerprint (digest of `checksums.json`) captured in the
    /// SAME validation call that built the plan, so the review's displayed
    /// inventory and the digest the import is bound to come from one read of the
    /// package — a source swapped between two separate reads can't pair one
    /// package's plan with another's accepted digest.
    var packageFingerprint: String?
    var issues: [PortablePackageValidationIssue]

    var blockers: [PortablePackageValidationIssue] {
        issues.filter { $0.severity == .blocker }
    }

    var canInstall: Bool {
        blockers.isEmpty && manifest != nil && shareDocument != nil
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

        // Bound the untrusted package BEFORE hashing anything: a crafted tree of
        // many files (or a few near-limit files) would otherwise be enumerated
        // and digested in full during review — the staging budget only applies
        // after the user confirms. This single lstat walk also surfaces the
        // symlink rejection `stageBoundedCopy` applies at import as a
        // pre-confirmation blocker, so the review never approves a package the
        // import will reject.
        if let violation = PortablePackageSafeFileReader.reviewBoundsViolation(in: packageURL) {
            let message: String
            switch violation {
            case .containsSymlink(let path):
                message = "Package contains a symbolic link (\(path)); links are not allowed in a portable package."
            case .tooManyFiles(let limit):
                message = "Package exceeds the \(limit)-file limit for import review."
            case .tooLarge(let limit):
                message = "Package exceeds the \(limit / (1024 * 1024))MB size limit for import review."
            case .copyFailed(let path):
                message = "Package could not be read (\(path))."
            }
            issues.append(blocker("/", message))
            return WorkspacePackageValidationReport(manifest: nil, shareDocument: nil, appReports: [:], issues: issues)
        }

        // Capture the whole-package fingerprint (checksums.json digest) BEFORE
        // decoding anything, and re-verify it hasn't changed at the end of this
        // call. The package may sit in an attacker-writable location; without this
        // an attacker could let package A finish validation, then swap
        // checksums.json (and the rest) for package B before the final digest —
        // the review would display A while the recorded fingerprint matched B, so
        // the coordinator (which binds the confirmed import to that fingerprint)
        // would accept and import B. Binding every read to one stable fingerprint
        // makes such a mid-validation swap a blocker.
        let initialFingerprint = try? PortablePackageSafeFileReader.digest(
            rootURL: packageURL,
            relativePath: "checksums.json"
        )

        let manifest: WorkspacePackageManifest? = decode(
            WorkspacePackageManifest.self,
            rootURL: packageURL,
            relativePath: "manifest.json",
            issuePath: "/manifest.json",
            issues: &issues
        )
        let shareDocument: WorkspaceShareDocument? = decode(
            WorkspaceShareDocument.self,
            rootURL: packageURL,
            relativePath: "workspace-share.json",
            issuePath: "/workspace-share.json",
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
            let actualShareDigest = (try? PortablePackageSafeFileReader.digest(
                rootURL: packageURL,
                relativePath: "workspace-share.json"
            )) ?? ""
            if shareDocument != nil, manifest.sourceShareDigest != actualShareDigest {
                issues.append(blocker("/manifest.json/sourceShareDigest", "Manifest digest does not match workspace-share.json."))
            }
            // The review sheet and the destination directory name are derived
            // from `manifest.workspaceName`, but the workspace is actually
            // created with `workspace-share.json`'s name. Bind them so the
            // imported workspace's identity can't differ from the one reviewed.
            if let shareName = shareDocument?.name, shareName != manifest.workspaceName {
                issues.append(blocker(
                    "/manifest.json/workspaceName",
                    "Manifest workspace name (\(manifest.workspaceName)) does not match workspace-share.json name (\(shareName))."
                ))
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
        if let shareDocument {
            // Reject a future/unsupported format up front: Swift's decoder
            // ignores unknown fields, so a newer additive format would otherwise
            // decode and import with the semantics this build doesn't understand
            // silently dropped.
            if shareDocument.formatVersion > WorkspaceShareDocument.currentFormatVersion {
                issues.append(blocker(
                    "/workspace-share.json/formatVersion",
                    "Package format version \(shareDocument.formatVersion) is newer than this build supports (\(WorkspaceShareDocument.currentFormatVersion))."
                ))
            }
            validateShareFreeTextContent(shareDocument, issues: &issues)
            validateShareResourceSafety(shareDocument, issues: &issues)
        }

        // Reports are keyed by logical ID, so two entries sharing one would make
        // the later report overwrite the earlier — and the planner would then
        // show a safe bundle's status for a permission-sensitive one while the
        // coordinator imports both (`createApp` suffixes the collided ID). Reject
        // duplicate app logical IDs so the reviewed status stays bound to the
        // bundle that installs.
        rejectDuplicateNames((manifest?.appEntries ?? []).map(\.logicalID), kind: "app entries", issues: &issues)
        var appReports: [String: WorkspaceAppPackageValidationReport] = [:]
        for entry in manifest?.appEntries ?? [] {
            validateEmbeddedApp(entry, packageURL: packageURL, appReports: &appReports, issues: &issues)
        }
        // Requirements are keyed by packageID, so two entries sharing one would
        // let the second overwrite the first — the planner then shows the last
        // payload's prerequisites for both while the coordinator installs the
        // first and skips the rest. Reject duplicate capability entry IDs.
        rejectDuplicateNames((manifest?.capabilityEntries ?? []).map(\.packageID), kind: "capability entries", issues: &issues)
        var capabilityRequirements: [String: WorkspacePackageCapabilityRequirements] = [:]
        for entry in manifest?.capabilityEntries ?? [] {
            validateEmbeddedCapability(
                entry,
                packageURL: packageURL,
                requirements: &capabilityRequirements,
                issues: &issues
            )
        }

        // Re-read the fingerprint and require it to match the one captured before
        // decoding: if checksums.json changed under us during validation, the
        // package was swapped mid-review and every decoded artifact above is
        // untrustworthy — fail closed rather than pairing this review with a
        // fingerprint the import would bind to.
        let finalFingerprint = try? PortablePackageSafeFileReader.digest(
            rootURL: packageURL,
            relativePath: "checksums.json"
        )
        if initialFingerprint != finalFingerprint {
            issues.append(blocker("/checksums.json", "Package changed during validation; re-open it to review."))
        }

        return WorkspacePackageValidationReport(
            manifest: manifest,
            shareDocument: shareDocument,
            appReports: appReports,
            capabilityRequirements: capabilityRequirements,
            packageFingerprint: initialFingerprint,
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
        // The outer entry's declared `logicalID`/`displayName` drive the review
        // plan, but the coordinator imports the nested bundle's OWN manifest. If
        // the entry advertises one identity while the bundle validates to a
        // different `app.id`, the reviewed inventory names an app other than the
        // one installed. Bind them, mirroring the embedded-capability ID check.
        if let embeddedAppID = report.manifest?.app.id, embeddedAppID != entry.logicalID {
            issues.append(blocker(
                "/manifest.json/appEntries/\(entry.logicalID)",
                "Embedded app ID (\(embeddedAppID)) does not match its manifest entry ID (\(entry.logicalID))."
            ))
        }
        // The review sheet shows `entry.displayName`, but the coordinator imports
        // and reports the embedded manifest's own `app.name`. A benign display
        // name over a different embedded name would let the recipient approve an
        // app identity other than the one shown — bind the name alongside the ID.
        if let embeddedAppName = report.manifest?.app.name, embeddedAppName != entry.displayName {
            issues.append(blocker(
                "/manifest.json/appEntries/\(entry.logicalID)",
                "Embedded app name (\(embeddedAppName)) does not match its manifest entry display name (\(entry.displayName))."
            ))
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
        requirements: inout [String: WorkspacePackageCapabilityRequirements],
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
        // The manifest entry's declared `packageID` drives the review plan, the
        // enabled-set draft stripping on import, and the "already installed"
        // check — but the importer installs the DECODED package, keyed by its
        // own `PluginPackage.id`. If the two disagree, a package could advertise
        // an innocuous ID while installing (or overwriting) a different one, and
        // the enabled-set stripping — which filters by the declared entry ID —
        // would miss the real installed ID, exposing the draft immediately. Bind
        // them: the declared entry ID must equal the embedded package's own ID.
        if rawCapability.id != entry.packageID {
            issues.append(blocker(
                "/\(entry.relativePath)",
                "Embedded capability package ID (\(rawCapability.id)) does not match its manifest entry ID (\(entry.packageID))."
            ))
        }
        // A curated built-in ID must never be *embedded*: if the recipient lacks
        // that built-in's library file, the exact-ID lookup finds nothing, the
        // draft install proceeds, and `CapabilityLibrary.decodeInstalledPackage`
        // then applies the compiled approved governance for every trusted
        // built-in ID while retaining the imported payload — auto-approving
        // attacker-controlled content the review promised was a draft. Built-ins
        // travel only as references (`capabilityIDs`), never as embedded packages.
        if CapabilityLibrary.trustedBuiltInPackageIDs.contains(entry.packageID)
            || CapabilityLibrary.trustedBuiltInPackageIDs.contains(rawCapability.id) {
            issues.append(blocker(
                "/\(entry.relativePath)",
                "Embedded capability may not use the built-in ID '\(entry.packageID)'; built-in capabilities are referenced, not embedded."
            ))
        }
        // The review sheet shows `entry.displayName`, but the coordinator installs
        // the decoded package's own `name`. A benign display name masking a
        // different embedded name would let the recipient approve an inventory
        // that names a different capability than the one added — bind them.
        if rawCapability.name != entry.displayName {
            issues.append(blocker(
                "/\(entry.relativePath)",
                "Embedded capability name (\(rawCapability.name)) does not match its manifest entry display name (\(entry.displayName))."
            ))
        }
        if rawCapability.governance.approvalStatus != .draft {
            issues.append(blocker("/\(entry.relativePath)", "Embedded capability must land as a local draft pending review."))
        }
        // Capability paths are excluded from the free-text credential scan, so a
        // hand-tampered package could carry a secret-keyed skill default the
        // export blanks. Reject any nonempty secret-keyed value here.
        for skill in rawCapability.skills {
            for (index, key) in skill.environmentKeys.enumerated() where Skill.isSecretEnvironmentKey(key) {
                let value = index < skill.environmentValues.count ? skill.environmentValues[index] : ""
                if !value.isEmpty {
                    issues.append(blocker(
                        "/\(entry.relativePath)",
                        "Embedded capability carries a secret environment value for '\(key)'; credential values never travel."
                    ))
                }
            }
        }
        // Surface what this capability will need locally so the review plan can
        // say "needs the gcloud CLI" / "needs a Google account" rather than a
        // bare "installs as a draft". Prerequisites are intentionally not
        // validated as package defects (a missing CLI is a recipient-state
        // readiness item), so this is the channel the `checkPrerequisites: false`
        // call above defers them to.
        let cli = rawCapability.prerequisites.map { $0.displayName.isEmpty ? $0.binary : $0.displayName }
        let accounts = rawCapability.setupRequirements
            .filter { $0.kind == .oauthAccount }
            .map { $0.provider ?? $0.displayName }
        if !cli.isEmpty || !accounts.isEmpty {
            requirements[entry.packageID] = WorkspacePackageCapabilityRequirements(
                cliPrerequisites: cli,
                accountRequirements: accounts
            )
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
            ["workspace-share.json", "manifest.json"]
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
    private func validateShareFreeTextContent(
        _ document: WorkspaceShareDocument,
        issues: inout [PortablePackageValidationIssue]
    ) {
        var reported = Set<String>()
        func scan(_ text: String?, _ field: String) {
            guard let text, !text.isEmpty else { return }
            appendForbiddenContentIssues(
                in: text,
                path: "/workspace-share.json/\(field)",
                reported: &reported,
                issues: &issues
            )
        }

        scan(document.instructions, "instructions")
        for (index, skill) in document.skills.enumerated() {
            scan(skill.behaviorInstructions, "skills[\(index)].behaviorInstructions")
            scan(skill.description, "skills[\(index)].description")
            for (valueIndex, value) in skill.environmentValues.enumerated() {
                scan(value, "skills[\(index)].environmentValues[\(valueIndex)]")
            }
        }
        for (index, connector) in document.connectors.enumerated() {
            scan(connector.description, "connectors[\(index)].description")
            scan(connector.notes, "connectors[\(index)].notes")
        }
        for (index, tool) in document.localTools.enumerated() {
            scan(tool.description, "localTools[\(index)].description")
            scan(tool.command, "localTools[\(index)].command")
            scan(tool.arguments, "localTools[\(index)].arguments")
        }
        for (index, template) in document.templates.enumerated() {
            scan(template.description, "templates[\(index)].description")
            scan(template.beforeGoal, "templates[\(index)].beforeGoal")
            scan(template.mainGoal, "templates[\(index)].mainGoal")
            scan(template.afterGoal, "templates[\(index)].afterGoal")
            scan(template.variablesJSON, "templates[\(index)].variablesJSON")
        }
        for (index, schedule) in document.schedules.enumerated() {
            scan(schedule.goal, "schedules[\(index)].goal")
            scan(schedule.routineDescription, "schedules[\(index)].routineDescription")
            scan(schedule.routineInstructions, "schedules[\(index)].routineInstructions")
            scan(schedule.templateVariablesJSON, "schedules[\(index)].templateVariablesJSON")
        }
    }

    /// Structural safety gates the dedicated importer applies anyway, hoisted
    /// to validation so an unsafe resource surfaces as a pre-import blocker
    /// instead of being silently dropped (leaving dangling name links) or
    /// installed with an embedded credential the review promised never travels.
    private func validateShareResourceSafety(
        _ document: WorkspaceShareDocument,
        issues: inout [PortablePackageValidationIssue]
    ) {
        for (index, connector) in document.connectors.enumerated() {
            // A base URL like https://user:pass@host embeds a credential the
            // review's "credential values never travel" promise would break.
            if let components = URLComponents(string: connector.baseURL),
               components.user != nil || components.password != nil {
                issues.append(blocker(
                    "/workspace-share.json/connectors[\(index)].baseURL",
                    "Connector base URL must not embed credentials (user:password@host)."
                ))
            }
            // The importer applies the same transport policy and *silently skips*
            // a connector that declares credentials over an unprotected URL (e.g.
            // http://host), even though the plan presented it as installable and
            // skills may keep a name link to it. Surface it as a blocker so the
            // package is rejected rather than partially imported.
            if let violation = ConnectorSecurityPolicy.credentialTransportViolation(
                baseURL: connector.baseURL,
                authMethod: connector.authMethod,
                credentialKeys: connector.credentialKeys
            ) {
                issues.append(blocker(
                    "/workspace-share.json/connectors[\(index)].baseURL",
                    violation
                ))
            }
        }
        // Secret-keyed env values never travel (export blanks them). A tampered
        // package that re-populates one would otherwise be persisted to the
        // Keychain/SwiftData by the importer, breaking the review's promise that
        // credential values never travel.
        for (index, skill) in document.skills.enumerated() {
            for (keyIndex, key) in skill.environmentKeys.enumerated()
            where Skill.isSecretEnvironmentKey(key) {
                let value = keyIndex < skill.environmentValues.count ? skill.environmentValues[keyIndex] : ""
                if !value.isEmpty {
                    issues.append(blocker(
                        "/workspace-share.json/skills[\(index)].environmentValues[\(keyIndex)]",
                        "Secret environment value for '\(key)' must not be present in a share (credential values never travel)."
                    ))
                }
            }
        }
        for (index, tool) in document.localTools.enumerated() {
            // The importer silently drops a policy-unsafe tool, which would
            // leave a skill's name link to it unresolved. Reject up front.
            if !LocalToolSecurityPolicy.isSafe(command: tool.command, arguments: tool.arguments) {
                issues.append(blocker(
                    "/workspace-share.json/localTools[\(index)].command",
                    "Local tool command is not permitted for import."
                ))
            }
        }
        // Resource links are resolved by NAME within the package, so a duplicate
        // name is ambiguous: the importer would keep only the last row under a
        // name, and any skill/schedule/template link to the others would rebind
        // to the wrong one (e.g. a routine running a different template's goal).
        // Reject duplicate names per resource type.
        rejectDuplicateNames(document.skills.map(\.name), kind: "skills", issues: &issues)
        rejectDuplicateNames(document.connectors.map(\.name), kind: "connectors", issues: &issues)
        rejectDuplicateNames(document.localTools.map(\.name), kind: "localTools", issues: &issues)
        rejectDuplicateNames(document.templates.map(\.name), kind: "templates", issues: &issues)
        let templateNames = Set(document.templates.map(\.name))
        // Apply the schedule editor's domain constraints: an out-of-range value
        // (notably interval <= 0) would make `advanceNextFireDate` place every
        // next fire at/before now, so `TaskScheduler` would relaunch the routine
        // on every ~0.5s iteration once the recipient enabled it.
        for (index, schedule) in document.schedules.enumerated() {
            let type = ScheduleType(rawValue: schedule.scheduleType)
            let invalid: String?
            switch type {
            case .interval where schedule.intervalSeconds <= 0:
                invalid = "interval must be a positive number of seconds"
            case .daily where !(0...23).contains(schedule.dailyHour) || !(0...59).contains(schedule.dailyMinute):
                invalid = "daily hour/minute is out of range"
            case .weekly where !(1...7).contains(schedule.weeklyDayOfWeek):
                invalid = "weekly day-of-week is out of range"
            case .none:
                invalid = "unknown schedule type '\(schedule.scheduleType)'"
            default:
                invalid = nil
            }
            if let invalid {
                issues.append(blocker("/workspace-share.json/schedules[\(index)]", "Schedule is invalid: \(invalid)."))
            }
            // A `templateName` absent from the package's own templates would be
            // silently stored as a nil `templateID`; the enabled routine then
            // runs `effectiveGoal` instead of the declared template's behavior.
            if let templateName = schedule.templateName,
               !templateName.isEmpty,
               !templateNames.contains(templateName) {
                issues.append(blocker(
                    "/workspace-share.json/schedules[\(index)].templateName",
                    "Schedule references template '\(templateName)' that is not present in the package."
                ))
            }
        }
        // An SSH `host`/`user`/`configAlias` that begins with `-` is parsed by
        // `ssh` as an OPTION, not a destination — e.g. `-oProxyCommand=…` runs an
        // attacker-selected local command when `SSHConnectionManager.test` places
        // it on the command line. Reject option-like values up front.
        for (index, ssh) in document.sshConnections.enumerated() {
            for (field, value) in [("host", ssh.host), ("user", ssh.user), ("configAlias", ssh.configAlias)]
            where value.hasPrefix("-") {
                issues.append(blocker(
                    "/workspace-share.json/sshConnections[\(index)].\(field)",
                    "SSH \(field) must not begin with '-' (it would be parsed as an ssh option)."
                ))
            }
        }
        // Connectors and local tools have a to-ONE inverse `skill` relationship,
        // so a name referenced by two skills would silently re-parent the single
        // row to whichever skill is imported last, stripping it from the earlier
        // one while the review still reports success. Reject a resource claimed by
        // more than one skill.
        rejectMultiSkillOwnership(
            document.skills.flatMap(\.connectorNames), kind: "connector", issues: &issues
        )
        rejectMultiSkillOwnership(
            document.skills.flatMap(\.localToolNames), kind: "local tool", issues: &issues
        )

        // Every by-name reference must resolve within the package. A skill that
        // names a connector/tool the package omits (e.g. the exporter filtered an
        // unsafe attached resource but the projection fell back to the saved name
        // list) would silently lose that behavior on import with no warning.
        let connectorNames = Set(document.connectors.map(\.name))
        let toolNames = Set(document.localTools.map(\.name))
        let skillNames = Set(document.skills.map(\.name))
        for skill in document.skills {
            for name in skill.connectorNames where !connectorNames.contains(name) {
                issues.append(blocker(
                    "/workspace-share.json/skills",
                    "Skill '\(skill.name)' references connector '\(name)' that is not present in the package."
                ))
            }
            for name in skill.localToolNames where !toolNames.contains(name) {
                issues.append(blocker(
                    "/workspace-share.json/skills",
                    "Skill '\(skill.name)' references local tool '\(name)' that is not present in the package."
                ))
            }
        }
        for template in document.templates {
            for name in template.defaultSkillNames where !skillNames.contains(name) {
                issues.append(blocker(
                    "/workspace-share.json/templates",
                    "Template '\(template.name)' references skill '\(name)' that is not present in the package."
                ))
            }
        }
        for schedule in document.schedules {
            for name in schedule.skillNames where !skillNames.contains(name) {
                issues.append(blocker(
                    "/workspace-share.json/schedules",
                    "Routine '\(schedule.name)' references skill '\(name)' that is not present in the package."
                ))
            }
        }
    }

    private func rejectMultiSkillOwnership(
        _ referencedNames: [String],
        kind: String,
        issues: inout [PortablePackageValidationIssue]
    ) {
        var counts: [String: Int] = [:]
        for name in referencedNames { counts[name, default: 0] += 1 }
        for name in counts.filter({ $0.value > 1 }).keys.sorted() {
            issues.append(blocker(
                "/workspace-share.json/skills",
                "\(kind.capitalized) '\(name)' is assigned to more than one skill; a shared resource can belong to only one skill."
            ))
        }
    }

    private func rejectDuplicateNames(
        _ names: [String],
        kind: String,
        issues: inout [PortablePackageValidationIssue]
    ) {
        var seen = Set<String>()
        var reported = Set<String>()
        for name in names where !seen.insert(name).inserted && reported.insert(name).inserted {
            issues.append(blocker(
                "/workspace-share.json/\(kind)",
                "Duplicate \(kind) name '\(name)' — resource names must be unique because links resolve by name."
            ))
        }
    }

    private func appendForbiddenContentIssues(
        in text: String,
        path: String,
        reported: inout Set<String>,
        issues: inout [PortablePackageValidationIssue]
    ) {
        if containsCredentialAssignment(text), reported.insert("\(path)#credential").inserted {
            issues.append(blocker(path, "Package content appears to include credential material."))
        }
        if containsAbsoluteMachinePath(text), reported.insert("\(path)#path").inserted {
            issues.append(blocker(path, "Package content appears to include an absolute local path."))
        }
    }

    /// True only when `text` looks like an actual credential ASSIGNMENT — a
    /// credential key name immediately followed by a `:`/`=` delimiter and a
    /// non-trivial value. The old check flagged any occurrence of "oauth",
    /// "password", "secret", "token", etc. anywhere in free text, so ordinary
    /// prose ("OAuth flow", "token budget", "password reset", "never reveal
    /// secrets") failed export self-verification even with no credential present.
    private func containsCredentialAssignment(_ text: String) -> Bool {
        // optional prefix segments (e.g. API_, GITHUB_) + credential key +
        // [: or =] + value(6+ non-space). Case-insensitive. The prefix group lets
        // `API_TOKEN=…` match (the `_` is a word char, so a bare `\btoken` never
        // starts inside `API_TOKEN`), without restoring prose false positives —
        // the required `[:=]` + value keeps "token budget"/"OAuth flow" out.
        let pattern = #"(?i)\b(?:[a-z0-9]+[_-])*(api[_-]?key|apikey|oauth[_-]?token|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret|bearer|token)\b\s*[:=]\s*\S{6,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// True when `text` embeds an absolute macOS/Unix path. The old check only
    /// recognized the running user's `NSHomeDirectory()` and `/Users/`, so a
    /// sender path like `/Volumes/External/...` or `/opt/custom/bin` slipped
    /// through the free-text scan; this matches the common absolute roots at a
    /// component boundary.
    private func containsAbsoluteMachinePath(_ text: String) -> Bool {
        if text.contains(NSHomeDirectory()) { return true }
        let lowered = text.lowercased()
        let roots = ["/users/", "/home/", "/volumes/", "/opt/", "/usr/", "/private/", "/var/", "/applications/", "/library/", "/system/"]
        // A path-segment character before the root would make it a relative
        // fragment (e.g. "abc/opt/x"); require the root to begin the string or
        // follow a non-path delimiter so only genuine absolute paths match.
        let pathSegmentChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        for root in roots {
            var searchStart = lowered.startIndex
            while let range = lowered.range(of: root, range: searchStart..<lowered.endIndex) {
                if range.lowerBound == lowered.startIndex
                    || !pathSegmentChars.contains(lowered[lowered.index(before: range.lowerBound)]) {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
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
