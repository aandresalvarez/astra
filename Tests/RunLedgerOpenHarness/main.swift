import ASTRACore
@_spi(RunLedgerTesting) import ASTRARunLedger
import Foundation

guard (4...5).contains(CommandLine.arguments.count),
      let installationUUID = UUID(uuidString: CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data(
        "usage: harness <ledger-dir> <installation-id> <output> [crash-point]\n".utf8
    ))
    exit(64)
}

do {
    let configuration = RunLedgerConfiguration(
        ledgerDirectoryURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
        installationID: .init(rawValue: installationUUID),
        busyTimeoutMilliseconds: 10_000
    )
    let initializationCrashPoint: RunLedgerInitializationCrashPoint?
    let migrationCrashPoint: RunLedgerMigrationCrashPoint?
    if CommandLine.arguments.count == 5 {
        let rawValue = CommandLine.arguments[4]
        initializationCrashPoint = RunLedgerInitializationCrashPoint(rawValue: rawValue)
        migrationCrashPoint = RunLedgerMigrationCrashPoint(rawValue: rawValue)
        guard initializationCrashPoint != nil || migrationCrashPoint != nil else {
            FileHandle.standardError.write(Data("unknown crash point\n".utf8))
            exit(64)
        }
    } else {
        initializationCrashPoint = nil
        migrationCrashPoint = nil
    }
    let ledger: RunLedger
    if let initializationCrashPoint {
        ledger = try RunLedger(
            configuration: configuration,
            crashingInitializationAt: initializationCrashPoint
        )
    } else if let migrationCrashPoint {
        ledger = try RunLedger(
            configuration: configuration,
            crashingMigrationAt: migrationCrashPoint
        )
    } else {
        ledger = try RunLedger(configuration: configuration)
    }
    let output = Data(ledger.identity.storeID.rawValue.uuidString.lowercased().utf8)
    try output.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    try ledger.close()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
