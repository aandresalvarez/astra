import Foundation

struct GitCredentialSandboxContext: Equatable, Sendable {
    var readablePaths: [String]
    var writablePaths: [String]
    var transports: [GitCredentialContextResolver.RemoteTransport]
    var diagnostics: [String]

    static let empty = GitCredentialSandboxContext(
        readablePaths: [],
        writablePaths: [],
        transports: [],
        diagnostics: []
    )

    var isEmpty: Bool {
        readablePaths.isEmpty && writablePaths.isEmpty
    }

    var needsExternalCredentialAccess: Bool {
        transports.contains(.ssh) || transports.contains(.https)
    }
}

enum GitOperationIntentDetector {
    static func detectsRuntimeGitOperation(prompt: String, task: AgentTask, contextText: String = "") -> Bool {
        detectsNetworkGitOperation(prompt: prompt, task: task, contextText: contextText)
            || detectsLocalGitInspectionOperation(prompt: prompt, task: task, contextText: contextText)
    }

    static func detectsNetworkGitOperation(prompt: String, task: AgentTask, contextText: String = "") -> Bool {
        let haystack = networkGitIntentText(prompt: prompt, task: task, contextText: contextText)

        let exactCommands = [
            "git pull", "git fetch", "git push", "git clone", "git ls-remote",
            "git remote update", "git submodule update", "gh pr", "gh repo", "gh auth"
        ]
        if exactCommands.contains(where: { haystack.contains($0) }) {
            return true
        }

        let naturalLanguageSignals = [
            "pull from github",
            "pull from git hub",
            "pull latest",
            "pull the latest",
            "pull latest code",
            "pull the latest code",
            "pull origin",
            "pull from remote",
            "pull remote",
            "fetch from github",
            "fetch origin",
            "fetch main",
            "sync with origin",
            "sync from github",
            "sync from remote",
            "sync main",
            "push to github",
            "clone from github",
            "clone from git hub",
            "clone the repo",
            "clone this repo",
            "clone repository",
            "create pull request",
            "open pull request"
        ]
        if naturalLanguageSignals.contains(where: { haystack.contains($0) }) {
            return true
        }

        let orderedSignals = [
            ["pull", "latest"],
            ["pull", "code", "main"],
            ["pull", "main"],
            ["pull", "remote"],
            ["pull", "origin"],
            ["fetch", "main"],
            ["fetch", "origin"],
            ["sync", "main"],
            ["sync", "origin"],
            ["update", "from", "main"],
            ["update", "with", "main"],
            ["latest", "code", "main"]
        ]
        return orderedSignals.contains { containsOrderedWords($0, in: haystack) }
    }

    static func detectsLocalGitInspectionOperation(prompt: String, task: AgentTask, contextText: String = "") -> Bool {
        let haystack = networkGitIntentText(prompt: prompt, task: task, contextText: contextText)

        let exactCommands = [
            "git status", "git diff", "git log", "git show", "git branch",
            "git rev-parse", "git describe", "git ls-files", "git grep",
            "git blame", "git stash list", "git worktree list"
        ]
        if exactCommands.contains(where: { haystack.contains($0) }) {
            return true
        }

        let naturalLanguageSignals = [
            "inspect the local diff",
            "check the local diff",
            "review local changes",
            "check uncommitted changes",
            "verify no unrelated files",
            "list changed files",
            "show changed files",
            "what changed locally"
        ]
        return naturalLanguageSignals.contains(where: { haystack.contains($0) })
    }

    static func networkGitIntentText(prompt: String, task: AgentTask, contextText: String = "") -> String {
        [
            prompt,
            task.title,
            task.goal,
            contextText
        ]
            .joined(separator: "\n")
            .lowercased()
    }

    private static func containsOrderedWords(_ words: [String], in text: String) -> Bool {
        guard !words.isEmpty else { return false }
        var searchStart = text.startIndex
        for word in words {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
            guard let range = text.range(
                of: pattern,
                options: [.regularExpression],
                range: searchStart..<text.endIndex
            ) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }
}

enum GitCredentialContextResolver {
    enum RemoteTransport: String, Equatable, Sendable {
        case ssh
        case https
        case file
        case unknown
    }

    struct Remote: Equatable, Sendable {
        let name: String
        let url: String
        let transport: RemoteTransport
        let host: String?
    }

