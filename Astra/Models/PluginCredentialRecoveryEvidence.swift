import Foundation

/// Value-free evidence that recovery could not fully represent in activation
/// settings or account bindings. Only the explicit activation owner writes it;
/// ordinary migration/reconciliation never silently clears it.
public struct PluginCredentialRecoveryEvidence: Codable, Equatable, Sendable {
    public struct Account: Codable, Hashable, Sendable {
        public var componentID: String
        public var connectorID: String

        public init(componentID: String, connectorID: String) {
            self.componentID = componentID
            self.connectorID = connectorID
        }
    }

    public var secretSettingKeysUnknown: Bool
    public var unresolvedSettingKeys: [String]
    public var unresolvedAccounts: [Account]
    /// The source mirror failed the shared proof rules. A runtime graph
    /// that drops the contradictory fields cannot upgrade that verdict.
    public var inventoryAmbiguous: Bool?
    /// Positive references the source reader held, independently of the
    /// definition history migration may seed. These contain no values.
    public var retainedComponentIDs: [String]?
    public var retainedSecretSettingKeys: [String]?
    /// Credential identity when the source proof was captured. Missing in an
    /// older evidence record is unknown and remains conservative. A published
    /// replacement must not inherit proof belonging to a retired generation.
    public var namespaceSeed: String?
    public var credentialNamespaceSeed: String?
    /// Recorded only by publication of a prepared, fresh private generation.
    /// Component history and an older model's empty array cannot certify it.
    public var secretSettingKeysKnown: Bool?
    /// One prior-own-mirror admission per activation and credential identity.
    public var admittedActivationID: String?
    public var hasUnresolvedReferences: Bool { !unresolvedSettingKeys.isEmpty || !unresolvedAccounts.isEmpty }
    public var isAmbiguous: Bool { inventoryAmbiguous == true || hasUnresolvedReferences }
    public var isEmpty: Bool {
        !secretSettingKeysUnknown && !isAmbiguous && secretSettingKeysKnown != true && admittedActivationID == nil
            && (retainedComponentIDs ?? []).isEmpty && (retainedSecretSettingKeys ?? []).isEmpty
    }

    public init(secretSettingKeysUnknown: Bool = false, unresolvedSettingKeys: [String] = [], unresolvedAccounts: [Account] = [],
        inventoryAmbiguous: Bool? = nil, retainedComponentIDs: [String]? = nil, retainedSecretSettingKeys: [String]? = nil,
        namespaceSeed: String? = nil, credentialNamespaceSeed: String? = nil,
        secretSettingKeysKnown: Bool? = nil, admittedActivationID: String? = nil) {
        self.secretSettingKeysUnknown = secretSettingKeysUnknown
        self.unresolvedSettingKeys = unresolvedSettingKeys
        self.unresolvedAccounts = unresolvedAccounts
        self.inventoryAmbiguous = inventoryAmbiguous
        self.retainedComponentIDs = retainedComponentIDs
        self.retainedSecretSettingKeys = retainedSecretSettingKeys
        self.namespaceSeed = namespaceSeed
        self.credentialNamespaceSeed = credentialNamespaceSeed
        self.secretSettingKeysKnown = secretSettingKeysKnown
        self.admittedActivationID = admittedActivationID
    }

    public var hasCompleteMarkerList: Bool {
        secretSettingKeysKnown == true && !secretSettingKeysUnknown
            && credentialNamespaceSeed.flatMap(UUID.init(uuidString:)) != nil
    }

    public func hasAdmittedMirror(for activation: PluginActivation) -> Bool {
        guard admittedActivationID.flatMap(UUID.init(uuidString:)) == activation.id,
              let generation = credentialNamespaceSeed, generation == activation.credentialNamespaceSeed else { return false }
        return !generation.isEmpty || namespaceSeed == activation.namespaceSeed
    }

    public func appliesTo(namespaceSeed: String, credentialNamespaceSeed: String) -> Bool {
        // These references have no proved namespace owner. Replacing a skill
        // generation cannot retire a missing account or an unparseable key.
        if hasUnresolvedReferences { return true }
        guard let recordedGeneration = self.credentialNamespaceSeed else { return true }
        guard recordedGeneration == credentialNamespaceSeed else { return false }
        // Private generations are independent of runtime/template IDs; only
        // the legacy empty generation derives credentials from the runtime seed.
        return !recordedGeneration.isEmpty || self.namespaceSeed == nil || self.namespaceSeed == namespaceSeed
    }

    public func merging(_ other: Self?) -> Self {
        guard let other else { return self }
        if let generation = credentialNamespaceSeed, let otherGeneration = other.credentialNamespaceSeed,
           generation != otherGeneration || (generation.isEmpty && namespaceSeed != other.namespaceSeed) {
            var current = self
            // An unassigned reference cannot be retired by a skill generation
            // change. Generation-bound key and inventory proof can be.
            current.unresolvedSettingKeys = Set(unresolvedSettingKeys + other.unresolvedSettingKeys).sorted()
            current.unresolvedAccounts = Set(unresolvedAccounts + other.unresolvedAccounts).sorted {
                $0.componentID == $1.componentID ? $0.connectorID < $1.connectorID : $0.componentID < $1.componentID
            }
            return current
        }
        let scope = credentialNamespaceSeed == nil ? other : self
        return Self(secretSettingKeysUnknown: secretSettingKeysUnknown || other.secretSettingKeysUnknown,
            unresolvedSettingKeys: Set(unresolvedSettingKeys + other.unresolvedSettingKeys).sorted(),
            unresolvedAccounts: Set(unresolvedAccounts + other.unresolvedAccounts).sorted {
                $0.componentID == $1.componentID ? $0.connectorID < $1.connectorID : $0.componentID < $1.componentID
            }, inventoryAmbiguous: inventoryAmbiguous == true || other.inventoryAmbiguous == true ? true : nil,
            retainedComponentIDs: Set((retainedComponentIDs ?? []) + (other.retainedComponentIDs ?? [])).sorted(),
            retainedSecretSettingKeys: Set((retainedSecretSettingKeys ?? []) + (other.retainedSecretSettingKeys ?? [])).sorted(),
            namespaceSeed: scope.namespaceSeed, credentialNamespaceSeed: scope.credentialNamespaceSeed,
            secretSettingKeysKnown: secretSettingKeysKnown ?? other.secretSettingKeysKnown,
            admittedActivationID: admittedActivationID ?? other.admittedActivationID)
    }
}
