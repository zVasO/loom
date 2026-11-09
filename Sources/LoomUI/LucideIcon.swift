import SwiftUI

/// A line icon from the Lucide set (lucide.dev, ISC licence), drawn from its
/// own SVG data: 24 × 24 grid, round caps and joins, stroke 1.5 — the icons of
/// the landing page, so the app and the page draw the same marks.
public struct LucideIcon: View {
    public enum Glyph: String, CaseIterable, Sendable {
        case terminal, gitPullRequest, workflow, blocks, folder, layoutGrid, activity
    }

    let glyph: Glyph
    let size: CGFloat
    let lineWidth: CGFloat

    /// `lineWidth` is in Lucide's 24-unit grid, like its `stroke-width`.
    public init(_ glyph: Glyph, size: CGFloat = 14, lineWidth: CGFloat = 1.5) {
        self.glyph = glyph
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        LucideShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The glyph as a shape, its 24-unit grid scaled to the rect.
public struct LucideShape: Shape {
    let glyph: LucideIcon.Glyph

    public init(glyph: LucideIcon.Glyph) {
        self.glyph = glyph
    }

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return LucideShape.gridPath(glyph)
            .applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.minX, ty: rect.minY))
    }

    /// The glyph in its own 24 × 24 grid.
    static func gridPath(_ glyph: LucideIcon.Glyph) -> Path {
        var path = Path()
        for element in elements(glyph) {
            switch element {
            case .d(let data): path.addPath(SVGPathData.path(data))
            case .circle(let cx, let cy, let r):
                path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case .rect(let x, let y, let w, let h, let rx):
                path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                                    cornerSize: CGSize(width: rx, height: rx))
            }
        }
        return path
    }

    enum Element {
        case d(String)
        case circle(CGFloat, CGFloat, CGFloat)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }

    /// Lucide's own elements for each glyph (`<polyline>` and `<line>` written as paths).
    static func elements(_ glyph: LucideIcon.Glyph) -> [Element] {
        switch glyph {
        case .terminal:
            [.d("M4 17 10 11 4 5"), .d("M12 19h8")]
        case .gitPullRequest:
            [.circle(18, 18, 3), .circle(6, 6, 3), .d("M13 6h3a2 2 0 0 1 2 2v7"), .d("M6 9v12")]
        case .workflow:
            [.rect(3, 3, 8, 8, 2), .d("M7 11v4a2 2 0 0 0 2 2h4"), .rect(13, 13, 8, 8, 2)]
        case .blocks:
            [.rect(14, 3, 7, 7, 1),
             .d("M10 21V8a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-5a1 1 0 0 0-1-1H3")]
        case .folder:
            [.d("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z")]
        case .layoutGrid:
            [.rect(3, 3, 7, 7, 1), .rect(14, 3, 7, 7, 1), .rect(14, 14, 7, 7, 1), .rect(3, 14, 7, 7, 1)]
        case .activity:
            [.d("M22 12h-4l-3 9L9 3l-3 9H2")]
        }
    }
}

/// The subset of SVG path data Lucide uses: M L H V C A Z, absolute and relative.
enum SVGPathData {

    static func path(_ data: String) -> Path {
        var path = Path()
        var tokens = Tokens(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        while let next = tokens.peekCommand() ?? (tokens.hasNumber ? command : nil) {
            if tokens.peekCommand() != nil { tokens.consumeCommand() }
            command = next
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard let p = tokens.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                start = current
                path.move(to: current)
                // Further pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L":
                guard let p = tokens.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addLine(to: current)
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
            case "C":
                guard let c1 = tokens.point(), let c2 = tokens.point(), let p = tokens.point() else { return path }
                let end = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addCurve(to: end,
                              control1: CGPoint(x: base.x + c1.x, y: base.y + c1.y),
                              control2: CGPoint(x: base.x + c2.x, y: base.y + c2.y))
                current = end
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let large = tokens.number(), let sweep = tokens.number(), let p = tokens.point()
                else { return path }
                let end = CGPoint(x: base.x + p.x, y: base.y + p.y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry, rotation: rotation,
                       largeArc: large != 0, sweep: sweep != 0)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
            default:
                return path
            }
        }
        return path
    }

    /// SVG endpoint arc → centre parameterisation (SVG 1.1, F.6.5), drawn as
    /// cubic segments of at most a quarter turn.
    static func addArc(to path: inout Path, from p1: CGPoint, to p2: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        guard p1 != p2 else { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else { path.addLine(to: p2); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let coef = sign * sqrt(max(0, numerator / denominator))
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        func onEllipse(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * ux - ry * sinPhi * uy,
                    y: cy + rx * sinPhi * ux + ry * cosPhi * uy)
        }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = theta1
        for index in 0..<segments {
            let t2 = t + step
            let c1 = onEllipse(cos(t) - k * sin(t), sin(t) + k * cos(t))
            let c2 = onEllipse(cos(t2) + k * sin(t2), sin(t2) - k * cos(t2))
            let end = index == segments - 1 ? p2 : onEllipse(cos(t2), sin(t2))
            path.addCurve(to: end, control1: c1, control2: c2)
            t = t2
        }
    }

    /// Commands and numbers, read in order. Numbers follow SVG's compact
    /// grammar: "1-9" is two numbers, ".25.25" too.
    struct Tokens {
        private let chars: [Character]
        private var index = 0

        init(_ data: String) {
            chars = Array(data)
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index].isNewline {
                index += 1
            }
        }

        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter, chars[index] != "e", chars[index] != "E" else { return nil }
            return chars[index]
        }

        mutating func consumeCommand() {
            index += 1
        }

        var hasNumber: Bool {
            var probe = self
            return probe.number() != nil
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var seenDot = false, seenDigit = false, seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c == "-" || c == "+" {
                    // A sign starts a number, or follows an exponent.
                    guard text.isEmpty || text.last == "e" || text.last == "E" else { break }
                } else if c == "." {
                    guard !seenDot, !seenExponent else { break }
                    seenDot = true
                } else if c == "e" || c == "E" {
                    guard seenDigit, !seenExponent else { break }
                    seenExponent = true
                } else if c.isNumber {
                    seenDigit = true
                } else {
                    break
                }
                text.append(c)
                index += 1
            }
            guard seenDigit, let value = Double(text) else { return nil }
            return CGFloat(value)
        }
    }

    /// Every number of a path's data, in order — for tests.
    static func numbers(in data: String) -> [CGFloat] {
        var tokens = Tokens(data)
        var out: [CGFloat] = []
        while true {
            if tokens.peekCommand() != nil { tokens.consumeCommand(); continue }
            guard let value = tokens.number() else { break }
            out.append(value)
        }
        return out
    }
}
