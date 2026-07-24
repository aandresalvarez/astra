import ASTRACore
import Foundation
import SQLite3

enum RunLedgerSchema {
    static let version = 2
    static let legacyVersion = 1
    static let applicationID: Int32 = 0x4153_5452 // "ASTR"
    static let legacyFingerprint = "astra.run-ledger.sqlite.v1.2026-07-16"
    static let fingerprint = "astra.run-ledger.sqlite.v2.2026-07-17-typed-outbox"

    static func open(
        configuration: RunLedgerConfiguration,
        createIfMissing: Bool,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?,
        migrationCrashPoint: RunLedgerMigrationCrashPoint? = nil
    ) throws -> (RunLedgerSQLiteConnection, RunLedgerIdentity) {
        try RunLedgerStorageSecurity.withInitializationLock(
            at: configuration.databaseURL,
            createIfMissing: createIfMissing
        ) {
            try openWhileInitializationLocked(
                configuration: configuration,
                createIfMissing: createIfMissing,
                initializationCrashPoint: initializationCrashPoint,
                migrationCrashPoint: migrationCrashPoint
            )
        }
    }

    private static func openWhileInitializationLocked(
        configuration: RunLedgerConfiguration,
        createIfMissing: Bool,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?,
        migrationCrashPoint: RunLedgerMigrationCrashPoint?
    ) throws -> (RunLedgerSQLiteConnection, RunLedgerIdentity) {
        let preparation = try RunLedgerStorageSecurity.prepareStorage(
            at: configuration.databaseURL,
            installationID: configuration.installationID,
            createIfMissing: createIfMissing,
            initializationCrashPoint: initializationCrashPoint
        )
        if preparation == .newlyCreated {
            _ = RunLedgerInitializationCrash.trigger(
                .afterMainFileCreated,
                requested: initializationCrashPoint
            )
        }
        let flags = SQLITE_OPEN_READWRITE
            | (createIfMissing ? SQLITE_OPEN_CREATE : 0)
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
            | SQLITE_OPEN_EXRESCODE
        let connection = try RunLedgerSQLiteConnection(
            path: configuration.databaseURL.path,
            flags: flags,
            busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
        )
        do {
            let identity = try connection.withLock { database in
                try configureConnection(connection, database: database)
                switch preparation {
                case .newlyCreated, .recoverableIncomplete:
                    guard createIfMissing else { throw RunLedgerError.missingLedger }
                    return try initialize(
                        connection,
                        database: database,
                        installationID: configuration.installationID,
                        initializationCrashPoint: initializationCrashPoint
                    )
                case .existing(let hasInitializationMarker):
                    if hasInitializationMarker,
                       try isStrictlyPristine(connection, database: database) {
                        guard createIfMissing else {
                            throw RunLedgerError.corrupt(
                                "Ledger initialization was interrupted before schema commit"
                            )
                        }
                        return try initialize(
                            connection,
                            database: database,
                            installationID: configuration.installationID,
                            initializationCrashPoint: initializationCrashPoint
                        )
                    }
                    return try validateExisting(
                        connection,
                        database: database,
                        configuration: configuration,
                        migrateIfNeeded: createIfMissing,
                        migrationCrashPoint: migrationCrashPoint
                    )
                }
            }
            try RunLedgerStorageSecurity.secureArtifacts(at: configuration.databaseURL)
            if createIfMissing {
                try RunLedgerStorageSecurity.completeInitialization(at: configuration.databaseURL)
            }
            return (connection, identity)
        } catch {
            try? connection.close()
            throw classify(error)
        }
    }

    static func classify(_ error: Error) -> RunLedgerError {
        guard let ledgerError = error as? RunLedgerError else {
            return .corrupt(String(describing: error))
        }
        if case .sqlite(_, let code, let message) = ledgerError {
            switch code & 0xFF {
            case SQLITE_CORRUPT, SQLITE_NOTADB:
                return .corrupt(message)
            default:
                return ledgerError
            }
        }
        return ledgerError
    }

    private static func configureConnection(
        _ connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        try connection.execute("PRAGMA foreign_keys = ON", database: database)
        try connection.execute("PRAGMA trusted_schema = OFF", database: database)
        try connection.execute("PRAGMA synchronous = FULL", database: database)
        guard try connection.scalarInt64("PRAGMA foreign_keys", database: database) == 1 else {
            throw RunLedgerError.corrupt("SQLite foreign-key enforcement could not be enabled")
        }
    }

