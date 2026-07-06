import Foundation
import os

// Added as part of Track A3 (extracting the ASTRAModels SwiftPM target).
// `Astra/Models/Connector.swift`/`Skill.swift` use `KeychainSecretStore()`
// (a thin, app-side wrapper around the real Keychain I/O in
// `AstraSecureKeychainStore`) as the *default* `SecretStore` for several
// methods. `KeychainSecretStore` itself can't move to `ASTRACore` (it's a
// concrete, I/O-performing implementation, the same reason `AppLogger`/
// `AgentRuntimeAdapterRegistry` stay app-side for their own seams), so this
// seam lets Models code reference "the default secret store" without
// depending on the app target.
//
// Unlike the other Track A2.x seams (which register a `Type` and call
// static members on it), `SecretStore` is an *instance* protocol -
// `KeychainSecretStore()` is constructed fresh per use - so this seam
// registers a factory closure instead of a metatype.
public enum SecretStoreSeam {
    private static let storage = OSAllocatedUnfairLock<(@Sendable () -> any SecretStore)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ factory: @escaping @Sendable () -> any SecretStore) {
        storage.withLock { $0 = factory }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet. Safe to
    /// gate behind a trap: every call site is a default parameter value on a
    /// method invoked from an explicit user/test action (credential load/
    /// save, connection test), never a passive top-level `static let`.
    public static var required: any SecretStore {
        guard let factory = storage.withLock({ $0 }) else {
            preconditionFailure(
                "SecretStoreSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return factory()
    }
}
