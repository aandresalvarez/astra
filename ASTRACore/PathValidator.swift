import Foundation

public enum PathValidationError: Error, LocalizedError {
    case emptyPath
    case relativePathTraversal(String)
    case symlinkEscapesRoot(resolved: String, root: String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Path cannot be empty"
        case .relativePathTraversal(let path):
            return "Path contains directory traversal: \(path)"
        case .symlinkEscapesRoot(let resolved, let root):
            return "Resolved path \(resolved) is outside workspace root \(root)"
        }
    }
}

public enum PathValidator {
    public static func validate(_ path: String) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PathValidationError.emptyPath
        }

        let components = path.components(separatedBy: "/")
        if components.contains("..") {
            throw PathValidationError.relativePathTraversal(path)
        }
    }

    public static func validate(_ path: String, withinRoot root: String) throws {
        try validate(path)

        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        let resolvedRoot = (root as NSString).resolvingSymlinksInPath

        guard resolvedPath.hasPrefix(resolvedRoot) else {
            throw PathValidationError.symlinkEscapesRoot(resolved: resolvedPath, root: resolvedRoot)
        }
    }
}
