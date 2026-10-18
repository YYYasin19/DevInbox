import AppKit

/// `ActionButton` for AppKit lists: a 24×22 icon button with the same hover fill, press feedback and
/// tooltip (shown by the list, see `ListView`). It never takes keyboard focus.
final class IconButton: NSView {
    static let size = NSSize(width: 24, height: Theme.Control.compactHeight)
    static let glyphSize: CGFloat = 15

    private(set) var icon: Icon = .check
    private(set) var help = ""
    /// Tells this button's tooltip apart from others.
    var tooltipKey = ""
    private var action: ((NSView) -> Void)?

    /// Scales on press around its center; the view's own layer belongs to AppKit.
    private let body = CALayer()
    private let glyph = CALayer()
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        body.cornerRadius = Theme.Radius.control
        body.cornerCurve = .continuous
        glyph.contentsGravity = .resizeAspect
        body.addSublayer(glyph)
        layer?.addSublayer(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ button: RowButton, key: String) {
        if icon != button.icon || glyph.contents == nil {
            icon = button.icon
            updateColors(animated: false)
        }
        help = button.help
        action = button.action
        tooltipKey = key
        setAccessibilityLabel(button.help)
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        withoutAnimation {
            body.bounds = bounds
            body.position = NSPoint(x: bounds.midX, y: bounds.midY)
            let glyphFrame = NSRect(x: (bounds.width - Self.glyphSize) / 2, y: (bounds.height - Self.glyphSize) / 2, width: Self.glyphSize, height: Self.glyphSize)
            glyph.frame = glyphFrame
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateColors(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors(animated: false)
    }

    /// A reused button starts plain.
    func reset() {
        isHovered = false
        isPressed = false
        updateColors(animated: false)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if isInside { action?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        action?(self)
        return true
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        updateColors(animated: true)
    }

    // MARK: Drawing

    private func updateColors(animated: Bool) {
        let fill: NSColor = isPressed ? .pressedFill : isHovered ? .hoverFill : .clear
        let tint: NSColor = isHovered ? .labelColor : .secondaryLabelColor
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // A tinted image rather than a mask, which snapshots don't render.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            body.backgroundColor = fill.cgColor
            glyph.contents = IconImages.image(icon, size: Self.glyphSize, color: tint, scale: scale)
            glyph.contentsScale = scale
        }
        let pressedScale = isPressed && !reduceMotion ? Theme.Control.pressedScale : 1
        body.transform = CATransform3DMakeScale(pressedScale, pressedScale, 1)
        CATransaction.commit()
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
