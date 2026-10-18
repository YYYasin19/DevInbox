import AppKit

/// A piece of a drawn row line: text, an icon, an avatar or a chip, or a stack of them. Rows describe
/// their lines with these, and `InlineLayout` sizes them the way the SwiftUI stacks they replaced did:
/// higher layout priorities get their width first, less flexible pieces before more flexible ones,
/// and text truncates at the tail. Everything in a line is centered on the same vertical middle.
struct Inline {
    enum Content {
        case text(NSAttributedString)
        case icon(Icon, size: CGFloat, color: NSColor)
        case avatar(URL?, size: CGFloat, isOrganization: Bool)
        case chip(NSAttributedString, icon: Icon?, tone: Tone)
        case spacer(minLength: CGFloat)
        /// Like an `HStack`.
        case stack([Inline], spacing: CGFloat)
        /// Like an `HStack`, but when the pieces don't fit it leaves out the `.droppable()` ones, last
        /// first. The others always keep their full width.
        case dropping([Inline], spacing: CGFloat)
        /// Like `ViewThatFits(in: .horizontal)`: the first variant that fits, else the last.
        case firstFitting([Inline])
    }

    var content: Content
    var priority: Double = 0
    var tooltip: String?
    var isDroppable = false
    var isFixed = false
    var minWidth: CGFloat = 0

    static func text(_ string: String, font: NSFont = .detail, color: NSColor = .secondaryLabelColor) -> Inline {
        Inline(content: .text(NSAttributedString(string: string, attributes: .line(font: font, color: color))))
    }

    static func icon(_ icon: Icon, size: CGFloat, color: NSColor = .secondaryLabelColor) -> Inline {
        Inline(content: .icon(icon, size: size, color: color))
    }

    static func avatar(_ url: URL?, size: CGFloat = 16, isOrganization: Bool = false) -> Inline {
        Inline(content: .avatar(url?.avatarSized(Int(size)), size: size, isOrganization: isOrganization))
    }

    /// A capsule with an optional icon, like the reason and status chips.
    static func chip(_ text: String, icon: Icon?, tone: Tone) -> Inline {
        let label = NSAttributedString(string: text, attributes: .line(font: .detail(.medium), color: tone.foregroundColor))
        return Inline(content: .chip(label, icon: icon, tone: tone))
    }

    static func spacer(minLength: CGFloat) -> Inline {
        Inline(content: .spacer(minLength: minLength))
    }

    static func stack(spacing: CGFloat, _ items: [Inline]) -> Inline {
        Inline(content: .stack(items, spacing: spacing))
    }

    static func dropping(spacing: CGFloat, _ items: [Inline]) -> Inline {
        Inline(content: .dropping(items, spacing: spacing))
    }

    static func firstFitting(_ variants: [Inline]) -> Inline {
        Inline(content: .firstFitting(variants))
    }

    /// The quiet "·" between parts of a detail line.
    static var separator: Inline {
        .text("·", color: .tertiaryLabelColor)
    }

    func layoutPriority(_ priority: Double) -> Inline {
        var copy = self
        copy.priority = priority
        return copy
    }

    func tooltip(_ text: String) -> Inline {
        var copy = self
        copy.tooltip = text.isEmpty ? nil : text
        return copy
    }

    /// Lets a `.dropping` stack leave this piece out when the line is too narrow.
    func droppable() -> Inline {
        var copy = self
        copy.isDroppable = true
        return copy
    }

    /// Always its full width, like `.fixedSize()`.
    func fixedSize() -> Inline {
        var copy = self
        copy.isFixed = true
        return copy
    }

    /// Never narrower than `width`, like `.frame(minWidth:alignment: .leading)`.
    func frame(minWidth width: CGFloat) -> Inline {
        var copy = self
        copy.minWidth = width
        return copy
    }
}

extension NSFont {
    /// SwiftUI's macOS text styles, which the panel was designed with.
    static let body = NSFont.systemFont(ofSize: 13)
    static let bodySemibold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let callout = NSFont.systemFont(ofSize: 12)
    static let calloutSemibold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The detail line: SwiftUI's `.subheadline`.
    static let detail = NSFont.systemFont(ofSize: 11)
    static let detailDigits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static func detail(_ weight: NSFont.Weight) -> NSFont {
        .systemFont(ofSize: 11, weight: weight)
    }

    /// The height SwiftUI gives a line of this font (16 for 13pt, 14 for 11pt).
    var lineHeight: CGFloat {
        if let height = Self.lineHeights[self] { return height }
        let height = ceil(NSAttributedString(string: "Hg", attributes: [.font: self]).size().height)
        Self.lineHeights[self] = height
        return height
    }

