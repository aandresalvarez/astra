import SwiftUI
import SwiftData
import ASTRACore

enum CatalogFocus: String {
    case all
    case skills
    case connectors
    case tools
    case templates

    var title: String {
        switch self {
        case .all: "Catalog"
        case .skills: "Catalog"
        case .connectors: "Catalog"
        case .tools: "Catalog"
        case .templates: "Catalog"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "Approved capabilities for this workspace"
        case .skills: "Approved capabilities with skills"
        case .connectors: "Approved capabilities with connectors"
        case .tools: "Approved capabilities with tools"
        case .templates: "Approved capabilities with templates"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .all: "Search catalog..."
        case .skills: "Search skills..."
        case .connectors: "Search connectors..."
        case .tools: "Search tools..."
        case .templates: "Search templates..."
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No approved capabilities found"
        case .skills: "No approved skill capabilities found"
        case .connectors: "No approved connector capabilities found"
        case .tools: "No approved tool capabilities found"
        case .templates: "No approved template capabilities found"
        }
    }

    func matches(_ package: PluginPackage) -> Bool {
        switch self {
        case .all:
            true
        case .skills:
            !package.skills.isEmpty
        case .connectors:
            !package.connectors.isEmpty
        case .tools:
            !package.localTools.isEmpty
        case .templates:
            !package.templates.isEmpty
        }
    }
}

struct PluginCatalogView: View {
    var workspace: Workspace
    var catalog: PluginCatalog
    var focus: CatalogFocus = .all
    var onInstall: ((PluginPackage) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.preflightCache) private var preflightCache
    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var expandedPackageID: String?
    @State private var installingPackage: PluginPackage?
    @State private var installError: String?
    @State private var showCreateWizard = false
    /// Cached prereq status per package id, aggregated from the badges.
    /// `nil` = not yet probed; `true` = all green; `false` = at least one
    /// red/amber. Drives the install button's disabled state.
    @State private var packagePrereqReady: [String: Bool] = [:]

    private var focusedPackages: [PluginPackage] {
        catalog.packages.filter { focus.matches($0) }
    }

