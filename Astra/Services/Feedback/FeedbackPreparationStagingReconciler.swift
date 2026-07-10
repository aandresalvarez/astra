import Foundation

struct FeedbackPreparationStagingReconciliationResult: Equatable, Sendable {
    let removedPackageCount: Int
    let unsafePackageCount: Int
    let failedPackageCount: Int

    static let empty = FeedbackPreparationStagingReconciliationResult(
        removedPackageCount: 0,
        unsafePackageCount: 0,
        failedPackageCount: 0
    )
}

enum FeedbackPreparationStagingReconciliationError: Error, Equatable {
    case unsafePreparationRoot
    case unreadablePreparationRoot
}

/// Removes preview and construction packages that cannot have a live owner
/// after process launch. Only direct, canonical ASTRA package directories are
/// eligible; malformed entries, files, and symlinks always remain untouched.
struct FeedbackPreparationStagingReconciler {
    private let storageRoot: URL
    private let fileManager: FileManager

    init(
        storageRoot: URL = FeedbackReportStoragePaths.root,
        fileManager: FileManager = .default
    ) {
        self.storageRoot = storageRoot
        self.fileManager = fileManager
    }

    func reconcileAbandonedPackages() throws -> FeedbackPreparationStagingReconciliationResult {
        let standardizedStorageRoot = storageRoot.standardizedFileURL
        guard let anchor = trustedAnchor(containing: standardizedStorageRoot) else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }
        let expectedStorageRoot = Self.replacingAnchor(
            in: standardizedStorageRoot,
            anchor: anchor,
            with: anchor.resolvingSymlinksInPath().standardizedFileURL
        )
        var isStorageDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedStorageRoot.path,
            isDirectory: &isStorageDirectory
        ) else {
            return .empty
        }
        guard isStorageDirectory.boolValue else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }
        let storageValues = try? standardizedStorageRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard storageValues?.isDirectory == true,
              storageValues?.isSymbolicLink != true,
              standardizedStorageRoot.resolvingSymlinksInPath().standardizedFileURL == expectedStorageRoot
        else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }

        let preparationRoot = FeedbackReportStoragePaths.preparationRoot(storageRoot: standardizedStorageRoot)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: preparationRoot.path, isDirectory: &isDirectory) else {
            return .empty
        }
        guard isDirectory.boolValue else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }

        let rootValues: URLResourceValues
        do {
            rootValues = try preparationRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw FeedbackPreparationStagingReconciliationError.unreadablePreparationRoot
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }

        let resolvedRoot = preparationRoot.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot == expectedStorageRoot
            .appendingPathComponent("Preparation", isDirectory: true)
            .standardizedFileURL
        else {
            throw FeedbackPreparationStagingReconciliationError.unsafePreparationRoot
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: resolvedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw FeedbackPreparationStagingReconciliationError.unreadablePreparationRoot
        }

        var removed = 0
        var unsafe = 0
        var failed = 0
        for entry in entries where Self.isOwnedPackageName(entry.lastPathComponent) {
            let supplied = entry.standardizedFileURL
            let values = try? supplied.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard supplied.deletingLastPathComponent() == resolvedRoot,
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  supplied.resolvingSymlinksInPath().standardizedFileURL == supplied
            else {
                unsafe += 1
                continue
            }
            do {
                try fileManager.removeItem(at: supplied)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return FeedbackPreparationStagingReconciliationResult(
            removedPackageCount: removed,
            unsafePackageCount: unsafe,
            failedPackageCount: failed
        )
    }

    private static func isOwnedPackageName(_ name: String) -> Bool {
        let previewPrefix = "feedback-"
        if name.hasPrefix(previewPrefix) {
            return isCanonicalUUID(String(name.dropFirst(previewPrefix.count)))
        }

        let constructionPrefix = ".feedback-staging-"
        guard name.hasPrefix(constructionPrefix) else { return false }
        let suffix = String(name.dropFirst(constructionPrefix.count))
        guard suffix.count == 73 else { return false }
        let separator = suffix.index(suffix.startIndex, offsetBy: 36)
        guard suffix[separator] == "-" else { return false }
        return isCanonicalUUID(String(suffix[..<separator]))
            && isCanonicalUUID(String(suffix[suffix.index(after: separator)...]))
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.lowercased() == value
    }

    private func trustedAnchor(containing url: URL) -> URL? {
        [fileManager.homeDirectoryForCurrentUser, fileManager.temporaryDirectory]
            .map(\.standardizedFileURL)
            .filter { Self.contains(url, in: $0) }
            .max { $0.path.count < $1.path.count }
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate == root || candidate.path.hasPrefix(root.path + "/")
    }

    private static func replacingAnchor(in url: URL, anchor: URL, with resolvedAnchor: URL) -> URL {
        guard url != anchor else { return resolvedAnchor }
        let relative = url.path.dropFirst(anchor.path.count + 1)
        return relative.split(separator: "/").reduce(resolvedAnchor) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: true)
        }.standardizedFileURL
    }
}
