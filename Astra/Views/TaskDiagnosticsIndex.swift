import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

struct TaskDiagnosticFileItem: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case runs = "Runs"
        case jobLogs = "Job logs"
        case runtimeEnvironment = "Runtime environment"
        case permissionsAndCredentials = "Permissions and credentials"
        case rawTaskPackage = "Raw task package"

        var systemImage: String {
            switch self {
            case .runs: "arrow.triangle.2.circlepath"
            case .jobLogs: "terminal"
            case .runtimeEnvironment: "shippingbox"
            case .permissionsAndCredentials: "key"
            case .rawTaskPackage: "archivebox"
            }
        }
    }

    let path: String
    let relativePath: String
    let name: String
    let size: Int64
    let group: Group

    var id: String { path }
}

struct TaskDiagnosticFileGroup: Identifiable, Hashable {
    let group: TaskDiagnosticFileItem.Group
    let items: [TaskDiagnosticFileItem]

    var id: String { group.rawValue }
    var title: String { group.rawValue }
    var systemImage: String { group.systemImage }
}

enum TaskDiagnosticsIndex {
    static func groups(in taskFolder: String, fileManager: FileManager = .default) -> [TaskDiagnosticFileGroup] {
        items(in: taskFolder, fileManager: fileManager)
            .reduce(into: [TaskDiagnosticFileItem.Group: [TaskDiagnosticFileItem]]()) { grouped, item in
                grouped[item.group, default: []].append(item)
            }
            .compactMap { group, items in
                guard !items.isEmpty else { return nil }
                return TaskDiagnosticFileGroup(
                    group: group,
                    items: items.sorted {
                        $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                    }
                )
            }
            .sorted {
                let lhsIndex = TaskDiagnosticFileItem.Group.allCases.firstIndex(of: $0.group) ?? .max
                let rhsIndex = TaskDiagnosticFileItem.Group.allCases.firstIndex(of: $1.group) ?? .max
                return lhsIndex < rhsIndex
            }
    }

    static func items(in taskFolder: String, fileManager: FileManager = .default) -> [TaskDiagnosticFileItem] {
        guard !taskFolder.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let broker = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: rootURL)
        var rootIsDirectory = ObjCBool(false)
        guard broker.fileExists(at: rootURL, isDirectory: &rootIsDirectory, intent: accessIntent),
              rootIsDirectory.boolValue,
              let enumerator = broker.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                intent: accessIntent
              ) else { return [] }

        var items: [TaskDiagnosticFileItem] = []
        while let url = enumerator.nextObject() as? URL {
            let itemURL = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if broker.shouldSkip(itemURL, intent: accessIntent) {
                enumerator.skipDescendants()
                continue
            }
            guard itemURL.path.hasPrefix(rootPath) else { continue }
            let relativePath = String(itemURL.path.dropFirst(rootPath.count))
            let normalizedRelativePath = TaskOutputArtifactPathPolicy.normalizedRelativePath(relativePath)
            let visibility = TaskOutputArtifactPathPolicy.visibility(
                for: normalizedRelativePath,
                context: .taskFolder
            )
            guard visibility != .deliverable,
                  let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            items.append(TaskDiagnosticFileItem(
                path: itemURL.path,
                relativePath: normalizedRelativePath,
                name: displayName(for: normalizedRelativePath),
                size: Int64(values.fileSize ?? 0),
                group: group(for: normalizedRelativePath, visibility: visibility)
            ))
        }
        return items.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func group(
        for relativePath: String,
        visibility: TaskOutputArtifactVisibility
    ) -> TaskDiagnosticFileItem.Group {
        let lower = relativePath.lowercased()
        if lower.hasPrefix("jobs/") {
            return .jobLogs
        }
        if lower.contains("permission") ||
            lower.contains("credential") ||
            lower.contains("policy") {
            return .permissionsAndCredentials
        }
        if lower.hasPrefix(".runtime/") ||
            lower.hasPrefix(".runtime-bin/") ||
            lower.hasPrefix("diagnostics/") ||
            lower.hasPrefix("run_resource_manifest") ||
            lower == "cache/projects.json" {
            return .runtimeEnvironment
        }
        if lower.hasPrefix("turns/") ||
            lower.hasPrefix("outputs/") ||
            lower.hasPrefix("current_state.") ||
            lower == "session_history.md" {
            return .runs
        }
        return visibility == .internalState ? .rawTaskPackage : .runtimeEnvironment
    }

    private static func displayName(for relativePath: String) -> String {
        let basename = (relativePath as NSString).lastPathComponent
        let parent = ((relativePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !parent.isEmpty, parent != "." else { return basename }
        return "\(parent)/\(basename)"
    }
}
