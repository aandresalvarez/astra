import SwiftUI
import SwiftData
import ASTRACore

enum ConfigureTab: String, CaseIterable {
    case capabilities = "Capabilities"
    case connectors = "Connectors"
    case tools = "Tools"
    case skills = "Skills"
    case templates = "Templates"

    var icon: String {
        switch self {
        case .capabilities: return "square.grid.2x2"
        case .connectors: return "bolt.horizontal.circle"
        case .tools: return "wrench.and.screwdriver"
        case .skills: return "puzzlepiece.extension"
        case .templates: return "rectangle.3.group"
        }
    }

    var color: Color {
        switch self {
        case .capabilities: return Stanford.cardinalRed
        case .connectors: return Stanford.paloAltoGreen
        case .tools: return Stanford.tools
        case .skills: return Stanford.lagunita
        case .templates: return Stanford.poppy
        }
    }

    var subtitle: String {
        switch self {
        case .capabilities: return "Install & Enable"
        case .connectors: return "APIs & Services"
        case .tools: return "Scripts & MCP"

        case .skills: return "Intent & Behavior"
        case .templates: return "Multi-Phase Workflows"
        }
    }

}

struct ConfigureView: View {
    var workspace: Workspace
    var initialTab: ConfigureTab = .capabilities
    var focusItemID: UUID?
    var focusCapabilityPackageID: String?
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]
    @State private var selectedTab: ConfigureTab = .capabilities
    @State private var selectedFocusItemID: UUID?
    @State private var selectedFocusCapabilityPackageID: String?
    @State private var libraryCapabilityPackages: [PluginPackage] = []

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var catalogPolicyContext: CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            isAdmin: true,
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    private var enabledCapabilityCount: Int {
        var activeIDs = Set(workspace.enabledCapabilityIDs)
        for package in configureCapabilityPackages where packageState(package).isEnabled {
            activeIDs.insert(package.id)
        }
        return activeIDs.count
    }

    private var configureCapabilityPackages: [PluginPackage] {
        CapabilityGalleryInventory.managementPackages(
            catalogPackages: libraryCapabilityPackages + PluginCatalog.builtInPackages,
            capabilities: capabilities,
            workspace: workspace,
            policyContext: catalogPolicyContext
        )
    }

    private func count(for tab: ConfigureTab) -> Int {
        switch tab {
        case .capabilities:
            enabledCapabilityCount
        case .connectors:
            capabilities.activeConnectors.count
        case .tools:
            capabilities.activeTools.count
        case .skills:
            capabilities.activeSkills.count
        case .templates:
            workspace.templates.count
        }
    }

    private func packageState(_ package: PluginPackage) -> CapabilityPackageState {
        CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )
    }

    private var headerTitle: String {
        selectedTab == .capabilities ? "Manage Capabilities" : selectedTab.rawValue
    }

    private var headerSubtitle: String {
        if selectedTab == .capabilities {
            return "\(workspace.name) · \(configureCapabilityPackages.count) available · \(enabledCapabilityCount) enabled"
        }
        return "\(workspace.name) · \(selectedTab.subtitle)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: selectedTab.icon)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(headerSubtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            configureContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1040, idealWidth: 1180, maxWidth: 1320, minHeight: 760, idealHeight: 880)
        .onAppear {
            selectedTab = initialTab
            selectedFocusItemID = focusItemID
            selectedFocusCapabilityPackageID = focusCapabilityPackageID
            reloadCapabilityPackages()
        }
    }

    private func reloadCapabilityPackages() {
        libraryCapabilityPackages = PerformanceTelemetry.measure(
            "configure_capability_load",
            thresholdMilliseconds: 0
        ) {
            CapabilityLibrary().installedPackages()
        }
        PerformanceTelemetry.log(
            "configure_capability_count",
            fields: ["package_count": String(libraryCapabilityPackages.count)]
        )
    }

    @ViewBuilder
    private var configureContent: some View {
        switch selectedTab {
        case .capabilities:
            CapabilitiesTabContent(
                workspace: workspace,
                focusPackageID: selectedFocusCapabilityPackageID,
                onCatalogChanged: { reloadCapabilityPackages() },
                onPackageFocusChanged: { selectedFocusCapabilityPackageID = $0 },
                onEditElement: { tab, itemID in
                    selectedFocusItemID = itemID
                    selectedFocusCapabilityPackageID = nil
                    selectedTab = tab
                }
            )
        case .connectors:
            resourceConfigurationContent(.connectors) {
                ConnectorsTabContent(
                    workspace: workspace,
                    focusItemID: selectedFocusItemID,
                    onManageCapabilities: showCapabilities
                )
            }
        case .tools:
            resourceConfigurationContent(.tools) {
                ToolsTabContent(workspace: workspace, focusItemID: selectedFocusItemID)
            }
        case .skills:
            resourceConfigurationContent(.skills) {
                SkillsTabContent(
                    workspace: workspace,
                    focusItemID: selectedFocusItemID,
                    onManageCapabilities: showCapabilities
                )
            }
        case .templates:
            resourceConfigurationContent(.templates) {
                TemplatesTabContent(workspace: workspace, focusItemID: selectedFocusItemID)
            }
        }
    }

    private func resourceConfigurationContent<Content: View>(
        _ tab: ConfigureTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showCapabilities()
                } label: {
                    Label("Capabilities", systemImage: "chevron.left")
                        .font(Stanford.caption(12).weight(.medium))
                }
                .buttonStyle(.plain)

                ConfigureCardIcon(systemName: tab.icon, color: tab.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.rawValue)
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(tab.subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(count(for: tab)) active")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            content()
        }
    }

    private func showCapabilities() {
        selectedFocusItemID = nil
        selectedFocusCapabilityPackageID = nil
        selectedTab = .capabilities
    }
}

private struct ConfigureSelectionList<Content: View>: View {
    let maxContentWidth: CGFloat
    @ViewBuilder let content: Content

