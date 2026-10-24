import AppKit

/// Quiet, opaque card surfaces. Only a small selection tint uses the user's system accent.
struct MenuAppearance {
    let dark: Bool
    var surface: NSColor { NSColor(white: dark ? 0.19 : 0.98, alpha: 1) }
    var edge: NSColor { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.10) }
    var trim: NSColor { NSColor(white: dark ? 0.55 : 0.72, alpha: 1) }
    var rail: NSColor { NSColor(white: dark ? 0.27 : 0.87, alpha: 1) }
    var ink: NSColor { NSColor(white: dark ? 0.94 : 0.16, alpha: 1) }

    func card(_ index: Int, selection: CGFloat) -> NSColor {
        let hint = [NSColor.systemBlue, .systemGray, .systemTeal, .systemOrange][index % 4]
        return surface.mix(hint, dark ? 0.035 : 0.025)
            .mix(.controlAccentColor, min(max(selection, 0), 1) * (dark ? 0.14 : 0.07))
    }
}

/// Persist an opaque sRGB value, rather than archiving AppKit objects into preferences.
struct RGBColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = Self.bounded(red)
        self.green = Self.bounded(green)
        self.blue = Self.bounded(blue)
    }
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
    private static func bounded(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0.5 }
    var sanitized: Self { Self(red, green, blue) }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct ClotheslineColors: Codable, Equatable {
    var rope = RopeColorPreset.silver.rgb!
    var peg = RopeColorPreset.silver.rgb!
    var sanitized: Self { Self(rope: rope.sanitized, peg: peg.sanitized) }
}

enum RopeColorPreset: String, CaseIterable {
    case silver, graphite, sand, sage, mist, rose, custom
    var title: String {
        switch self {
        case .silver: L("Silver")
        case .graphite: L("Graphite")
        case .sand: L("Sand")
        case .sage: L("Sage")
        case .mist: L("Mist Blue")
        case .rose: L("Dusty Rose")
        case .custom: L("Custom")
        }
    }
    var rgb: RGBColor? {
        switch self {
        case .silver: RGBColor(0.76, 0.78, 0.80)
        case .graphite: RGBColor(0.40, 0.43, 0.47)
        case .sand: RGBColor(0.77, 0.72, 0.64)
        case .sage: RGBColor(0.65, 0.73, 0.69)
        case .mist: RGBColor(0.64, 0.72, 0.79)
        case .rose: RGBColor(0.79, 0.68, 0.70)
        case .custom: nil
        }
    }
    static func matching(_ rgb: RGBColor) -> Self { allCases.first { $0.rgb == rgb } ?? .custom }
}

/// Each template owns a four-colour palette and an optional supporting shelf colour.
struct TemplatePalette: Codable, Equatable {
    var colors: [RGBColor]
    var rail: RGBColor

    static let native = TemplatePalette(colors: [RGBColor(0.96, 0.97, 0.98), RGBColor(0.98, 0.98, 0.98),
                                                 RGBColor(0.96, 0.98, 0.97), RGBColor(0.99, 0.98, 0.96)],
                                        rail: RGBColor(0.87, 0.87, 0.87))
    var sanitized: Self {
        let safe = colors.prefix(4).map(\.sanitized)
        return Self(colors: safe + Array(Self.native.colors.dropFirst(safe.count)), rail: rail.sanitized)
    }

    func card(_ index: Int, dark: Bool, selection: CGFloat = 0) -> NSColor {
        let theme = MenuAppearance(dark: dark)
        if colors == Self.native.colors { return theme.card(index, selection: selection) }
        let color = colors.isEmpty ? Self.native.colors[index % 4].color : colors[index % colors.count].color
        let base = dark ? theme.surface.mix(color, 0.24) : color
        return base.mix(.controlAccentColor, min(max(selection, 0), 1) * (dark ? 0.14 : 0.07))
    }

    func railColor(dark: Bool) -> NSColor {
        if rail == Self.native.rail { return MenuAppearance(dark: dark).rail }
        return dark ? MenuAppearance(dark: dark).rail.mix(rail.color, 0.28) : rail.color
    }

    /// Choose text by contrast, including custom near-black colours in light appearance.
    func ink(_ index: Int, dark: Bool, selection: CGFloat = 0) -> NSColor {
        let rgb = card(index, dark: dark, selection: selection).usingColorSpace(.sRGB)!
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        if luminance < 0.179 { return .white }
        return luminance >= 0.221 ? NSColor(white: 0.10, alpha: 1) : .black
    }
}

enum ColorTemplate: String, CaseIterable {
    case shelf, notes
    var style: MenuStyle { self == .shelf ? .shelf : .notes }
    var title: String { style.title }
}

struct TemplateColors: Codable, Equatable {
    var shelf = TemplatePalette.native
    var notes = TemplatePalette.native
    subscript(_ template: ColorTemplate) -> TemplatePalette {
        get { template == .shelf ? shelf : notes }
        set {
            if template == .shelf { shelf = newValue.sanitized } else { notes = newValue.sanitized }
        }
    }
    var sanitized: Self { Self(shelf: shelf.sanitized, notes: notes.sanitized) }
}

enum TemplateColorPreset: String, CaseIterable {
    case native, mist, sage, sand, rose, lavender, custom
    var title: String {
        switch self {
        case .native: L("Soft Neutrals")
        case .mist: L("Misty Coast")
        case .sage: L("Sage Garden")
        case .sand: L("Warm Linen")
        case .rose: L("Rose Clay")
        case .lavender: L("Lavender Haze")
        case .custom: L("Custom")
        }
    }
    var palette: TemplatePalette? {
        switch self {
        case .native: .native
        case .mist: TemplatePalette(colors: [RGBColor(0.83, 0.89, 0.93), RGBColor(0.89, 0.93, 0.95), RGBColor(0.84, 0.90, 0.90), RGBColor(0.91, 0.92, 0.94)], rail: RGBColor(0.71, 0.77, 0.81))
        case .sage: TemplatePalette(colors: [RGBColor(0.84, 0.89, 0.83), RGBColor(0.91, 0.93, 0.87), RGBColor(0.85, 0.91, 0.88), RGBColor(0.92, 0.91, 0.85)], rail: RGBColor(0.72, 0.77, 0.70))
        case .sand: TemplatePalette(colors: [RGBColor(0.94, 0.89, 0.80), RGBColor(0.96, 0.93, 0.87), RGBColor(0.90, 0.87, 0.81), RGBColor(0.93, 0.89, 0.85)], rail: RGBColor(0.79, 0.73, 0.64))
        case .rose: TemplatePalette(colors: [RGBColor(0.93, 0.85, 0.85), RGBColor(0.95, 0.90, 0.88), RGBColor(0.90, 0.85, 0.87), RGBColor(0.93, 0.88, 0.82)], rail: RGBColor(0.79, 0.70, 0.70))
        case .lavender: TemplatePalette(colors: [RGBColor(0.88, 0.85, 0.93), RGBColor(0.93, 0.90, 0.96), RGBColor(0.85, 0.88, 0.93), RGBColor(0.92, 0.88, 0.91)], rail: RGBColor(0.74, 0.71, 0.80))
        case .custom: nil
        }
    }
    static func matching(_ palette: TemplatePalette) -> Self { allCases.first { $0.palette == palette } ?? .custom }
}