    private var filteredPackages: [PluginPackage] {
        var result = focusedPackages
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.description.lowercased().contains(query) ||
                $0.tags.contains { $0.lowercased().contains(query) }
            }
        }
        return result
    }

    private var installedCount: Int {
        focusedPackages.filter { catalog.isInstalled($0.id, in: workspace) }.count
    }

    private var visibleCategories: [String] {
        let cats = focusedPackages.map(\.category)
        return Array(NSOrderedSet(array: cats)) as? [String] ?? Array(Set(cats)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            categoryStrip

            Divider()

            if filteredPackages.isEmpty {
                Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(Stanford.ui(36))
                            .foregroundStyle(.quaternary)
                    Text(focus.emptyTitle)
                        .font(Stanford.body(15))
                        .foregroundStyle(.secondary)
                    if !searchText.isEmpty {
                        Text("Try a different search term")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(filteredPackages) { package in
                            packageCard(package)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(width: 740, height: 600)
        .onAppear {
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
            }
        }
        .sheet(isPresented: $showCreateWizard) {
            CapabilityCreationWizardView(workspace: workspace) { package, enableHere in
                createCapability(package, enableHere: enableHere)
            }
        }
        .sheet(item: $installingPackage) { package in
            PluginInstallSheet(
                package: package,
                workspace: workspace,
                onDismiss: { installingPackage = nil },
                onInstalled: { pkg in
                    installingPackage = nil
                    onInstall?(pkg)
                }
            )
        }
        .alert("Capability could not be installed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 36, height: 36)
                .background(Stanford.lagunita.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title)
                    .font(Stanford.heading(20))
                    .foregroundStyle(Stanford.black)
                Text("\(focusedPackages.count) available \u{00B7} \(installedCount) installed \u{00B7} \(focus.subtitle)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showCreateWizard = true
            } label: {
                Label("New Capability", systemImage: "plus")
                    .font(Stanford.body(13))
            }
            .buttonStyle(.bordered)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Search

    private var searchBar: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Stanford.ui(13))
                    .foregroundStyle(.tertiary)
            TextField(focus.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(Stanford.body(14))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Stanford.ui(13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Category Strip

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(nil, label: "All", count: focusedPackages.count)
                ForEach(visibleCategories, id: \.self) { cat in
                    let count = focusedPackages.filter { $0.category == cat }.count
                    categoryChip(cat, label: cat, count: count)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private func categoryChip(_ category: String?, label: String, count: Int) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(Stanford.body(13))
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(count)")
                    .font(Stanford.caption(10))
                    .foregroundStyle(isSelected ? Stanford.lagunita.opacity(0.7) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Stanford.lagunita.opacity(0.12) : Color.primary.opacity(0.04))
            .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.black)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Stanford.lagunita.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Package Card

    private func packageCard(_ package: PluginPackage) -> some View {
        let installed = catalog.isInstalled(package.id, in: workspace)
        let isExpanded = expandedPackageID == package.id

        return VStack(alignment: .leading, spacing: 0) {
            // Main card — tappable to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPackageID = isExpanded ? nil : package.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: package.icon)
                            .font(Stanford.ui(18, weight: .medium))
                            .foregroundStyle(installed ? .secondary : Stanford.lagunita)
                            .frame(width: 36, height: 36)
                            .background((installed ? Color.secondary : Stanford.lagunita).opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(package.name)
                                    .font(Stanford.body(14))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(installed ? .secondary : Stanford.black)
                                    .lineLimit(1)

                                if package.requiresSetup {
                                    Image(systemName: "key.fill")
                                        .font(Stanford.ui(10))
                                        .foregroundStyle(Stanford.poppy.opacity(0.7))
                                        .help("Requires configuration")
                                }
                            }

                            Text(package.description)
                                .font(Stanford.caption(12))
                                .foregroundStyle(installed ? Color.secondary.opacity(0.6) : .secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    // Bottom row
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(package.contentParts, id: \.self) { part in
                                Text(part)
                                    .font(Stanford.caption(10))
                                    .foregroundStyle(installed ? Stanford.coolGrey.opacity(0.5) : Stanford.coolGrey)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(Capsule())
                            }
                        }

                        Spacer()

                        if installed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(Stanford.ui(12))
                                Text("Installed")
                                    .font(Stanford.caption(11))
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(Stanford.paloAltoGreen)
                        } else {
                            installButton(for: package)
                        }
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                expandedDetail(package, installed: installed)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(installed ? Color.primary.opacity(0.02) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isExpanded ? Stanford.lagunita.opacity(0.25) :
                    installed ? Color.primary.opacity(0.04) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private func installButton(for package: PluginPackage) -> some View {
        // packagePrereqReady == nil means we haven't probed yet (or package
        // has no prereqs); treat as "go ahead and install". Only block
        // when we've proven a prereq is red/amber.
        let ready = packagePrereqReady[package.id] ?? true
        let prereqBlocks = !package.prerequisites.isEmpty && !ready

        return Button {
            if package.requiresSetup {
                installingPackage = package
            } else {
                installCapability(package)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: prereqBlocks ? "exclamationmark.triangle.fill" : "plus.circle.fill")
                    .font(Stanford.ui(12))
                Text(prereqBlocks ? "Install anyway" : "Install")
                    .font(Stanford.caption(12))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(prereqBlocks ? Stanford.poppy : Stanford.lagunita)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(prereqBlocks
              ? "Some prerequisites aren't ready. Installation will still add the package, but tasks using it may fail until you fix them."
              : "Install \(package.name)")
    }

    private func installCapability(
        _ package: PluginPackage,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:]
    ) {
        do {
            try CapabilityInstaller().install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides
            )
            onInstall?(package)
        } catch {
            installError = error.localizedDescription
        }
    }

    private func createCapability(_ package: PluginPackage, enableHere: Bool) {
        do {
            if enableHere {
                try CapabilityInstaller().install(
                    package,
                    into: workspace,
                    modelContext: modelContext
                )
                onInstall?(package)
            } else {
                try CapabilityLibrary().install(package)
            }
            catalog.loadApprovedCapabilities()
        } catch {
            installError = error.localizedDescription
        }
    }

    // MARK: - Prerequisite Section

    private func prerequisiteSection(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Requirements")
                    .font(Stanford.caption(11))
                    .fontWeight(.semibold)
                    .foregroundStyle(Stanford.lagunita)
                Spacer()
                Text("\(package.prerequisites.count) checks")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 4) {
                ForEach(package.prerequisites) { prereq in
                    PluginCatalogPrereqBadge(
                        prerequisite: prereq,
                        cache: preflightCache,
                        onStatusChange: { status in
                            updateAggregateStatus(package: package, prereq: prereq, status: status)
                        }
                    )
                }
            }
        }
    }

    private func updateAggregateStatus(
        package: PluginPackage,
        prereq: CLIPrerequisite,
        status: HealthStatus
    ) {
        // "Ready" iff every one of this package's prereqs is .healthy.
        // We re-probe everything on each status change — this is O(n²)
        // across renders but n is at most a handful. Keeping it simple is
        // worth more than the cycles saved.
        Task {
            var allReady = true
            for p in package.prerequisites {
                let s = await preflightCache.cachedStatus(for: p)
                switch s {
                case .healthy: continue
                case .none:
                    // If we haven't probed this one yet but the current
                    // callback IS for it, use the incoming status.
                    if p.id == prereq.id {
                        if case .healthy = status { continue }
                        allReady = false
                    } else {
                        allReady = false
                    }
                default:
                    allReady = false
                }
            }
            await MainActor.run {
                packagePrereqReady[package.id] = allReady
            }
        }
    }

    // MARK: - Expanded Detail

    private func expandedDetail(_ package: PluginPackage, installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 10) {
                // Prerequisite badges — render before the setup guide so
                // "what you need on your Mac" is the first thing the user
                // sees. Hidden when the package declares zero prereqs.
                if !package.prerequisites.isEmpty {
                    prerequisiteSection(package)
                }

                // Setup guide
                if !package.setupGuide.isEmpty {
                    Text(package.setupGuide)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                // Author & version
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.circle")
                            .font(Stanford.ui(11))
                            .foregroundStyle(.tertiary)
                        Text(package.author)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(Stanford.ui(10))
                            .foregroundStyle(.tertiary)
                        Text("v\(package.version)")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                    }
                    if package.requiresSetup {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(Stanford.ui(10))
                                .foregroundStyle(Stanford.poppy)
                            Text("Setup required")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.poppy)
                        }
                    }
                }

                // Contents breakdown
                if !package.skills.isEmpty {
                    contentListSection(
                        title: "Skills",
                        icon: "puzzlepiece.extension",
                        color: Stanford.lagunita,
                        items: package.skills.map { ($0.icon, $0.name, "\($0.allowedTools.count) tools") }
                    )
                }

                if !package.connectors.isEmpty {
                    contentListSection(
                        title: "Connectors",
                        icon: "bolt.horizontal.circle",
                        color: Stanford.paloAltoGreen,
                        items: package.connectors.map { ($0.icon, $0.name, $0.authMethod) }
                    )
                }

                if !package.localTools.isEmpty {
                    contentListSection(
                        title: "CLI Tools",
                        icon: "terminal",
                        color: Stanford.poppy,
                        items: package.localTools.map { ($0.icon, $0.name, $0.command) }
                    )
                }

                // Tags
                if !package.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(package.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(Capsule())
                        }
                    }
                }

                // Install button in expanded view too
                if !installed {
                    HStack {
                        Spacer()
                        installButton(for: package)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func contentListSection(
        title: String,
        icon: String,
        color: Color,
        items: [(String, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(Stanford.caption(11))
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }

            ForEach(items.indices, id: \.self) { idx in
                let item = items[idx]
                HStack(spacing: 6) {
                    Image(systemName: item.0)
                        .font(Stanford.ui(10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(item.1)
                        .font(Stanford.caption(11))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(item.2)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.leading, 15)
            }
        }
    }
}

// MARK: - Install Setup Sheet

struct PluginInstallSheet: View {
    let package: PluginPackage
    let workspace: Workspace
    let onDismiss: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var credentialValues: [String: String] = [:]
    @State private var configValues: [String: String] = [:]
    @State private var baseURLValues: [String: String] = [:]
    @State private var installError: String?

    private var allConnectorHints: [(connector: PluginConnector, credentials: [PluginConnector.CredentialHint], configs: [PluginConnector.ConfigHint])] {
        package.connectors.map { ($0, $0.credentialHints, $0.configHints) }
    }

    private var hasRequiredEmpty: Bool {
        // At least one credential field should be filled for each connector
        for conn in package.connectors {
            for hint in conn.credentialHints {
                if (credentialValues[hint.key] ?? "").isEmpty {
                    return true
                }
            }
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: package.icon)
                    .font(Stanford.ui(22, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 44, height: 44)
                    .background(Stanford.lagunita.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Install \(package.name)")
                        .font(Stanford.heading(18))
                        .foregroundStyle(Stanford.black)
                    Text(package.description)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Setup guide
                    if !package.setupGuide.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(package.setupGuide)
                                .font(Stanford.body(13))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(3)
                        }
                    }

                    // Configuration fields per connector
                    ForEach(package.connectors, id: \.name) { connector in
                        connectorSetupSection(connector)
                    }

                    // Local tools summary
                    if !package.localTools.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "terminal")
                                    .font(Stanford.body(14))
                                    .foregroundStyle(Stanford.poppy)
                                    .frame(width: 26, height: 26)
                                    .background(Stanford.poppy.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))

                                Text("CLI Tools")
                                    .font(Stanford.body(14))
                                    .fontWeight(.semibold)

                                Text("local")
                                    .font(Stanford.caption(10))
                                    .foregroundStyle(Stanford.coolGrey)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(Capsule())
                            }

                            VStack(spacing: 1) {
                                ForEach(Array(package.localTools.enumerated()), id: \.offset) { index, tool in
                                    HStack(spacing: 10) {
                                        Image(systemName: "chevron.right")
                                            .font(Stanford.ui(9, weight: .bold))
                                            .foregroundStyle(Stanford.coolGrey)
                                        Text(tool.name)
                                            .font(Stanford.body(13))
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text(tool.command + (tool.arguments.isEmpty ? "" : " \(tool.arguments)"))
                                            .font(Stanford.mono(11))
                                            .foregroundStyle(Stanford.coolGrey)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    if index < package.localTools.count - 1 {
                                        Divider().padding(.leading, 30)
                                    }
                                }
                            }
                            .background(Stanford.fog.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1))

                            Text("These tools use CLI commands installed on your machine.")
                                .font(Stanford.caption(11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Actions
            HStack {
                if hasRequiredEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(Stanford.ui(12))
                        Text("You can fill in credentials later in the Connector editor")
                            .font(Stanford.caption(11))
                    }
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Install") {
                    installCapability()
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 500, height: 560)
        .onAppear {
            // Pre-populate base URLs from connector defaults
            for conn in package.connectors {
                if !conn.baseURL.isEmpty {
                    baseURLValues[conn.name] = conn.baseURL
                }
            }
        }
        .alert("Capability could not be installed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    private func installCapability() {
        do {
            try CapabilityInstaller().install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialValues,
                configInputs: configValues,
                baseURLOverrides: baseURLValues
            )
            onInstalled(package)
        } catch {
            installError = error.localizedDescription
        }
    }

    // MARK: - Connector Setup Section

    private func connectorSetupSection(_ connector: PluginConnector) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Connector header
            HStack(spacing: 8) {
                Image(systemName: connector.icon)
                    .font(Stanford.ui(14, weight: .medium))
                    .foregroundStyle(Stanford.paloAltoGreen)
                    .frame(width: 26, height: 26)
                    .background(Stanford.paloAltoGreen.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(connector.name)
                    .font(Stanford.body(14))
                    .fontWeight(.semibold)

                Text(connector.authMethod.replacingOccurrences(of: "_", with: " "))
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }

            // Base URL
            if !connector.baseURL.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(Stanford.caption(11))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    TextField(connector.baseURL, text: Binding(
                        get: { baseURLValues[connector.name] ?? connector.baseURL },
                        set: { baseURLValues[connector.name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
                }
            }

            // Credentials
            if !connector.credentialHints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill")
                            .font(Stanford.ui(10))
                            .foregroundStyle(Stanford.poppy)
                        Text("Credentials")
                            .font(Stanford.caption(11))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("stored in Keychain")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(connector.credentialHints, id: \.key) { hint in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.key)
                                .font(Stanford.ui(12, design: .monospaced))
                                .fontWeight(.medium)
                            SecureField(hint.hint, text: Binding(
                                get: { credentialValues[hint.key] ?? "" },
                                set: { credentialValues[hint.key] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(13, design: .monospaced))
                            Text(hint.hint)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
                .background(Stanford.poppy.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Stanford.poppy.opacity(0.12), lineWidth: 1)
                )
            }

            // Config
            if !connector.configHints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(Stanford.ui(10))
                            .foregroundStyle(Stanford.lagunita)
                        Text("Configuration")
                            .font(Stanford.caption(11))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(connector.configHints, id: \.key) { hint in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.key)
                                .font(Stanford.ui(12, design: .monospaced))
                                .fontWeight(.medium)
                            TextField(hint.hint, text: Binding(
                                get: { configValues[hint.key] ?? "" },
                                set: { configValues[hint.key] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(13, design: .monospaced))
                            Text(hint.hint)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if !connector.notes.isEmpty {
                Text(connector.notes)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
