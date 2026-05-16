import SwiftUI
import AppKit

// Stanford Identity Design System
// https://identity.stanford.edu/design-elements/color/
// https://identity.stanford.edu/design-elements/typography/

enum Stanford {
    // MARK: - Primary Colors
    //
    // Every brand color exposes a dark-mode sibling tuned for contrast on
    // dark backgrounds. Rule of thumb: pump saturation by ~15% and
    // brightness by ~25% so the color reads as "the same hue" to the
    // eye without getting muddy against Color(nsColor: .windowBackgroundColor).
    //
    // Light hexes are the official Stanford Identity values; dark hexes
    // were picked by eye to pair with a typical macOS dark window.
    static let cardinalRed = Color(
        light: 0x8C1515,  // Stanford cardinal
        dark:  0xD93A3A   // readable on dark; still distinctly red
    )
    static let white = Color.white
    static let black = Color.primary
    static let readingTextLightHex: UInt = 0x2E2D29
    static let readingTextDarkHex: UInt = 0xE7E1D8
    static let warmCanvasLightHex: UInt = 0xF8F6F2
    static let readingText = Color(
        light: readingTextLightHex,  // warm charcoal for long-form reading
        dark:  readingTextDarkHex    // warm off-white tuned for dark surfaces
    )

    // MARK: - Secondary Colors
    static let coolGrey = Color.secondary
    static let paloAltoGreen = Color(
        light: 0x175E54,  // Stanford green (very dark)
        dark:  0x7AD4BC   // mid-green that holds up on dark
    )
    static let bay = Color(
        light: 0x6FA287,
        dark:  0x8FC2A7
    )
    static let sky = Color(
        light: 0x0098DB,
        dark:  0x5CB8E8
    )
    static let lagunita = Color(
        light: 0x007C92,
        dark:  0x4AB5C9
    )
    static let poppy = Color(
        light: 0xE98300,
        dark:  0xFFA84D
    )
    static let illuminating = Color(
        light: 0xFEC51D,
        dark:  0xFFD65C
    )
    static let plum = Color(
        light: 0x620059,
        dark:  0xB062A8
    )

    // MARK: - Neutral Colors
    static let stone = Color(
        light: 0xD2C295,
        dark:  0x6A5F48
    )
    static let sandstone = Color(
        light: 0xB6B1A9,
        dark:  0x5A5651
    )
    static let driftwood = Color(
        light: 0xB3995D,
        dark:  0x8A7547
    )

    // MARK: - Semantic Task Colors
    static let queued = sandstone
    static let running = lagunita
    static let pendingUser = poppy
    static let completed = paloAltoGreen
    static let failed = cardinalRed
    static let cancelled = coolGrey

    // MARK: - Semantic Status Colors
    //
    // Use these for health / preflight / diagnostic UI instead of
    // reaching for raw SwiftUI `.green` / `.orange` / `.red`, which don't
    // carry brand hues and look like system surfaces.
    static let statusHealthy = paloAltoGreen
    static let statusWarn = poppy
    static let statusError = cardinalRed
    static let statusInfo = sky

    // MARK: - Semantic UI Colors
    static let diffAdded = paloAltoGreen
    static let diffRemoved = cardinalRed
    static let tools = plum
    static let interactive = sky
    static let scrim = Color.black
    static let focusRing = lagunita
    static let link = lagunita
    static let selectionFill = lagunita.opacity(0.12)

    // MARK: - Global UI Scale

    nonisolated(unsafe) private static var _cachedUIScale: Double?

    /// Persisted scale factor for ⌘+/⌘- font & icon sizing (0.7–1.5)
    static var uiScale: Double {
        get {
            if let cached = _cachedUIScale { return cached }
            let v = UserDefaults.standard.double(forKey: "appUIScale")
            let result = v < 0.1 ? 1.0 : min(max(v, 0.7), 1.5)
            _cachedUIScale = result
            return result
        }
        set {
            let clamped = min(max(newValue, 0.7), 1.5)
            _cachedUIScale = clamped
            UserDefaults.standard.set(clamped, forKey: "appUIScale")
        }
    }

    static func scaled(_ size: CGFloat) -> CGFloat {
        size * CGFloat(uiScale)
    }

    // MARK: - Stanford Identity Typefaces
    // Primary: Source Sans 3 (UI/body), Source Serif 4 (headings/excerpts)
    // Accent: Roboto Mono (code)
    // Tracking: use platform-default optical kerning; do not add letter spacing.
    // Leading: point size + 2–4pt
    // https://identity.stanford.edu/design-elements/typography/

    static let sansFamily = "Source Sans 3"
    static let serifFamily = "Source Serif 4"
    static let monoFamily = "Roboto Mono"

