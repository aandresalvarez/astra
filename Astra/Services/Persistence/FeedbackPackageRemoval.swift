import Foundation

public enum FeedbackPackageRemovalError: Error, Equatable {
    case sourceIsNotDirectory
    case symbolicLink(String)
    case unreadableTree(String)
}

/// Reopens only directories inside an already validated feedback package, then
/// removes the package. Evidence files remain read-only until deletion. Callers
/// continue to own containment and report-identity validation for the root URL.
public enum FeedbackPackageRemoval {
    public static func removeOwnedPackage(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let root = directory.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw FeedbackPackageRemovalError.sourceIsNotDirectory
        }

        var enumerationFailure: String?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { url, _ in
                enumerationFailure = url.standardizedFileURL.path
                return false
            }
        ) else {
            throw FeedbackPackageRemovalError.unreadableTree(root.path)
        }

        var directories = [root]
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            let relative = String(child.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw FeedbackPackageRemovalError.symbolicLink(relative)
            }
            if values.isDirectory == true {
                directories.append(child.standardizedFileURL)
            }
        }
        if let enumerationFailure {
            throw FeedbackPackageRemovalError.unreadableTree(enumerationFailure)
        }

        for child in directories.sorted(by: { $0.path.count < $1.path.count }) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: child.path
            )
        }
        try fileManager.removeItem(at: root)
    }
}
