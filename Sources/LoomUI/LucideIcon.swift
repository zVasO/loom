import SwiftUI

/// A line icon from the Lucide set (lucide.dev, ISC licence), drawn from its
/// own SVG data: 24 × 24 grid, round caps and joins, stroke 1.5 — the icons of
/// the landing page, so the app and the page draw the same marks.
public struct LucideIcon: View {
    public enum Glyph: String, CaseIterable, Sendable {
        case terminal, gitPullRequest, workflow, blocks, folder, layoutGrid, activity
        case plus, x, sparkles, gitBranch, chevronDown, chevronUp, chevronLeft, chevronRight
        case rotateCw, rotateCcw, check, trash, globe, search, link, triangleAlert
        case externalLink, undo, download, settings, eye, copy, compass, dollarSign
        case play, square, messageSquare, panelRight, pin, circleCheck, circleX
        case arrowRight, arrowLeft, menu, listFilter, moon, sun, database, circleUser
        case shield, inbox

        /// The Lucide glyph standing for an SF Symbol the app used, if any.
        public init?(systemName: String) {
            let name = systemName.replacingOccurrences(of: ".fill", with: "")
            switch name {
            case "terminal": self = .terminal
            case "arrow.triangle.pull": self = .gitPullRequest
            case "point.3.connected.trianglepath.dotted": self = .workflow
            case "puzzlepiece.extension": self = .blocks
            case "folder": self = .folder
            case "square.grid.2x2": self = .layoutGrid
            case "waveform.path.ecg": self = .activity
            case "plus": self = .plus
            case "xmark": self = .x
            case "sparkles": self = .sparkles
            case "arrow.triangle.branch": self = .gitBranch
            case "chevron.down": self = .chevronDown
            case "chevron.up": self = .chevronUp
            case "chevron.left": self = .chevronLeft
            case "chevron.right": self = .chevronRight
            case "arrow.clockwise": self = .rotateCw
            case "arrow.counterclockwise": self = .rotateCcw
            case "checkmark": self = .check
            case "trash": self = .trash
            case "globe", "network": self = .globe
            case "magnifyingglass", "text.magnifyingglass": self = .search
            case "link": self = .link
            case "exclamationmark.triangle": self = .triangleAlert
            case "arrow.up.forward.square", "arrow.up.right.square", "arrow.up.forward": self = .externalLink
            case "arrow.uturn.backward": self = .undo
            case "square.and.arrow.down", "tray.and.arrow.down", "arrow.down.circle": self = .download
            case "gearshape", "gear": self = .settings
            case "eye": self = .eye
            case "doc.on.doc": self = .copy
            case "safari": self = .compass
            case "dollarsign", "dollarsign.circle": self = .dollarSign
            case "play", "play.circle": self = .play
            case "stop", "stop.circle": self = .square
            case "text.bubble", "bubble.left", "plus.bubble": self = .messageSquare
            case "sidebar.right": self = .panelRight
            case "pin": self = .pin
            case "checkmark.circle": self = .circleCheck
            case "xmark.circle": self = .circleX
            case "arrow.right": self = .arrowRight
            case "arrow.left": self = .arrowLeft
            case "line.3.horizontal": self = .menu
            case "line.3.horizontal.decrease.circle", "line.3.horizontal.decrease": self = .listFilter
            case "moon": self = .moon
            case "sun.max": self = .sun
            case "cylinder", "externaldrive": self = .database
            case "person.crop.circle": self = .circleUser
            case "lock.shield", "shield": self = .shield
            case "tray": self = .inbox
            default: return nil
            }
        }
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

/// An icon by its SF Symbol name: the Lucide glyph that stands for it when
/// there is one, else the symbol itself, light, at the same optical size.
/// `size` is the icon's box, like Lucide's (a 14 pt box ≈ a 12 pt symbol).
public struct AppIcon: View {
    let systemName: String
    let size: CGFloat

    public init(_ systemName: String, size: CGFloat = 14) {
        self.systemName = systemName
        self.size = size
    }

