import SwiftUI

// A theme's design in SwiftUI's units: what the views ask the palette —
// the active one through `DefaultTheme`, any other (a preview) directly.

public extension ThemePalette {

    /// A corner radius of the charter, on the theme's scale.
    func radius(_ charter: CGFloat) -> CGFloat {
        guard let design else { return charter }
        return CGFloat(design.radius(Double(charter)))
    }

    /// A padding, a gap or a control's height of the charter, in the theme's spacing.
    func space(_ charter: CGFloat) -> CGFloat {
        guard let design else { return charter }
        return CGFloat(design.space(Double(charter)))
    }

    /// The theme's letter-spacing, in points: the same for every text,
    /// 0 without one.
    var tracking: CGFloat {
        guard let design else { return 0 }
        return CGFloat(design.tracking)
    }

    /// The theme's font: `--font-mono` for a monospaced design, `--font-serif`
    /// for a serif one, `--font-sans` otherwise — read like a browser reads
    /// a font stack, down to the system's own face.
    @MainActor
    func font(size: CGFloat, weight: Font.Weight? = nil, design fontDesign: Font.Design? = nil) -> Font {
        let stack: String?
        switch fontDesign {
        case .monospaced?: stack = design?.fontMono
        case .serif?: stack = design?.fontSerif
        case .rounded?: stack = nil
        default: stack = design?.fontSans
        }
        guard let stack, !stack.isEmpty else {
            return .system(size: size, weight: weight, design: fontDesign)
        }
        return ThemeFonts.shared.font(stack: stack, size: size, weight: weight, design: fontDesign)
    }
}

// MARK: - Text and views

public extension Text {

    /// The theme's font at this size, with its letter-spacing — what
    /// `.font(.system(size:…))` was. `kerning` or `tracking` is the text's
    /// own, in points (the mono capitals' 5 %): it adds to the theme's
    /// letter-spacing, as `calc(var(--tracking-normal) + …)` does. `palette`
    /// paints with a theme other than the active one (a preview).
    @MainActor
    func themeFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                   kerning: CGFloat? = nil, tracking: CGFloat? = nil,
                   palette: ThemePalette? = nil) -> Text {
        let palette = palette ?? DefaultTheme.palette
        let text = font(palette.font(size: size, weight: weight, design: design))
        let letterSpacing = palette.tracking
        // SwiftUI applies tracking and ignores kerning when a text has both:
        // with a letter-spacing, the text's own kerning joins it.
        if letterSpacing != 0 { return text.tracking(letterSpacing + (tracking ?? kerning ?? 0)) }
        if let tracking { return text.tracking(tracking) }
        if let kerning { return text.kerning(kerning) }
        return text
    }
}

public extension View {

    /// The theme's font at this size, with its letter-spacing, for the
    /// text inside this view — what `.font(.system(size:…))` was. `kerning`
    /// or `tracking`: the view's own, added to the theme's letter-spacing.
    @MainActor
    func themeFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                   kerning: CGFloat? = nil, tracking: CGFloat? = nil,
                   palette: ThemePalette? = nil) -> some View {
        modifier(ThemeFontModifier(size: size, weight: weight, design: design,
                                   kerning: kerning, tracking: tracking, palette: palette))
    }

    /// The theme's shadow at a level of Tailwind's scale (`shadow-xs` a
    /// field, `shadow-sm` a card), cast by a rounded rectangle of the
    /// charter's `radius` behind this view. Nothing for a theme without one.
    @MainActor
    func themeShadow(_ level: ThemeShadow.Level, radius: CGFloat,
                     palette: ThemePalette? = nil) -> some View {
        modifier(ThemeShadowModifier(level: level, radius: radius, palette: palette))
    }
}

struct ThemeFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    let kerning: CGFloat?
    let tracking: CGFloat?
    let palette: ThemePalette?

    func body(content: Content) -> some View {
        let palette = self.palette ?? DefaultTheme.palette
        let font = palette.font(size: size, weight: weight, design: design)
        let letterSpacing = palette.tracking
        // No tracking at all without a letter-spacing: a zero would still
        // win over the kerning of the texts inside.
        if letterSpacing != 0 {
            content.font(font).tracking(letterSpacing + (tracking ?? kerning ?? 0))
        } else if let tracking {
            content.font(font).tracking(tracking)
        } else if let kerning {
            content.font(font).kerning(kerning)
        } else {
            content.font(font)
        }
    }
}

/// CSS's `box-shadow` behind a view: each layer a filled rounded rectangle,
/// grown by its spread, blurred and offset — drawn under the view's own
/// background, so only what sticks out shows.
struct ThemeShadowModifier: ViewModifier {
    let level: ThemeShadow.Level
    let radius: CGFloat
    let palette: ThemePalette?

    func body(content: Content) -> some View {
        let palette = self.palette ?? DefaultTheme.palette
        // The view keeps its place in the tree with or without a shadow:
        // switching theme never resets what it holds.
        content.background {
            if let shadow = palette.design?.shadow, !shadow.isInvisible {
                ZStack {
                    // The first layer is the top one: drawn last.
                    ForEach(Array(shadow.layers(level).enumerated().reversed()), id: \.offset) { _, layer in
                        RoundedRectangle(cornerRadius: palette.radius(radius))
                            .fill(ThemePalette.color(layer.color).opacity(layer.opacity))
                            .padding(-layer.spread)
                            // CSS's blur radius is twice the Gaussian's deviation.
                            .blur(radius: layer.blur / 2)
                            .offset(x: layer.x, y: layer.y)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}
