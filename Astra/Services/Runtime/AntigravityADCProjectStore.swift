import Foundation
import ASTRAModels

/// ASTRA's record of the Google Cloud project the Antigravity ADC route bills.
///
/// gcloud also keeps a quota project inside its ADC file, but every bare
/// `gcloud auth application-default login` rewrites that file, and it drops
/// the quota project whenever the account cannot use the gcloud config's
/// default project. On 2026-10-14 two such logins, run from a terminal, left
/// Antigravity with no quota project, and the Settings field (which was only
/// ever seeded from the file) came back empty after a restart.
///
/// So ASTRA owns the value for its own launches. It is saved only after gcloud
/// accepted it (`set-quota-project` succeeded), and every `agy` launch and
/// probe on the ADC route receives it as `GOOGLE_CLOUD_QUOTA_PROJECT`, which
/// takes precedence over the file's `quota_project_id`.
enum AntigravityADCProjectStore {
    static func load(defaults: UserDefaults = .standard) -> String {
        sanitized(defaults.string(forKey: AppStorageKeys.antigravityADCProject) ?? "")
    }

    /// Stores nothing and returns false for a value that cannot be a project
    /// ID. A change bumps the provider-settings revision so composers and the
    /// readiness cache re-key on the new billing project.
    @discardableResult
    static func save(_ project: String, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GCPProjectIDValidation.failure(for: trimmed) == nil else { return false }
        guard load(defaults: defaults) != trimmed else { return true }
        defaults.set(trimmed, forKey: AppStorageKeys.antigravityADCProject)
        RuntimeProviderSettingsStore.bumpRevision(defaults: defaults)
        return true
    }

    /// Trimmed, or empty when the value is not a well-formed project ID, so a
    /// corrupted entry never reaches `agy` as a billing header.
    static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return GCPProjectIDValidation.failure(for: trimmed) == nil ? trimmed : ""
    }
}
