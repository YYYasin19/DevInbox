import SwiftUI

/// Shared design tokens, so every list, chip and control uses the same geometry and colors.
enum Theme {
    enum Radius {
        static let panel: CGFloat = 14
        /// Highlights, buttons and segments: concentric with the panel corner at an 8pt inset.
        static let control: CGFloat = 6
        /// Banners and command rows.
        static let card: CGFloat = 8
    }

    enum Inset {
        /// Where fills start: highlights, pills, cards.
        static let fill: CGFloat = 8
        /// Where text and icons start.
        static let content: CGFloat = 16
        /// Trailing padding for a row of 24pt icon buttons, so their glyphs end where row text ends.
        static let iconTrailing: CGFloat = 12
    }

    /// Shared row geometry, so text starts at the same x in every list and section header.
    enum Row {
        /// Between the highlight's leading edge and the unread marker.
        static let leadingPadding: CGFloat = 2
        static let markerColumn: CGFloat = 10
        static let iconColumn: CGFloat = 20
        static let gap: CGFloat = 6
        /// Where row text and separators start, measured from the panel edge.
        static let textColumn: CGFloat = Inset.fill + leadingPadding + markerColumn + iconColumn + gap
    }

    /// Control sizes and feedback, so pills and icon buttons line up and respond alike wherever they sit.
    enum Control {
        /// Toolbar pills and the icon buttons in rows and section headers.
        static let compactHeight: CGFloat = 22
        /// The panel header: tabs, the moon and its icon buttons.
        static let regularHeight: CGFloat = 28
        /// Pressed controls shrink a little, so a click feels registered.
        static let pressedScale: CGFloat = 0.97
    }

    /// Neutral fills for controls (see `NSColor.hoverFill` and its siblings).
    enum Fill {
        static let hover = Color(nsColor: .hoverFill)
        static let selected = Color(nsColor: .selectedFill)
        static let pressed = Color(nsColor: .pressedFill)
    }

    /// Opaque panel surface: dense text lists stay legible whatever is behind the panel.
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    static let tooltipBackground = Color(nsColor: .tooltipBackground)

    /// Hover feedback follows the mouse quickly; keyboard-driven changes never animate.
    static let hoverAnimation = Animation.easeOut(duration: 0.1)
}

/// Semantic status colors. System greens and oranges are too light for text on white, so text and
/// icons use darker shades in light mode and brighter ones in dark mode.
enum Tone {
    case success, failure, warning, merged, attention, neutral

    /// Text and icons inside chips and next to status icons.
    var foregroundColor: NSColor {
        switch self {
        case .success: .dynamic(light: 0x116329, dark: 0x56D364)
        case .failure: .dynamic(light: 0xA40E26, dark: 0xFF7B72)
        case .warning: .dynamic(light: 0x7D4E00, dark: 0xE3B341)
        case .merged: .dynamic(light: 0x6639BA, dark: 0xBC8CFF)
        case .attention: .dynamic(light: 0x0550AE, dark: 0x79C0FF)
        case .neutral: .secondaryLabelColor
        }
    }

    /// Standalone symbols, such as the state icon at the start of a row.
    var symbolColor: NSColor {
        switch self {
        case .success: .dynamic(light: 0x1A7F37, dark: 0x56D364)
        case .failure: .dynamic(light: 0xCF222E, dark: 0xFF7B72)
        case .warning: .dynamic(light: 0x9A6700, dark: 0xE3B341)
        case .merged: .dynamic(light: 0x8250DF, dark: 0xBC8CFF)
        case .attention: .dynamic(light: 0x0969DA, dark: 0x79C0FF)
        case .neutral: .secondaryLabelColor
        }
    }

    /// Chip background.
    var fillColor: NSColor {
        switch self {
        case .success: .dynamic(light: 0x1A7F37, dark: 0x56D364, lightAlpha: 0.12, darkAlpha: 0.14)
        case .failure: .dynamic(light: 0xCF222E, dark: 0xFF7B72, lightAlpha: 0.12, darkAlpha: 0.14)
        case .warning: .dynamic(light: 0x9A6700, dark: 0xE3B341, lightAlpha: 0.12, darkAlpha: 0.14)
        case .merged: .dynamic(light: 0x8250DF, dark: 0xBC8CFF, lightAlpha: 0.12, darkAlpha: 0.14)
        case .attention: .dynamic(light: 0x0969DA, dark: 0x79C0FF, lightAlpha: 0.12, darkAlpha: 0.14)
        case .neutral: NSColor.labelColor.withAlphaComponent(0.08)
        }
    }

    var foreground: Color { Color(nsColor: foregroundColor) }
    var symbol: Color { Color(nsColor: symbolColor) }
    var fill: Color { Color(nsColor: fillColor) }
}

extension NSColor {
    /// Neutral fills for controls, a little stronger in dark mode where low opacities disappear.
    static let hoverFill = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    static let selectedFill = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.11)
    static let pressedFill = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.16)
    /// The highlighted row. Neutral, so it doesn't wash out blue chips or compete with the unread dot.
    static let selectionFill = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.10)

    static let tooltipBackground = NSColor.dynamic(light: 0x1C1C1E, dark: 0x3A3A3C, lightAlpha: 0.94, darkAlpha: 0.98)

    /// A color that resolves per appearance. Nonisolated because AppKit may resolve it off the main thread.
    nonisolated static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }
}