    /// From the top of a line to its baseline, where SwiftUI puts it.
    var baselineOffset: CGFloat {
        ceil(ascender)
    }

    private static var lineHeights: [NSFont: CGFloat] = [:]
}

extension [NSAttributedString.Key: Any] {
    /// One line, drawn by Core Text in the color set when drawing (see `TextLine`).
    static func line(font: NSFont, color: NSColor) -> Self {
        [.font: font, .foregroundColor: color, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    }
}

extension NSAttributedString {
    var font: NSFont {
        length > 0 ? attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .detail : .detail
    }

    var color: NSColor {
        length > 0 ? attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .labelColor : .labelColor
    }
}

/// One line of text, cut at the tail with "…" like SwiftUI's `Text`. Drawn with Core Text: AppKit's
/// string drawing squeezes truncated text a little, so more of it fits than in SwiftUI.
struct TextLine {
    let string: NSAttributedString
    let line: CTLine
    let width: CGFloat

    init(_ string: NSAttributedString) {
        self.string = string
        line = CTLineCreateWithAttributedString(string)
        width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private init(string: NSAttributedString, line: CTLine) {
        self.string = string
        self.line = line
        width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Cut to fit `width`, or nil when not even "…" fits.
    func truncated(to width: CGFloat) -> TextLine? {
        guard width < self.width else { return self }
        let attributes = string.length > 0 ? string.attributes(at: 0, effectiveRange: nil) : [:]
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(width), .end, token).map { TextLine(string: string, line: $0) }
    }

    /// Draws the line with its top at `origin`, in a flipped view.
    func draw(at origin: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setFillColor(string.color.cgColor)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + string.font.baselineOffset)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Layout

/// A piece placed in a line, ready to draw.
struct PlacedPiece {
    let content: Inline.Content
    let frame: NSRect
    /// Text pieces: the text as it fits the frame.
    var text: TextLine?
}

/// A tooltip and the area it covers.
struct PlacedTooltip {
    let key: String
    let text: String
    let frame: NSRect
}

/// The pieces of a line with their frames, and the tooltips over them.
struct InlineLayout {
    private(set) var pieces: [PlacedPiece] = []
    private(set) var tooltips: [PlacedTooltip] = []

    /// Lays `item` out from `x`, `width` wide, centered on `centerY`. `key` tells its tooltips apart
    /// from other lines'.
    mutating func place(_ item: Inline, x: CGFloat, width: CGFloat, centerY: CGFloat, key: String) {
        let measured = Measured(item)
        measured.place(x: x, width: measured.width(offered: width), centerY: centerY, into: &self, key: key)
    }

    /// The width `item` takes when offered `width`: its ideal width by default. For pieces the caller
    /// has to align itself, like the right-aligned time.
    static func width(of item: Inline, offered width: CGFloat = .infinity) -> CGFloat {
        let measured = Measured(item)
        return width.isFinite ? measured.width(offered: width) : measured.ideal
    }

    fileprivate mutating func append(_ piece: PlacedPiece) {
        pieces.append(piece)
    }

    fileprivate mutating func append(_ tooltip: PlacedTooltip) {
        tooltips.append(tooltip)
    }

    /// The innermost tooltip at `point`.
    func tooltip(at point: NSPoint) -> PlacedTooltip? {
        tooltips.last { $0.frame.contains(point) }
    }
}

/// An `Inline` measured once, so laying it out doesn't measure its text again.
private final class Measured {
    let item: Inline
    let children: [Measured]
    private var text: TextLine?
    /// The last truncation, which layout asks for twice: to size the piece and to place it.
    private var truncation: (width: CGFloat, line: TextLine?)?
    /// Width when offered as much as it likes, and when offered nothing.
    private(set) var ideal: CGFloat = 0
    private(set) var minimum: CGFloat = 0
    /// Width when offered unlimited room: infinite with a spacer inside.
    private(set) var maximum: CGFloat = 0
    private(set) var height: CGFloat = 0

    init(_ item: Inline) {
        self.item = item
        switch item.content {
        case .stack(let items, _), .dropping(let items, _), .firstFitting(let items):
            children = items.map(Measured.init)
        default:
            children = []
        }
        measure()
    }

    private var spacing: CGFloat {
        switch item.content {
        case .stack(_, let spacing), .dropping(_, let spacing): spacing
        default: 0
        }
    }

    private func totalSpacing(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
    }

    var flexibility: CGFloat {
        maximum - minimum
    }

    private func measure() {
        switch item.content {
        case .text(let string):
            let line = TextLine(string)
            text = line
            // Like SwiftUI's `Text`, it can shrink to nothing.
            (ideal, minimum, maximum) = (line.width, 0, line.width)
            height = string.font.lineHeight
        case .icon(_, let size, _), .avatar(_, let size, _):
            (ideal, minimum, maximum, height) = (size, size, size, size)
        case .chip(let label, let icon, _):
            let width = TextLine(label).width + (icon == nil ? 0 : 12 + 3) + 12
            (ideal, minimum, maximum, height) = (width, width, width, label.font.lineHeight + 2)
        case .spacer(let minLength):
            (ideal, minimum, maximum, height) = (minLength, minLength, .infinity, 0)
        case .stack:
            ideal = children.reduce(0) { $0 + $1.ideal } + totalSpacing(children.count)
            minimum = children.reduce(0) { $0 + $1.minimum } + totalSpacing(children.count)
            maximum = children.reduce(0) { $0 + $1.maximum } + totalSpacing(children.count)
            height = children.map(\.height).max() ?? 0
        case .dropping:
            ideal = children.reduce(0) { $0 + $1.ideal } + totalSpacing(children.count)
            let kept = children.filter { !$0.item.isDroppable }
            minimum = kept.reduce(0) { $0 + $1.ideal } + totalSpacing(kept.count)
            maximum = ideal
            height = children.map(\.height).max() ?? 0
        case .firstFitting:
            ideal = children.first?.ideal ?? 0
            minimum = children.last.map { $0.width(offered: 0) } ?? 0
            maximum = children.first?.maximum ?? 0
            height = children.map(\.height).max() ?? 0
        }
        if item.isFixed {
            (minimum, maximum) = (ideal, ideal)
        }
        ideal = max(ideal, item.minWidth)
        minimum = max(minimum, item.minWidth)
        maximum = max(maximum, item.minWidth)
    }

    /// The width it takes when offered `offered`, like SwiftUI's `sizeThatFits`.
    func width(offered: CGFloat) -> CGFloat {
        if item.isFixed { return ideal }
        let offered = max(offered, item.minWidth)
        let width: CGFloat = switch item.content {
        case .text: offered >= ideal ? ideal : truncated(to: offered)?.width ?? max(offered, 0)
        case .icon, .avatar, .chip: ideal
        case .spacer(let minLength): max(minLength, offered)
        case .stack: allocate(offered).reduce(0, +) + totalSpacing(children.count)
        case .dropping: visible(in: offered).reduce(0) { $0 + children[$1].ideal } + totalSpacing(visible(in: offered).count)
        case .firstFitting: chosen(for: offered)?.width(offered: offered) ?? 0
        }
        return max(width, item.minWidth)
    }

    private func truncated(to width: CGFloat) -> TextLine? {
        if let truncation, truncation.width == width { return truncation.line }
        let line = text?.truncated(to: width)
        truncation = (width, line)
        return line
    }

    private var isSpacer: Bool {
        if case .spacer = item.content { true } else { false }
    }

    /// SwiftUI's `HStack`: higher priorities first, each keeping the minimum widths of the lower ones
    /// free. Within a priority the least flexible first, each offered an equal share of what's left
    /// after the spacers' minimum lengths; the spacers get the rest.
    private func allocate(_ width: CGFloat) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: children.count)
        var remaining = width - totalSpacing(children.count)
        var reserved = children.reduce(0) { $0 + $1.minimum }
        for priority in Set(children.map(\.item.priority)).sorted(by: >) {
            let group = children.indices.filter { children[$0].item.priority == priority }
            reserved -= group.reduce(0) { $0 + children[$1].minimum }
            let spacers = group.filter { children[$0].isSpacer }
            let spacerMinimum = spacers.reduce(0) { $0 + children[$1].minimum }
            var available = remaining - reserved - spacerMinimum
            let ordered = group.filter { !children[$0].isSpacer }.sorted { (children[$0].flexibility, $0) < (children[$1].flexibility, $1) }
            for (position, index) in ordered.enumerated() {
                let share = max(available / CGFloat(ordered.count - position), 0)
                widths[index] = children[index].width(offered: share)
                available -= widths[index]
            }
            available += spacerMinimum
            for (position, index) in spacers.enumerated() {
                widths[index] = children[index].width(offered: available / CGFloat(spacers.count - position))
                available -= widths[index]
            }
            remaining -= group.reduce(0) { $0 + widths[$1] }
        }
        return widths
    }