    private static func brandFont(
        family: String,
        size: CGFloat,
        weight: Font.Weight,
        fallbackDesign: Font.Design = .default
    ) -> Font {
        if NSFontManager.shared.availableFontFamilies.contains(family) {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: fallbackDesign)
    }

    // MARK: - Typography Helpers

    private static let approvedFontSizes: [CGFloat] = [
        10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 28, 36, 48, 56
    ]

    private static func normalizedFontSize(_ requestedSize: CGFloat, minimum: CGFloat = 10) -> CGFloat {
        let clamped = max(requestedSize, minimum)
        return approvedFontSizes.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
    }

    static func ui(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        minimum: CGFloat = 10
    ) -> Font {
        let finalSize = scaled(normalizedFontSize(size, minimum: minimum))
        if design == .monospaced {
            return brandFont(family: monoFamily, size: finalSize, weight: weight, fallbackDesign: .monospaced)
        }
        if design == .serif {
            return brandFont(family: serifFamily, size: finalSize, weight: weight, fallbackDesign: .serif)
        }
        if design == .rounded {
            return .system(size: finalSize, weight: weight, design: .rounded)
        }
        return brandFont(family: sansFamily, size: finalSize, weight: weight)
    }

    static func heading(_ size: CGFloat = 22, weight: Font.Weight = .semibold) -> Font {
        let finalSize = scaled(normalizedFontSize(size))
        return brandFont(family: serifFamily, size: finalSize, weight: weight, fallbackDesign: .serif)
    }

    static func body(_ size: CGFloat = 15) -> Font {
        ui(size)
    }

    static func caption(_ size: CGFloat = 13) -> Font {
        ui(size, minimum: 10)
    }

    static func mono(_ size: CGFloat = 14) -> Font {
        ui(size, design: .monospaced, minimum: 10)
    }

    static let chatBodyPointSize: CGFloat = 16
    static let chatBodyLineSpacing: CGFloat = 4
    static let chatCompactLineSpacing: CGFloat = 3
    static let chatParagraphMaxWidth: CGFloat = 1280

    static func chatBody(_ size: CGFloat = chatBodyPointSize) -> Font {
        ui(size)
    }

    static func chatMeta(_ size: CGFloat = 11) -> Font {
        caption(size)
    }

    static func chatSection(_ size: CGFloat = 12) -> Font {
        caption(size)
    }

    static func chatRaw(_ size: CGFloat = 12) -> Font {
        mono(size)
    }

    static func documentExcerpt(_ size: CGFloat = 15) -> Font {
        ui(size, design: .serif)
    }

    /// Keep letter spacing neutral in app UI; platform optical kerning handles readability.
    static func bodyTracking(for fontSize: CGFloat) -> CGFloat {
        0
    }

    // MARK: - Radii Scale
    // Small (6) → controls; Medium (8) → cards/inputs; Large (12) → feature cards. Use nestedRadius() for inset shapes.
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 12

    static func nestedRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 2)
    }

    // MARK: - Stroke Scale
    // Rest (0.12) → resting borders; Active (0.22) → state-tinted; Focus (0.36) → keyboard ring. Pair with Color.primary or a status tint.
    static let strokeRest: Double = 0.12
    static let strokeActive: Double = 0.22
    static let strokeFocus: Double = 0.36

    // MARK: - Density Tokens

    static func density(_ value: CGFloat) -> CGFloat {
        round(scaled(value))
    }

    static var taskRowHeight: CGFloat { density(46) }
    static var sidebarWorkspaceRowHeight: CGFloat { density(44) }
    static var sidebarSectionHeaderHeight: CGFloat { density(30) }
    static var sidebarThreadRowHeight: CGFloat { density(42) }
    static var sidebarScheduleRowHeight: CGFloat { density(40) }
    static var sidebarBadgeHeight: CGFloat { density(18) }
    static var sidebarBadgeMinWidth: CGFloat { density(18) }
    static var sidebarBadgeHorizontalPadding: CGFloat { density(6) }
    static var sidebarBadgeCornerRadius: CGFloat { density(9) }
    static var sidebarAccessoryControlSize: CGFloat { density(18) }
    static var sidebarWorkspaceAccessoryTopInset: CGFloat { density(1) }
    static var railSectionSpacing: CGFloat { density(14) }
    static var railPanelSpacing: CGFloat { density(18) }
    static var railSectionContentSpacing: CGFloat { density(10) }
    static var railListSpacing: CGFloat { density(6) }
    static var railContentPadding: CGFloat { density(16) }
    static var railCardPadding: CGFloat { density(10) }
    static var railInlineCardPadding: CGFloat { density(8) }
    static var railBadgeHeight: CGFloat { density(18) }
    static var railBadgeMinWidth: CGFloat { density(18) }
    static var railBadgeHorizontalPadding: CGFloat { density(6) }
    static var railBadgeVerticalPadding: CGFloat { density(2) }
    static var railBadgeCornerRadius: CGFloat { density(9) }
    static var railCardCornerRadius: CGFloat { density(radiusLarge) }
    static var railCompactCardCornerRadius: CGFloat { density(radiusMedium) }
    static var railIconFrame: CGFloat { density(24) }
    static var railHeaderIconFrame: CGFloat { density(30) }
    static var railHeaderTopPadding: CGFloat { density(14) }
    static var railHeaderBottomPadding: CGFloat { density(10) }
    static var railTabStripSpacing: CGFloat { density(2) }
    static var railTabStripPadding: CGFloat { density(4) }
    static var railTabButtonVerticalPadding: CGFloat { density(7) }
    static var railTabOuterHorizontalPadding: CGFloat { density(14) }
    static var railTabBottomPadding: CGFloat { density(10) }
    static var railActionRowHeight: CGFloat { density(40) }
    static var railResourceRowHeight: CGFloat { density(42) }
    static var railCompactRowHeight: CGFloat { density(30) }
    static var railCompactLogRowHeight: CGFloat { density(40) }
    static var railInfoLabelWidth: CGFloat { density(64) }
    static var inspectorLabelWidth: CGFloat { density(72) }

    // MARK: - Backgrounds
    static let fog = Color(nsColor: .controlBackgroundColor)
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
}

