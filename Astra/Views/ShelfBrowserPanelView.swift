import SwiftUI
import WebKit

struct ShelfBrowserPanelView: View {
    @ObservedObject var session: ShelfBrowserSession
    @Binding var isPresented: Bool

    @State private var addressText = ""
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            browserBody
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .animation(.easeInOut(duration: 0.18), value: session.engine)
        .animation(.easeInOut(duration: 0.16), value: session.isLoading)
        .animation(.easeInOut(duration: 0.16), value: session.controlledBrowser.runState)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerWide
            headerCompact
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: Stanford.density(78), alignment: .center)
        .background(.bar)
    }

    private var headerWide: some View {
        HStack(spacing: 10) {
            headerIdentity

            Spacer(minLength: 8)

            if shouldShowHeaderStatusBadge {
                browserStatusBadge
            }
            browserEnginePicker
            agentControlToggle(label: "Agent control")
            closeButton
        }
    }

    private var headerCompact: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                headerIdentity
                Spacer(minLength: 8)
                if shouldShowHeaderStatusBadge {
                    browserStatusBadge
                }
                closeButton
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    browserEnginePicker
                    Spacer(minLength: 8)
                    agentControlToggle(label: "Agent")
                }

                HStack(spacing: 10) {
                    browserEngineMenu
                    Spacer(minLength: 8)
                    agentControlToggle(label: "Agent")
                }
            }
        }
    }

    // Show only during controlled-mode lifecycle or while actively loading.
    private var shouldShowHeaderStatusBadge: Bool {
        if session.isUsingControlledBrowser { return true }
        return session.isLoading
    }

    private var headerIdentity: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(Stanford.ui(14, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Shelf")
                    .font(Stanford.heading(14))
                    .lineLimit(1)
                Text("Browser")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
                    .lineLimit(1)
            }
        }
    }

    private var browserEnginePicker: some View {
        Picker("Browser engine", selection: $session.engine) {
            ForEach(ShelfBrowserEngine.allCases) { engine in
                Text(engine.label).tag(engine)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 178)
        .help("Switch between the embedded WebKit preview and a controlled external Chromium profile.")
    }

    private var browserEngineMenu: some View {
        Menu {
            Picker("Browser engine", selection: $session.engine) {
                ForEach(ShelfBrowserEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
        } label: {
            Label(session.engine.label, systemImage: session.isUsingControlledBrowser ? "globe.badge.chevron.backward" : "safari")
        }
        .menuStyle(.borderlessButton)
        .help("Switch browser engine")
    }

    private func agentControlToggle(label: String) -> some View {
        Toggle(label, isOn: $session.isAgentBridgeEnabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(Stanford.caption(11).weight(.medium))
            .fixedSize()
            .help("Allow agents to inspect and interact with this browser through the local bridge.")
    }

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            Image(systemName: "xmark")
                .font(Stanford.ui(12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close shelf")
        .accessibilityIdentifier("ShelfBrowserCloseButton")
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                toolbarWideRow
                toolbarCompactRows
            }

            browserLocationSummary
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var toolbarWideRow: some View {
        HStack(spacing: 8) {
            navigationButtonGroup
            addressField
                .frame(minWidth: 160)
                .layoutPriority(1)
            goButton(isCompact: false)
            externalBrowserButton
        }
    }

    private var toolbarCompactRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                navigationButtonGroup
                Spacer(minLength: 8)
                externalBrowserButton
            }

            HStack(spacing: 8) {
                addressField
                    .frame(minWidth: 80)
                    .layoutPriority(1)
                goButton(isCompact: true)
            }
        }
    }

    private var navigationButtonGroup: some View {
        HStack(spacing: 8) {
            browserButton("chevron.left", help: session.canGoBack ? "Back" : "No previous page", disabled: !session.canGoBack) {
                session.goBack()
            }
            browserButton("chevron.right", help: session.canGoForward ? "Forward" : "No next page", disabled: !session.canGoForward) {
                session.goForward()
            }
            browserButton(navigationControlIcon, help: navigationControlHelp, disabled: navigationControlDisabled) {
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
        TextField("Search or enter website", text: $addressText)
            .textFieldStyle(.plain)
            .font(Stanford.caption(12))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .focused($isAddressFocused)
            .onSubmit(go)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                    .stroke(isAddressFocused ? Stanford.lagunita.opacity(Stanford.strokeFocus) : Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
            )
    }

    private func goButton(isCompact: Bool) -> some View {
        Button(action: go) {
            HStack(spacing: 6) {
                if session.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.right")
                        .font(Stanford.ui(11, weight: .semibold))
                }
                Text(session.isLoading ? "Opening" : "Open")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(minWidth: isCompact ? 58 : 72)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: true))
        .controlSize(.small)
        .disabled(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.controlledBrowser.isLaunching)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ShelfBrowserWebView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyBrowserStartView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
            Text("Open a Website")
                .font(Stanford.heading(18))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    quickLink("Outlook", url: "https://outlook.office.com/mail/")
                    quickLink("Office", url: "https://www.office.com/")
                }

                VStack(spacing: 8) {
                    quickLink("Outlook", url: "https://outlook.office.com/mail/")
                    quickLink("Office", url: "https://www.office.com/")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 280)
        .liquidSurface(
            cornerRadius: Stanford.radiusLarge,
            fallbackFill: Stanford.cardBackground,
            fallbackStrokeOpacity: Stanford.strokeRest
        )
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 7)
        .padding(.horizontal, 16)
    }

    private var browserStatusBadge: some View {
        HStack(spacing: 6) {
            if session.isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(browserStatusTint)
                    .frame(width: 7, height: 7)
            }

            Text(browserStatusText)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(browserStatusTint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(browserStatusTint.opacity(0.10))
        .clipShape(Capsule())
        .help(browserStatusHelp)
    }

    private var browserLocationSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: locationSummaryIcon)
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(browserStatusTint)
                .frame(width: 14)

            Text(locationSummaryTitle)
                .font(Stanford.caption(11).weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)

            if !locationSummaryDetail.isEmpty {
                Text(locationSummaryDetail)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if session.isLoading {
                ProgressView(value: max(0.05, min(session.estimatedProgress, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            } else if session.isAgentBridgeEnabled {
                Label(session.bridgeEndpoint == nil ? "Bridge starting" : "Agent ready", systemImage: session.bridgeEndpoint == nil ? "antenna.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(session.bridgeEndpoint == nil ? Stanford.statusInfo : Stanford.statusHealthy)
                    .lineLimit(1)
            }
        }
        .frame(height: 18)
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
                controlledBrowserHeader
                controlledBrowserActions
                if shouldShowControlledLaunchProgress {
                    controlledLaunchProgress
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                controlledBrowserDiagnostics

                if let error = session.controlledBrowser.lastErrorMessage {
                    controlledBrowserNotice(
                        title: "Last error",
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Stanford.statusError
                    )
                }

                controlledCurrentPageCard

                Text("Use this isolated profile for SSO-heavy sites such as Outlook, ServiceNow, Jira, Salesforce, or internal tools. The page opens in a separate Chromium window; the Shelf bridge remains local to this Mac and only exposes it to the linked task when Agent control is enabled.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
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

    private var controlledBrowserHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.controlledBrowser.runState.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(controlledBrowserTint)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.controlledBrowser.browserName ?? "Controlled Chromium Profile")
                        .font(Stanford.heading(18))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    statusBadge(session.controlledBrowser.runState.label, tint: controlledBrowserTint)
                }

                Text(session.controlledBrowser.statusMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
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

    private var controlledPrimaryButton: some View {
        Button(action: controlledPrimaryAction) {
            Label(controlledPrimaryActionTitle, systemImage: controlledPrimaryActionIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: true))
        .disabled(session.controlledBrowser.isLaunching)
    }

    private var controlledRefreshButton: some View {
        Button {
            Task { await session.refreshControlledBrowserStatus() }
        } label: {
            Label(session.controlledBrowser.runState == .failed ? "Retry connection" : "Refresh status", systemImage: "arrow.clockwise")
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .disabled(session.controlledBrowser.isLaunching)
    }

    private var controlledStopButton: some View {
        Button {
            session.stopControlledBrowser()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .lineLimit(1)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .disabled(!session.controlledBrowser.isRunning)
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
        VStack(alignment: .leading, spacing: 6) {
            Label("Current page", systemImage: "doc.text.magnifyingglass")
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)

            Text(session.pageTitle.isEmpty ? "No page loaded yet" : session.pageTitle)
                .font(Stanford.caption(13).weight(.semibold))
                .lineLimit(2)

            Text(session.currentURL.isEmpty ? "Launch the controlled browser or enter a URL above." : session.currentURL)
                .font(session.currentURL.isEmpty ? Stanford.caption(12) : Stanford.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
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

    private func controlledPrimaryAction() {
        if session.controlledBrowser.isRunning {
            session.openExternal()
        } else {
            session.launchControlledBrowser()
        }
    }

    private var controlledPrimaryActionTitle: String {
        if session.controlledBrowser.isLaunching { return "Opening..." }
        if session.controlledBrowser.isRunning { return "Show Browser" }
        return "Launch Browser"
    }

    private var controlledPrimaryActionIcon: String {
        if session.controlledBrowser.isLaunching { return "arrow.triangle.2.circlepath" }
        if session.controlledBrowser.isRunning { return "macwindow" }
        return "play.fill"
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

    private var locationSummaryIcon: String {
        if session.isLoading { return "arrow.triangle.2.circlepath" }
        if session.currentURL.isEmpty { return "globe" }
        return session.isUsingControlledBrowser ? "link" : "doc.text.magnifyingglass"
    }

    private var locationSummaryTitle: String {
        if !hasDisplayablePage {
            return session.isUsingControlledBrowser ? "No controlled page loaded" : "No page loaded"
        }
        if !session.pageTitle.isEmpty {
            return session.pageTitle
        }
        return URL(string: session.currentURL)?.host ?? "Current page"
    }

    private var locationSummaryDetail: String {
        guard hasDisplayablePage else {
            return session.isUsingControlledBrowser
                ? "Launch the isolated profile or enter a URL."
                : "Enter a URL or search phrase."
        }
        return URL(string: session.currentURL)?.host ?? session.currentURL
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

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                bridgeStatusLabel
                Spacer(minLength: 8)
                copyBridgeButton(title: "Copy bridge URL")
            }

            HStack(spacing: 10) {
                bridgeStatusLabel
                Spacer(minLength: 8)
                copyBridgeButton(title: "Copy")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var bridgeStatusLabel: some View {
        Label(bridgeStatusText, systemImage: session.isAgentBridgeEnabled ? bridgeStatusIcon : "lock")
            .font(Stanford.caption(11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
    }

    private func copyBridgeButton(title: String) -> some View {
        Button {
            session.copyBridgeEndpointToPasteboard()
        } label: {
            Label(title, systemImage: "doc.on.doc")
                .lineLimit(1)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .controlSize(.small)
        .disabled(session.bridgeEndpoint == nil)
    }

    private var bridgeStatusText: String {
        guard session.isAgentBridgeEnabled else { return "Agent control disabled" }
        guard let endpoint = session.bridgeEndpoint else { return "Starting browser bridge" }
        return "\(session.engine.bridgeBackendLabel) bridge \(endpoint)"
    }

    private var bridgeStatusIcon: String {
        session.isUsingControlledBrowser ? "globe.badge.chevron.backward" : "point.3.connected.trianglepath.dotted"
    }

    private func browserButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .primary)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
        .disabled(disabled)
        .help(help)
    }

    private func quickLink(_ title: String, url: String) -> some View {
        Button(title) {
            addressText = url
            session.load(url)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: false))
        .controlSize(.small)
    }

    private func go() {
        session.load(addressText)
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