    init(maxContentWidth: CGFloat = 640, @ViewBuilder content: () -> Content) {
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConfigureSelectionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    private let columns = [
        GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 12, alignment: .top)
    ]

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfigureSelectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.018)))
        .overlay {
            shape.stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
        .clipShape(shape)
    }
}

private struct ConfigureCardIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(Stanford.ui(14, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ConfigureCardChip: View {
    let title: String
    var color: Color? = nil

    var body: some View {
        Text(title)
            .font(Stanford.caption(10))
            .foregroundStyle(color ?? Stanford.coolGrey)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((color ?? Color.primary).opacity(color == nil ? 0.04 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Capabilities Tab

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    var focusPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onPackageFocusChanged: (String?) -> Void = { _ in }
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }
    @State private var catalog = PluginCatalog()

    var body: some View {
        PluginCatalogView(
            workspace: workspace,
            catalog: catalog,
            focus: .all,
            presentation: .embedded,
            focusedPackageID: focusPackageID,
            onCatalogChanged: onCatalogChanged,
            onPackageFocusChanged: onPackageFocusChanged,
            onEditElement: onEditElement
        )
    }
}

// MARK: - Capability Creation Wizard

struct CapabilityCreationWizardView: View {
    enum Step: String, CaseIterable {
        case tools = "Tools"
        case connectors = "Connectors"
        case behavior = "Behavior"
        case scope = "Scope"
        case validate = "Validate"
    }

    var workspace: Workspace
    var onCreated: (PluginPackage, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @State private var selectedStep: Step = .tools
    @State private var name = "New Capability"
    @State private var capabilityDescription = ""
    @State private var behaviorInstructions = ""
    @State private var selectedToolIDs: Set<UUID> = []
    @State private var selectedDetectedCLIIDs: Set<String> = []
    @State private var detectedCLIStatuses: [String: HealthStatus] = [:]
    @State private var isDetectingCLIs = false
    @State private var selectedConnectorIDs: Set<UUID> = []
    @State private var draftConnectors: [Connector] = []
    @State private var draftConnectorName = ""
    @State private var draftConnectorDescription = ""
    @State private var draftConnectorServiceType = "custom"
    @State private var draftConnectorAuthMethod = "none"
    @State private var draftConnectorBaseURL = ""
    @State private var draftConnectorCredentialKeys = ""
    @State private var draftConnectorConfigLines = ""
    @State private var allowedTools = "Read, Grep"
    @State private var installEnabled = true

    private var availableTools: [LocalTool] {
        uniqueTools(workspace.localTools + globalTools)
    }

    private var availableCLICandidates: [CapabilityToolDetector.Candidate] {
        let existingCommands = Set(availableTools.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) })
        return CapabilityToolDetector.knownCandidates.filter { !existingCommands.contains($0.command) }
    }

    private var availableConnectors: [Connector] {
        uniqueConnectors(workspace.connectors + globalConnectors + draftConnectors)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!selectedToolIDs.isEmpty ||
         !selectedDetectedCLIIDs.isEmpty ||
         !selectedConnectorIDs.isEmpty ||
         !behaviorInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ConfigureCardIcon(systemName: "puzzlepiece.extension", color: ConfigureTab.capabilities.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Capability")
                        .font(Stanford.heading(18))
                    Text(name)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Picker("", selection: $selectedStep) {
                ForEach(Step.allCases, id: \.self) { step in
                    Text(step.rawValue).tag(step)
                }
            }
            .pickerStyle(.segmented)
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedStep {
                    case .tools:
                        selectableTools
                    case .connectors:
                        selectableConnectors
                    case .behavior:
                        behaviorStep
                    case .scope:
                        scopeStep
                    case .validate:
                        validateStep
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    createCapability()
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.capabilities.color)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 620, height: 620)
    }

    private var selectableTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityFields
            selectionSection(
                title: "Local Tools",
                empty: "No tools available",
                items: availableTools,
                isSelected: { selectedToolIDs.contains($0.id) },
                toggle: { toggle($0.id, in: &selectedToolIDs) },
                title: { $0.name.isEmpty ? "Untitled Tool" : $0.name },
                subtitle: { $0.displayCommand.isEmpty ? $0.toolType.uppercased() : $0.displayCommand },
                icon: { LocalTool.iconForType($0.toolType) }
            )
            detectedCLISection
        }
    }

    private var selectableConnectors: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionSection(
                title: "Connectors",
                empty: "No connectors available",
                items: availableConnectors,
                isSelected: { selectedConnectorIDs.contains($0.id) },
                toggle: { toggle($0.id, in: &selectedConnectorIDs) },
                title: { $0.name.isEmpty ? "Untitled Connector" : $0.name },
                subtitle: { $0.displaySummary },
                icon: { $0.icon }
            )
            connectorCreationSection
        }
    }

    private var detectedCLISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Detected CLI Tools")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    detectCLIs()
                } label: {
                    Label(isDetectingCLIs ? "Checking" : "Check CLIs", systemImage: "magnifyingglass")
                        .font(Stanford.caption(12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDetectingCLIs || availableCLICandidates.isEmpty)
            }

            if availableCLICandidates.isEmpty {
                Text("Known CLI tools are already defined in this workspace or shared library.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(availableCLICandidates) { candidate in
                        let selected = selectedDetectedCLIIDs.contains(candidate.id)
                        let status = detectedCLIStatuses[candidate.id]
                        let unavailable = isMissing(status)

                        Button {
                            toggle(candidate.id, in: &selectedDetectedCLIIDs)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "terminal")
                                    .font(Stanford.ui(14))
                                    .foregroundStyle(ConfigureTab.tools.color)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name)
                                        .font(Stanford.body(13).weight(.medium))
                                    Text(candidate.description)
                                        .font(Stanford.caption(11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ConfigureCardChip(
                                    title: statusLabel(status),
                                    color: statusColor(status)
                                )
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? ConfigureTab.tools.color : Color.secondary.opacity(0.45))
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(unavailable)
                    }
                }
            }
        }
    }

    private var connectorCreationSection: some View {
        DisclosureGroup("Create Connector") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Connector name", text: $draftConnectorName)
                    .textFieldStyle(.roundedBorder)
                TextField("Description", text: $draftConnectorDescription)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Picker("Type", selection: $draftConnectorServiceType) {
                        ForEach(connectorServiceOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    Picker("Auth", selection: $draftConnectorAuthMethod) {
                        ForEach(connectorAuthOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                }

                TextField("Base URL", text: $draftConnectorBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
                TextField("Credential keys, comma-separated", text: $draftConnectorCredentialKeys)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Config values")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draftConnectorConfigLines)
                        .font(Stanford.ui(13, design: .monospaced))
                        .frame(minHeight: 70)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }

                HStack {
                    Spacer()
                    Button {
                        addDraftConnector()
                    } label: {
                        Label("Add Connector", systemImage: "plus")
                            .font(Stanford.body(13))
                    }
                    .buttonStyle(.bordered)
                    .disabled(draftConnectorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 8)
        }
        .font(Stanford.body(13).weight(.medium))
    }

    private var behaviorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityFields
            VStack(alignment: .leading, spacing: 6) {
                Text("Allowed Tools")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                TextField("Read, Grep, Bash", text: $allowedTools)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Behavior Instructions")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                TextEditor(text: $behaviorInstructions)
                    .font(Stanford.ui(13, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Install in app-local capability library", isOn: .constant(true))
                .disabled(true)
            Toggle("Enable in this workspace", isOn: $installEnabled)
            HStack(spacing: 6) {
                ConfigureCardChip(title: CapabilityLibrary.capabilitiesDirectory().lastPathComponent, color: ConfigureTab.capabilities.color)
                ConfigureCardChip(title: workspace.name)
            }
        }
    }

    private var validateStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            validationRow("Name", name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Ready")
            validationRow("Tools", "\(selectedToolIDs.count + selectedDetectedCLIIDs.count) selected")
            if !selectedDetectedCLIIDs.isEmpty {
                ForEach(availableCLICandidates.filter { selectedDetectedCLIIDs.contains($0.id) }) { candidate in
                    validationRow(candidate.command, statusLabel(detectedCLIStatuses[candidate.id]))
                }
            }
            validationRow("Connectors", "\(selectedConnectorIDs.count) selected")
            validationRow("Behavior", behaviorInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : "Ready")
            validationRow("Scope", installEnabled ? "Install and enable here" : "Install only")
        }
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Capability name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Description", text: $capabilityDescription)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var connectorServiceOptions: [(String, String)] {
        [
            ("custom", "Custom"),
            ("jira", "Jira"),
            ("github", "GitHub"),
            ("slack", "Slack"),
            ("database", "Database"),
            ("rest_api", "REST API"),
            ("confluence", "Confluence"),
            ("redcap", "REDCap")
        ]
    }

    private var connectorAuthOptions: [(String, String)] {
        [
            ("none", "None"),
            ("basic", "Basic"),
            ("bearer", "Bearer"),
            ("api_key", "API Key")
        ]
    }

    private func selectionSection<Item: Identifiable>(
        title: String,
        empty: String,
        items: [Item],
        isSelected: @escaping (Item) -> Bool,
        toggle: @escaping (Item) -> Void,
        title titleText: @escaping (Item) -> String,
        subtitle: @escaping (Item) -> String,
        icon: @escaping (Item) -> String
    ) -> some View where Item.ID == UUID {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if items.isEmpty {
                Text(empty)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        Button { toggle(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(item))
                                    .font(Stanford.ui(14))
                                    .foregroundStyle(ConfigureTab.capabilities.color)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(titleText(item))
                                        .font(Stanford.body(13).weight(.medium))
                                    Text(subtitle(item).isEmpty ? "No details" : subtitle(item))
                                        .font(Stanford.caption(11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: isSelected(item) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected(item) ? ConfigureTab.capabilities.color : Color.secondary.opacity(0.45))
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func validationRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(Stanford.body(13).weight(.medium))
            Spacer()
            Text(value)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func createCapability() {
        let selectedExistingTools = availableTools.filter { selectedToolIDs.contains($0.id) }
        let selectedCandidates = availableCLICandidates.filter { selectedDetectedCLIIDs.contains($0.id) }
        let detectedTools = selectedCandidates.map(CapabilityToolDetector.makeTool)
        let selectedTools = selectedExistingTools + detectedTools
        let selectedConnectors = availableConnectors.filter { selectedConnectorIDs.contains($0.id) }
        let prerequisites = uniquePrerequisites(
            selectedCandidates.map(\.prerequisite) +
            selectedExistingTools.compactMap { CapabilityToolDetector.prerequisite(forCommand: $0.command) }
        )
        let package = CapabilityPackageFactory.makePackage(
            name: name,
            description: capabilityDescription,
            behaviorInstructions: behaviorInstructions,
            allowedTools: allowedTools.split(separator: ",").map(String.init),
            connectors: selectedConnectors,
            localTools: selectedTools,
            prerequisites: prerequisites
        )

        onCreated(package, installEnabled)
        dismiss()
    }

    private func detectCLIs() {
        let candidates = availableCLICandidates
        isDetectingCLIs = true
        Task {
            let statuses = await CapabilityToolDetector().detect(candidates)
            await MainActor.run {
                detectedCLIStatuses = statuses
                selectedDetectedCLIIDs = selectedDetectedCLIIDs.filter { id in
                    !isMissing(statuses[id])
                }
                isDetectingCLIs = false
            }
        }
    }

    private func toggle(_ id: UUID, in ids: inout Set<UUID>) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    private func toggle(_ id: String, in ids: inout Set<String>) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    private func addDraftConnector() {
        let connector = Connector(
            name: draftConnectorName.trimmingCharacters(in: .whitespacesAndNewlines),
            serviceType: draftConnectorServiceType,
            icon: connectorIcon(for: draftConnectorServiceType),
            connectorDescription: draftConnectorDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: draftConnectorBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: draftConnectorAuthMethod
        )
        let credentialKeys = parseCredentialKeys(draftConnectorCredentialKeys)
        connector.credentialKeys = credentialKeys
        connector.credentialValues = Array(repeating: "", count: credentialKeys.count)
        let config = parseConfigLines(draftConnectorConfigLines)
        connector.configKeys = config.keys
        connector.configValues = config.values
        draftConnectors.append(connector)
        selectedConnectorIDs.insert(connector.id)
        draftConnectorName = ""
        draftConnectorDescription = ""
        draftConnectorServiceType = "custom"
        draftConnectorAuthMethod = "none"
        draftConnectorBaseURL = ""
        draftConnectorCredentialKeys = ""
        draftConnectorConfigLines = ""
    }

    private func statusLabel(_ status: HealthStatus?) -> String {
        switch status {
        case .some(.healthy):
            return "Ready"
        case .some(.unauthenticated):
            return "Needs auth"
        case .some(.unresponsive):
            return "Issue"
        case .some(.missingBinary):
            return "Not found"
        case nil:
            return "Not checked"
        }
    }

    private func statusColor(_ status: HealthStatus?) -> Color {
        switch status {
        case .some(.healthy):
            return Stanford.paloAltoGreen
        case .some(.unauthenticated):
            return Stanford.poppy
        case .some(.unresponsive), .some(.missingBinary):
            return Stanford.cardinalRed
        case nil:
            return Stanford.coolGrey
        }
    }

    private func isMissing(_ status: HealthStatus?) -> Bool {
        if case .some(.missingBinary) = status {
            return true
        }
        return false
    }

    private func connectorIcon(for serviceType: String) -> String {
        switch serviceType {
        case "jira": return "list.bullet.rectangle"
        case "github": return "arrow.triangle.branch"
        case "slack": return "bubble.left.and.bubble.right"
        case "database": return "cylinder.split.1x2"
        case "rest_api": return "network"
        case "confluence": return "doc.richtext"
        case "redcap": return "cross.case"
        default: return "network"
        }
    }

    private func parseCredentialKeys(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func parseConfigLines(_ value: String) -> (keys: [String], values: [String]) {
        var keys: [String] = []
        var values: [String] = []
        for rawLine in value.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !key.isEmpty else { continue }
            let configValue = parts.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            keys.append(key)
            values.append(configValue)
        }
        return (keys, values)
    }

    private func uniquePrerequisites(_ prerequisites: [CLIPrerequisite]) -> [CLIPrerequisite] {
        var seen = Set<String>()
        return prerequisites.filter { seen.insert($0.id).inserted }
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        Dictionary(grouping: tools, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        Dictionary(grouping: connectors, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Connectors Tab

struct ConnectorsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    var onManageCapabilities: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @State private var selectedConnector: Connector?
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(workspace: workspace, globalConnectors: globalConnectors)
    }

    private var workspaceConnectors: [Connector] {
        capabilities.workspaceConnectors
    }

    private var sharedLibraryConnectors: [Connector] {
        capabilities.availableGlobalConnectors
    }

    private var hasVisibleConnectors: Bool {
        !workspaceConnectors.isEmpty || !sharedLibraryConnectors.isEmpty
    }

    var body: some View {
        let showingDetail = selectedConnector != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connectors")
                        .font(Stanford.heading(18))
                    Text("APIs & Services")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if showingDetail {
                        Button {
                            selectedConnector = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(Stanford.body(13))
                        }
                    } else {
                        Button { onManageCapabilities() } label: {
                            Label("Manage Capabilities", systemImage: "square.grid.2x2")
                                .font(Stanford.body(13))
                        }

                        Button { createConnector() } label: {
                            Label("New Connector", systemImage: "plus")
                                .font(Stanford.body(13))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let connector = selectedConnector {
                    ConnectorEditorView(connector: connector, workspace: workspace, onDelete: {
                        deleteConnector(connector)
                    }, onDuplicate: { copy in
                        selectedConnector = copy
                    })
                } else if !hasVisibleConnectors {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        if !workspaceConnectors.isEmpty {
                            ConfigureSelectionSection("Workspace Connectors") {
                                ForEach(workspaceConnectors) { connector in
                                    connectorCard(connector)
                                }
                            }
                        }

                        if !sharedLibraryConnectors.isEmpty {
                            ConfigureSelectionSection("Shared Library") {
                                ForEach(sharedLibraryConnectors) { connector in
                                    let enabled = workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString)

                                    ConfigureSelectionCard {
                                        HStack(spacing: 12) {
                                            Button {
                                                selectedConnector = connector
                                            } label: {
                                                HStack(spacing: 12) {
                                                    connectorRow(connector)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "chevron.right")
                                                        .font(Stanford.ui(11, weight: .semibold))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .buttonStyle(.plain)

                                            Button("Duplicate") {
                                                duplicateConnector(connector)
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button(enabled ? "Disable" : "Enable") {
                                                toggleGlobalConnector(connector)
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let conn = (workspaceConnectors + sharedLibraryConnectors).first(where: { $0.id == focusItemID }) {
                selectedConnector = conn
            }
        }
    }

    private func connectorCard(_ connector: Connector) -> some View {
        ConfigureSelectionCard {
            Button {
                selectedConnector = connector
            } label: {
                HStack(spacing: 12) {
                    connectorRow(connector)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.connectors.color.opacity(0.5))
            Text("No Connectors Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Connectors provide authentication and configuration for external services like Jira, GitHub, Slack, and databases.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    createConnector()
                } label: {
                    Label("Create Blank", systemImage: "plus")
                        .font(Stanford.body(14))
                }

                Button {
                    onManageCapabilities()
                } label: {
                    Label("Manage Capabilities", systemImage: "square.grid.2x2")
                        .font(Stanford.body(14))
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.connectors.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectorRow(_ connector: Connector) -> some View {
        let subtitle = connector.connectorDescription.isEmpty ? connector.displaySummary : connector.connectorDescription
        let serviceLabel = connector.serviceType.replacingOccurrences(of: "_", with: " ").capitalized
        let authLabel = connector.authMethod.replacingOccurrences(of: "_", with: " ").capitalized

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: connector.icon, color: ConfigureTab.connectors.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.name.isEmpty ? "Untitled" : connector.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: serviceLabel, color: ConfigureTab.connectors.color)
                ConfigureCardChip(title: authLabel)
                if !connector.credentialKeys.isEmpty {
                    ConfigureCardChip(title: "\(connector.credentialKeys.count) secret\(connector.credentialKeys.count == 1 ? "" : "s")")
                }
                if connector.isGlobal {
                    ConfigureCardChip(title: "Shared", color: Stanford.poppy)
                }
            }
        }
    }

    private func createConnector() {
        let connector = Connector(name: "New Connector")
        connector.workspace = workspace
        modelContext.insert(connector)
        selectedConnector = connector
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorCreated, category: "UI", fields: [
            "connector_id": connector.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func toggleGlobalConnector(_ connector: Connector) {
        if workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString) {
            CapabilitySharing.disableShared(connector, in: workspace)
        } else {
            CapabilitySharing.enableShared(connector, in: workspace)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorUpdated, category: "UI", fields: [
            "connector_id": connector.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "enabled_global": String(workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString))
        ])
    }

    private func duplicateConnector(_ connector: Connector) {
        let copy = CapabilitySharing.duplicateForWorkspace(connector, in: workspace)
        modelContext.insert(copy)
        selectedConnector = copy
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func deleteConnector(_ connector: Connector) {
        if selectedConnector?.id == connector.id {
            selectedConnector = nil
        }
        workspace.enabledGlobalConnectorIDs.removeAll { $0 == connector.id.uuidString }
        connector.cleanupKeychain()
        modelContext.delete(connector)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

// MARK: - Tools Tab

struct ToolsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTool: LocalTool?
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(workspace: workspace, globalTools: globalTools)
    }

    private var workspaceTools: [LocalTool] {
        capabilities.workspaceTools
    }

    private var sharedLibraryTools: [LocalTool] {
        capabilities.availableGlobalTools
    }

    private var hasVisibleTools: Bool {
        !workspaceTools.isEmpty || !sharedLibraryTools.isEmpty
    }

    var body: some View {
        let showingDetail = selectedTool != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools")
                        .font(Stanford.heading(18))
                    Text("Scripts & MCP")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showingDetail {
                    Button {
                        selectedTool = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Stanford.body(13))
                    }
                } else {
                    Button { createTool() } label: {
                        Label("New Tool", systemImage: "plus")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let tool = selectedTool {
                    LocalToolEditorView(tool: tool, workspace: workspace, onDelete: {
                        deleteTool(tool)
                    }, onDuplicate: { copy in
                        selectedTool = copy
                    })
                } else if !hasVisibleTools {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        if !workspaceTools.isEmpty {
                            ConfigureSelectionSection("Workspace Tools") {
                                ForEach(workspaceTools) { tool in
                                    ConfigureSelectionCard {
                                        Button {
                                            selectedTool = tool
                                        } label: {
                                            HStack(spacing: 12) {
                                                toolRow(tool)
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .font(Stanford.ui(11, weight: .semibold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !sharedLibraryTools.isEmpty {
                            ConfigureSelectionSection("Shared Library") {
                                ForEach(sharedLibraryTools) { tool in
                                    let enabled = workspace.enabledGlobalToolIDs.contains(tool.id.uuidString)
                                    ConfigureSelectionCard {
                                        HStack(spacing: 12) {
                                            Button {
                                                selectedTool = tool
                                            } label: {
                                                HStack(spacing: 12) {
                                                    toolRow(tool)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "chevron.right")
                                                        .font(Stanford.ui(11, weight: .semibold))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .buttonStyle(.plain)

                                            Button {
                                                duplicateTool(tool)
                                            } label: {
                                                Label("Duplicate", systemImage: "doc.on.doc")
                                                    .font(Stanford.body(12))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button {
                                                toggleGlobalTool(tool)
                                            } label: {
                                                Label(enabled ? "Disable" : "Enable", systemImage: enabled ? "checkmark.circle.fill" : "plus.circle")
                                                    .font(Stanford.body(12))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .tint(enabled ? ConfigureTab.tools.color : nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let tool = (workspace.localTools + globalTools).first(where: { $0.id == focusItemID }) {
                selectedTool = tool
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.tools.color.opacity(0.5))
            Text("No Tools Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Tools are local scripts, CLI commands, or MCP servers that extend your agent's capabilities. Define them here and attach them to skills.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                createTool()
            } label: {
                Label("Create Tool", systemImage: "plus")
                    .font(Stanford.body(14))
            }
            .buttonStyle(.borderedProminent)
            .tint(ConfigureTab.tools.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolRow(_ tool: LocalTool) -> some View {
        let typeLabel: String = switch tool.toolType {
        case "cli": "CLI"
        case "mcp": "MCP"
        case "script": "Script"
        default: tool.toolType.capitalized
        }
        let subtitle = tool.toolDescription.isEmpty ? (tool.displayCommand.isEmpty ? "No command configured yet" : tool.displayCommand) : tool.toolDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: LocalTool.iconForType(tool.toolType), color: ConfigureTab.tools.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name.isEmpty ? "Untitled" : tool.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: typeLabel, color: ConfigureTab.tools.color)
                if !tool.command.isEmpty {
                    ConfigureCardChip(title: "Configured")
                }
                if tool.isGlobal {
                    ConfigureCardChip(title: "Shared", color: ConfigureTab.tools.color)
                    if workspace.enabledGlobalToolIDs.contains(tool.id.uuidString) {
                        ConfigureCardChip(title: "Enabled here")
                    }
                }
            }
        }
    }

    private func createTool() {
        let tool = LocalTool(name: "New Tool")
        tool.workspace = workspace
        modelContext.insert(tool)
        selectedTool = tool
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolCreated, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteTool(_ tool: LocalTool) {
        if selectedTool?.id == tool.id {
            selectedTool = nil
        }
        workspace.enabledGlobalToolIDs.removeAll { $0 == tool.id.uuidString }
        modelContext.delete(tool)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolDeleted, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func toggleGlobalTool(_ tool: LocalTool) {
        if workspace.enabledGlobalToolIDs.contains(tool.id.uuidString) {
            CapabilitySharing.disableShared(tool, in: workspace)
        } else {
            CapabilitySharing.enableShared(tool, in: workspace)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolUpdated, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "enabled_global": String(workspace.enabledGlobalToolIDs.contains(tool.id.uuidString))
        ])
    }

    private func duplicateTool(_ tool: LocalTool) {
        let copy = CapabilitySharing.duplicateForWorkspace(tool, in: workspace)
        modelContext.insert(copy)
        selectedTool = copy
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

// MARK: - Skills Tab

struct SkillsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    var onManageCapabilities: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSkill: Skill?

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var workspaceSkills: [Skill] {
        workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn }.sorted { $0.name < $1.name }
    }

    private var sharedLibrarySkills: [Skill] {
        globalSkills.filter { globalSkill in
            !globalSkill.isSystemBuiltIn &&
            !workspaceSkills.contains { $0.id == globalSkill.id }
        }
        .sorted { $0.name < $1.name }
    }

    private var hasVisibleSkills: Bool {
        !workspaceSkills.isEmpty || !sharedLibrarySkills.isEmpty
    }

    var body: some View {
        let showingDetail = selectedSkill != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(Stanford.heading(18))

                    Text("Intent & Behavior")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if showingDetail {
                        Button {
                            selectedSkill = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(Stanford.body(13))
                        }
                    } else {
                        Button { onManageCapabilities() } label: {
                            Label("Manage Capabilities", systemImage: "square.grid.2x2")
                                .font(Stanford.body(13))
                        }

                        Button { createSkill() } label: {
                            Label("New Skill", systemImage: "plus")
                                .font(Stanford.body(13))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let skill = selectedSkill {
                    SkillEditorView(skill: skill, workspace: workspace, onDelete: {
                        deleteSkill(skill)
                    })
                } else if !hasVisibleSkills {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        if !workspaceSkills.isEmpty {
                            ConfigureSelectionSection("Workspace Skills") {
                                ForEach(workspaceSkills) { skill in
                                    ConfigureSelectionCard {
                                        Button {
                                            selectedSkill = skill
                                        } label: {
                                            HStack(spacing: 12) {
                                                skillRow(skill)
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .font(Stanford.ui(11, weight: .semibold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !sharedLibrarySkills.isEmpty {
                            ConfigureSelectionSection("Shared Library") {
                                ForEach(sharedLibrarySkills) { skill in
                                    let enabled = workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)

                                    ConfigureSelectionCard {
                                        HStack(spacing: 12) {
                                            Button {
                                                selectedSkill = skill
                                            } label: {
                                                HStack(spacing: 12) {
                                                    skillRow(skill)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "chevron.right")
                                                        .font(Stanford.ui(11, weight: .semibold))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .buttonStyle(.plain)

                                            Button(enabled ? "Disable" : "Enable") {
                                                toggleGlobalSkill(skill)
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let skill = workspace.skills.first(where: { $0.id == focusItemID }) {
                selectedSkill = skill
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.skills.color.opacity(0.5))
            Text("No Skills Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Skills define what your agent can do — which tools it can use, behavioral instructions, and attached connectors and tools.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    createSkill()
                } label: {
                    Label("Create Blank", systemImage: "plus")
                        .font(Stanford.body(14))
                }

                Button {
                    onManageCapabilities()
                } label: {
                    Label("Manage Capabilities", systemImage: "square.grid.2x2")
                        .font(Stanford.body(14))
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.skills.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func skillRow(_ skill: Skill) -> some View {
        let subtitle = skill.skillDescription.isEmpty
            ? "\(skill.allowedTools.count) capabilities configured"
            : skill.skillDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(
                    systemName: skill.icon,
                    color: skill.isGlobal ? Stanford.poppy : ConfigureTab.skills.color
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name.isEmpty ? "Untitled" : skill.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: "\(skill.allowedTools.count) capabilities")
                if !skill.connectors.isEmpty {
                    ConfigureCardChip(title: "\(skill.connectors.count) connector\(skill.connectors.count == 1 ? "" : "s")", color: ConfigureTab.connectors.color)
                }
                if !skill.localTools.isEmpty {
                    ConfigureCardChip(title: "\(skill.localTools.count) tool\(skill.localTools.count == 1 ? "" : "s")", color: ConfigureTab.tools.color)
                }
                if skill.isGlobal {
                    ConfigureCardChip(title: "Shared", color: Stanford.poppy)
                }
            }
        }
    }

    private func createSkill() {
        let skill = Skill(name: "New Skill", allowedTools: Skill.defaultAllowed)
        skill.workspace = workspace
        modelContext.insert(skill)
        selectedSkill = skill
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillCreated, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "allowed_tools_count": String(skill.allowedTools.count)
        ])
    }

    private func toggleGlobalSkill(_ skill: Skill) {
        let idString = skill.id.uuidString
        if let idx = workspace.enabledGlobalSkillIDs.firstIndex(of: idString) {
            workspace.enabledGlobalSkillIDs.remove(at: idx)
        } else {
            workspace.enabledGlobalSkillIDs.append(idString)
        }
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillToolPermissionChanged, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "enabled_global": String(workspace.enabledGlobalSkillIDs.contains(idString))
        ])
    }

    private func deleteSkill(_ skill: Skill) {
        if selectedSkill?.id == skill.id {
            selectedSkill = nil
        }
        skill.cleanupKeychain()
        modelContext.delete(skill)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

}

// MARK: - Templates Tab

struct TemplatesTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTemplate: TaskTemplate?

    var body: some View {
        let templates = workspace.templates.sorted(by: { $0.name < $1.name })
        let showingDetail = selectedTemplate != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Templates")
                        .font(Stanford.heading(18))
                    Text("Multi-Phase Workflows")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showingDetail {
                    Button {
                        selectedTemplate = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Stanford.body(13))
                    }
                } else {
                    Button { createTemplate() } label: {
                        Label("New Template", systemImage: "plus")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let template = selectedTemplate {
                    TemplateEditorView(template: template, onDelete: {
                        deleteTemplate(template)
                    })
                } else if templates.isEmpty {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        ConfigureSelectionSection("Templates") {
                            ForEach(templates) { template in
                                ConfigureSelectionCard {
                                    Button {
                                        selectedTemplate = template
                                    } label: {
                                        HStack(spacing: 12) {
                                            templateRow(template)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(Stanford.ui(11, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let template = workspace.templates.first(where: { $0.id == focusItemID }) {
                selectedTemplate = template
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.3.group")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.templates.color.opacity(0.5))
            Text("No Templates Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Templates define multi-phase workflows with before, main, and after agents. Each phase runs through the selected provider and can think, adapt, and troubleshoot.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                createTemplate()
            } label: {
                Label("Create Template", systemImage: "plus")
                    .font(Stanford.body(14))
            }
            .buttonStyle(.borderedProminent)
            .tint(ConfigureTab.templates.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func templateRow(_ template: TaskTemplate) -> some View {
        let subtitle = template.templateDescription.isEmpty ? templatePhaseSummary(template) : template.templateDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: template.icon, color: ConfigureTab.templates.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name.isEmpty ? "Untitled" : template.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                if template.hasBeforePhase {
                    ConfigureCardChip(title: "Before", color: Stanford.interactive)
                }
                ConfigureCardChip(title: "Main", color: Stanford.paloAltoGreen)
                if template.hasAfterPhase {
                    ConfigureCardChip(title: "After", color: Stanford.tools)
                }
                if !template.variables.isEmpty {
                    ConfigureCardChip(title: "\(template.variables.count) variable\(template.variables.count == 1 ? "" : "s")")
                }
            }
        }
    }

    private func templatePhaseSummary(_ template: TaskTemplate) -> String {
        var phases = ["main"]
        if template.hasBeforePhase {
            phases.insert("before", at: 0)
        }
        if template.hasAfterPhase {
            phases.append("after")
        }
        return phases.joined(separator: " · ")
    }

    private func createTemplate() {
        let template = TaskTemplate(name: "New Template", mainGoal: "{{goal}}", workspace: workspace)
        modelContext.insert(template)
        selectedTemplate = template
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.templateCreated, category: "UI", fields: [
            "template_id": template.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteTemplate(_ template: TaskTemplate) {
        if selectedTemplate?.id == template.id {
            selectedTemplate = nil
        }
        modelContext.delete(template)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.templateDeleted, category: "UI", fields: [
            "template_id": template.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }
}

// MARK: - Template Editor

struct TemplateEditorView: View {
    @Bindable var template: TaskTemplate
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var selectedPhase: TemplatePhase = .main
    @State private var showVariableEditor = false
    @State private var showDeleteConfirm = false
    @FocusState private var isNameFocused: Bool

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var availableSkills: [Skill] {
        let workspaceSkills = template.workspace?.skills ?? []
        let enabledIDs = Set(template.workspace?.enabledGlobalSkillIDs ?? [])
        let enabledGlobals = globalSkills.filter { enabledIDs.contains($0.id.uuidString) }
        return (workspaceSkills.filter { !$0.isGlobal } + enabledGlobals).sorted { $0.name < $1.name }
    }

    enum TemplatePhase: String, CaseIterable {
        case before = "Before"
        case main = "Main"
        case after = "After"

        var color: Color {
            switch self {
            case .before: return Stanford.interactive
            case .main: return Stanford.paloAltoGreen
            case .after: return Stanford.tools
            }
        }

        var icon: String {
            switch self {
            case .before: return "arrow.right.circle"
            case .main: return "play.circle.fill"
            case .after: return "checkmark.circle"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Name & icon
                HStack(spacing: 12) {
                    Menu {
                        ForEach(templateIcons, id: \.self) { icon in
                            Button {
                                template.icon = icon
                                template.updatedAt = Date()
                            } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    } label: {
                        Image(systemName: template.icon)
                            .font(Stanford.ui(22))
                            .foregroundStyle(ConfigureTab.templates.color)
                            .frame(width: 36, height: 36)
                            .background(ConfigureTab.templates.color.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Template Name", text: $template.name)
                            .font(Stanford.heading(18))
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                        TextField("Description", text: $template.templateDescription)
                            .font(Stanford.body(13))
                            .foregroundStyle(.secondary)
                            .textFieldStyle(.plain)
                    }
                }

                Divider()

                // Phase selector
                HStack(spacing: 4) {
                    ForEach(TemplatePhase.allCases, id: \.self) { phase in
                        let isActive = phaseIsActive(phase)
                        Button {
                            selectedPhase = phase
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: phase.icon)
                                    .font(Stanford.ui(13))
                                Text(phase.rawValue)
                                    .font(Stanford.body(13))
                                    .fontWeight(.medium)
                                if !isActive && phase != .main {
                                    Text("off")
                                        .font(Stanford.caption(10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedPhase == phase ? phase.color.opacity(0.12) : .clear)
                            .foregroundStyle(selectedPhase == phase ? phase.color : isActive ? Stanford.black : Stanford.coolGrey)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedPhase == phase ? phase.color.opacity(0.3) : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // Phase content
                phaseEditor(for: selectedPhase)

                Divider()

                // Variables
                variablesSection

                Divider()

                // Options
                optionsSection

                // Default skills
                if !availableSkills.isEmpty {
                    Divider()
                    defaultSkillsSection
                }

                Divider()

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Template", systemImage: "trash")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if template.name == "New Template" { isNameFocused = true } }
        .alert("Delete Template?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will permanently delete \"\(template.name)\". This cannot be undone.")
        }
        .onDisappear {
            template.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: template.workspace, modelContext: modelContext)
        }
    }

    // MARK: - Phase Editor

    @ViewBuilder
    private func phaseEditor(for phase: TemplatePhase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .before:
                Toggle("Enable Before Phase", isOn: Binding(
                    get: { template.hasBeforePhase },
                    set: { enabled in
                        template.beforeGoal = enabled ? "Prepare the environment for the main task." : ""
                        template.updatedAt = Date()
                    }
                ))
                .font(Stanford.body(14))

                if template.hasBeforePhase {
                    goalEditor(title: "Before Agent Goal", text: $template.beforeGoal)
                    budgetField(label: "Budget", value: $template.beforeBudget)
                    modelField(label: "Model Override", value: $template.beforeModel)
                }

            case .main:
                goalEditor(title: "Main Agent Goal", text: $template.mainGoal)
                budgetField(label: "Budget", value: $template.mainBudget)
                modelField(label: "Model Override", value: $template.mainModel)

            case .after:
                Toggle("Enable After Phase", isOn: Binding(
                    get: { template.hasAfterPhase },
                    set: { enabled in
                        template.afterGoal = enabled ? "Verify and clean up after the main task." : ""
                        template.updatedAt = Date()
                    }
                ))
                .font(Stanford.body(14))

                if template.hasAfterPhase {
                    goalEditor(title: "After Agent Goal", text: $template.afterGoal)
                    budgetField(label: "Budget", value: $template.afterBudget)
                    modelField(label: "Model Override", value: $template.afterModel)
                }
            }
        }
    }

    private func goalEditor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(Stanford.ui(13, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 160)
                .padding(6)
                .background(Stanford.fog.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Stanford.coolGrey.opacity(0.2), lineWidth: 1)
                )
            Text("Use {{variable}} placeholders. Available: " + template.variables.map { "{{\($0.name)}}" }.joined(separator: ", "))
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
        }
    }

    private func budgetField(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("", value: value, format: .number)
                .font(Stanford.body(13))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Text("tokens")
                .font(Stanford.caption(12))
                .foregroundStyle(.tertiary)
        }
    }

    private func modelField(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("default", text: value)
                .font(Stanford.body(13))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    // MARK: - Variables

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Variables")
                    .font(Stanford.body(15))
                    .fontWeight(.medium)
                Spacer()
                Button {
                    var vars = template.variables
                    vars.append(TemplateVariable(name: "new_var", label: "New Variable"))
                    template.variables = vars
                    template.updatedAt = Date()
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(Stanford.body(12))
                }
            }

            if template.variables.isEmpty {
                Text("No variables defined. Variables let users customize the template when creating tasks.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(template.variables.enumerated()), id: \.element.id) { index, variable in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("{{\(variable.name)}}")
                                    .font(Stanford.ui(12, design: .monospaced))
                                    .foregroundStyle(ConfigureTab.templates.color)
                                if variable.isRequired {
                                    Text("required")
                                        .font(Stanford.caption(10))
                                        .foregroundStyle(Stanford.cardinalRed)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Stanford.cardinalRed.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(variable.label)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                            if !variable.defaultValue.isEmpty {
                                Text("Default: \(variable.defaultValue)")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button {
                            var vars = template.variables
                            vars.remove(at: index)
                            template.variables = vars
                            template.updatedAt = Date()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(Stanford.ui(15))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Stanford.fog.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Passing")
                .font(Stanford.body(15))
                .fontWeight(.medium)

            Toggle("Pass Before output to Main agent", isOn: $template.passContextToMain)
                .font(Stanford.body(13))
                .disabled(!template.hasBeforePhase)

            Toggle("Pass Main output to After agent", isOn: $template.passContextToAfter)
                .font(Stanford.body(13))
                .disabled(!template.hasAfterPhase)
        }
    }

    private var defaultSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Skills")
                .font(Stanford.body(15))
                .fontWeight(.medium)
            Text("Skills auto-attached to tasks created from this template")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)

            ForEach(availableSkills) { skill in
                Toggle(isOn: Binding(
                    get: { template.defaultSkillIDs.contains(skill.id.uuidString) },
                    set: { enabled in
                        if enabled {
                            if !template.defaultSkillIDs.contains(skill.id.uuidString) {
                                template.defaultSkillIDs.append(skill.id.uuidString)
                            }
                        } else {
                            template.defaultSkillIDs.removeAll { $0 == skill.id.uuidString }
                        }
                        template.updatedAt = Date()
                    }
                )) {
                    Label(skill.name, systemImage: skill.icon)
                        .font(Stanford.body(13))
                }
            }
        }
    }

    private func phaseIsActive(_ phase: TemplatePhase) -> Bool {
        switch phase {
        case .before: return template.hasBeforePhase
        case .main: return true
        case .after: return template.hasAfterPhase
        }
    }

    private var templateIcons: [String] {
        [
            "rectangle.3.group", "gearshape.2", "arrow.triangle.branch",
            "server.rack", "cloud", "terminal",
            "doc.text", "folder.badge.gearshape", "testtube.2",
            "shield.checkered", "antenna.radiowaves.left.and.right", "bolt.circle"
        ]
    }
}
