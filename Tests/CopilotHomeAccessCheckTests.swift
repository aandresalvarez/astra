import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Every test builds a throwaway folder that stands in for `~/.copilot`; the
/// real one is never inspected. Root can read a mode-000 file, so the suite
/// only means something when it runs as a normal user.
@Suite("CopilotHomeAccessCheck", .enabled(if: getuid() != 0))
struct CopilotHomeAccessCheckTests {
    @Test("A healthy or missing Copilot home reports nothing")
    func healthyAndMissingHomesAreClean() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.makeDirectory("session-state", mode: 0o755)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)
        #expect(report.isClean)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report) == nil)

        let missing = CopilotHomeAccessCheck.inspect(home: home.path + "-missing")
        #expect(missing.isClean)
    }

    @Test("A root-owned unreadable config.json blocks Copilot and names the chown fix")
    func foreignUnreadableConfigBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)

        // Another uid stands in for root: the file is unreadable either way,
        // and only its owner decides whether the fix is chown or chmod.
        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1)
        #expect(problem.path == config)
        #expect(problem.access == .unreadable)
        #expect(!problem.ownedByCurrentUser)
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("Copilot cannot read"))
        #expect(report.cause.contains("config.json"))
        #expect(report.cause.contains("mode 0"))
        #expect(report.cause.contains("sudo"))
        // config.json is read-only to Copilot, so read access is all it gets back.
        #expect(report.fixCommand == "sudo chown \"$USER\" '\(config)' && chmod u+r '\(config)'")
        #expect(report.userMessage.contains("Run `\(report.fixCommand)` in Terminal"))
    }

    @Test("An unreadable file the user owns gets a chmod fix, not a chown")
    func ownUnreadableConfigGetsChmod() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.blocksCopilot)
        #expect(report.fixCommand == "chmod u+r '\(config)'")
        #expect(!report.cause.contains("sudo"))
    }

    @Test("A read-only state folder warns instead of blocking, and a foreign one is chowned recursively")
    func unwritableDirectoryWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        let sessions = try home.makeDirectory("session-state", mode: 0o555)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        let problem = try #require(report.problems.first)
        #expect(problem.path == sessions)
        #expect(problem.isDirectory)
        #expect(problem.access == .unwritable)
        #expect(!report.blocksCopilot)
        #expect(report.cause.contains("Copilot cannot write"))
        #expect(report.fixCommand == "sudo chown -R \"$USER\" '\(sessions)' && chmod u+rwx '\(sessions)'")
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .warning)
    }

    @Test("An unusable home is reported once, not once per child")
    func unreadableHomeIsReportedAlone() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.setMode(0o000, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.problems.map(\.path) == [home.path])
        #expect(report.blocksCopilot)
        #expect(report.fixCommand
            == "sudo chown -R \"$USER\" '\(home.path)' && chmod u+rwx '\(home.path)' && chmod -R u+rX '\(home.path)'")
    }

    @Test("Read-only Copilot config files are a hardened setup, not a problem")
    func readOnlyConfigFilesAreClean() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o400)
        try home.write("mcp-config.json", mode: 0o444)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
        // Write access is waived, read access is not.
        try home.setMode(0o000, of: config)
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).blocksCopilot)
    }

    @Test("A home that is only unwritable still has its children checked")
    func unwritableHomeStillChecksChildren() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        try home.setMode(0o555, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.problems.map(\.path) == [config, home.path])
        #expect(report.problems.map(\.access) == [.unreadable, .unwritable])
        #expect(report.blocksCopilot)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .blocked)
        #expect(report.fixCommand.contains("'\(config)'"))
        #expect(report.fixCommand.contains("'\(home.path)'"))
    }

    @Test("A silent exit with only an unwritable entry keeps the generic diagnosis")
    func unwritableOnlyDoesNotExplainSilentExit() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.makeDirectory("session-state", mode: 0o555)

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: home.path) }
        )

        #expect(diagnostic.category == .providerProcessFailed)
    }

    @Test("An unreadable file Copilot never opens warns instead of blocking")
    func strayUnreadableFileOnlyWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        let stray = try home.write("config.json.bak", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.map(\.path) == [stray])
        #expect(report.problems.first?.access == .unreadable)
        #expect(!report.blocksCopilot)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .warning)
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { report }
        )
        #expect(diagnostic.category == .providerProcessFailed)
    }

    @Test("A Copilot home that is a file blocks and is moved aside")
    func fileInPlaceOfHomeBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let notAFolder = try home.write("copilot-home", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(home: notAFolder)

        #expect(report.problems.map(\.access) == [.notADirectory])
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("is a file, not a folder"))
        #expect(report.fixCommand == "mv -n '\(notAFolder)' '\(notAFolder).bak'")
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .blocked)
    }

    @Test("Moving a file-shaped home aside never overwrites an earlier backup")
    func moveAsideAvoidsExistingBackup() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let notAFolder = try home.write("copilot-home", mode: 0o600)
        try home.write("copilot-home.bak", mode: 0o600)
        try home.write("copilot-home.bak-2", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(home: notAFolder)

        #expect(report.problems.first?.backupPath == "\(notAFolder).bak-3")
        #expect(report.fixCommand == "mv -n '\(notAFolder)' '\(notAFolder).bak-3'")
    }

    @Test("A symlinked startup entry is judged by its target, and never repaired outside the home")
    func symlinkedStartupEntryChecksTarget() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let elsewhere = try FakeCopilotHome()
        defer { elsewhere.remove() }
        let target = try elsewhere.write("real-config.json", mode: 0o600)
        let strayTarget = try elsewhere.write("stray", mode: 0o000)
        let link = (home.path as NSString).appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try FileManager.default.createSymbolicLink(
            atPath: (home.path as NSString).appendingPathComponent("notes.link"),
            withDestinationPath: strayTarget
        )

        // Readable, but outside the home: a sandboxed task cannot follow it.
        let readable = CopilotHomeAccessCheck.inspect(home: home.path)
        #expect(readable.problems.map(\.access) == [.linksOutsideHome])
        #expect(!readable.blocksCopilot)
        #expect(readable.cause.contains("sandboxed policy"))
        #expect(readable.fixCommand.isEmpty)
        #expect(readable.remediation.contains("with a copy of the file"))
        #expect(CopilotHomeAccessCheck.readinessCheck(for: readable)?.state == .warning)

        try elsewhere.setMode(0o000, of: target)
        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1)
        #expect(problem.path == link)
        #expect(problem.symlinkTarget == (target as NSString).standardizingPath)
        #expect(report.blocksCopilot)
        #expect(report.fixCommand.isEmpty)
        #expect(report.remediation.contains("real-config.json readable again"))
        #expect(!report.userMessage.contains("chmod"))
    }

    @Test("The legacy extensionless permissions file is a startup entry")
    func legacyPermissionsFileBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("permissions-config", mode: 0o000)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).blocksCopilot)
    }

    @Test("An ACL that denies reading is removed by the fix, not just the mode bits")
    func aclDenialIsRepaired() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o600)
        try Self.shell("/bin/chmod", ["+a", "user:\(NSUserName()) deny read", config])

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first)
        #expect(problem.access == .unreadable)
        #expect(problem.hasACL)
        #expect(report.cause.contains("with an ACL"))
        #expect(report.fixCommand == "chmod -N '\(config)' && chmod u+r '\(config)'")
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("A missing home in a folder the user cannot write blocks, without a recursive chown")
    func uncreatableHomeBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let parent = try home.makeDirectory("locked", mode: 0o555)
        let missingHome = (parent as NSString).appendingPathComponent(".copilot")

        let own = CopilotHomeAccessCheck.inspect(home: missingHome)
        #expect(own.problems.map(\.access) == [.cannotCreateHome])
        #expect(own.problems.first?.path == parent)
        #expect(own.blocksCopilot)
        #expect(own.cause.contains("cannot create"))
        #expect(own.fixCommand == "chmod u+rwx '\(parent)'")

        let foreign = CopilotHomeAccessCheck.inspect(home: missingHome, currentUserID: getuid() + 1)
        #expect(foreign.fixCommand == "sudo chown \"$USER\" '\(parent)' && chmod u+rwx '\(parent)'")

        try home.setMode(0o755, of: parent)
        #expect(CopilotHomeAccessCheck.inspect(home: missingHome).isClean)
    }

    @Test("A benign stderr warning does not hide an unreadable home from the diagnosis")
    func warningOnlyStderrStillDiagnosesHome() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "Warning: --stream is deprecated. Use --stream=on.\n", runOutput: "",
            providerVersion: nil, stream: nil,
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: home.path) }
        )

        #expect(diagnostic.category == .providerHomeAccessDenied)
        #expect(diagnostic.stderrWasWarningOnly)
    }

    @Test("A symlinked home is judged by its target's type and write access")
    func symlinkedHomeChecksTarget() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let fileTarget = try root.write("not-a-folder", mode: 0o600)
        let linkToFile = (root.path as NSString).appendingPathComponent("home-link-file")
        try FileManager.default.createSymbolicLink(atPath: linkToFile, withDestinationPath: fileTarget)

        let toFile = CopilotHomeAccessCheck.inspect(home: linkToFile)
        #expect(toFile.problems.map(\.access) == [.notADirectory])
        #expect(toFile.fixCommand == "mv -n '\(linkToFile)' '\(linkToFile).bak'")

        let folder = try root.makeDirectory("real-home", mode: 0o755)
        let config = (folder as NSString).appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: config))
        let linkToFolder = (root.path as NSString).appendingPathComponent("home-link-folder")
        try FileManager.default.createSymbolicLink(atPath: linkToFolder, withDestinationPath: folder)
        #expect(CopilotHomeAccessCheck.inspect(home: linkToFolder).isClean)

        try root.setMode(0o000, of: config)
        try root.setMode(0o555, of: folder)
        defer { try? root.setMode(0o755, of: folder); try? root.setMode(0o600, of: config) }
        let readOnly = CopilotHomeAccessCheck.inspect(home: linkToFolder)
        #expect(readOnly.problems.map(\.path) == [config, linkToFolder])
        #expect(readOnly.problems.map(\.access) == [.unreadable, .unwritable])
        #expect(readOnly.problems.last?.symlinkTarget == folder)
        #expect(readOnly.blocksCopilot)
        // The linked folder is advised, never chmod-ed or chown-ed by the fix.
        #expect(!readOnly.fixCommand.contains("'\(folder)'"))
        #expect(readOnly.remediation.contains("replace the link at"))
    }

    @Test("A home symlink to nothing blocks and the link is moved aside")
    func danglingHomeLinkBlocks() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let gone = (root.path as NSString).appendingPathComponent("unmounted/copilot")
        let link = (root.path as NSString).appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: gone)

        let report = CopilotHomeAccessCheck.inspect(home: link)

        #expect(report.problems.map(\.access) == [.danglingLink])
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("unmounted/copilot, which does not exist"))
        #expect(report.fixCommand == "mv -n '\(link)' '\(link).bak'")
        #expect(!report.remediation.contains("readable again"))
    }

    @Test("A startup link inside the home is clean")
    func startupLinkInsideHomeIsClean() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let real = try home.write("config.real.json", mode: 0o600)
        try FileManager.default.createSymbolicLink(
            atPath: (home.path as NSString).appendingPathComponent("config.json"), withDestinationPath: real
        )

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("A symlinked state folder inside the home still needs write access")
    func symlinkedStateFolderNeedsWrite() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let realSessions = try home.makeDirectory("real-sessions", mode: 0o555)
        let link = (home.path as NSString).appendingPathComponent("session-state")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realSessions)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let linked = try #require(report.problems.first { $0.path == link })
        #expect(linked.access == .unwritable)
        #expect(!report.blocksCopilot)
        #expect(report.remediation.contains("real-sessions writable again"))
    }

    @Test("A startup link through an intermediate link out of the home is outside it")
    func intermediateLinkOutOfHomeIsOutside() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let elsewhere = try FakeCopilotHome()
        defer { elsewhere.remove() }
        try elsewhere.write("config", mode: 0o600)
        let alias = (home.path as NSString).appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(
            atPath: (home.path as NSString).appendingPathComponent("config.json"),
            withDestinationPath: (alias as NSString).appendingPathComponent("config")
        )

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.map(\.access) == [.linksOutsideHome])
    }

    @Test("Repairing an unwritable home comes before moving a misplaced entry out of it")
    func homeRepairPrecedesMove() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let configFolder = try home.makeDirectory("config.json", mode: 0o755)
        try home.setMode(0o555, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.fixCommand == "chmod u+rwx '\(home.path)' && mv -n '\(configFolder)' '\(configFolder).bak'")
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("Repairing an unreadable home also restores read access to what it hid")
    func unreadableHomeRepairReachesChildren() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        try home.setMode(0o000, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.map(\.path) == [home.path])
        // It may hide entries owned by someone else, so ownership comes back too.
        #expect(report.fixCommand
            == "sudo chown -R \"$USER\" '\(home.path)' && chmod u+rwx '\(home.path)' && chmod -R u+rX '\(home.path)'")
        try Self.runSkippingChown(report.fixCommand)
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("An unreadable providers.json blocks: BYOK models read it at startup")
    func unreadableProvidersFileBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("providers.json", mode: 0o000)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path, environment: [:]).blocksCopilot)
    }

    @Test("Only Copilot's silent exit 1 is blamed on the home, not a signal or other code")
    func onlyExitOneIsDiagnosedAsHomeAccess() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        func category(exitCode: Int) -> AgentRuntimeFailureCategory {
            AgentRuntimeFailureDiagnostic.classify(
                runtime: .copilotCLI, model: "gpt-5", exitCode: exitCode,
                rawError: "", providerVersion: nil, stream: nil,
                copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: home.path) }
            ).category
        }

        #expect(category(exitCode: 1) == .providerHomeAccessDenied)
        #expect(category(exitCode: 137) == .providerProcessFailed)
        #expect(category(exitCode: 2) == .providerProcessFailed)
    }

    @Test("An unreadable settings.json only warns: Copilot ignores it")
    func unreadableSettingsOnlyWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("settings.json", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)
        #expect(report.problems.map(\.access) == [.unreadable])
        #expect(!report.blocksCopilot)
    }

    @Test("The legacy permissions file is ignored when the current one exists")
    func legacyPermissionsIgnoredBesideCurrent() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("permissions-config", mode: 0o000)
        try home.write("permissions-config.json", mode: 0o600)

        #expect(!CopilotHomeAccessCheck.inspect(home: home.path).blocksCopilot)
    }

    @Test("COPILOT_PROVIDERS_CONFIG replaces providers.json in the check")
    func providersOverrideReplacesDefault() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("providers.json", mode: 0o000)
        let override = try home.write("my-providers.json", mode: 0o600)
        let environment = [CopilotHomeAccessCheck.providersOverrideVariable: override]

        #expect(!CopilotHomeAccessCheck.inspect(home: home.path, environment: environment).blocksCopilot)

        try home.setMode(0o000, of: override)
        let broken = CopilotHomeAccessCheck.inspect(home: home.path, environment: environment)
        #expect(broken.blocksCopilot)
        #expect(broken.problems.contains { $0.path == override && $0.blocksCopilot })
    }

    @Test("A writable file gets read and write back; a read-only config keeps its write bit off")
    func repairKeepsReadOnlyConfigsReadOnly() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        let store = try home.write("session-store.db", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.fixCommand == "chmod u+rw '\(store)' && chmod u+r '\(config)'")
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        let mode = try FileManager.default.attributesOfItem(atPath: config)[.posixPermissions] as? Int
        #expect(mode == 0o400)
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("An unreadable session-state is repaired down to the resumed session it hides")
    func unreadableSessionStateRepairReachesSession() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let sessions = try home.makeDirectory("session-state", mode: 0o755)
        let resumed = (sessions as NSString).appendingPathComponent("abc")
        try FileManager.default.createDirectory(atPath: resumed, withIntermediateDirectories: false)
        try home.setMode(0o000, of: resumed)
        try home.setMode(0o000, of: sessions)
        defer { try? home.setMode(0o755, of: sessions); try? home.setMode(0o755, of: resumed) }

        let report = CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc")

        #expect(report.problems.first?.hidesChildren == true)
        #expect(report.fixCommand.contains("chmod -R u+rwX '\(sessions)'"))
        try Self.runSkippingChown(report.fixCommand)
        #expect(!CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc").blocksCopilot)
    }

    @Test("A folder-shaped providers override gets an unused backup name too")
    func providersOverrideWrongTypeGetsUnusedBackup() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let override = try home.makeDirectory("providers-override", mode: 0o755)
        try home.write("providers-override.bak", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(
            home: home.path, environment: [CopilotHomeAccessCheck.providersOverrideVariable: override]
        )

        let problem = try #require(report.problems.first { $0.path == override })
        #expect(problem.access == .wrongType)
        #expect(problem.backupPath == "\(override).bak-2")
        #expect(report.fixCommand.contains("mv -n '\(override)' '\(override).bak-2'"))
    }

    @Test("A FIFO where a config file belongs blocks as a special file")
    func fifoConfigBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let fifo = (home.path as NSString).appendingPathComponent("config.json")
        #expect(mkfifo(fifo, 0o600) == 0)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first)
        #expect(problem.access == .wrongType)
        #expect(problem.isSpecialFile)
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("special file (FIFO, socket or device), but Copilot expects a regular file"))
    }

    @Test("A home linked to a folder the user does not own never gets a chown or chmod")
    func foreignLinkedHomeGetsNoCommands() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let target = try root.makeDirectory("someone-elses", mode: 0o755)
        let config = (target as NSString).appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: config))
        try root.setMode(0o000, of: config)
        defer { try? root.setMode(0o600, of: config) }
        let link = (root.path as NSString).appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        // Another uid stands in for "the link target belongs to someone else".
        let report = CopilotHomeAccessCheck.inspect(home: link, currentUserID: getuid() + 1)

        #expect(report.blocksCopilot)
        #expect(report.problems.allSatisfy { !$0.isRepairable })
        #expect(report.fixCommand.isEmpty)
        #expect(report.remediation.contains("links to a folder you do not own"))
    }

    @Test("A linked home the user cannot read is advised, not recursively chowned")
    func unreadableLinkedHomeIsAdvised() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let target = try root.makeDirectory("locked", mode: 0o000)
        defer { try? root.setMode(0o755, of: target) }
        let link = (root.path as NSString).appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let report = CopilotHomeAccessCheck.inspect(home: link, currentUserID: getuid() + 1)

        #expect(report.problems.map(\.path) == [link])
        #expect(report.blocksCopilot)
        #expect(report.fixCommand.isEmpty)
        #expect(report.remediation.contains("readable again, or replace the link at"))
    }

    @Test("Hidden session state gets write back; the home's recursive repair stays read-only")
    func hiddenStateRepairRestoresWrite() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let sessions = try home.makeDirectory("session-state", mode: 0o755)
        let resumed = (sessions as NSString).appendingPathComponent("abc")
        try FileManager.default.createDirectory(atPath: resumed, withIntermediateDirectories: false)
        try home.setMode(0o000, of: resumed)
        try home.setMode(0o000, of: sessions)
        defer { try? home.setMode(0o755, of: sessions); try? home.setMode(0o755, of: resumed) }

        let report = CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc")
        #expect(report.fixCommand.contains("chmod -R u+rwX '\(sessions)'"))
        try Self.runSkippingChown(report.fixCommand)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc").isClean)
    }

    @Test("A sharing ACL is kept when the mode bits are what deny the owner")
    func sharingACLKeptWhenModeBitsDeny() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        try Self.shell("/bin/chmod", ["+a", "user:nobody allow read", config])

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.first?.hasACL == false)
        #expect(!report.fixCommand.contains("chmod -N"))
    }

    @Test("The providers override is checked even before the home exists, and only once")
    func providersOverrideCheckedOnce() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let missingHome = (root.path as NSString).appendingPathComponent(".copilot")
        let override = try root.write("providers.json", mode: 0o000)

        let absent = CopilotHomeAccessCheck.inspect(
            home: missingHome, environment: [CopilotHomeAccessCheck.providersOverrideVariable: override]
        )
        #expect(absent.problems.map(\.path) == [override])
        #expect(absent.blocksCopilot)

        // An override inside the home is one problem, repaired read-only.
        try FileManager.default.createDirectory(atPath: missingHome, withIntermediateDirectories: false)
        let inside = (missingHome as NSString).appendingPathComponent("registry.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: inside))
        try root.setMode(0o000, of: inside)
        let report = CopilotHomeAccessCheck.inspect(
            home: missingHome, environment: [CopilotHomeAccessCheck.providersOverrideVariable: inside]
        )
        #expect(report.problems.filter { $0.path == inside }.count == 1)
        #expect(report.fixCommand == "chmod u+r '\(inside)'")
        try root.setMode(0o600, of: inside)
    }

    @Test("A readable providers override outside the home warns about sandboxed policies")
    func providersOverrideOutsideHomeWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let elsewhere = try FakeCopilotHome()
        defer { elsewhere.remove() }
        let override = try elsewhere.write("providers.json", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(
            home: home.path, environment: [CopilotHomeAccessCheck.providersOverrideVariable: override]
        )

        #expect(report.problems.map(\.access) == [.linksOutsideHome])
        #expect(!report.blocksCopilot)
        #expect(report.cause.contains("COPILOT_PROVIDERS_CONFIG names"))
        #expect(report.remediation.contains("keep the providers file inside the Copilot folder"))
    }

    @Test("A resumed session linked outside the home is reported against the sandbox boundary")
    func resumedSessionLinkOutsideHomeWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let elsewhere = try FakeCopilotHome()
        defer { elsewhere.remove() }
        let sessions = try home.makeDirectory("session-state", mode: 0o755)
        let outside = try elsewhere.makeDirectory("abc", mode: 0o755)
        try FileManager.default.createSymbolicLink(
            atPath: (sessions as NSString).appendingPathComponent("abc"), withDestinationPath: outside
        )

        let report = CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc")

        #expect(report.problems.map(\.access) == [.linksOutsideHome])
    }

    @Test("The launch gate uses the launch's own providers override and resumed session")
    func launchBlockerUsesLaunchEnvironment() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        let stale = try home.write("stale-providers.json", mode: 0o000)
        let active = try home.write("active-providers.json", mode: 0o600)
        let variable = CopilotHomeAccessCheck.providersOverrideVariable

        // The launch's override replaces a stale process-level one.
        #expect(CopilotHomeAccessCheck.launchBlocker(
            home: home.path, resumeSessionID: nil, environment: [variable: active], workingDirectory: nil
        ) == nil)
        let blocked = try #require(CopilotHomeAccessCheck.launchBlocker(
            home: home.path, resumeSessionID: nil, environment: [variable: stale], workingDirectory: nil
        ))
        #expect(blocked.state == .blocked)
        #expect(blocked.checks.first?.id == CopilotHomeAccessCheck.readinessCheckID)

        // A warning (an unwritable state folder) never stops a launch.
        try home.makeDirectory("session-state", mode: 0o555)
        #expect(CopilotHomeAccessCheck.launchBlocker(
            home: home.path, resumeSessionID: nil, environment: [variable: active], workingDirectory: nil
        ) == nil)
    }

    @Test("The chown in a fix keeps the entry's group")
    func chownKeepsGroup() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.fixCommand.hasPrefix("sudo chown \"$USER\" '"))
        #expect(!report.fixCommand.contains(":staff"))
    }

    @Test("A providers override outside the home is never chowned, chmod-ed or moved")
    func externalOverrideIsNeverRepaired() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let elsewhere = try FakeCopilotHome()
        defer { elsewhere.remove() }
        let unreadable = try elsewhere.write("providers.json", mode: 0o000)
        let folder = try elsewhere.makeDirectory("providers-dir", mode: 0o755)
        let variable = CopilotHomeAccessCheck.providersOverrideVariable

        for override in [unreadable, folder] {
            let report = CopilotHomeAccessCheck.inspect(
                home: home.path, environment: [variable: override], currentUserID: getuid() + 1
            )
            #expect(report.blocksCopilot)
            #expect(report.fixCommand.isEmpty, "\(override)")
            #expect(report.remediation.contains("ASTRA suggests no command for it"))
        }
    }

    @Test("A relative providers override is resolved against the launch's working directory")
    func relativeOverrideUsesWorkingDirectory() throws {
        let workspace = try FakeCopilotHome()
        defer { workspace.remove() }
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try workspace.makeDirectory("config", mode: 0o755)
        let registry = (workspace.path as NSString).appendingPathComponent("config/providers.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: registry))
        try workspace.setMode(0o000, of: registry)
        defer { try? workspace.setMode(0o600, of: registry) }
        let environment = [CopilotHomeAccessCheck.providersOverrideVariable: "config/providers.json"]

        let report = CopilotHomeAccessCheck.inspect(
            home: home.path, environment: environment, workingDirectory: workspace.path
        )

        #expect(report.problems.map(\.path) == [registry])
        #expect(report.blocksCopilot)
    }

    @Test("A locked state file is unwritable even when its mode allows writing")
    func lockedStateFileIsUnwritable() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let store = try home.write("session-store.db", mode: 0o600)
        try Self.shell("/usr/bin/chflags", ["uchg", store])

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first)
        #expect(problem.access == .unwritable)
        #expect(problem.hasLockFlag)
        #expect(report.cause.contains("locked"))
        #expect(report.fixCommand.hasPrefix("chflags -h nouchg,nouappnd '\(store)'"))
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("Readiness only warns about providers.json; the launch gate decides with the task's environment")
    func providersFileBlocksOnlyAtLaunch() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.write("providers.json", mode: 0o000)
        let usable = try home.write("skill-providers.json", mode: 0o600)
        let service = await Self.readyCopilotService(home: home.path)

        let readiness = await service.check(configuration: Self.copilotConfiguration)
        #expect(readiness.state == .warning)

        #expect(CopilotHomeAccessCheck.launchBlocker(
            home: home.path, resumeSessionID: nil, environment: [:], workingDirectory: nil
        ) != nil)
        #expect(CopilotHomeAccessCheck.launchBlocker(
            home: home.path, resumeSessionID: nil,
            environment: [CopilotHomeAccessCheck.providersOverrideVariable: usable], workingDirectory: nil
        ) == nil)
    }

    @Test("A symlinked state file whose target is locked is unwritable")
    func lockedSymlinkTargetIsUnwritable() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let real = try home.write("store-real.db", mode: 0o600)
        let link = (home.path as NSString).appendingPathComponent("session-store.db")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try Self.shell("/usr/bin/chflags", ["uchg", real])

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first { $0.path == link })
        #expect(problem.access == .unwritable)
        #expect(problem.hasLockFlag)
    }

    @Test("A locked file-shaped home is unlocked before it is moved aside")
    func lockedMisplacedHomeIsUnlockedFirst() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let notAFolder = try root.write("copilot-home", mode: 0o600)
        try Self.shell("/usr/bin/chflags", ["uchg", notAFolder])

        let report = CopilotHomeAccessCheck.inspect(home: notAFolder)

        #expect(report.fixCommand
            == "chflags -h nouchg,nouappnd '\(notAFolder)' && mv -n '\(notAFolder)' '\(notAFolder).bak'")
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(!FileManager.default.fileExists(atPath: notAFolder))
    }

    @Test("A denying ACL on another user's entry is removed after the chown")
    func foreignDenyingACLIsRemoved() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let store = try home.write("session-store.db", mode: 0o600)
        try Self.shell("/bin/chmod", ["+a", "user:\(NSUserName()) deny read", store])

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.problems.first?.hasACL == true)
        #expect(report.fixCommand
            == "sudo chown \"$USER\" '\(store)' && chmod -N '\(store)' && chmod u+rw '\(store)'")
    }

    @Test("A missing home under a locked parent blocks and the parent is unlocked")
    func lockedParentBlocksHomeCreation() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let parent = try root.makeDirectory("parent", mode: 0o755)
        try Self.shell("/usr/bin/chflags", ["uchg", parent])
        let missingHome = (parent as NSString).appendingPathComponent(".copilot")

        let report = CopilotHomeAccessCheck.inspect(home: missingHome)

        #expect(report.problems.map(\.access) == [.cannotCreateHome])
        #expect(report.blocksCopilot)
        #expect(report.fixCommand.hasPrefix("chflags -h nouchg,nouappnd '\(parent)'"))
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(CopilotHomeAccessCheck.inspect(home: missingHome).isClean)
    }

    @Test("An unreadable folder Copilot does not write below gets read access back, not write")
    func unknownHiddenFolderGetsReadOnlyRepair() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let agents = try home.makeDirectory("agents", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.fixCommand.contains("chmod -R u+rX '\(agents)'"))
        #expect(!report.fixCommand.contains("u+rwX"))
    }

    @Test("A locked dangling home link is unlocked with -h before it is moved")
    func lockedDanglingLinkIsUnlockedFirst() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let link = (root.path as NSString).appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: (root.path as NSString).appendingPathComponent("gone")
        )
        try Self.shell("/usr/bin/chflags", ["-h", "uchg", link])

        let report = CopilotHomeAccessCheck.inspect(home: link)

        #expect(report.fixCommand == "chflags -h nouchg,nouappnd '\(link)' && mv -n '\(link)' '\(link).bak'")
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect((try? FileManager.default.attributesOfItem(atPath: link)) == nil)
    }

    @Test("An override inside a linked home the user does not own gets no command either")
    func overrideUnderUntrustedLinkedHomeIsNotRepaired() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let target = try root.makeDirectory("someone-elses", mode: 0o755)
        let registry = (target as NSString).appendingPathComponent("providers.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: registry))
        try root.setMode(0o000, of: registry)
        defer { try? root.setMode(0o600, of: registry) }
        let link = (root.path as NSString).appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        // Another uid stands in for "the link target belongs to someone else".
        let report = CopilotHomeAccessCheck.inspect(
            home: link,
            environment: [CopilotHomeAccessCheck.providersOverrideVariable: registry],
            currentUserID: getuid() + 1
        )

        #expect(report.blocksCopilot)
        #expect(report.problems.allSatisfy { !$0.isRepairable })
        #expect(report.fixCommand.isEmpty)
    }

    @Test("A repair of an unreadable folder says what it hid will be checked next")
    func hiddenEntriesAreCheckedAfterRepair() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.setMode(0o000, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.remediation.contains("could not be checked; once it is readable ASTRA checks them"))
    }

    @Test("A locked broken startup link is unlocked so it can be replaced")
    func lockedBrokenStartupLinkIsUnlocked() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let link = (home.path as NSString).appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: (home.path as NSString).appendingPathComponent("missing.json")
        )
        try Self.shell("/usr/bin/chflags", ["-h", "uchg", link])

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        let problem = try #require(report.problems.first { $0.path == link })
        #expect(problem.linkIsLocked)
        #expect(report.fixCommand == "chflags -h nouchg,nouappnd '\(link)'")
        #expect(report.remediation.contains("replace the link at"))
        try Self.shell("/bin/sh", ["-c", report.fixCommand])
        #expect(!CopilotHomeAccessCheck.lockState(of: link, followLinks: false).any)
    }

    @Test("A home symlink loop blocks like a dangling link")
    func homeLinkLoopBlocks() throws {
        let root = try FakeCopilotHome()
        defer { root.remove() }
        let link = (root.path as NSString).appendingPathComponent("home-loop")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: link)

        let report = CopilotHomeAccessCheck.inspect(home: link)

        #expect(report.problems.map(\.access) == [.danglingLink])
        #expect(report.problems.first?.isLinkLoop == true)
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("loops back on itself"))
        #expect(report.fixCommand == "mv -n '\(link)' '\(link).bak'")
    }

    @Test("The fix covers every problem even when the explanation is capped")
    func fixCoversEveryProblem() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let names = ["config.json", "mcp-config.json", "settings.json", "permissions-config.json",
                     "permissions-config", "session-store.db", "session-store.db-wal"]
        let paths = try names.map { try home.write($0, mode: 0o000) }

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.count == names.count)
        #expect(report.cause.contains("and 2 more"))
        for path in paths {
            #expect(report.fixCommand.contains("'\(path)'"))
        }
    }

    @Test("Blank plain-text stdout lines do not hide an unreadable home")
    func blankStreamFramesStillDiagnoseHome() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        let telemetry = AgentRuntimeStreamTelemetry()
        telemetry.recordRawLine(parsesJSONLines: false)

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", runOutput: "", providerVersion: nil, stream: telemetry.snapshot(),
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: home.path) }
        )

        #expect(diagnostic.category == .providerHomeAccessDenied)
    }

    @Test("A startup entry of the wrong type blocks and is moved aside")
    func wrongTypeStartupEntriesBlock() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let configFolder = try home.makeDirectory("config.json", mode: 0o755)
        let sessionFile = try home.write("session-state", mode: 0o600)
        try home.makeDirectory("some-cache", mode: 0o755)
        try home.write("notes.txt", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(Set(report.problems.map(\.path)) == [configFolder, sessionFile])
        #expect(report.problems.allSatisfy { $0.access == .wrongType })
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("config.json is a folder, but Copilot expects a regular file there."))
        #expect(report.cause.contains("session-state is a file, but Copilot expects a folder there."))
        #expect(report.fixCommand.contains("mv -n '\(configFolder)' '\(configFolder).bak'"))
        #expect(report.fixCommand.contains("mv -n '\(sessionFile)' '\(sessionFile).bak'"))
        #expect(!report.fixCommand.contains("chmod"))
    }

    @Test("Only the resumed session folder is checked below session-state")
    func resumedSessionFolderIsChecked() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let sessions = try home.makeDirectory("session-state", mode: 0o755)
        let resumed = (sessions as NSString).appendingPathComponent("abc-123")
        let other = (sessions as NSString).appendingPathComponent("old-456")
        for folder in [resumed, other] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try home.setMode(0o000, of: folder)
        }
        defer { for folder in [resumed, other] { try? home.setMode(0o755, of: folder) } }

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
        let resuming = CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "abc-123")
        #expect(resuming.problems.map(\.path) == [resumed])
        #expect(resuming.blocksCopilot)
        #expect(CopilotHomeAccessCheck.inspect(home: home.path, resumeSessionID: "../session-state").isClean)
    }

    @Test("The composer's cached readiness re-checks the Copilot home on every answer")
    func availabilityCacheRechecksHome() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o600)
        let service = RuntimeProviderAvailabilityService(readinessService: await Self.readyCopilotService(home: home.path))
        let cache = RuntimeReadinessStateCache()
        let configuration = RuntimeProviderAvailabilityConfiguration(
            claudePath: "", copilotPath: "", claudeProvider: .anthropic,
            vertexProjectID: "", vertexRegion: "", vertexOpusModel: "", vertexSonnetModel: "", vertexHaikuModel: ""
        )

        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .ready)

        try home.setMode(0o000, of: config)
        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .blocked)

        // The cache never stored the block, so the repair shows at once too.
        try home.setMode(0o600, of: config)
        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .ready)
        #expect(await cache.states(for: configuration, maxAge: 300)?[.copilotCLI] == .ready)
    }

    @Test("A cached launch verdict re-checks the Copilot home before it is trusted")
    func launchCacheRechecksHome() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o600)
        let service = await Self.readyCopilotService(home: home.path)
        let cache = RuntimeLaunchReadinessCache()

        let probed = await service.check(configuration: Self.copilotConfiguration)
        #expect(probed.state == .ready)
        await cache.record(probed.cacheable, for: Self.copilotConfiguration)

        try home.setMode(0o000, of: config)
        let hit = try #require(await cache.hit(for: Self.copilotConfiguration))
        let refreshed = service.refreshingUncachedChecks(hit.report, runtime: .copilotCLI)
        #expect(refreshed.state == .blocked)
        #expect(refreshed.checks.contains { $0.id == CopilotHomeAccessCheck.readinessCheckID })
        // A blocked report must never be what the cache keeps.
        #expect(!probed.cacheable.checks.contains { $0.id == CopilotHomeAccessCheck.readinessCheckID })
    }

    @Test("Once ownership is back, the rest of the fix command restores access")
    func fixCommandRestoresPermissionBits() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        try home.makeDirectory("session-state", mode: 0o555)
        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)
        #expect(report.problems.count == 2)

        // The test already owns the entries, so the `sudo chown` step is the
        // one part it can skip; a chown alone would leave both still broken.
        let afterChown = report.fixCommand
            .components(separatedBy: " && ")
            .filter { !$0.hasPrefix("sudo chown") }
            .joined(separator: " && ")
        #expect(afterChown.contains("chmod"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", afterChown]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("Copilot readiness reports Needs setup when its config is unreadable")
    func readinessBlocksOnUnreadableConfig() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.98\n", stderr: "")
        )
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" },
            copilotStateHome: home.path
        )

        let report = await service.check(configuration: Self.copilotConfiguration)

        #expect(report.state == .blocked)
        let check = try #require(report.checks.first { $0.id == "copilot-home-access" })
        #expect(check.state == .blocked)
        #expect(check.detail.contains("config.json"))
        #expect(check.remediation?.contains("chmod u+r ") == true)

        try home.setMode(0o600, of: (home.path as NSString).appendingPathComponent("config.json"))
        let repaired = await service.check(configuration: Self.copilotConfiguration)
        #expect(repaired.state == .ready)
        #expect(!repaired.checks.contains { $0.id == "copilot-home-access" })
    }

    @Test("A silent Copilot exit with an unreadable home names the cause and the fix")
    func silentExitNamesHomeAccessCause() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        let inspect = { CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1) }

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 1,
            rawError: "",
            runOutput: "",
            providerVersion: "1.0.98",
            stream: nil,
            copilotHomeAccess: inspect
        )

        #expect(diagnostic.category == .providerHomeAccessDenied)
        #expect(diagnostic.userMessage.contains("config.json"))
        #expect(diagnostic.userMessage.contains("sudo chown \"$USER\" '\(config)'"))
        #expect(diagnostic.summarySource == .fallback)
        #expect(!diagnostic.redactedSummary.isEmpty)
        let payload = diagnostic.userFacingPayload(prefix: "Copilot exited with code 1.")
        #expect(!payload.contains("failed before ASTRA received a visible assistant response"))
        #expect(diagnostic.auditFields(phase: "start", stream: nil)["failure_category"] == "provider_home_access_denied")
        #expect(AgentRuntimeWorker.durableFailureStopReason(category: diagnostic.category).rawValue
            == "provider_home_access_denied")
    }

    @Test("Any provider evidence or a clean home keeps the existing classification")
    func homeAccessOnlyExplainsSilentFailures() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        var inspections = 0
        let inspect = { () -> CopilotHomeAccessReport in
            inspections += 1
            return CopilotHomeAccessCheck.inspect(home: home.path)
        }

        let withStderr = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "Error: something else broke", providerVersion: nil, stream: nil,
            copilotHomeAccess: inspect
        )
        #expect(withStderr.category == .providerProcessFailed)
        #expect(inspections == 0)

        let withOutput = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", runOutput: "partial answer", providerVersion: nil, stream: nil,
            copilotHomeAccess: inspect
        )
        #expect(withOutput.category == .providerProcessFailed)
        #expect(inspections == 0)

        let healthy = try FakeCopilotHome()
        defer { healthy.remove() }
        try healthy.write("config.json", mode: 0o600)
        let clean = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: healthy.path) }
        )
        #expect(clean.category == .providerProcessFailed)
        #expect(clean.userMessage.contains("failed before ASTRA received a visible assistant response"))
    }

    /// Runs a fix without its `sudo chown` step: the test already owns
    /// everything, and cannot sudo.
    private static func runSkippingChown(_ command: String) throws {
        let rest = command.components(separatedBy: " && ").filter { !$0.hasPrefix("sudo chown") }
        try shell("/bin/sh", ["-c", rest.joined(separator: " && ")])
    }

    private static func shell(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(executable) \(arguments)")
    }

    /// A readiness service whose Copilot CLI probe always answers, so the
    /// home check alone decides the verdict.
    private static func readyCopilotService(home: String) async -> RuntimeReadinessService {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.98\n", stderr: "")
        )
        return RuntimeReadinessService(
            runner: runner,
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" },
            copilotStateHome: home
        )
    }

    private static let copilotConfiguration = RuntimeReadinessConfiguration(
        runtime: .copilotCLI,
        claudePath: "",
        copilotPath: "",
        claudeProvider: .anthropic,
        vertexProjectID: "",
        vertexRegion: "",
        vertexOpusModel: "",
        vertexSonnetModel: "",
        vertexHaikuModel: ""
    )
}

/// A temp folder standing in for `~/.copilot`. `remove()` restores owner
/// permissions first so a mode-000 entry cannot leak a folder per run.
struct FakeCopilotHome {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-home-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, mode: Int) throws -> String {
        let file = (path as NSString).appendingPathComponent(name)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        try setMode(mode, of: file)
        return file
    }

    @discardableResult
    func makeDirectory(_ name: String, mode: Int) throws -> String {
        let directory = (path as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try setMode(mode, of: directory)
        return directory
    }

    func setMode(_ mode: Int, of target: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
    }

    func remove() {
        try? setMode(0o700, of: path)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            let childPath = (path as NSString).appendingPathComponent(child)
            _ = lchflags(childPath, 0)
            try? setMode(0o700, of: childPath)
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