// MARK: - Color Extension for Hex

extension Color {
    /// Build a solid `Color` from a 24-bit RGB hex value. No dark-mode
    /// adaptation — prefer `Color(light:dark:)` for brand tokens.
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Build a `Color` that renders `light` in .light mode and `dark` in
    /// .dark mode, selected by the current `NSAppearance` at draw time.
    /// This is how every brand hue in `Stanford` composes its dark
    /// variant — when macOS flips appearance, AppKit re-resolves the
    /// dynamic color on our behalf.
    init(light: UInt, dark: UInt, opacity: Double = 1.0) {
        let dynamic = NSColor(name: nil) { appearance in
            let wantsDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = wantsDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >>  8) & 0xFF) / 255,
                blue:    CGFloat((hex >>  0) & 0xFF) / 255,
                alpha:   CGFloat(opacity)
            )
        }
        self.init(nsColor: dynamic)
    }
}

// MARK: - Stanford View Modifiers

struct StanfordCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusMedium)
                    .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
            )
    }
}

struct StanfordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var isPrimary: Bool = true
    var color: Color = Stanford.cardinalRed

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)

        configuration.label
            .font(Stanford.body(15).weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(shape)
            .overlay(
                shape
                    .stroke(strokeColor, lineWidth: 1)
            )
            .contentShape(shape)
            .opacity(configuration.isPressed && isEnabled ? 0.8 : 1.0)
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Stanford.fog.opacity(0.85)
        }
        return isPrimary ? color : Stanford.cardBackground
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Stanford.coolGrey.opacity(0.82)
        }
        return isPrimary ? .white : Stanford.black
    }

    private var strokeColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.12)
        }
        return isPrimary ? color.opacity(0.0) : Color.secondary.opacity(0.25)
    }
}

extension View {
    func stanfordCard() -> some View {
        modifier(StanfordCardStyle())
    }

    @ViewBuilder
    func liquidSurface(
        cornerRadius: CGFloat = 10,
        interactive: Bool = false,
        fallbackFill: Color = Color(nsColor: .windowBackgroundColor),
        fallbackStrokeOpacity: Double = 0.06
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(shape.fill(fallbackFill))
                .overlay {
                    if fallbackStrokeOpacity > 0 {
                        shape.stroke(Color.primary.opacity(fallbackStrokeOpacity), lineWidth: 1)
                    }
                }
        }
    }

    @ViewBuilder
    func backgroundExtensionEffectIfAvailable(isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, *), isEnabled {
            backgroundExtensionEffect()
        } else {
            self
        }
    }

    func topDividerShade(height: CGFloat = 18) -> some View {
        overlay(alignment: .top) {
            TopDividerShade(height: height)
        }
    }

    func softHorizontalTransition(height: CGFloat = 10) -> some View {
        SoftHorizontalTransition(height: height)
    }
}

struct TopDividerShade: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [Color.primary.opacity(0.06), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

struct SoftHorizontalTransition: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [Color.primary.opacity(0.06), Color.clear],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