    /// The children a dropping stack keeps in `width`.
    private func visible(in width: CGFloat) -> [Int] {
        var indices = Array(children.indices)
        func total(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + children[$1].ideal } + totalSpacing(indices.count)
        }
        while total(indices) > width, let drop = indices.last(where: { children[$0].item.isDroppable }) {
            indices.removeAll { $0 == drop }
        }
        return indices
    }

    private func chosen(for width: CGFloat) -> Measured? {
        children.first { $0.ideal <= width } ?? children.last
    }

    func place(x: CGFloat, width: CGFloat, centerY: CGFloat, into layout: inout InlineLayout, key: String) {
        let frame = NSRect(x: x, y: centerY - height / 2, width: width, height: height)
        if let tooltip = item.tooltip {
            layout.append(PlacedTooltip(key: "\(key).\(layout.tooltips.count)", text: tooltip, frame: frame))
        }
        // A minimum width or a fixed size leaves the content at its own width, on the leading edge.
        let contentWidth = item.isFixed ? ideal : width
        switch item.content {
        case .text:
            // Without room for "…" it takes what it's offered and shows nothing.
            let line = contentWidth >= ideal ? text : truncated(to: contentWidth)
            layout.append(PlacedPiece(content: item.content, frame: NSRect(x: x, y: frame.minY, width: line?.width ?? max(contentWidth, 0), height: height), text: line))
        case .icon, .avatar, .chip:
            layout.append(PlacedPiece(content: item.content, frame: NSRect(x: x, y: frame.minY, width: ideal, height: height)))
        case .spacer:
            break
        case .stack:
            var childX = x
            for (child, childWidth) in zip(children, allocate(contentWidth)) {
                child.place(x: childX, width: childWidth, centerY: centerY, into: &layout, key: key)
                childX += childWidth + spacing
            }
        case .dropping:
            var childX = x
            for index in visible(in: contentWidth) {
                let childWidth = min(children[index].ideal, max(x + contentWidth - childX, 0))
                children[index].place(x: childX, width: childWidth, centerY: centerY, into: &layout, key: key)
                childX += childWidth + spacing
            }
        case .firstFitting:
            chosen(for: contentWidth)?.place(x: x, width: contentWidth, centerY: centerY, into: &layout, key: key)
        }
    }
}

