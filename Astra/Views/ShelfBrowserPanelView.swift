import SwiftUI
import WebKit

struct ShelfBrowserPanelView: View {
    @ObservedObject var session: ShelfBrowserSession
    @Binding var isPresented: Bool
    @Binding var isPinnedToTask: Bool

    @State private var addressText = ""
    @FocusState private var isAddressFocused: Bool
    @State private var isAddressHovered = false
    @State private var isControlledTechnicalDetailsExpanded = false
    // Tracks whether the user has seen the Embedded vs Controlled explanation
    // on the empty browser screen. Persists across sessions so the hint only
    // teaches once per install, not every time the shelf is empty.
    @AppStorage("browserEngineHintDismissed") private var engineHintDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
                .opacity(0.65)
            browserBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(session))
        // No background — parent paints .bar material that extends behind toolbar.
        .onAppear {
            addressText = session.currentURL
            session.setPresented(true)
        }
        .onDisappear {
            session.setPresented(false)
        }
        .onChange(of: session.currentURL) { _, newValue in
            if !isAddressFocused {
                addressText = newValue
            }
            // First successful navigation retires the engine-modes hint —
            // by now the user is past the empty-state and the Emb/Ctrl
            // labels in the toolbar have context.
            if !newValue.isEmpty {
                engineHintDismissed = true
            }
        }
        .animation(.easeInOut(duration: 0.18), value: session.engine)
        .animation(.easeInOut(duration: 0.16), value: session.isLoading)
        .animation(.easeInOut(duration: 0.16), value: session.controlledBrowser.runState)
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                session.openExternal()
            } label: {
                Label(
                    session.isUsingControlledBrowser ? "Show controlled browser window" : "Open in default browser",
                    systemImage: "arrow.up.forward.square"
                )
            }
            .disabled(!hasDisplayablePage && !session.isUsingControlledBrowser)

            Divider()

            Toggle(isOn: $isPinnedToTask) {
                Label(
                    "Pin to task",
                    systemImage: isPinnedToTask ? "pin.fill" : "pin"
                )
            }

            Divider()

            Toggle(isOn: agentControlOverflowBinding) {
                Label(
                    "Agent control",
                    systemImage: session.isAgentBridgeEnabled ? "lock.open.fill" : "lock.fill"
                )
            }

            Divider()

            Button {
                session.copyBridgeEndpointToPasteboard()
            } label: {
                Label("Copy bridge URL", systemImage: "doc.on.doc")
            }
            .disabled(session.bridgeEndpoint == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(BrowserBarButtonStyle())
        .fixedSize()
        .help("Browser options")
    }

    private var agentControlOverflowBinding: Binding<Bool> {
        Binding(
            get: { session.isAgentBridgeEnabled },
            set: { session.setAgentBridgeEnabled($0, source: "overflow_menu") }
        )
    }

    private var agentControlPanelBinding: Binding<Bool> {
        Binding(
            get: { session.isAgentBridgeEnabled },
            set: { session.setAgentBridgeEnabled($0, source: "controlled_panel") }
        )
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            navigationButtonGroup
            engineSwitcher
            addressField
                .frame(minWidth: 60)
                .layoutPriority(1)
            // The Open button drops its label to icon-only at very narrow widths so
            // the URL field is the one that gives up space first, not the toolbar.
            ViewThatFits(in: .horizontal) {
                goButton(isCompact: false)
                goButton(isCompact: true)
            }
            overflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var engineSwitcher: some View {
        ViewThatFits(in: .horizontal) {
            engineSegmentedControl(compact: false)
            engineSegmentedControl(compact: true)
        }
        .help("Choose whether this shelf uses embedded WebKit or a controlled Chromium profile")
    }

    private func engineSegmentedControl(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 7) {
            if !compact {
                Text("Engine")
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Picker("Browser engine", selection: $session.engine) {
                ForEach(ShelfBrowserEngine.allCases) { engine in
                    Label(
                        compact ? compactEngineLabel(for: engine) : engine.label,
                        systemImage: engineIcon(for: engine)
                    )
                    .tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Stanford.lagunita)
            .frame(width: compact ? 86 : 178)
        }
        .fixedSize()
    }

    private var navigationButtonGroup: some View {
        HStack(spacing: 1) {
            browserButton("chevron.left", help: session.canGoBack ? "Back" : "No previous page", disabled: !session.canGoBack) {
                session.goBack()
            }
            browserButton("chevron.right", help: session.canGoForward ? "Forward" : "No next page", disabled: !session.canGoForward) {
                session.goForward()
            }
            browserButton(
                navigationControlIcon,
                help: navigationControlHelp,
                disabled: navigationControlDisabled,
                accent: session.isLoading ? Stanford.statusError : nil
            ) {
                performNavigationControl()
            }
        }
        .fixedSize()
    }

    private var externalBrowserButton: some View {
        browserButton(
            "arrow.up.forward.square",
            help: session.isUsingControlledBrowser ? "Show controlled browser window" : "Open in default browser",
            disabled: !hasDisplayablePage && !session.isUsingControlledBrowser
        ) {
            session.openExternal()
        }
    }

    private var addressField: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: addressFieldIcon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(addressFieldIconTint)
                .frame(width: 14)
                .animation(.easeOut(duration: 0.18), value: addressFieldIcon)

            engineModeBadge

            TextField("Search or enter website", text: $addressText)
                .textFieldStyle(.plain)
                .font(Stanford.ui(12, weight: .medium))
                .focused($isAddressFocused)
                .onSubmit(go)

            if !addressText.isEmpty && isAddressFocused {
                Button {
                    addressText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Clear address")
                .transition(.opacity)
            }

            // Trailing agent indicator — only when Agent control is on. Replaces the
            // separate status row that used to live below the toolbar.
            if session.isAgentBridgeEnabled {
                BridgeStatusDot(isReady: session.bridgeEndpoint != nil)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 30)
        .background(shape.fill(addressFieldFill))
        .overlay(shape.stroke(addressFieldStroke, lineWidth: isAddressFocused ? 1.5 : 1))
        .contentShape(shape)
        .onHover { isAddressHovered = $0 }
        .onTapGesture { isAddressFocused = true }
        .animation(.easeOut(duration: 0.16), value: isAddressFocused)
        .animation(.easeOut(duration: 0.14), value: isAddressHovered)
        .animation(.easeOut(duration: 0.14), value: addressText.isEmpty)
    }

    private var engineModeBadge: some View {
        Label(session.engine.label, systemImage: engineIcon(for: session.engine))
            .labelStyle(.titleAndIcon)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(engineModeTint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(engineModeTint.opacity(0.10))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(engineModeTint.opacity(0.16), lineWidth: 1)
            )
            .help("\(session.engine.label) mode: \(engineModeHelp)")
            .accessibilityLabel("Browser engine: \(session.engine.label)")
    }

    private var engineModeTint: Color {
        session.isUsingControlledBrowser ? Stanford.lagunita : .secondary
    }

    private var engineModeHelp: String {
        session.isUsingControlledBrowser
            ? "The address opens in the controlled Chromium profile."
            : "The address opens in the embedded WebKit browser."
    }

    private func engineIcon(for engine: ShelfBrowserEngine) -> String {
        switch engine {
        case .embedded: "safari"
        case .controlled: "globe.badge.chevron.backward"
        }
    }

    private func compactEngineLabel(for engine: ShelfBrowserEngine) -> String {
        switch engine {
        case .embedded: "Emb"
        case .controlled: "Ctrl"
        }
    }

    private var addressFieldIcon: String {
        if hasDisplayablePage && !isAddressFocused {
            return session.currentURL.lowercased().hasPrefix("https://") ? "lock.fill" : "globe"
        }
        return "magnifyingglass"
    }

    private var addressFieldIconTint: Color {
        if hasDisplayablePage && !isAddressFocused && session.currentURL.lowercased().hasPrefix("https://") {
            return Stanford.statusHealthy
        }
        return isAddressFocused ? Stanford.lagunita : .secondary
    }

    private var addressFieldFill: Color {
        if isAddressFocused { return Stanford.cardBackground }
        if isAddressHovered { return Stanford.cardBackground }
        return Stanford.cardBackground.opacity(0.55)
    }

    private var addressFieldStroke: Color {
        if isAddressFocused { return Stanford.lagunita.opacity(Stanford.strokeFocus) }
        if isAddressHovered { return Color.primary.opacity(Stanford.strokeActive) }
        return Color.primary.opacity(Stanford.strokeRest)
    }

    private func goButton(isCompact: Bool) -> some View {
        Button(action: go) {
            HStack(spacing: 6) {
                if session.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right")
                        .font(Stanford.ui(11, weight: .bold))
                }
                if !isCompact {
                    Text(session.isLoading ? "Opening" : "Open")
                        .font(Stanford.ui(12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .buttonStyle(BrowserGoButtonStyle())
        .disabled(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.controlledBrowser.isLaunching)
        .help(session.isLoading ? "Opening…" : "Open address")
    }

    private var browserBody: some View {
        ZStack(alignment: .top) {
            if session.isUsingControlledBrowser {
                controlledBrowserBody
                    .transition(engineTransition)
            } else {
                embeddedBrowserBody
                    .transition(engineTransition)
            }

            // Thin top progress bar replaces the old status-row linear progress.
            if session.isLoading && !session.isUsingControlledBrowser {
                ProgressView(value: max(0.05, min(session.estimatedProgress, 1)))
                    .progressViewStyle(.linear)
                    .tint(Stanford.lagunita)
                    .frame(height: 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if shouldShowGoogleEditorEmbeddedWarning {
                googleEditorEmbeddedWarning
                    .padding(.top, 10)
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .id(session.engine)
    }

    @ViewBuilder
    private var embeddedBrowserBody: some View {
        if !hasDisplayablePage && !session.isLoading {
            ZStack {
                Stanford.panelBackground
                emptyBrowserStartView
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .center)),
                            removal: .opacity
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.32, extraBounce: 0.05), value: hasDisplayablePage)
        } else {
            ShelfBrowserWebView(session: session)
                .id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyBrowserStartView: some View {
        // No card chrome, no shadow — the empty state speaks for itself.
        // Content is centered as a single column with generous spacing.
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 44, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Stanford.lagunita)

                VStack(spacing: 6) {
                    Text("Open a Website")
                        .font(Stanford.heading(20))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("Type a URL above or jump to a quick link.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    quickLink("Outlook", url: "https://outlook.office.com/mail/", systemImage: "envelope.fill", tint: Stanford.sky)
                    quickLink("Google Drive", url: "https://drive.google.com/", systemImage: "folder.fill", tint: Stanford.paloAltoGreen)
                }

                VStack(spacing: 10) {
                    quickLink("Outlook", url: "https://outlook.office.com/mail/", systemImage: "envelope.fill", tint: Stanford.sky)
                    quickLink("Google Drive", url: "https://drive.google.com/", systemImage: "folder.fill", tint: Stanford.paloAltoGreen)
                }
            }

            if !engineHintDismissed {
                engineComparisonHint
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 420)
        .animation(.easeInOut(duration: 0.2), value: engineHintDismissed)
    }

    /// Inline first-run explanation of the two browser engines. Dismissible,
    /// and auto-hides after the user actually loads a page (since by then
    /// they've started using the shelf and the labels are no longer cryptic).
    private var engineComparisonHint: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("ENGINE MODES")
                    .font(Stanford.caption(10).weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                Button {
                    engineHintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Hide this hint")
            }

            VStack(alignment: .leading, spacing: 10) {
                engineHintRow(
                    title: "Embedded",
                    body: "Fast WebKit view inside this panel."
                )
                engineHintRow(
                    title: "Controlled",
                    body: "Full Chromium profile the agent can drive."
                )
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func engineHintRow(title: String, body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 78, alignment: .leading)
            Text(body)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var engineTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.992, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.998, anchor: .top))
        )
    }

    private var googleEditorEmbeddedWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(Stanford.statusWarn)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Google editor detected")
                    .font(Stanford.caption(12).weight(.semibold))
                Text("Use Controlled mode for reliable clicks, shortcuts, and canvas editing.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                session.launchControlledBrowser()
            } label: {
                Label("Use Controlled", systemImage: "globe.badge.chevron.backward")
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Stanford.statusWarn.opacity(Stanford.strokeActive), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 5)
    }

    private var controlledBrowserBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controlledBrowserHero
                controlledAgentControlCard
                controlledBrowserActions
                if shouldShowControlledLaunchProgress {
                    controlledLaunchProgress
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = session.controlledBrowser.lastErrorMessage {
                    controlledBrowserNotice(
                        title: "Last error",
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Stanford.statusError
                    )
                }

                controlledCurrentPageCard
                controlledTechnicalDetails
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.panelBackground)
        .task {
            await session.refreshControlledBrowserStatus()
        }
    }

    private var shouldShowControlledLaunchProgress: Bool {
        switch session.controlledBrowser.runState {
        case .idle, .launching, .stopped, .failed:
            return true
        case .running, .attached:
            return session.isAgentBridgeEnabled && session.bridgeEndpoint == nil
        }
    }

    private var controlledBrowserHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                        .fill(controlledBrowserTint.opacity(0.12))
                    Image(systemName: controlledHeroIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(controlledBrowserTint)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(controlledHeroTitle)
                            .font(Stanford.heading(18))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        statusBadge(session.controlledBrowser.runState.label, tint: controlledBrowserTint)
                    }

                    Text(controlledHeroSubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            controlledUserFlow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)
                .stroke(controlledBrowserTint.opacity(Stanford.strokeActive), lineWidth: 1)
        )
    }

    private var controlledAgentControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: session.isAgentBridgeEnabled ? "cursorarrow.rays" : "lock.fill")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(controlledTaskFlowTint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    // Dropped the "On"/"Off" status badge — the toggle on the
                    // right already communicates state. Two indicators for the
                    // same thing was noise.
                    Text("Agent control")
                        .font(Stanford.caption(13).weight(.semibold))
                    Text(agentControlCardMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: agentControlPanelBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(controlledTaskFlowTint)
                    .help(session.isAgentBridgeEnabled ? "Turn off Agent control" : "Turn on Agent control")
            }

            if let issue = session.agentControlPermissionIssue {
                controlledAgentControlPermissionGuide(issue: issue)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            // Neutral subtle border so this card doesn't compete with the
            // hero card above (which legitimately gets a tinted border to
            // signal the overall connection state).
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private func controlledAgentControlPermissionGuide(issue: MacOSPermissionIssue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.systemImage)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.statusInfo)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(Stanford.caption(12).weight(.semibold))
                    Text(issue.message)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openPermissionSettingsButton(issue: issue)
                    checkPermissionAgainButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    openPermissionSettingsButton(issue: issue)
                    checkPermissionAgainButton
                }
            }
        }
        .padding(10)
        .background(Stanford.statusInfo.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .stroke(Stanford.statusInfo.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private func openPermissionSettingsButton(issue: MacOSPermissionIssue) -> some View {
        Button {
            session.openAgentControlPrivacySettings()
        } label: {
            Label(issue.actionTitle, systemImage: "gearshape")
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .controlSize(.small)
    }

    private var checkPermissionAgainButton: some View {
        Button {
            Task { await session.checkAgentControlPermissionAgain() }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: true))
        .controlSize(.small)
    }

    private var controlledBrowserActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                controlledPrimaryButton
                controlledRefreshButton
                controlledStopButton
            }

            VStack(alignment: .leading, spacing: 8) {
                controlledPrimaryButton
                HStack(spacing: 8) {
                    controlledRefreshButton
                    controlledStopButton
                }
            }
        }
    }

    private var controlledUserFlow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                controlledFlowPill(
                    "Browser",
                    value: controlledBrowserFlowValue,
                    systemImage: "macwindow",
                    tint: controlledBrowserTint
                )
                controlledFlowPill(
                    "Page",
                    value: hasDisplayablePage ? "Open" : "No page",
                    systemImage: "doc.text.magnifyingglass",
                    tint: hasDisplayablePage ? Stanford.statusHealthy : .secondary
                )
                controlledFlowPill(
                    "Task",
                    value: controlledTaskFlowValue,
                    systemImage: session.isAgentBridgeEnabled ? "cursorarrow.rays" : "lock.fill",
                    tint: controlledTaskFlowTint
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                controlledFlowPill(
                    "Browser",
                    value: controlledBrowserFlowValue,
                    systemImage: "macwindow",
                    tint: controlledBrowserTint
                )
                controlledFlowPill(
                    "Page",
                    value: hasDisplayablePage ? "Open" : "No page",
                    systemImage: "doc.text.magnifyingglass",
                    tint: hasDisplayablePage ? Stanford.statusHealthy : .secondary
                )
                controlledFlowPill(
                    "Task",
                    value: controlledTaskFlowValue,
                    systemImage: session.isAgentBridgeEnabled ? "cursorarrow.rays" : "lock.fill",
                    tint: controlledTaskFlowTint
                )
            }
        }
    }

    private func controlledFlowPill(_ title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08))
        .clipShape(Capsule())
    }

    private var controlledPrimaryButton: some View {
        Button(action: controlledPrimaryAction) {
            Label(controlledPrimaryActionTitle, systemImage: controlledPrimaryActionIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: controlledPrimaryButtonIsPrimary))
        .disabled(session.controlledBrowser.isLaunching)
    }

    private var controlledRefreshButton: some View {
        Button {
            Task { await session.refreshControlledBrowserStatus() }
        } label: {
            Label(session.controlledBrowser.runState == .failed ? "Retry" : "Check status", systemImage: "arrow.clockwise")
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .disabled(session.controlledBrowser.isLaunching)
    }

    private var controlledStopButton: some View {
        // Outlined instead of solid red — pulling the "danger" attention down
        // a notch so it sits as a peer of Show Chrome / Check status, not as
        // the visual centerpiece of the action row.
        Button {
            session.stopControlledBrowser()
        } label: {
            Label("Stop control", systemImage: "stop.fill")
                .font(Stanford.body(15).weight(.medium))
                .foregroundStyle(Stanford.failed)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(Stanford.failed.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!session.controlledBrowser.isRunning)
        .opacity(session.controlledBrowser.isRunning ? 1 : 0.5)
        .help("Stop the controlled Chromium profile and disconnect task control")
    }

    private var controlledLaunchProgress: some View {
        VStack(spacing: 0) {
            controlledStageRow(
                title: "Browser",
                detail: controlledBrowserStageDetail,
                state: controlledBrowserStageState
            )

            diagnosticDivider

            controlledStageRow(
                title: "DevTools",
                detail: devToolsDetail,
                state: controlledDevToolsStageState
            )

            diagnosticDivider

            controlledStageRow(
                title: "Shelf bridge",
                detail: bridgeDiagnosticDetail,
                state: controlledBridgeStageState
            )

            diagnosticDivider

            controlledStageRow(
                title: "Agent access",
                detail: agentAccessDetail,
                state: controlledAgentStageState
            )
        }
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private func controlledStageRow(title: String, detail: String, state: ControlledStageState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.systemImage)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Stanford.caption(12).weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(state.label)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(state.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Text(detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private var controlledBrowserDiagnostics: some View {
        VStack(spacing: 0) {
            diagnosticRow(
                title: "Browser",
                value: browserDiagnosticValue,
                detail: browserDiagnosticDetail,
                systemImage: session.controlledBrowser.runState.systemImage,
                tint: controlledBrowserTint
            )

            diagnosticDivider

            diagnosticRow(
                title: "Shelf bridge",
                value: bridgeDiagnosticValue,
                detail: bridgeDiagnosticDetail,
                systemImage: bridgeDiagnosticIcon,
                tint: bridgeDiagnosticTint,
                monospacedDetail: session.bridgeEndpoint != nil
            )

            diagnosticDivider

            diagnosticRow(
                title: "Agent access",
                value: agentAccessValue,
                detail: agentAccessDetail,
                systemImage: session.isAgentBridgeEnabled ? "lock.open.fill" : "lock.fill",
                tint: session.isAgentBridgeEnabled ? Stanford.statusHealthy : Stanford.statusWarn
            )

            diagnosticDivider

            diagnosticRow(
                title: "DevTools",
                value: devToolsValue,
                detail: devToolsDetail,
                systemImage: "network",
                tint: session.controlledBrowser.debugPort == nil ? .secondary : Stanford.statusInfo,
                monospacedDetail: session.controlledBrowser.debugPort != nil
            )

            diagnosticDivider

            diagnosticRow(
                title: "Profile",
                value: "Isolated",
                detail: session.controlledBrowser.profilePath,
                systemImage: "person.crop.square",
                tint: Stanford.lagunita,
                monospacedDetail: true
            )
        }
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private var controlledCurrentPageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(hasDisplayablePage ? Stanford.statusHealthy : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(hasDisplayablePage ? "Browser context for this task" : "No page linked yet")
                        .font(Stanford.caption(12).weight(.semibold))
                    Text(controlledCurrentPageMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Only show the page-title row when we actually have a page; the
            // previous "No page loaded yet" string echoed the header above and
            // read as redundant.
            if hasDisplayablePage {
                if !session.pageTitle.isEmpty {
                    Text(session.pageTitle)
                        .font(Stanford.caption(13).weight(.semibold))
                        .lineLimit(2)
                }

                if !session.currentURL.isEmpty {
                    Text(session.currentURL)
                        .font(Stanford.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private var controlledTechnicalDetails: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isControlledTechnicalDetailsExpanded.toggle()
                }
            } label: {
                controlledTechnicalDetailsLabel
            }
            .buttonStyle(.plain)

            if isControlledTechnicalDetailsExpanded {
                controlledBrowserDiagnostics
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var controlledTechnicalDetailsLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Technical details")
                .font(Stanford.caption(12).weight(.semibold))
            Spacer(minLength: 8)
            Text(controlledTechnicalSummary)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: isControlledTechnicalDetailsExpanded ? "chevron.up" : "chevron.down")
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .help(isControlledTechnicalDetailsExpanded ? "Hide technical details" : "Show technical details")
    }

    private var diagnosticDivider: some View {
        Divider()
            .padding(.leading, 42)
    }

    private func diagnosticRow(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color,
        monospacedDetail: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Stanford.caption(12).weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.82)
                }

                Text(detail)
                    .font(monospacedDetail ? Stanford.mono(11) : Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private func controlledBrowserNotice(title: String, message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                Text(message)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(tint.opacity(Stanford.strokeActive), lineWidth: 1)
        )
    }

    private func statusBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var controlledHeroIcon: String {
        if session.controlledBrowser.runState == .failed {
            return "exclamationmark.triangle.fill"
        }
        if session.controlledBrowser.isRunning {
            return session.isAgentBridgeEnabled ? "cursorarrow.rays" : "macwindow"
        }
        if session.controlledBrowser.isLaunching {
            return "arrow.triangle.2.circlepath"
        }
        return "globe.badge.chevron.backward"
    }

    private var controlledHeroTitle: String {
        if session.controlledBrowser.runState == .failed {
            return "Browser control needs attention"
        }
        if session.controlledBrowser.isRunning && session.isAgentBridgeEnabled {
            return "ASTRA can use this browser"
        }
        if session.controlledBrowser.isRunning {
            return "Browser is open"
        }
        if session.controlledBrowser.isLaunching {
            return "Opening controlled browser"
        }
        return "Controlled browser is off"
    }

    private var controlledHeroSubtitle: String {
        if session.controlledBrowser.runState == .failed {
            return session.controlledBrowser.lastErrorMessage ?? session.controlledBrowser.statusMessage
        }
        if session.controlledBrowser.isRunning && session.isAgentBridgeEnabled {
            return controlledReadStatusMessage
        }
        if session.controlledBrowser.isRunning {
            return "Turn on Agent control when you want the task to read or operate this page."
        }
        if session.controlledBrowser.isLaunching {
            return "ASTRA is starting Chrome and linking it to this task."
        }
        return "Use this for signed-in or canvas-heavy pages like Google Docs, Jira, or internal tools."
    }

    private var controlledBrowserFlowValue: String {
        switch session.controlledBrowser.runState {
        case .running, .attached:
            return "Ready"
        case .launching:
            return "Opening"
        case .failed:
            return "Failed"
        case .idle:
            return "Off"
        case .stopped:
            return "Stopped"
        }
    }

    private var controlledTaskFlowValue: String {
        guard session.isAgentBridgeEnabled else { return "Off" }
        if session.boundTaskID != nil {
            return session.bridgeEndpoint == nil ? "Starting" : "Linked"
        }
        return "Waiting"
    }

    private var controlledTaskFlowTint: Color {
        guard session.isAgentBridgeEnabled else { return Stanford.statusWarn }
        return session.boundTaskID == nil || session.bridgeEndpoint == nil ? Stanford.statusInfo : Stanford.statusHealthy
    }

    private var agentControlCardMessage: String {
        guard session.isAgentBridgeEnabled else {
            return "The page stays visible, but tasks cannot read or operate it."
        }
        if session.boundTaskID == nil {
            return "The next task message will link to this page when it starts."
        }
        if session.bridgeEndpoint == nil {
            return "ASTRA is preparing local browser access for this task."
        }
        return "This task can inspect and operate the current Chrome page."
    }

    private var controlledCurrentPageMessage: String {
        if hasDisplayablePage && session.isAgentBridgeEnabled {
            return controlledReadStatusMessage
        }
        if hasDisplayablePage {
            return "The page is open in Chrome. Agent control is currently off."
        }
        return "Open a page in Chrome or enter a URL above."
    }

    private var controlledReadStatusMessage: String {
        guard hasDisplayablePage else {
            return "Open a page in Chrome or enter a URL above."
        }
        guard session.isAgentBridgeEnabled else {
            return "Turn on Agent control when you want the task to inspect or operate this page."
        }
        guard readURLMatchesCurrentPage(session.lastPageReadURL, session.currentURL),
              let coverage = session.lastPageReadCoverage else {
            return "The current task can operate this page. Content readability will be verified when the task reads it."
        }
        switch coverage {
        case "full":
            return "ASTRA verified a full readable page snapshot for this task."
        case "partial":
            return "ASTRA can read part of this page. Check read-page warnings; site-specific helpers may be required."
        default:
            return "ASTRA could not verify readable page content yet. The task can still use browser controls."
        }
    }

    private func readURLMatchesCurrentPage(_ readURL: String?, _ currentURL: String) -> Bool {
        guard let readURL, !readURL.isEmpty else { return false }
        if readURL == currentURL {
            return true
        }
        return urlWithoutFragment(readURL) == urlWithoutFragment(currentURL)
    }

    private func urlWithoutFragment(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.fragment = nil
        return components.string ?? value
    }

    private var controlledTechnicalSummary: String {
        var readyCount = 0
        if session.controlledBrowser.isRunning { readyCount += 1 }
        if session.bridgeEndpoint != nil { readyCount += 1 }
        if session.isAgentBridgeEnabled && session.boundTaskID != nil { readyCount += 1 }
        if session.controlledBrowser.runState == .failed { return "Connection failed" }
        return "\(readyCount)/3 ready"
    }

    private func controlledPrimaryAction() {
        if session.controlledBrowser.isRunning {
            session.openExternal()
        } else {
            session.launchControlledBrowser()
        }
    }

    private var controlledPrimaryActionTitle: String {
        if session.controlledBrowser.isLaunching { return "Opening..." }
        if session.controlledBrowser.isRunning { return "Show Chrome" }
        return "Open Browser"
    }

    private var controlledPrimaryActionIcon: String {
        if session.controlledBrowser.isLaunching { return "arrow.triangle.2.circlepath" }
        if session.controlledBrowser.isRunning { return "macwindow" }
        return "play.fill"
    }

    private var controlledPrimaryButtonIsPrimary: Bool {
        !session.controlledBrowser.isRunning
    }

    private var controlledBrowserTint: Color {
        switch session.controlledBrowser.runState {
        case .running, .attached:
            return Stanford.statusHealthy
        case .launching:
            return Stanford.statusInfo
        case .failed:
            return Stanford.statusError
        case .idle, .stopped:
            return .secondary
        }
    }

    private var controlledBrowserStageState: ControlledStageState {
        switch session.controlledBrowser.runState {
        case .running, .attached:
            return .ready("Connected")
        case .launching:
            return .active("Opening")
        case .failed:
            return .failed("Failed")
        case .idle:
            return .waiting("Not started")
        case .stopped:
            return .waiting("Stopped")
        }
    }

    private var controlledDevToolsStageState: ControlledStageState {
        if session.controlledBrowser.debugPort != nil {
            return .ready("Connected")
        }
        if session.controlledBrowser.isLaunching {
            return .active("Waiting")
        }
        if session.controlledBrowser.runState == .failed {
            return .failed("Unavailable")
        }
        return .waiting("No process")
    }

    private var controlledBridgeStageState: ControlledStageState {
        guard session.isAgentBridgeEnabled else { return .waiting("Off") }
        if session.bridgeEndpoint != nil {
            return .ready("Ready")
        }
        return .active("Starting")
    }

    private var controlledAgentStageState: ControlledStageState {
        guard session.isAgentBridgeEnabled else { return .waiting("Off") }
        return session.boundTaskID == nil ? .active("Pending link") : .ready("Linked")
    }

    private var controlledBrowserStageDetail: String {
        switch session.controlledBrowser.runState {
        case .running, .attached:
            return "\(session.controlledBrowser.browserName ?? "Chromium") is reachable from ASTRA."
        case .launching:
            return session.controlledBrowser.statusMessage
        case .failed:
            return session.controlledBrowser.lastErrorMessage ?? session.controlledBrowser.statusMessage
        case .idle:
            return "Launch the isolated Chromium profile or enter a URL above."
        case .stopped:
            return "The controlled profile was stopped."
        }
    }

    private var browserStatusText: String {
        if session.isUsingControlledBrowser {
            return session.controlledBrowser.runState.label
        }
        if session.isLoading {
            return "Loading"
        }
        return session.currentURL.isEmpty ? "Ready" : "Loaded"
    }

    private var browserStatusTint: Color {
        if session.isUsingControlledBrowser {
            return controlledBrowserTint
        }
        return session.isLoading ? Stanford.statusInfo : Stanford.statusHealthy
    }

    private var browserStatusHelp: String {
        if session.isUsingControlledBrowser {
            return session.controlledBrowser.statusMessage
        }
        return session.isLoading ? "The embedded page is loading." : "The embedded browser is ready."
    }

    private var navigationControlIcon: String {
        session.isLoading ? "xmark" : "arrow.clockwise"
    }

    private var navigationControlHelp: String {
        if session.isLoading {
            return session.isUsingControlledBrowser ? "Cancel opening controlled browser" : "Stop loading"
        }
        return session.currentURL.isEmpty ? "No page to reload" : "Reload"
    }

    private var navigationControlDisabled: Bool {
        !session.isLoading && !hasDisplayablePage
    }

    private var hasDisplayablePage: Bool {
        let normalizedURL = session.currentURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedURL.isEmpty && normalizedURL != "about:blank"
    }

    private func performNavigationControl() {
        if session.isLoading {
            session.isUsingControlledBrowser ? session.stopControlledBrowser() : session.stopLoading()
        } else {
            session.reload()
        }
    }

    private var shouldShowGoogleEditorEmbeddedWarning: Bool {
        !session.isUsingControlledBrowser && session.isGoogleWorkspaceEditor
    }

    private var browserDiagnosticValue: String {
        session.controlledBrowser.runState.label
    }

    private var browserDiagnosticDetail: String {
        if session.controlledBrowser.isLaunching {
            return "Opening the isolated Chromium profile and waiting for the localhost DevTools endpoint."
        }
        if session.controlledBrowser.isRunning {
            return "\(session.controlledBrowser.browserName ?? "Chromium") is reachable from ASTRA."
        }
        return session.controlledBrowser.statusMessage
    }

    private var bridgeDiagnosticValue: String {
        guard session.isAgentBridgeEnabled else { return "Disabled" }
        guard session.bridgeEndpoint != nil else { return "Starting" }
        return "Ready"
    }

    private var bridgeDiagnosticDetail: String {
        guard session.isAgentBridgeEnabled else {
            return "Agent control is off. Agents cannot inspect or operate this browser."
        }
        guard let endpoint = session.bridgeEndpoint else {
            return "Waiting for the local Shelf bridge server to publish an endpoint."
        }
        return endpoint
    }

    private var bridgeDiagnosticIcon: String {
        guard session.isAgentBridgeEnabled else { return "lock.fill" }
        return session.bridgeEndpoint == nil ? "antenna.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted"
    }

    private var bridgeDiagnosticTint: Color {
        guard session.isAgentBridgeEnabled else { return Stanford.statusWarn }
        return session.bridgeEndpoint == nil ? Stanford.statusInfo : Stanford.statusHealthy
    }

    private var agentAccessValue: String {
        session.isAgentBridgeEnabled ? "Enabled" : "Off"
    }

    private var agentAccessDetail: String {
        guard session.isAgentBridgeEnabled else {
            return "Turn Agent control on to let the linked task use the bridge."
        }
        if let taskID = session.boundTaskID {
            return "Linked to this task thread: \(taskID.uuidString)"
        }
        return "This browser will link to the task when the new chat is created."
    }

    private var devToolsValue: String {
        if let processID = session.controlledBrowser.processID {
            return "PID \(processID)"
        }
        return "No process"
    }

    private var devToolsDetail: String {
        var parts: [String] = []
        if let debugPort = session.controlledBrowser.debugPort {
            parts.append("DevTools http://127.0.0.1:\(debugPort)")
        }
        if let processID = session.controlledBrowser.processID {
            parts.append("Process \(processID)")
        }
        if parts.isEmpty {
            return "No controlled Chromium process is connected yet."
        }
        return parts.joined(separator: "  ")
    }

    private func browserButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        accent: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(
                    disabled
                        ? Color.secondary.opacity(0.45)
                        : (accent ?? Color.primary.opacity(0.82))
                )
        }
        .buttonStyle(BrowserBarButtonStyle())
        .disabled(disabled)
        .help(help)
    }

    private func quickLink(_ title: String, url: String, systemImage: String, tint: Color) -> some View {
        Button {
            addressText = url
            session.load(url, source: "quick_link")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(BrowserQuickLinkButtonStyle(tint: tint))
    }

    private func go() {
        session.load(addressText, source: "address_bar")
        isAddressFocused = false
    }
}

private struct ControlledStageState {
    let label: String
    let systemImage: String
    let tint: Color

    static func ready(_ label: String) -> ControlledStageState {
        ControlledStageState(label: label, systemImage: "checkmark.circle.fill", tint: Stanford.statusHealthy)
    }

    static func active(_ label: String) -> ControlledStageState {
        ControlledStageState(label: label, systemImage: "arrow.triangle.2.circlepath", tint: Stanford.statusInfo)
    }

    static func waiting(_ label: String) -> ControlledStageState {
        ControlledStageState(label: label, systemImage: "circle", tint: .secondary)
    }

    static func failed(_ label: String) -> ControlledStageState {
        ControlledStageState(label: label, systemImage: "exclamationmark.triangle.fill", tint: Stanford.statusError)
    }
}

private struct ShelfBrowserWebView: NSViewRepresentable {
    @ObservedObject var session: ShelfBrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// Compact status indicator that lives at the trailing edge of the URL field. A
// pulsing sky dot while the bridge is starting, a calm green dot once the agent
// is ready. The text label and dedicated status row were removed in favor of
// this single inline dot.
private struct BridgeStatusDot: View {
    let isReady: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(isReady ? Stanford.statusHealthy : Stanford.statusInfo)
            .frame(width: 7, height: 7)
            .scaleEffect(isReady ? 1.0 : (isPulsing ? 1.25 : 0.85))
            .opacity(isReady ? 1.0 : (isPulsing ? 1.0 : 0.55))
            .help(isReady ? "Agent ready" : "Bridge starting")
            .onAppear { startPulseIfNeeded() }
            .onChange(of: isReady) { _, ready in
                if ready {
                    isPulsing = false
                } else {
                    startPulseIfNeeded()
                }
            }
    }

    private func startPulseIfNeeded() {
        guard !isReady else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}

// Ghost button used in the browser toolbar (back, forward, refresh, external link, close).
// Transparent at rest, lightly tinted on hover, slightly tinted on press, with a small scale dip.
private struct BrowserBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 30
    var cornerRadius: CGFloat = Stanford.radiusSmall

    func makeBody(configuration: Configuration) -> some View {
        BrowserBarButtonContent(
            configuration: configuration,
            isEnabled: isEnabled,
            size: size,
            cornerRadius: cornerRadius
        )
    }
}

private struct BrowserBarButtonContent: View {
    let configuration: ButtonStyle.Configuration
    let isEnabled: Bool
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .frame(width: size, height: size)
            .background(shape.fill(backgroundFill))
            .contentShape(shape)
            .opacity(isEnabled ? 1.0 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.92 : 1.0)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var backgroundFill: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Color.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

// Compact primary button for the address bar's Go action. Tighter than StanfordButtonStyle,
// tuned to sit alongside a 30pt-tall address field without overpowering it.
private struct BrowserGoButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .foregroundStyle(.white)
            .background(shape.fill(backgroundFill(isPressed: configuration.isPressed)))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private func backgroundFill(isPressed: Bool) -> Color {
        if !isEnabled { return Stanford.cardinalRed.opacity(0.42) }
        if isPressed { return Stanford.cardinalRed.opacity(0.85) }
        return Stanford.cardinalRed
    }
}

// Quick-link button for the empty-state suggestions. Soft card by default,
// gains a tinted wash on hover that previews the destination's brand color.
private struct BrowserQuickLinkButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        BrowserQuickLinkContent(
            configuration: configuration,
            tint: tint,
            isEnabled: isEnabled
        )
    }
}

private struct BrowserQuickLinkContent: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(shape.fill(backgroundFill))
            .overlay(shape.stroke(strokeColor, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var backgroundFill: Color {
        if configuration.isPressed { return tint.opacity(0.18) }
        if isHovered { return tint.opacity(0.10) }
        return Stanford.cardBackground
    }

    private var strokeColor: Color {
        if configuration.isPressed || isHovered { return tint.opacity(0.36) }
        return Color.primary.opacity(Stanford.strokeRest)
    }
}
