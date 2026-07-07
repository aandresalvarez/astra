import Foundation
import os

// Added as part of Track A2.4 (finishing A2's Models cycle-break) so
// `Astra/Models/Skill.swift` can persist secret environment values without
// depending on `Astra/Services/Capabilities/ModelSecretPersistence.swift`
// (Keychain-backed, via `KeychainService`/`AstraSecureKeychainStore`).
//
// Unlike the original `SkillSecretPersistence` API (which took `Skill`
// directly), every method here is primitive-only (`UUID`/`String`), since
// `ASTRACore` can never import Models. The "is this environment key a
// secret" decision (`Skill.isSecretEnvironmentKey`) and all `Skill`
// property/index access stay in `Skill.swift` itself; this seam is pure
// Keychain I/O plumbing. Audit logging for save/delete moved to
// `Skill.swift` too, reusing the `AuditLoggingSeam` seam added in
// Track A2.3 rather than adding a second logging pathway.
//
// Follows the exact registration pattern in `RuntimeSeams.swift`.
public enum SkillSecretSeam {
    private static let storage = OSAllocatedUnfairLock<(any SkillSecretPersisting.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ persistence: any SkillSecretPersisting.Type) {
        storage.withLock { $0 = persistence }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet. Safe to
    /// gate behind a trap (unlike `TaskExecutionDefaults.model` in Track
    /// A2.2): every method here runs from an explicit skill-mutation action
    /// (saving/removing an environment entry, migrating on init, deleting a
    /// skill), never a passive default-parameter construction path.
    public static var required: any SkillSecretPersisting.Type {
        guard let persistence = storage.withLock({ $0 }) else {
            preconditionFailure(
                "SkillSecretSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return persistence
    }
}

public protocol SkillSecretPersisting: Sendable {
    /// Matches `SecretStore.load(key:entityID:)`'s optional-return
    /// semantics; the caller falls back to the stored placeholder value.
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String?
    @discardableResult
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String) -> Bool
    @discardableResult
    static func deleteSecret(key: String, skillID: UUID) -> Bool
    static func secretExists(key: String, skillID: UUID) -> Bool
    static func deleteAllSecrets(skillID: UUID)
}
