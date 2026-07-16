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

        validateNoForbiddenContent(checksums: declaredChecksums, packageURL: packageURL, issues: &issues)

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
        let bundleURL = packageURL.appendingPathComponent(entry.relativeBundlePath)
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let capability = try? decoder.decode(PluginPackage.self, from: data) else {
            issues.append(blocker("/\(entry.relativePath)", "Embedded capability package could not be decoded."))
            return
        }
        // Package JSON is not a trust boundary (see CapabilityGovernanceNormalizer):
        // an exporter that skipped the local-draft clamp, or a package hand-edited
        // after export, must not be trusted just because it decodes cleanly.
        if capability.governance.approvalStatus != .draft {
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
        guard let required = SemanticVersion(string: minimumASTRAVersion) else { return }
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
    private func validateNoForbiddenContent(
        checksums: [WorkspacePackageChecksum]?,
        packageURL: URL,
        issues: inout [PortablePackageValidationIssue]
    ) {
        let scannedPaths = (
            checksums?.map(\.path) ??
                PortablePackageSafeFileReader.portableFilePaths(in: packageURL, intent: .explicitUserSelection)
        )
        .filter { $0.hasSuffix(".json") || $0.hasSuffix(".md") }
        var reported = Set<String>()
        for path in scannedPaths {
            guard let data = try? PortablePackageSafeFileReader.readData(rootURL: packageURL, relativePath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            appendForbiddenContentIssues(in: text, path: "/\(path)", reported: &reported, issues: &issues)
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