    public var body: some View {
        if let glyph = LucideIcon.Glyph(systemName: systemName) {
            LucideIcon(glyph, size: size)
        } else {
            Image(systemName: systemName)
                .font(.system(size: (size * 0.84).rounded(), weight: .light))
                .frame(width: size, height: size)
        }
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

    /// Lucide's own elements for each glyph (`<polyline>`, `<polygon>` and
    /// `<line>` written as paths).
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
        case .plus:
            [.d("M5 12h14"), .d("M12 5v14")]
        case .x:
            [.d("M18 6 6 18"), .d("m6 6 12 12")]
        case .sparkles:
            [.d("M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"),
             .d("M20 3v4"), .d("M22 5h-4"), .d("M4 17v2"), .d("M5 18H3")]
        case .gitBranch:
            [.d("M6 3v12"), .circle(18, 6, 3), .circle(6, 18, 3), .d("M18 9a9 9 0 0 1-9 9")]
        case .chevronDown: [.d("m6 9 6 6 6-6")]
        case .chevronUp: [.d("m18 15-6-6-6 6")]
        case .chevronLeft: [.d("m15 18-6-6 6-6")]
        case .chevronRight: [.d("m9 18 6-6-6-6")]
        case .rotateCw:
            [.d("M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"), .d("M21 3v5h-5")]
        case .rotateCcw:
            [.d("M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"), .d("M3 3v5h5")]
        case .check: [.d("M20 6 9 17l-5-5")]
        case .trash:
            [.d("M3 6h18"), .d("M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"), .d("M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"),
             .d("M10 11v6"), .d("M14 11v6")]
        case .globe:
            [.circle(12, 12, 10), .d("M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"), .d("M2 12h20")]
        case .search: [.circle(11, 11, 8), .d("m21 21-4.3-4.3")]
        case .link:
            [.d("M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"),
             .d("M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71")]
        case .triangleAlert:
            [.d("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"),
             .d("M12 9v4"), .d("M12 17h.01")]
        case .externalLink:
            [.d("M15 3h6v6"), .d("M10 14 21 3"), .d("M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6")]
        case .undo:
            [.d("M9 14 4 9l5-5"), .d("M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11")]
        case .download:
            [.d("M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"), .d("M7 10l5 5 5-5"), .d("M12 15V3")]
        case .settings:
            [.d("M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"),
             .circle(12, 12, 3)]
        case .eye:
            [.d("M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"),
             .circle(12, 12, 3)]
        case .copy:
            [.rect(8, 8, 14, 14, 2), .d("M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2")]
        case .compass:
            [.circle(12, 12, 10), .d("M16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88Z")]
        case .dollarSign:
            [.d("M12 2v20"), .d("M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6")]
        case .play: [.d("M6 3 20 12 6 21Z")]
        case .square: [.rect(3, 3, 18, 18, 2)]
        case .messageSquare:
            [.d("M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z")]
        case .panelRight: [.rect(3, 3, 18, 18, 2), .d("M15 3v18")]
        case .pin:
            [.d("M12 17v5"),
             .d("M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z")]
        case .circleCheck: [.circle(12, 12, 10), .d("m9 12 2 2 4-4")]
        case .circleX: [.circle(12, 12, 10), .d("m15 9-6 6"), .d("m9 9 6 6")]
        case .arrowRight: [.d("M5 12h14"), .d("m12 5 7 7-7 7")]
        case .arrowLeft: [.d("m12 19-7-7 7-7"), .d("M19 12H5")]
        case .menu: [.d("M4 12h16"), .d("M4 6h16"), .d("M4 18h16")]
        case .listFilter: [.d("M3 6h18"), .d("M7 12h10"), .d("M10 18h4")]
        case .moon: [.d("M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z")]
        case .sun:
            [.circle(12, 12, 4), .d("M12 2v2"), .d("M12 20v2"), .d("m4.93 4.93 1.41 1.41"), .d("m17.66 17.66 1.41 1.41"),
             .d("M2 12h2"), .d("M20 12h2"), .d("m6.34 17.66-1.41 1.41"), .d("m19.07 4.93-1.41 1.41")]
        case .database:
            [.d("M3 5a9 3 0 1 0 18 0a9 3 0 1 0-18 0"), .d("M3 5V19A9 3 0 0 0 21 19V5"), .d("M3 12A9 3 0 0 0 21 12")]
        case .circleUser:
            [.circle(12, 12, 10), .circle(12, 10, 3), .d("M7 20.662V19a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v1.662")]
        case .shield:
            [.d("M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z")]
        case .inbox:
            [.d("M22 12h-6l-2 3h-4l-2-3H2"),
             .d("M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z")]
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