    private static func initialize(
        _ connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        installationID: RunBrokerInstallationID,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?
    ) throws -> RunLedgerIdentity {
        let journalMode = try connection.scalarText(
            "PRAGMA journal_mode = WAL",
            database: database
        )?.lowercased()
        guard journalMode == "wal" else {
            throw RunLedgerError.corrupt("SQLite refused WAL journal mode")
        }
        try connection.execute("PRAGMA wal_autocheckpoint = 1000", database: database)

        let nowMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let identity = RunLedgerIdentity(
            storeID: .init(),
            installationID: installationID,
            schemaVersion: version,
            createdAt: Date(timeIntervalSince1970: Double(nowMilliseconds) / 1_000)
        )
        try connection.withImmediateTransaction(database: database) {
            try connection.execute("PRAGMA application_id = \(applicationID)", database: database)
            try connection.execute("PRAGMA user_version = \(version)", database: database)
            try connection.execute(RunLedgerSchemaSQL.v2, database: database)

            let statement = try connection.statement(
                """
                INSERT INTO ledger_metadata (
                    singleton_id, schema_version, schema_fingerprint,
                    store_id, installation_id, created_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .integer(Int64(version)),
                    .text(fingerprint),
                    .text(uuid(identity.storeID.rawValue)),
                    .text(uuid(identity.installationID.rawValue)),
                    .real(identity.createdAt.timeIntervalSince1970),
                ],
                database: database
            )
            defer { statement.finalize() }
            guard try statement.step() == .done else {
                throw RunLedgerError.corrupt("Metadata insert returned a row")
            }
            try connection.execute(
                "INSERT INTO outbox_state (singleton_id, last_acknowledged_sequence) VALUES (1, 0)",
                database: database
            )
            _ = RunLedgerInitializationCrash.trigger(
                .beforeSchemaCommit,
                requested: initializationCrashPoint
            )
        }
        _ = RunLedgerInitializationCrash.trigger(
            .afterSchemaCommitBeforeMarkerRemoval,
            requested: initializationCrashPoint
        )
        return identity
    }

    private static func isStrictlyPristine(
        _ connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> Bool {
        guard try connection.scalarText("PRAGMA quick_check", database: database) == "ok",
              try connection.scalarInt64("PRAGMA application_id", database: database) == 0,
              try connection.scalarInt64("PRAGMA user_version", database: database) == 0 else {
            return false
        }
        let userObjectCount = try connection.scalarInt64(
            """
            SELECT COUNT(*) FROM sqlite_schema
            WHERE name NOT LIKE 'sqlite_%'
            """,
            database: database
        )
        return userObjectCount == 0
    }

    private static func validateExisting(
        _ connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        configuration: RunLedgerConfiguration,
        migrateIfNeeded: Bool,
        migrationCrashPoint: RunLedgerMigrationCrashPoint?
    ) throws -> RunLedgerIdentity {
        guard try connection.scalarText("PRAGMA quick_check", database: database) == "ok" else {
            throw RunLedgerError.corrupt("SQLite quick_check failed")
        }
        let foundApplicationID = Int32(
            try connection.scalarInt64("PRAGMA application_id", database: database) ?? -1
        )
        guard foundApplicationID == applicationID else {
            throw RunLedgerError.applicationIdentityMismatch(
                expected: applicationID,
                found: foundApplicationID
            )
        }
        let foundVersion = Int(try connection.scalarInt64("PRAGMA user_version", database: database) ?? -1)
        guard try connection.scalarText("PRAGMA journal_mode", database: database)?.lowercased() == "wal" else {
            throw RunLedgerError.corrupt("Existing ledger is not in WAL mode")
        }

        let metadata = try { () throws -> (
            version: Int,
            fingerprint: String,
            storeID: RunBrokerStoreID,
            installationID: RunBrokerInstallationID,
            createdAt: Date
        ) in
            let statement = try connection.statement(
                """
                SELECT schema_version, schema_fingerprint, store_id, installation_id, created_at
                FROM ledger_metadata WHERE singleton_id = 1
                """,
                database: database
            )
            defer { statement.finalize() }
            guard try statement.step() == .row else {
                throw RunLedgerError.corrupt("Ledger metadata row is missing")
            }
            let value = (
                version: Int(statement.int64(at: 0)),
                fingerprint: try statement.text(at: 1),
                storeID: try RunBrokerStoreID(rawValue: parsedUUID(try statement.text(at: 2))),
                installationID: try RunBrokerInstallationID(
                    rawValue: parsedUUID(try statement.text(at: 3))
                ),
                createdAt: Date(timeIntervalSince1970: statement.double(at: 4))
            )
            guard try statement.step() == .done else {
                throw RunLedgerError.corrupt("Ledger metadata contains duplicate singleton rows")
            }
            return value
        }()
        let metadataVersion = metadata.version
        let expectedFingerprint: String
        switch foundVersion {
        case legacyVersion:
            expectedFingerprint = legacyFingerprint
        case version:
            expectedFingerprint = fingerprint
        default:
            throw RunLedgerError.incompatibleSchema(expected: version, found: foundVersion)
        }
        guard metadataVersion == foundVersion else {
            throw RunLedgerError.incompatibleSchema(expected: version, found: metadataVersion)
        }
        guard metadata.fingerprint == expectedFingerprint else {
            throw RunLedgerError.incompatibleSchema(expected: version, found: metadataVersion)
        }
        let identity = RunLedgerIdentity(
            storeID: metadata.storeID,
            installationID: metadata.installationID,
            schemaVersion: metadataVersion,
            createdAt: metadata.createdAt
        )
        if let expectedStoreID = configuration.expectedStoreID,
           expectedStoreID != identity.storeID {
            throw RunLedgerError.storeIdentityMismatch(
                expected: expectedStoreID,
                found: identity.storeID
            )
        }
        guard configuration.installationID == identity.installationID else {
            throw RunLedgerError.installationIdentityMismatch(
                expected: configuration.installationID,
                found: identity.installationID
            )
        }
        if foundVersion == legacyVersion {
            guard migrateIfNeeded else {
                throw RunLedgerError.incompatibleSchema(expected: version, found: foundVersion)
            }
            try RunLedgerV1ToV2Migration.migrate(
                connection: connection,
                database: database,
                identity: identity,
                crashPoint: migrationCrashPoint
            )
            return try validateExisting(
                connection,
                database: database,
                configuration: configuration,
                migrateIfNeeded: false,
                migrationCrashPoint: nil
            )
        }
        return identity
    }

    private static func parsedUUID(_ value: String) throws -> UUID {
        guard let value = UUID(uuidString: value) else {
            throw RunLedgerError.corrupt("Ledger metadata contains an invalid UUID")
        }
        return value
    }

    static func uuid(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

}
