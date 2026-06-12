import SwiftUI

// Real brand marks for capability rows. The app ships no asset catalog and the
// custom bundling step makes one fragile, so brand glyphs are rendered from
// their vector path data directly into a SwiftUI `Path`. The path strings are
// the official single-colour marks from Simple Icons (CC0 / public domain); the
// trademarks belong to their owners and are used here only to identify the
// integration each capability talks to.
//
// Marks are monochrome (they inherit `foregroundStyle`), which keeps them
// legible in both light and dark mode and consistent with the SF Symbol icons
// they sit beside.

enum BrandMark: String, CaseIterable {
    case github
    case jira
    case googleCloud
    case googleDrive

    /// Resolve a capability's brand from its identifier and display name. Returns
    /// nil when the capability has no well-known mark (it then keeps its SF
    /// Symbol). Matching is deliberately loose so package, agent, and connector
    /// rows that share a brand all light up.
    static func resolve(id: String, name: String) -> BrandMark? {
        let haystack = "\(id) \(name)".lowercased()
        if haystack.contains("github") { return .github }
        if haystack.contains("jira") { return .jira }
        if haystack.contains("google drive") || haystack.contains("gdrive") { return .googleDrive }
        if haystack.contains("google cloud") || haystack.contains("gcloud")
            || haystack.contains("bigquery") || haystack.contains("gcp") { return .googleCloud }
        return nil
    }

    /// The mark's SVG `d` path data on a 24×24 viewBox.
    var pathData: String {
        switch self {
        case .github:
            return "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
        case .jira:
            return "M11.571 11.513H0a5.218 5.218 0 0 0 5.232 5.215h2.13v2.057A5.215 5.215 0 0 0 12.575 24V12.518a1.005 1.005 0 0 0-1.005-1.005zm5.723-5.756H5.736a5.215 5.215 0 0 0 5.215 5.214h2.129v2.058a5.218 5.218 0 0 0 5.215 5.214V6.758a1.001 1.001 0 0 0-1.001-1.001zM23.013 0H11.455a5.215 5.215 0 0 0 5.215 5.215h2.129v2.057A5.215 5.215 0 0 0 24 12.483V1.005A1.001 1.001 0 0 0 23.013 0Z"
        case .googleCloud:
            return "M12.19 2.38a9.344 9.344 0 0 0-9.234 6.893c.053-.02-.055.013 0 0-3.875 2.551-3.922 8.11-.247 10.941l.006-.007-.007.03a6.717 6.717 0 0 0 4.077 1.356h5.173l.03.03h5.192c6.687.053 9.376-8.605 3.835-12.35a9.365 9.365 0 0 0-2.821-4.552l-.043.043.006-.05A9.344 9.344 0 0 0 12.19 2.38zm-.358 4.146c1.244-.04 2.518.368 3.486 1.15a5.186 5.186 0 0 1 1.862 4.078v.518c3.53-.07 3.53 5.262 0 5.193h-5.193l-.008.009v-.04H6.785a2.59 2.59 0 0 1-1.067-.23h.001a2.597 2.597 0 1 1 3.437-3.437l3.013-3.012A6.747 6.747 0 0 0 8.11 8.24c.018-.01.04-.026.054-.023a5.186 5.186 0 0 1 3.67-1.69z"
        case .googleDrive:
            return "M12.01 1.485c-2.082 0-3.754.02-3.743.047.01.02 1.708 3.001 3.774 6.62l3.76 6.574h3.76c2.081 0 3.753-.02 3.742-.047-.005-.02-1.708-3.001-3.775-6.62l-3.76-6.574zm-4.76 1.73a789.828 789.861 0 0 0-3.63 6.319L0 15.868l1.89 3.298 1.885 3.297 3.62-6.335 3.618-6.33-1.88-3.287C8.1 4.704 7.255 3.22 7.25 3.214zm2.259 12.653-.203.348c-.114.198-.96 1.672-1.88 3.287a423.93 423.948 0 0 1-1.698 2.97c-.01.026 3.24.042 7.222.042h7.244l1.796-3.157c.992-1.734 1.85-3.23 1.906-3.323l.104-.167h-7.249z"
        }
    }

    /// The parsed mark, on its native 24×24 viewBox. Parsed once and reused.
    var path: Path { Self.cache[self] ?? Path() }

    private static let cache: [BrandMark: Path] = {
        var map: [BrandMark: Path] = [:]
        for mark in BrandMark.allCases {
            if let path = SVGPathParser.parse(mark.pathData) {
                map[mark] = path
            }
        }
        return map
    }()
}

/// A brand mark scaled to fit its frame, preserving the 24×24 viewBox so each
/// glyph keeps its intended internal padding and sits at the same optical weight
/// as the SF Symbols beside it.
struct BrandMarkShape: Shape {
    let mark: BrandMark
    private let viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let base = mark.path
        guard !base.isEmpty else { return base }
        let scale = min(rect.width, rect.height) / viewBox
        let drawn = viewBox * scale
        let transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - drawn) / 2,
            y: rect.minY + (rect.height - drawn) / 2
        ).scaledBy(x: scale, y: scale)
        return base.applying(transform)
    }
}

/// Leading icon for a capability: the brand mark when one is known, otherwise
/// the capability's SF Symbol. Both inherit the caller's foreground style.
struct CapabilityLeadingIcon: View {
    let systemImage: String
    let brand: BrandMark?
    let pointSize: CGFloat

    var body: some View {
        if let brand {
            // Brand marks fill more of their box than SF Symbols, so render a
            // touch smaller to sit at the same optical weight as sibling rows.
            BrandMarkShape(mark: brand)
                .frame(width: pointSize * 0.92, height: pointSize * 0.92)
        } else {
            Image(systemName: systemImage)
                .font(Stanford.ui(pointSize, weight: .medium))
        }
    }
}
