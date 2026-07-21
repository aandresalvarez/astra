import Foundation
import ASTRAPersistence

enum PersistentStoreRecoveryAction: Equatable, Sendable {
    case createFreshDevelopmentStore
    case openCompatibleBuild(bundlePath: String)
    case locateCompatibleBuild(requiredSchemaVersion: Int)
    case checkForUpdates
    case chooseStore
    case revealStore
    case quit
}

struct PersistentStoreRecoveryBlocker: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case incompatible(required: Int, supported: Int)
        case contention
        case leaseConflict
        case corruptionRecoveryFailed
        case unknown
    }

    let kind: Kind
    let title: String
    let message: String
    let technicalDetail: String
    let actions: [PersistentStoreRecoveryAction]

    init(
        kind: Kind = .unknown,
        title: String,
        message: String,
        technicalDetail: String = "",
        actions: [PersistentStoreRecoveryAction] = [.revealStore, .quit]
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.technicalDetail = technicalDetail
        self.actions = actions
    }
}

enum PersistentStoreRetryPolicy {
    static let contentionDelays: [TimeInterval] = [0.10, 0.25, 0.50]
}

enum PersistentStoreRecoveryPolicy {
    static func unknownOpenFailureBlocker(channel: String) -> PersistentStoreRecoveryBlocker {
        let isDevelopment = channel == "dev"
        return PersistentStoreRecoveryBlocker(
            title: "ASTRA could not safely open its store",
            message: isDevelopment
                ? "The failure was not proven recoverable. ASTRA left the current development store unchanged; you can start with a validated fresh development store while retaining this one for inspection."
                : "The failure was not proven to be recoverable, so ASTRA left the store unchanged.",
            actions: isDevelopment
                ? [.createFreshDevelopmentStore, .revealStore, .quit]
                : [.revealStore, .quit]
        )
    }

    static func requiredSchemaVersion(
        afterOpenFailure assessment: PersistentStoreCompatibilityAssessment,
        supportedSchemaVersion: Int
    ) -> Int {
        if case .requiresNewerReader(let requiredSchemaVersion) = assessment {
            return requiredSchemaVersion
        }
        return supportedSchemaVersion + 1
    }

    static func storeSelectionFailureMessage(
        assessment: PersistentStoreCompatibilityAssessment,
        supportedSchemaVersion: Int
    ) -> String? {
        switch assessment {
        case .compatible:
            return nil
        case .requiresNewerReader(let requiredSchemaVersion):
            return "The selected store requires schema V\(requiredSchemaVersion), but this build supports through V\(supportedSchemaVersion). Choose a newer compatible ASTRA build or a different store."
        case .unknown:
            return "ASTRA could not verify the selected store's schema compatibility, so it left the active store unchanged."
        }
    }

    static func storeSelectionChannelFailureMessage(
        metadata: PersistentStoreCompatibilityMetadata?,
        currentChannel: String
    ) -> String? {
        guard let storeChannel = metadata?.channel,
              storeChannel != currentChannel else { return nil }
        return "The selected store belongs to the \(storeChannel) channel and cannot be activated in the \(currentChannel) channel. Choose a store from this ASTRA channel."
    }

    static func incompatibleBlocker(
        requiredSchemaVersion: Int,
        supportedSchemaVersion: Int,
        channel: String,
        compatibleBundlePath: String?
    ) -> PersistentStoreRecoveryBlocker {
        var actions: [PersistentStoreRecoveryAction] = []
        if let compatibleBundlePath {
            actions.append(.openCompatibleBuild(bundlePath: compatibleBundlePath))
        } else if channel == "dev" {
            actions.append(.locateCompatibleBuild(requiredSchemaVersion: requiredSchemaVersion))
        } else if channel == "prod" || channel == "beta" {
            actions.append(.checkForUpdates)
        }
        actions.append(contentsOf: [.chooseStore, .revealStore, .quit])
        return PersistentStoreRecoveryBlocker(
            kind: .incompatible(required: requiredSchemaVersion, supported: supportedSchemaVersion),
            title: "This ASTRA build is older than the store",
            message: "The store requires schema V\(requiredSchemaVersion), but this build supports through V\(supportedSchemaVersion). ASTRA left the store unchanged.",
            technicalDetail: "required_schema=\(requiredSchemaVersion) supported_schema=\(supportedSchemaVersion)",
            actions: actions
        )
    }
}
