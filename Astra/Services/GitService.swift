import Foundation

struct GitRepositoryInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
}

struct GitStatusFile: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let status: String // "M", "A", "D", "?", "R"
    let isStaged: Bool
}

class GitService {
    static let shared = GitService()
    
    private init() {}

    /// Scans a workspace's primary path and additional paths for folders containing a `.git` subdirectory.
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        var repos: [GitRepositoryInfo] = []
        let allPaths = [primaryPath] + additionalPaths
        
        for path in allPaths where !path.isEmpty {
            let expandedPath = NSString(string: path).expandingTildeInPath
            var isDir: ObjCBool = false
            let fm = FileManager.default
            
            if fm.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                let gitPath = URL(fileURLWithPath: expandedPath).appendingPathComponent(".git")
                if fm.fileExists(atPath: gitPath.path, isDirectory: &isDir), isDir.boolValue {
                    let name = URL(fileURLWithPath: expandedPath).lastPathComponent
                    repos.append(GitRepositoryInfo(name: name, path: expandedPath))
                }
            }
        }
        return repos
    }
    
    /// Spawns a git subprocess and returns standard output or throws standard error.
    private func runGit(at repoPath: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath] + arguments
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        try process.run()
        
        // Asynchronously wait for exit to prevent blocking the main thread
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                
                if process.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: NSError(domain: "GitError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errString]))
                } else {
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let outString = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: outString)
                }
            }
        }
    }
    
    func getCurrentBranch(at repoPath: String) async -> String {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--show-current"])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }
    
    func getLocalBranches(at repoPath: String) async -> [String] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--format=%(refname:short)"])
            return output.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
    
    func checkoutBranch(_ branch: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["checkout", branch])
    }
    
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws {
        var args = ["checkout", "-b", branch]
        if let base = base {
            args.append(base)
        }
        _ = try await runGit(at: repoPath, arguments: args)
    }
    
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["status", "--porcelain"])
            var files: [GitStatusFile] = []
            let lines = output.split(separator: "\n")
            
            for line in lines {
                guard line.count >= 3 else { continue }
                let xIndex = line.index(line.startIndex, offsetBy: 0)
                let yIndex = line.index(line.startIndex, offsetBy: 1)
                let x = String(line[xIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let y = String(line[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                let fileStartIndex = line.index(line.startIndex, offsetBy: 3)
                let relativePath = String(line[fileStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // If X is not empty, it means there are changes in the staging index
                if !x.isEmpty {
                    files.append(GitStatusFile(relativePath: relativePath, status: x, isStaged: true))
                }
                // If Y is not empty, it means there are unstaged changes in the worktree
                if !y.isEmpty || (x == "?" && y == "?") {
                    let status = (x == "?" && y == "?") ? "?" : y
                    files.append(GitStatusFile(relativePath: relativePath, status: status, isStaged: false))
                }
            }
            return files
        } catch {
            return []
        }
    }
    
    func stageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", relativePath])
    }
    
    func stageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", "."])
    }
    
    func unstageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD", relativePath])
    }
    
    func unstageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD"])
    }
    
    func commit(message: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["commit", "-m", message])
    }
    
    func pull(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["pull"])
    }
    
    func push(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["push"])
    }
}
