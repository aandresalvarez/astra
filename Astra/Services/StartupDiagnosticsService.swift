import Foundation

enum StartupDiagnosticsService {
    static func record(
        stage: String,
        isUITesting: Bool,
        skipWorkspaceRecovery: Bool,
        persistentStoreURL: URL?,
        modelContainerResult: String? = nil,
        level: LogLevel = .info
    ) {
        AppLogger.audit(
            .startupDiagnostics,
            category: "App",
            fields: snapshotFields(
                stage: stage,
                isUITesting: isUITesting,
                skipWorkspaceRecovery: skipWorkspaceRecovery,
                persistentStoreURL: persistentStoreURL,
                modelContainerResult: modelContainerResult
            ),
            level: level,
            fieldMaxLength: 240
        )
    }

    static func snapshotFields(
        stage: String,
        isUITesting: Bool,
        skipWorkspaceRecovery: Bool,
        persistentStoreURL: URL?,
        modelContainerResult: String? = nil,
        fileManager: FileManager = .default,
        crashReports: [CrashReportSummary] = CrashDiagnosticsService.recentReports(limit: 3)
    ) -> [String: String] {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        let appSupportDirectory = WorkspaceRecoveryService.applicationSupportDirectory
        let workspaceRoot = URL(fileURLWithPath: AppChannel.current.defaultWorkspacesRoot, isDirectory: true)
        let logDirectory = AppLogger.mainLogFile.deletingLastPathComponent()
        let latestCrash = crashReports.first

        var fields: [String: String] = [
            "stage": stage,
            "app": AppBuildInfo.current.displayName,
            "version": AppBuildInfo.current.version,
            "build": AppBuildInfo.current.build,
            "channel": AppChannel.current.rawValue,
            "channel_name": AppChannel.current.displayName,
            "bundle_id": bundle.bundleIdentifier ?? "unknown",
            "executable": bundle.executableURL?.lastPathComponent ?? process.processName,
            "process": process.processName,
            "pid": String(process.processIdentifier),
            "arch": architectureName,
            "os": process.operatingSystemVersionString,
            "ui_testing": String(isUITesting),
            "skip_workspace_recovery": String(skipWorkspaceRecovery),
            "logging_subsystem": AppChannel.current.loggingSubsystem,
            "app_support_dir": CrashDiagnosticsService.userFacingPath(appSupportDirectory, fileManager: fileManager),
            "app_support_exists": String(fileManager.fileExists(atPath: appSupportDirectory.path)),
            "workspace_root": CrashDiagnosticsService.userFacingPath(workspaceRoot, fileManager: fileManager),
            "workspace_root_exists": startupSafeExists(at: workspaceRoot, fileManager: fileManager),
            "log_dir": CrashDiagnosticsService.userFacingPath(logDirectory, fileManager: fileManager),
            "log_dir_exists": String(fileManager.fileExists(atPath: logDirectory.path)),
            "main_log_exists": String(fileManager.fileExists(atPath: AppLogger.mainLogFile.path)),
            "crash_report_dir": CrashDiagnosticsService.userFacingPath(CrashDiagnosticsService.defaultDiagnosticReportsDirectory, fileManager: fileManager),
            "recent_crash_reports": String(crashReports.count),
            "latest_crash_report": latestCrash?.fileName ?? "none",
            "latest_crash_report_path": latestCrash?.displayPath ?? "none"
        ]

        if let modelContainerResult {
            fields["model_container"] = modelContainerResult
        }

        if let persistentStoreURL {
            fields["store_mode"] = "persistent"
            fields["store_url"] = CrashDiagnosticsService.userFacingPath(persistentStoreURL, fileManager: fileManager)
            fields["store_file"] = persistentStoreURL.lastPathComponent
            fields["store_exists"] = String(fileManager.fileExists(atPath: persistentStoreURL.path))
            if let size = fileSize(at: persistentStoreURL, fileManager: fileManager) {
                fields["store_size_bytes"] = String(size)
            }
        } else {
            fields["store_mode"] = "memory"
            fields["store_file"] = "none"
            fields["store_exists"] = "false"
        }

        if let latestCrash {
            fields["latest_crash_report_at"] = iso8601.string(from: latestCrash.modifiedAt)
            fields["latest_crash_report_bytes"] = String(latestCrash.sizeBytes)
        }

        return fields
    }

    private static func startupSafeExists(at url: URL, fileManager: FileManager) -> String {
        if isProtectedUserContentPath(url) {
            return "not_checked_protected_location"
        }
        return String(fileManager.fileExists(atPath: url.path))
    }

    private static func isProtectedUserContentPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let protectedRoots = ["Desktop", "Documents", "Downloads"].map {
            home.appendingPathComponent($0, isDirectory: true).path
        }
        return protectedRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}
