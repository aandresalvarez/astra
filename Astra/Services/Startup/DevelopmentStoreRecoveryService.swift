import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Creates a new validated store generation target without modifying or
/// deleting the active store. The capability is intentionally unavailable to
/// production and beta channels: frequent schema churn is a development-only
/// concern, while production recovery remains fail-closed.
@MainActor
enum DevelopmentStoreRecoveryService {
    enum RecoveryError: LocalizedError, Equatable {
        case unavailableOutsideDevelopment
        case integrityValidationFailed

        var errorDescription: String? {
            switch self {
            case .unavailableOutsideDevelopment:
                "Fresh-store recovery is available only in ASTRA Dev."
            case .integrityValidationFailed:
                "The new development store failed SQLite integrity validation."
            }
        }
    }

    @discardableResult
    static func createAndActivateFreshStore(
        buildChannel: String = AppBuildInfo.current.channelRawValue,
        effectiveChannel: AppChannel = .current,
        makeRecoveryURL: () throws -> URL = WorkspaceRecoveryService.makeRecoveryStoreURL,
        createContainer: (URL) throws -> Void = { url in
            _ = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: url)]
            )
        },
        validateIntegrity: (URL) -> Bool = WorkspaceRecoveryService.sqliteIntegrityIsValid,
        activateStore: (URL) throws -> Void = { url in
            try WorkspaceRecoveryService.activateRecoveryStore(
                at: url,
                compatibility: AstraStoreStartupCoordinator.compatibilityMetadata(appInfo: .current)
            )
        }
    ) throws -> URL {
        guard buildChannel == "dev", effectiveChannel == .development else {
            throw RecoveryError.unavailableOutsideDevelopment
        }

        let recoveryURL = try makeRecoveryURL()
        try createContainer(recoveryURL)
        guard validateIntegrity(recoveryURL) else {
            throw RecoveryError.integrityValidationFailed
        }
        try activateStore(recoveryURL)
        AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
            "result": "fresh_development_store_activated",
            "store_generation": WorkspaceRecoveryService.storeGeneration
        ], level: .warning)
        return recoveryURL
    }
}
