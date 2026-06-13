import Foundation

struct CrashReportSummary: Equatable, Identifiable {
    let url: URL
    let appName: String
    let modifiedAt: Date
    let sizeBytes: Int64

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var displayPath: String { CrashDiagnosticsService.userFacingPath(url) }
}

enum CrashDiagnosticsService {
    static let defaultRecentLimit = 8
    static let defaultRecentDays = 30
    static let supportedExtensions: Set<String> = ["ips", "crash"]

    static var defaultDiagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    static func defaultSearchDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CrashReporter", isDirectory: true)
        ]
    }

    static func reportNamePrefixes(for channel: AppChannel = .current) -> [String] {
        var prefixes: [String] = [channel.displayName]
        for candidate in ["ASTRA Dev", "ASTRA Beta", "ASTRA"] where !prefixes.contains(candidate) {
            prefixes.append(candidate)
        }
        return prefixes
    }

    static func recentReports(
        limit: Int = defaultRecentLimit,
        withinDays: Int? = defaultRecentDays,
        prefixes: [String] = reportNamePrefixes(),
        searchDirectories: [URL] = defaultSearchDirectories(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [CrashReportSummary] {
        let interval = withinDays.map {
            DateInterval(
                start: now.addingTimeInterval(-TimeInterval(max(0, $0)) * 24 * 60 * 60),
                end: now
            )
        }
        return reports(
            limit: limit,
            modifiedIn: interval,
            prefixes: prefixes,
            searchDirectories: searchDirectories,
            fileManager: fileManager
        )
    }

    static func reports(
        limit: Int = defaultRecentLimit,
        modifiedIn interval: DateInterval?,
        prefixes: [String] = reportNamePrefixes(),
        searchDirectories: [URL] = defaultSearchDirectories(),
        fileManager: FileManager = .default
    ) -> [CrashReportSummary] {
        let normalizedPrefixes = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPrefixes.isEmpty, limit > 0 else { return [] }

        let reports = searchDirectories.flatMap { directory -> [CrashReportSummary] in
            let broker = HostFileAccessBroker(fileManager: fileManager)
            guard let files = try? broker.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                intent: .astraManagedStorage(root: directory)
            ) else { return [] }

            return files.compactMap { file in
                guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
                let fileName = file.lastPathComponent
                guard let appName = matchingAppName(for: fileName, prefixes: normalizedPrefixes) else {
                    return nil
                }

                guard let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ]),
                      values.isRegularFile == true
                else { return nil }

                let modifiedAt = values.contentModificationDate ?? Date.distantPast
                if let interval, (modifiedAt < interval.start || modifiedAt > interval.end) {
                    return nil
                }

                return CrashReportSummary(
                    url: file,
                    appName: appName,
                    modifiedAt: modifiedAt,
                    sizeBytes: Int64(values.fileSize ?? 0)
                )
            }
        }

        return Array(reports
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.fileName < rhs.fileName
            }
            .prefix(limit))
    }

    static func userFacingPath(_ url: URL, fileManager: FileManager = .default) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home {
            return "$HOME"
        }
        if path.hasPrefix(home + "/") {
            return "$HOME/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private static func matchingAppName(for fileName: String, prefixes: [String]) -> String? {
        prefixes.first { prefix in
            fileName.hasPrefix("\(prefix)-")
        }
    }
}
