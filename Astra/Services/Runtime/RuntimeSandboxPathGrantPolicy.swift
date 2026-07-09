import Foundation
import ASTRACore

enum RuntimeSandboxPathGrantPolicy {
    enum Decision: Equatable {
        case eligible(path: String, access: String)
        case denied(reason: String)
    }

    static func evaluate(
        path rawPath: String,
        operation: RuntimeSandboxFileDenial.Operation,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Decision {
        guard operation != .write else {
            return .denied(reason: "sandbox_write_approval_not_supported")
        }
        guard let path = ExecutionSandbox.canonicalize(rawPath),
              path.hasPrefix("/"),
              !ExecutionSandbox.isOverlyBroadRoot(path) else {
            return .denied(reason: "sandbox_path_unbounded")
        }
        let accessBroker = HostFileAccessBroker(homeDirectory: homeDirectory)
        guard !accessBroker.shouldSkip(
            URL(fileURLWithPath: path),
            intent: .implicitScan(root: nil)
        ) else {
            return .denied(reason: "sandbox_path_privacy_protected")
        }

        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let forbiddenRoots = [
            "\(home)/.ssh",
            "\(home)/.config/gcloud",
            "\(home)/.aws",
            "\(home)/.azure",
            "\(home)/Library/Keychains",
            "\(home)/Library/Application Support/Astra",
            "\(home)/Library/Application Support/AstraDev"
        ]
        guard !forbiddenRoots.contains(where: { isInsideOrEqual(path, root: $0) }) else {
            return .denied(reason: "sandbox_path_security_owned")
        }
        return .eligible(path: path, access: "read")
    }

    private static func isInsideOrEqual(_ path: String, root: String) -> Bool {
        let canonicalRoot = ExecutionSandbox.canonicalize(root) ?? root
        return path == canonicalRoot || path.hasPrefix(canonicalRoot + "/")
    }
}
