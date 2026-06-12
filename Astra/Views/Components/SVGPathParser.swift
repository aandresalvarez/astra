import SwiftUI
import CoreGraphics

/// Minimal SVG `<path d="…">` → SwiftUI `Path` parser, scoped to what the bundled
/// brand marks need: move/line/horizontal/vertical/cubic/smooth-cubic/arc/close,
/// in both absolute and relative forms. Elliptical arcs are converted to cubic
/// Béziers so large curves (e.g. the Google Cloud body) stay smooth rather than
/// faceted. Returns nil if the data contains a command it does not understand,
/// so callers can fall back to an SF Symbol instead of drawing a broken glyph.
enum SVGPathParser {
    static func parse(_ d: String) -> Path? {
        var scanner = Scanner(Array(d))
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        // The command *before* the one being processed (normalized to upper case).
        // Smooth curves (`S`/`T`) reflect the previous control point only when
        // preceded by the matching curve type, so this must reflect history, not
        // the current command.
        var previousCommand: Character = " "

        func reflectedQuadControl() -> CGPoint {
            guard let lastQuadControl else { return current }
            return CGPoint(x: 2 * current.x - lastQuadControl.x, y: 2 * current.y - lastQuadControl.y)
        }

        func reflectedControl() -> CGPoint {
            guard let lastControl else { return current }
            return CGPoint(x: 2 * current.x - lastControl.x, y: 2 * current.y - lastControl.y)
        }

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            let upperCommand = Character(command.uppercased())
            defer { previousCommand = upperCommand }
            switch upperCommand {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                start = current
                lastControl = nil
                // Subsequent implicit coordinate pairs are line-tos.
                while scanner.hasNumber {
                    guard let lx = scanner.number(), let ly = scanner.number() else { return nil }
                    current = relative ? CGPoint(x: current.x + lx, y: current.y + ly) : CGPoint(x: lx, y: ly)
                    path.addLine(to: current)
                }
                lastControl = nil

            case "L":
                while scanner.hasNumber {
                    guard let x = scanner.number(), let y = scanner.number() else { return nil }
                    current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    path.addLine(to: current)
                }
                lastControl = nil

            case "H":
                while scanner.hasNumber {
                    guard let x = scanner.number() else { return nil }
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
                lastControl = nil

            case "V":
                while scanner.hasNumber {
                    guard let y = scanner.number() else { return nil }
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                }
                lastControl = nil

            case "C":
                while scanner.hasNumber {
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return nil }
                    let c1 = point(x1, y1, relativeTo: current, relative)
                    let c2 = point(x2, y2, relativeTo: current, relative)
                    let end = point(x, y, relativeTo: current, relative)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                }

            case "S":
                // The first segment reflects only if the *preceding* command was a
                // cubic; every later segment in this same `S` run is itself
                // preceded by a cubic, so it reflects too.
                var segmentPrevious = previousCommand
                while scanner.hasNumber {
                    guard let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return nil }
                    let c1 = (segmentPrevious == "C" || segmentPrevious == "S") ? reflectedControl() : current
                    let c2 = point(x2, y2, relativeTo: current, relative)
                    let end = point(x, y, relativeTo: current, relative)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                    segmentPrevious = "S"
                }

            case "Q":
                while scanner.hasNumber {
                    guard let cx = scanner.number(), let cy = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return nil }
                    let control = point(cx, cy, relativeTo: current, relative)
                    let end = point(x, y, relativeTo: current, relative)
                    path.addQuadCurve(to: end, control: control)
                    lastQuadControl = control
                    current = end
                }
                lastControl = nil

            case "T":
                // Smooth quadratic: reflect the previous quad control when the run
                // is preceded by a quadratic; otherwise the control is the point.
                var segmentPrevious = previousCommand
                while scanner.hasNumber {
                    guard let x = scanner.number(), let y = scanner.number() else { return nil }
                    let control = (segmentPrevious == "Q" || segmentPrevious == "T") ? reflectedQuadControl() : current
                    let end = point(x, y, relativeTo: current, relative)
                    path.addQuadCurve(to: end, control: control)
                    lastQuadControl = control
                    current = end
                    segmentPrevious = "T"
                }
                lastControl = nil

            case "A":
                while scanner.hasNumber {
                    guard let rx = scanner.number(), let ry = scanner.number(),
                          let rot = scanner.number(),
                          let large = scanner.flag(), let sweep = scanner.flag(),
                          let x = scanner.number(), let y = scanner.number() else { return nil }
                    let end = point(x, y, relativeTo: current, relative)
                    appendArc(to: &path, from: current, to: end,
                              rx: rx, ry: ry, xRotationDegrees: rot,
                              largeArc: large != 0, sweep: sweep != 0)
                    current = end
                }
                lastControl = nil

            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil

            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    private static func point(_ x: Double, _ y: Double, relativeTo base: CGPoint, _ relative: Bool) -> CGPoint {
        relative ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
    }

    // MARK: - Arc → cubic Béziers (per the SVG implementation notes)

    private static func appendArc(
        to path: inout Path,
        from p0: CGPoint, to p1: CGPoint,
        rx rxIn: Double, ry ryIn: Double,
        xRotationDegrees: Double, largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0 == p1) {
            path.addLine(to: p1)
            return
        }
        let phi = xRotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Scale radii up if they are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s
        }

        let rx2 = rx * rx, ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coef = den == 0 ? 0 : (num / den).squareRoot()
        if largeArc == sweep { coef = -coef }

        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = len == 0 ? 0 : acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / Double(segments)
        let t = (4.0 / 3.0) * tan(delta / 4)

        var angleStart = theta1
        for _ in 0..<segments {
            let angleEnd = angleStart + delta
            let cosA1 = cos(angleStart), sinA1 = sin(angleStart)
            let cosA2 = cos(angleEnd), sinA2 = sin(angleEnd)

            func map(_ ex: Double, _ ey: Double) -> CGPoint {
                CGPoint(
                    x: cosPhi * (rx * ex) - sinPhi * (ry * ey) + cx,
                    y: sinPhi * (rx * ex) + cosPhi * (ry * ey) + cy
                )
            }

            let end = map(cosA2, sinA2)
            let c1 = map(cosA1 - t * sinA1, sinA1 + t * cosA1)
            let c2 = map(cosA2 + t * sinA2, sinA2 - t * cosA2)
            path.addCurve(to: end, control1: c1, control2: c2)
            angleStart = angleEnd
        }
    }

    // MARK: - Tokeniser

    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ chars: [Character]) { self.chars = chars }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                || chars[i] == "\t" || chars[i] == "\r" {
                i += 1
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter else { return nil }
            let c = chars[i]
            i += 1
            return c
        }

        var hasNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n"
                || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
            guard j < chars.count else { return false }
            let c = chars[j]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        mutating func number() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            var s = ""
            if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." {
                    if sawDot { break }  // a second dot starts a new number
                    sawDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            return Double(s)
        }

        /// Arc flags are a single `0` or `1`, often not separated from the next
        /// number ("…0 0 0-9.234…"), so read exactly one digit.
        mutating func flag() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "0" { i += 1; return 0 }
            if c == "1" { i += 1; return 1 }
            return number()
        }
    }
}