// MARK: - Drawing

extension PlacedPiece {
    /// Draws into the current context of a flipped view. `scale` is the backing scale, for icons.
    func draw(scale: CGFloat) {
        switch content {
        case .text:
            text?.draw(at: frame.origin)
        case .icon(let icon, let size, let color):
            IconImages.draw(icon, size: size, color: color, in: frame, scale: scale)
        case .avatar(let url, let size, let isOrganization):
            let path = isOrganization
                ? NSBezierPath(roundedRect: frame, xRadius: size / 4, yRadius: size / 4)
                : NSBezierPath(ovalIn: frame)
            if let url, let image = AvatarCache.shared.cached(url) {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.quaternaryLabelColor.setFill()
                path.fill()
            }
        case .chip(let label, let icon, let tone):
            tone.fillColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
            var x = frame.minX + 6
            if let icon {
                IconImages.draw(icon, size: 12, color: tone.foregroundColor, in: NSRect(x: x, y: frame.midY - 6, width: 12, height: 12), scale: scale)
                x += 12 + 3
            }
            TextLine(label).draw(at: NSPoint(x: x, y: frame.minY + 1))
        case .spacer, .stack, .dropping, .firstFitting:
            break
        }
    }

    /// Avatars that still have to load before the piece can draw them.
    var missingAvatar: URL? {
        guard case .avatar(let url?, _, _) = content, AvatarCache.shared.cached(url) == nil else { return nil }
        return url
    }
}

/// Tinted icons, rendered once per icon, size, color and scale.
enum IconImages {
    private static var cache: [String: NSImage] = [:]

    /// Draws `icon` in the color, which resolves for the current drawing appearance.
    static func draw(_ icon: Icon, size: CGFloat, color: NSColor, in rect: NSRect, scale: CGFloat) {
        guard let image = image(icon, size: size, color: color, scale: scale) else { return }
        let origin = NSPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        image.draw(in: NSRect(origin: origin, size: NSSize(width: size, height: size)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func image(_ icon: Icon, size: CGFloat, color: NSColor, scale: CGFloat) -> NSImage? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let key = "\(icon.rawValue) \(size) \(scale) \(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent) \(rgb.alphaComponent)"
        if let image = cache[key] { return image }
        guard let template = NSImage(named: icon.rawValue) else { return nil }
        let pixels = Int((size * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        template.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        context.setBlendMode(.sourceIn)
        context.setFillColor(rgb.cgColor)
        context.fill(bounds)
        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: bounds.size)
        cache[key] = image
        return image
    }
}