    private struct GitConfigData {
        var remotes: [Remote] = []
        var includePaths: [String] = []
        var credentialHelpers: [String] = []
    }

    private struct GitConfigEvaluationContext {
        let repositoryRoot: String
        let gitDirectory: String?
        let currentBranch: String?
    }

    static func sandboxContext(
        repositoryPath: String,
        intentText: String = "",
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> GitCredentialSandboxContext {
        let trimmedRepo = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty else {
            return .empty
        }
        let intentRemotes = remotesFromNetworkGitIntent(intentText)
        guard let repositoryRoot = repositoryRoot(startingAt: trimmedRepo, fileManager: fileManager),
              let gitLayout = gitLayout(repositoryRoot: repositoryRoot, fileManager: fileManager) else {
            guard !intentRemotes.isEmpty else { return .empty }
            return credentialContextWithoutRepository(
                workspacePath: trimmedRepo,
                intentRemotes: intentRemotes,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }

        var diagnostics: [String] = []
        var configs = defaultGitConfigPaths(homeDirectory: homeDirectory, fileManager: fileManager)
        configs.append(gitLayout.configPath)
        let evaluationContext = GitConfigEvaluationContext(
            repositoryRoot: repositoryRoot,
            gitDirectory: gitLayout.gitDirectory,
            currentBranch: currentBranch(gitDirectory: gitLayout.gitDirectory, fileManager: fileManager)
        )

        var parsedConfigs: [GitConfigData] = []
        var processedConfigs: Set<String> = []
        var pendingConfigs = configs
        while let config = pendingConfigs.popLast() {
            guard processedConfigs.insert(config).inserted,
                  fileManager.fileExists(atPath: config),
                  let data = parseGitConfig(
                    at: config,
                    homeDirectory: homeDirectory,
                    evaluationContext: evaluationContext,
                    fileManager: fileManager
                  ) else {
                continue
            }
            parsedConfigs.append(data)
            pendingConfigs.append(contentsOf: data.includePaths.filter {
                !processedConfigs.contains($0) && fileManager.fileExists(atPath: $0)
            })
        }

        let remotes = uniqueRemotes(parsedConfigs.flatMap(\.remotes) + intentRemotes)
        guard !remotes.isEmpty else {
            return GitCredentialSandboxContext(
                readablePaths: externalReadablePaths(
                    rawPaths: Array(processedConfigs),
                    repositoryRoot: repositoryRoot,
                    fileManager: fileManager
                ),
                writablePaths: externalWritableGitPaths(gitLayout: gitLayout, repositoryRoot: repositoryRoot, fileManager: fileManager),
                transports: [],
                diagnostics: ["no_remotes"]
            )
        }

        var readable = Array(processedConfigs)
        let transports = uniqueTransports(remotes.map(\.transport))
        let credentialHelpers = parsedConfigs.flatMap(\.credentialHelpers)

        if transports.contains(.ssh) {
            let sshPaths = sshCredentialPaths(
                remotes: remotes.filter { $0.transport == .ssh },
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            readable.append(contentsOf: sshPaths.paths)
            diagnostics.append(contentsOf: sshPaths.diagnostics)
        }

        if transports.contains(.https) {
            readable.append(contentsOf: httpsCredentialPaths(
                homeDirectory: homeDirectory,
                credentialHelpers: credentialHelpers,
                fileManager: fileManager
            ))
        }

        return GitCredentialSandboxContext(
            readablePaths: externalReadablePaths(
                rawPaths: readable,
                repositoryRoot: repositoryRoot,
                fileManager: fileManager
            ),
            writablePaths: externalWritableGitPaths(
                gitLayout: gitLayout,
                repositoryRoot: repositoryRoot,
                fileManager: fileManager
            ),
            transports: transports,
            diagnostics: uniqueNonEmpty(diagnostics)
        )
    }

    static func runtimeSandboxContext(
        prompt: String,
        task: AgentTask,
        contextText: String,
        repositoryPath: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> GitCredentialSandboxContext {
        let intentText = GitOperationIntentDetector.networkGitIntentText(
            prompt: prompt,
            task: task,
            contextText: contextText
        )
        if GitOperationIntentDetector.detectsNetworkGitOperation(
            prompt: prompt,
            task: task,
            contextText: contextText
        ) {
            return sandboxContext(
                repositoryPath: repositoryPath,
                intentText: intentText,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }
        if GitOperationIntentDetector.detectsLocalGitInspectionOperation(
            prompt: prompt,
            task: task,
            contextText: contextText
        ) {
            return localGitConfigSandboxContext(
                repositoryPath: repositoryPath,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }
        return .empty
    }

    static func localGitConfigSandboxContext(
        repositoryPath: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> GitCredentialSandboxContext {
        let trimmedRepo = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty else { return .empty }

        let fallbackRoot = canonicalPath(trimmedRepo, fileManager: fileManager)
        let repositoryRoot = repositoryRoot(startingAt: trimmedRepo, fileManager: fileManager) ?? fallbackRoot
        let gitLayout = gitLayout(repositoryRoot: repositoryRoot, fileManager: fileManager)
        let evaluationContext = GitConfigEvaluationContext(
            repositoryRoot: repositoryRoot,
            gitDirectory: gitLayout?.gitDirectory,
            currentBranch: gitLayout.flatMap { currentBranch(gitDirectory: $0.gitDirectory, fileManager: fileManager) }
        )

        var processedConfigs: Set<String> = []
        var pendingConfigs = defaultGitConfigPaths(homeDirectory: homeDirectory, fileManager: fileManager)
        if let configPath = gitLayout?.configPath {
            pendingConfigs.append(configPath)
        }

        while let config = pendingConfigs.popLast() {
            guard processedConfigs.insert(config).inserted,
                  fileManager.fileExists(atPath: config),
                  let data = parseGitConfig(
                    at: config,
                    homeDirectory: homeDirectory,
                    evaluationContext: evaluationContext,
                    fileManager: fileManager
                  ) else {
                continue
            }
            pendingConfigs.append(contentsOf: data.includePaths.filter {
                !processedConfigs.contains($0) && fileManager.fileExists(atPath: $0)
            })
        }

        return GitCredentialSandboxContext(
            readablePaths: externalReadablePaths(
                rawPaths: Array(processedConfigs),
                repositoryRoot: repositoryRoot,
                fileManager: fileManager
            ),
            writablePaths: gitLayout.map {
                externalWritableGitPaths(gitLayout: $0, repositoryRoot: repositoryRoot, fileManager: fileManager)
            } ?? [],
            transports: [],
            diagnostics: ["local_git_config"]
        )
    }

    private struct GitLayout {
        let gitDirectory: String
        let commonDirectory: String?
        let configPath: String
    }

    private static func credentialContextWithoutRepository(
        workspacePath: String,
        intentRemotes: [Remote],
        homeDirectory: String,
        fileManager: FileManager
    ) -> GitCredentialSandboxContext {
        let workspaceRoot = canonicalPath(workspacePath, fileManager: fileManager)
        let configs = defaultGitConfigPaths(homeDirectory: homeDirectory, fileManager: fileManager)
        let evaluationContext = GitConfigEvaluationContext(
            repositoryRoot: workspaceRoot,
            gitDirectory: nil,
            currentBranch: nil
        )
        var parsedConfigs: [GitConfigData] = []
        var processedConfigs: Set<String> = []
        var pendingConfigs = configs
        while let config = pendingConfigs.popLast() {
            guard processedConfigs.insert(config).inserted,
                  fileManager.fileExists(atPath: config),
                  let data = parseGitConfig(
                    at: config,
                    homeDirectory: homeDirectory,
                    evaluationContext: evaluationContext,
                    fileManager: fileManager
                  ) else {
                continue
            }
            parsedConfigs.append(data)
            pendingConfigs.append(contentsOf: data.includePaths.filter {
                !processedConfigs.contains($0) && fileManager.fileExists(atPath: $0)
            })
        }

        var readable = Array(processedConfigs)
        var diagnostics = ["intent_remotes_without_repository"]
        let remotes = uniqueRemotes(parsedConfigs.flatMap(\.remotes) + intentRemotes)
        let transports = uniqueTransports(remotes.map(\.transport))
        let credentialHelpers = parsedConfigs.flatMap(\.credentialHelpers)
        if transports.contains(.ssh) {
            let sshPaths = sshCredentialPaths(
                remotes: remotes.filter { $0.transport == .ssh },
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            readable.append(contentsOf: sshPaths.paths)
            diagnostics.append(contentsOf: sshPaths.diagnostics)
        }
        if transports.contains(.https) {
            readable.append(contentsOf: httpsCredentialPaths(
                homeDirectory: homeDirectory,
                credentialHelpers: credentialHelpers,
                fileManager: fileManager
            ))
        }

        return GitCredentialSandboxContext(
            readablePaths: externalReadablePaths(
                rawPaths: readable,
                repositoryRoot: workspaceRoot,
                fileManager: fileManager
            ),
            writablePaths: [],
            transports: transports,
            diagnostics: uniqueNonEmpty(diagnostics)
        )
    }

    private static func repositoryRoot(
        startingAt path: String,
        fileManager: FileManager
    ) -> String? {
        var candidate = canonicalPath(path, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) {
            candidate = canonicalPath((candidate as NSString).deletingLastPathComponent, fileManager: fileManager)
        } else if !isDirectory.boolValue {
            candidate = canonicalPath((candidate as NSString).deletingLastPathComponent, fileManager: fileManager)
        }

        while !candidate.isEmpty && candidate != "/" {
            let dotGit = (candidate as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGit) {
                return candidate
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func gitLayout(repositoryRoot: String, fileManager: FileManager) -> GitLayout? {
        let dotGit = (repositoryRoot as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }

        let gitDirectory: String
        if isDirectory.boolValue {
            gitDirectory = canonicalPath(dotGit, fileManager: fileManager)
        } else {
            guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  raw.lowercased().hasPrefix("gitdir:") else {
                return nil
            }
            let value = raw.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = canonicalPath(resolvePath(value, relativeTo: repositoryRoot, homeDirectory: nil), fileManager: fileManager)
        }

        let commonDirectory = commonGitDirectory(gitDirectory: gitDirectory, fileManager: fileManager)
        let configBase = commonDirectory ?? gitDirectory
        let configPath = (configBase as NSString).appendingPathComponent("config")
        return GitLayout(gitDirectory: gitDirectory, commonDirectory: commonDirectory, configPath: configPath)
    }

    private static func commonGitDirectory(gitDirectory: String, fileManager: FileManager) -> String? {
        let commonDirFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let raw = try? String(contentsOfFile: commonDirFile, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return canonicalPath(resolvePath(value, relativeTo: gitDirectory, homeDirectory: nil), fileManager: fileManager)
    }

    private static func currentBranch(gitDirectory: String, fileManager: FileManager) -> String? {
        let headFile = (gitDirectory as NSString).appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOfFile: headFile, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private static func defaultGitConfigPaths(homeDirectory: String, fileManager _: FileManager) -> [String] {
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return [] }
        return [
            (home as NSString).appendingPathComponent(".gitconfig"),
            (home as NSString).appendingPathComponent(".config/git/config")
        ]
    }

    private static func parseGitConfig(
        at path: String,
        homeDirectory: String,
        evaluationContext: GitConfigEvaluationContext,
        fileManager: FileManager
    ) -> GitConfigData? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        var rawSection = ""
        var section = ""
        var data = GitConfigData()

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                rawSection = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                section = rawSection.lowercased()
                continue
            }
            let parts = splitConfigLine(line)
            guard let key = parts.key else { continue }
            let value = unquoteConfigValue(parts.value)

            if section.hasPrefix("remote "),
               key == "url",
               let remoteName = quotedSectionValue(section) {
                let parsed = parseRemote(url: value, name: remoteName)
                data.remotes.append(parsed)
            } else if (section == "include" || section.hasPrefix("includeif ")),
                      key == "path" {
                if section.hasPrefix("includeif "),
                   !includeIfConditionMatches(
                    rawSection,
                    configDirectory: directory,
                    homeDirectory: homeDirectory,
                    context: evaluationContext,
                    fileManager: fileManager
                   ) {
                    continue
                }
                data.includePaths.append(canonicalPath(
                    resolvePath(value, relativeTo: directory, homeDirectory: homeDirectory),
                    fileManager: fileManager
                ))
            } else if section == "credential" || section.hasPrefix("credential "),
                      key == "helper" {
                data.credentialHelpers.append(value)
            }
        }
        return data
    }

    private static func includeIfConditionMatches(
        _ rawSection: String,
        configDirectory: String,
        homeDirectory: String,
        context: GitConfigEvaluationContext,
        fileManager: FileManager
    ) -> Bool {
        guard let condition = quotedSectionValue(rawSection) else { return false }
        let lower = condition.lowercased()
        if lower.hasPrefix("gitdir/i:") {
            let pattern = String(condition.dropFirst("gitdir/i:".count))
            return gitDirectoryMatches(
                pattern: pattern,
                caseInsensitive: true,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory,
                context: context,
                fileManager: fileManager
            )
        }
        if lower.hasPrefix("gitdir:") {
            let pattern = String(condition.dropFirst("gitdir:".count))
            return gitDirectoryMatches(
                pattern: pattern,
                caseInsensitive: false,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory,
                context: context,
                fileManager: fileManager
            )
        }
        if lower.hasPrefix("onbranch:") {
            guard let branch = context.currentBranch else { return false }
            var pattern = String(condition.dropFirst("onbranch:".count))
            if pattern.hasSuffix("/") {
                pattern += "**"
            }
            return wildcardPatternMatches(pattern: pattern, candidate: branch, caseInsensitive: false)
        }
        return false
    }

    private static func gitDirectoryMatches(
        pattern: String,
        caseInsensitive: Bool,
        configDirectory: String,
        homeDirectory: String,
        context: GitConfigEvaluationContext,
        fileManager: FileManager
    ) -> Bool {
        guard let gitDirectory = context.gitDirectory else { return false }
        let normalizedPattern = normalizedGitDirectoryPattern(
            pattern,
            configDirectory: configDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let targets = uniqueNonEmpty([
            canonicalPath(gitDirectory, fileManager: fileManager),
            canonicalPath((context.repositoryRoot as NSString).appendingPathComponent(".git"), fileManager: fileManager)
        ])
        return targets.contains { target in
            wildcardPatternMatches(pattern: normalizedPattern, candidate: target, caseInsensitive: caseInsensitive)
                || wildcardPatternMatches(pattern: normalizedPattern, candidate: target + "/", caseInsensitive: caseInsensitive)
        }
    }

    private static func normalizedGitDirectoryPattern(
        _ pattern: String,
        configDirectory: String,
        homeDirectory: String,
        fileManager: FileManager
    ) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.hasPrefix("~/") || trimmed == "~" {
            resolved = resolvePath(trimmed, relativeTo: configDirectory, homeDirectory: homeDirectory)
        } else if trimmed.hasPrefix("./") {
            resolved = resolvePath(trimmed, relativeTo: configDirectory, homeDirectory: homeDirectory)
        } else if trimmed.hasPrefix("/") {
            resolved = trimmed
        } else {
            resolved = "**/" + trimmed
        }
        let canonical = canonicalPath(resolved, fileManager: fileManager)
        return resolved.hasSuffix("/") ? appendingDescendantGlob(to: canonical) : canonical
    }

    private static func appendingDescendantGlob(to canonicalDirectoryPattern: String) -> String {
        canonicalDirectoryPattern.hasSuffix("/")
            ? canonicalDirectoryPattern + "**"
            : canonicalDirectoryPattern + "/**"
    }

    private static func wildcardPatternMatches(
        pattern: String,
        candidate: String,
        caseInsensitive: Bool
    ) -> Bool {
        let regex = "^" + wildcardPatternRegex(pattern) + "$"
        var options: String.CompareOptions = [.regularExpression]
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return candidate.range(of: regex, options: options) != nil
    }

    private static func wildcardPatternRegex(_ pattern: String) -> String {
        var regex = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    index = pattern.index(after: next)
                } else {
                    regex += "[^/]*"
                    index = next
                }
            } else if char == "?" {
                regex += "[^/]"
                index = pattern.index(after: index)
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
                index = pattern.index(after: index)
            }
        }
        return regex
    }

    private static func splitConfigLine(_ line: String) -> (key: String?, value: String) {
        if let index = line.firstIndex(of: "=") {
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (key.isEmpty ? nil : key, String(value))
        }
        let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard let key = pieces.first?.lowercased(), !key.isEmpty else { return (nil, "") }
        return (key, pieces.count > 1 ? pieces[1] : "")
    }

    private static func quotedSectionValue(_ section: String) -> String? {
        guard let firstQuote = section.firstIndex(of: "\""),
              let lastQuote = section.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return nil
        }
        return String(section[section.index(after: firstQuote)..<lastQuote])
    }

    private static func unquoteConfigValue(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func parseRemote(url: String, name: String) -> Remote {
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return Remote(name: name, url: url, transport: .https, host: URL(string: url)?.host)
        }
        if lower.hasPrefix("ssh://") {
            let host = URL(string: url)?.host
            return Remote(name: name, url: url, transport: .ssh, host: host)
        }
        if let atRange = url.range(of: "@"),
           let colonRange = url[atRange.upperBound...].range(of: ":") {
            let host = String(url[atRange.upperBound..<colonRange.lowerBound])
            return Remote(name: name, url: url, transport: .ssh, host: host.isEmpty ? nil : host)
        }
        if lower.hasPrefix("file://") || url.hasPrefix("/") || url.hasPrefix("../") || url.hasPrefix("./") {
            return Remote(name: name, url: url, transport: .file, host: nil)
        }
        return Remote(name: name, url: url, transport: .unknown, host: nil)
    }

    private static func remotesFromNetworkGitIntent(_ text: String) -> [Remote] {
        let trimCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>.,;")
        let tokens = text.components(separatedBy: .whitespacesAndNewlines)
        let remotes = tokens.enumerated().compactMap { index, token -> Remote? in
            let cleaned = token.trimmingCharacters(in: trimCharacters)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("-") else { return nil }
            let remote = parseRemote(url: cleaned, name: "intent-\(index)")
            guard remote.transport == .ssh || remote.transport == .https else { return nil }
            return remote
        }
        return uniqueRemotes(remotes)
    }

    private static func sshCredentialPaths(
        remotes: [Remote],
        homeDirectory: String,
        fileManager: FileManager
    ) -> (paths: [String], diagnostics: [String]) {
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return ([], ["missing_home"]) }
        let sshDirectory = (home as NSString).appendingPathComponent(".ssh")
        let sshConfig = (sshDirectory as NSString).appendingPathComponent("config")
        var paths = existingPaths([
            sshConfig,
            (sshDirectory as NSString).appendingPathComponent("known_hosts"),
            (sshDirectory as NSString).appendingPathComponent("known_hosts2")
        ], fileManager: fileManager)
        var diagnostics: [String] = []

        let hostNames = remotes.compactMap(\.host)
        let identityPaths = matchingSSHIdentityFiles(
            sshConfigPath: sshConfig,
            hosts: hostNames,
            homeDirectory: home,
            fileManager: fileManager
        )
        if identityPaths.isEmpty {
            diagnostics.append("ssh_default_identities")
            paths.append(contentsOf: defaultSSHIdentityPaths(sshDirectory: sshDirectory, fileManager: fileManager))
        } else {
            paths.append(contentsOf: identityPaths)
        }
        return (uniqueExistingPaths(paths, fileManager: fileManager), diagnostics)
    }

    private static func matchingSSHIdentityFiles(
        sshConfigPath: String,
        hosts: [String],
        homeDirectory: String,
        fileManager: FileManager
    ) -> [String] {
        guard fileManager.fileExists(atPath: sshConfigPath),
              let raw = try? String(contentsOfFile: sshConfigPath, encoding: .utf8),
              !hosts.isEmpty else {
            return []
        }

        var activePatterns: [String] = ["*"]
        var identities: [String] = []
        var knownHostFiles: [String] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let pieces = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = pieces.first?.lowercased() else { continue }
            if keyword == "host" {
                activePatterns = Array(pieces.dropFirst())
            } else if keyword == "identityfile",
                      let value = pieces.dropFirst().first,
                      hosts.contains(where: { host in activePatterns.contains(where: { hostMatches(pattern: $0, host: host) }) }) {
                identities.append(resolvePath(value, relativeTo: homeDirectory, homeDirectory: homeDirectory))
            } else if keyword == "userknownhostsfile",
                      hosts.contains(where: { host in activePatterns.contains(where: { hostMatches(pattern: $0, host: host) }) }) {
                for value in pieces.dropFirst() {
                    knownHostFiles.append(resolvePath(value, relativeTo: homeDirectory, homeDirectory: homeDirectory))
                }
            }
        }
        return identities.flatMap { withPublicKeyCompanion($0, fileManager: fileManager) }
            + existingPaths(knownHostFiles, fileManager: fileManager)
    }

    private static func defaultSSHIdentityPaths(sshDirectory: String, fileManager: FileManager) -> [String] {
        [
            "id_ed25519",
            "id_ecdsa",
            "id_rsa",
            "id_dsa"
        ]
        .map { (sshDirectory as NSString).appendingPathComponent($0) }
        .flatMap { withPublicKeyCompanion($0, fileManager: fileManager) }
    }

    private static func withPublicKeyCompanion(_ path: String, fileManager: FileManager) -> [String] {
        var result = existingPaths([path], fileManager: fileManager)
        let publicKey = path + ".pub"
        if fileManager.fileExists(atPath: publicKey) {
            result.append(publicKey)
        }
        return result
    }

    private static func hostMatches(pattern: String, host: String) -> Bool {
        let lowerPattern = pattern.lowercased()
        let lowerHost = host.lowercased()
        if lowerPattern == "*" || lowerPattern == lowerHost { return true }
        let escaped = NSRegularExpression.escapedPattern(for: lowerPattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return lowerHost.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }

    private static func httpsCredentialPaths(
        homeDirectory: String,
        credentialHelpers: [String],
        fileManager: FileManager
    ) -> [String] {
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return [] }
        var paths = [
            (home as NSString).appendingPathComponent(".git-credentials"),
            (home as NSString).appendingPathComponent(".netrc"),
            (home as NSString).appendingPathComponent(".config/git/credentials"),
            (home as NSString).appendingPathComponent(".config/gh")
        ]
        let usesOSXKeychain = credentialHelpers.contains { $0.lowercased().contains("osxkeychain") }
        if usesOSXKeychain {
            paths.append((home as NSString).appendingPathComponent("Library/Keychains/login.keychain-db"))
        }
        return uniqueExistingPaths(paths, fileManager: fileManager)
    }

    private static func externalReadablePaths(
        rawPaths: [String],
        repositoryRoot: String,
        fileManager: FileManager
    ) -> [String] {
        uniqueExistingPaths(rawPaths, fileManager: fileManager)
            .filter { !isSameOrDescendant($0, of: repositoryRoot) }
    }

    private static func externalWritableGitPaths(
        gitLayout: GitLayout,
        repositoryRoot: String,
        fileManager: FileManager
    ) -> [String] {
        uniqueExistingPaths([
            gitLayout.gitDirectory,
            gitLayout.commonDirectory
        ].compactMap { $0 }, fileManager: fileManager)
            .filter { !isSameOrDescendant($0, of: repositoryRoot) }
    }

    private static func existingPaths(_ paths: [String], fileManager: FileManager) -> [String] {
        paths
            .map { canonicalPath($0, fileManager: fileManager) }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    private static func uniqueExistingPaths(_ paths: [String], fileManager: FileManager) -> [String] {
        uniqueNonEmpty(existingPaths(paths, fileManager: fileManager))
    }

    private static func uniqueRemotes(_ remotes: [Remote]) -> [Remote] {
        var seen: Set<String> = []
        return remotes.filter { seen.insert("\($0.name)|\($0.url)").inserted }
    }

    private static func uniqueTransports(_ transports: [RemoteTransport]) -> [RemoteTransport] {
        var seen: Set<RemoteTransport> = []
        return transports.filter { seen.insert($0).inserted }
    }

    private static func uniqueNonEmpty(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }

    private static func resolvePath(_ path: String, relativeTo base: String, homeDirectory: String?) -> String {
        let expanded: String
        let home = homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" {
            expanded = home?.isEmpty == false ? home! : FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            let root = home?.isEmpty == false ? home! : FileManager.default.homeDirectoryForCurrentUser.path
            expanded = (root as NSString)
                .appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = (base as NSString).appendingPathComponent(path)
        }
        return expanded
    }

    private static func canonicalPath(_ path: String, fileManager _: FileManager) -> String {
        (path as NSString).standardizingPath
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        let cleanPath = (path as NSString).standardizingPath
        let cleanRoot = (root as NSString).standardizingPath
        return cleanPath == cleanRoot || cleanPath.hasPrefix(cleanRoot + "/")
    }
}
