import AppKit

/// Base of every cell in a `ListView`: flipped, and able to name the tooltip under the pointer.
class ListCell: NSView {
    /// The entry the cell shows.
    var entryID = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The tooltip at `point`, in the cell's coordinates.
    func tooltip(at point: NSPoint) -> PlacedTooltip? { nil }

    var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Redraws once the avatars of `layout` have loaded.
    func loadAvatars(of layouts: [InlineLayout]) {
        let id = entryID
        for url in Set(layouts.flatMap(\.pieces).compactMap(\.missingAvatar)) {
            Task { [weak self] in
                _ = await AvatarCache.shared.image(for: url)
                guard let self, entryID == id else { return }
                needsDisplay = true
                subviews.forEach { $0.needsDisplay = true }
            }
        }
    }
}

/// How a row is highlighted, decided by the list.
struct RowState: Equatable {
    var isSelected = false
    /// The pointer selected it (or it just copied something): the time gives way to the buttons.
    var showsActions = false
    var showsSeparator = false
}

// MARK: - Row

/// A two-line row (see `RowModel`). The highlight and the separator are layers of their own, so moving
/// the highlight doesn't redraw any text.
final class RowCell: ListCell {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    private let highlight = FillView(color: .selectionFill, cornerRadius: Theme.Radius.control)
    private let separator = FillView(color: .separatorColor)
    private let content = RowContentView()
    private var buttons: [IconButton] = []
    private(set) var model: RowModel?
    private(set) var state = RowState()
    private var configuredWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(highlight)
        addSubview(separator)
        addSubview(content)
        content.cell = self
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ model: RowModel, id: String, state: RowState) {
        let isNewEntry = id != entryID
        entryID = id
        self.model = model
        while buttons.count < model.buttons.count {
            let button = IconButton()
            addSubview(button)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            if index < model.buttons.count {
                button.configure(model.buttons[index], key: "\(id).button\(index)")
                if isNewEntry { button.reset() }
            }
        }
        setAccessibilityLabel(model.title)
        setAccessibilityCustomActions(model.buttons.map { button in
            NSAccessibilityCustomAction(name: button.help) { [weak self] in
                guard let self else { return false }
                button.action(self)
                return true
            }
        })
        self.state = state
        layOutContent()
        apply(state, force: true)
    }

    func apply(_ state: RowState, force: Bool = false) {
        guard force || state != self.state else { return }
        let actionsChanged = state.showsActions != self.state.showsActions
        self.state = state
        highlight.isHidden = !state.isSelected
        separator.isHidden = !state.showsSeparator
        highlight.showsBorder = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        updateButtons()
        if actionsChanged || force {
            content.needsDisplay = true
        }
    }

    private var rowHeight: CGFloat {
        if case .buttons = model?.trailing { RowModel.heightWithButtons } else { RowModel.height }
    }

    override func layout() {
        super.layout()
        highlight.frame = NSRect(x: Theme.Inset.fill, y: 0, width: bounds.width - 2 * Theme.Inset.fill, height: rowHeight)
        separator.frame = NSRect(x: Theme.Row.textColumn, y: rowHeight, width: bounds.width - Theme.Inset.content - Theme.Row.textColumn, height: 1)
        content.frame = bounds
        if bounds.width != configuredWidth { layOutContent() }
        updateButtons()
    }

    private func layOutContent() {
        guard let model, bounds.width > 0 else { return }
        configuredWidth = bounds.width
        content.layOut(model, width: bounds.width)
        loadAvatars(of: [content.titleLayout, content.detailLayout])
    }

    /// Hover buttons sit over the time; buttons that always show sit on the title's baseline.
    private func updateButtons() {
        guard let model else { return }
        let count = model.buttons.count
        let width = CGFloat(count) * IconButton.size.width + CGFloat(max(count - 1, 0)) * 2
        var x = bounds.width - Theme.Inset.content - width
        let y: CGFloat = if case .buttons = model.trailing { 7 } else { RowContentView.actionsTop }
        let isVisible = if case .buttons = model.trailing { true } else { state.showsActions }
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= count || !isVisible
            guard index < count else { continue }
            button.frame = NSRect(origin: NSPoint(x: x, y: y), size: IconButton.size)
            x += IconButton.size.width + 2
        }
    }

    var actionsWidth: CGFloat {
        let count = model?.buttons.count ?? 0
        return CGFloat(count) * IconButton.size.width + CGFloat(max(count - 1, 0)) * 2
    }

    override func tooltip(at point: NSPoint) -> PlacedTooltip? {
        content.tooltip(at: point)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        model?.onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = model?.menu, !items.isEmpty else { return nil }
        return MenuItem.menu(items)
    }

    override func accessibilityPerformPress() -> Bool {
        model?.onOpen?()
        return model?.onOpen != nil
    }
}

/// The drawn part of a row: marker, icon, title, time and detail line.
private final class RowContentView: NSView {
    /// Where the hover buttons sit: centered on the time.
    static let actionsTop: CGFloat = 6

    weak var cell: RowCell?
    private(set) var titleLayout = InlineLayout()
    private(set) var timeLayout = InlineLayout()
    private(set) var detailLayout = InlineLayout()
    private var markerRect: NSRect?
    private var isUnread = false
    private var hasTime = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func layOut(_ model: RowModel, width: CGFloat) {
        let textX = Theme.Row.textColumn
        let textMaxX = width - Theme.Inset.content
        // Hover-button rows: the 16pt title line starts at 8, the icon reaching 1pt above it. Rows with
        // buttons on the title's baseline start the 22pt buttons at 7 and the title 9pt lower.
        let titleTop: CGFloat
        let titleLineMiddle: CGFloat
        let detailTop: CGFloat
        var trailingWidth: CGFloat
        switch model.trailing {
        case .time:
            titleTop = 8
            titleLineMiddle = titleTop + 8
            detailTop = titleTop + 16 + 3
            trailingWidth = 0
        case .buttons:
            titleTop = 16
            titleLineMiddle = (7 + titleTop + 16) / 2
            detailTop = titleTop + 16 + 3
            trailingWidth = cell?.actionsWidth ?? 0
        }

        titleLayout = InlineLayout()
        timeLayout = InlineLayout()
        detailLayout = InlineLayout()
        hasTime = false
        if case .time(let time, let help) = model.trailing {
            let item = Inline.text(time, font: .detailDigits).tooltip(help)
            trailingWidth = InlineLayout.width(of: item)
            // On the title's baseline.
            let top = titleTop + NSFont.body.baselineOffset - NSFont.detail.baselineOffset
            timeLayout.place(item, x: textMaxX - trailingWidth, width: trailingWidth, centerY: top + NSFont.detail.lineHeight / 2, key: "time")
            hasTime = true
        }
        let iconWidth = InlineLayout.width(of: model.icon)
        titleLayout.place(model.icon, x: Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn + (Theme.Row.iconColumn - iconWidth) / 2, width: iconWidth, centerY: titleLineMiddle, key: "icon")
        let title = Inline.text(model.title, font: model.isUnread ? .bodySemibold : .body, color: .labelColor).tooltip(model.title)
        titleLayout.place(title, x: textX, width: max(textMaxX - textX - 8 - trailingWidth, 0), centerY: titleTop + 8, key: "title")
        detailLayout.place(.stack(spacing: 4, model.detail), x: textX, width: textMaxX - textX, centerY: detailTop + 8, key: "detail")

        isUnread = model.isUnread
        let markerCenter = NSPoint(x: Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn / 2, y: titleLineMiddle)
        markerRect = NSRect(x: markerCenter.x - 3.5, y: markerCenter.y - 3.5, width: 7, height: 7)
        needsDisplay = true
    }

    /// The buttons replace the time while the pointer selects the row.
    private var showsButtonsOverTime: Bool {
        guard hasTime, let cell else { return false }
        return cell.state.showsActions && cell.actionsWidth > 0
    }

    func tooltip(at point: NSPoint) -> PlacedTooltip? {
        if isUnread, let markerRect, markerRect.insetBy(dx: -1.5, dy: -6).contains(point) {
            return PlacedTooltip(key: "marker", text: "New: you haven't opened it yet", frame: markerRect)
        }
        return detailLayout.tooltip(at: point)
            ?? (showsButtonsOverTime ? nil : timeLayout.tooltip(at: point))
            ?? titleLayout.tooltip(at: point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        if isUnread, let markerRect {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: markerRect).fill()
        }
        titleLayout.pieces.forEach { $0.draw(scale: scale) }
        if let cell, showsButtonsOverTime {
            drawActionsBackground(width: cell.actionsWidth)
        } else {
            timeLayout.pieces.forEach { $0.draw(scale: scale) }
        }
        detailLayout.pieces.forEach { $0.draw(scale: scale) }
    }

    /// The buttons sit on the highlight's color with a short fade, so a long title runs under them
    /// instead of colliding with them.
    private func drawActionsBackground(width: CGFloat) {
        guard let surface = NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
              let selection = NSColor.selectionFill.usingColorSpace(.sRGB) else { return }
        let alpha = selection.alphaComponent
        let color = NSColor(
            srgbRed: selection.redComponent * alpha + surface.redComponent * (1 - alpha),
            green: selection.greenComponent * alpha + surface.greenComponent * (1 - alpha),
            blue: selection.blueComponent * alpha + surface.blueComponent * (1 - alpha),
            alpha: 1
        )
        let x = bounds.width - Theme.Inset.content - width
        let fade = NSRect(x: x - 16, y: Self.actionsTop, width: 16, height: IconButton.size.height)
        NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: fade, angle: 0)
        color.setFill()
        NSRect(x: x, y: Self.actionsTop, width: width, height: IconButton.size.height).fill()
    }
}

/// A plain fill, optionally rounded, that ignores the mouse.
final class FillView: NSView {
    private let color: NSColor
    var showsBorder = false {
        didSet { if showsBorder != oldValue { needsDisplay = true } }
    }

    init(color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.borderWidth = showsBorder ? 1 : 0
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Headers

/// A chevron that turns to show whether a section is open.
private final class Chevron {
    let layer = CALayer()
    private var isOpen: Bool?

    init() {
        layer.contentsGravity = .resizeAspect
        layer.bounds = NSRect(x: 0, y: 0, width: 10, height: 10)
    }

    func update(isOpen: Bool, animated: Bool, appearance: NSAppearance, scale: CGFloat) {
        CATransaction.begin()
        let animates = animated && isOpen != self.isOpen && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.setDisableActions(!animates)
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        appearance.performAsCurrentDrawingAppearance {
            layer.contents = IconImages.image(.chevronRight, size: 10, color: .secondaryLabelColor, scale: scale)
        }
        layer.contentsScale = scale
        // Clockwise in the flipped view: right when closed, down when open.
        layer.setAffineTransform(CGAffineTransform(rotationAngle: isOpen ? .pi / 2 : 0))
        CATransaction.commit()
        self.isOpen = isOpen
    }
}

final class RepositoryHeaderCell: ListCell {
    static let identifier = NSUserInterfaceItemIdentifier("repositoryHeader")

    private let chevron = Chevron()
    private let button = IconButton()
    private var model: RepositoryHeaderModel?
    private var line = InlineLayout()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(chevron.layer)
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The middle of the header's content, under 10pt of padding.
    private static let middle: CGFloat = 10 + Theme.Control.compactHeight / 2

    func configure(_ model: RepositoryHeaderModel, id: String) {
        let isSameEntry = id == entryID
        entryID = id
        self.model = model
        button.configure(model.markRead, key: "\(id).markRead")
        if !isSameEntry { button.reset() }
        chevron.update(isOpen: !model.isCollapsed, animated: isSameEntry, appearance: effectiveAppearance, scale: scale)
        setAccessibilityLabel("\(model.repository.fullName), \(model.isCollapsed ? "collapsed" : "expanded")")
        layOut()
    }

    private var buttonX: CGFloat {
        bounds.width - Theme.Inset.iconTrailing - IconButton.size.width
    }

    override func layout() {
        super.layout()
        layOut()
    }

    private func layOut() {
        guard let model, bounds.width > 0 else { return }
        button.frame = NSRect(origin: NSPoint(x: buttonX, y: 10), size: IconButton.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.layer.position = NSPoint(x: Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn / 2, y: Self.middle)
        CATransaction.commit()

        let repository = model.repository
        let count: String? = model.newCount > 0 ? "\(model.newCount) new" : model.isCollapsed ? "\(model.count)" : nil
        // Separate texts, so a long owner and a long name each keep a share of the width.
        var items: [Inline] = [
            .stack(spacing: 4, [
                .text(repository.owner.login, font: .callout),
                .text("/", font: .callout),
                .text(repository.name, font: .calloutSemibold, color: .labelColor),
            ]),
        ]
        if let count {
            items.append(Inline.text(count, font: .detailDigits).fixedSize())
        }
        items.append(.spacer(minLength: 8))
        line = InlineLayout()
        let avatar = Inline.avatar(repository.owner.avatarURL, size: 16, isOrganization: true)
        line.place(avatar, x: Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn + 2, width: 16, centerY: Self.middle, key: "avatar")
        line.place(.stack(spacing: 6, items), x: Theme.Row.textColumn, width: buttonX - Theme.Row.textColumn, centerY: Self.middle, key: "title")
        loadAvatars(of: [line])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Opaque, so rows scrolling under the pinned header disappear behind it.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        line.pieces.forEach { $0.draw(scale: scale) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let model { chevron.update(isOpen: !model.isCollapsed, animated: false, appearance: effectiveAppearance, scale: scale) }
    }

    override func tooltip(at point: NSPoint) -> PlacedTooltip? {
        guard let model, point.x < buttonX else { return nil }
        let count = model.count == 1 ? "1 notification" : "\(model.count) notifications"
        let action = model.isCollapsed ? "Show the \(count) in" : "Collapse the \(count) in"
        return PlacedTooltip(key: "toggle", text: "\(action) \(model.repository.fullName) (⌥-click: all repositories)", frame: bounds)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        model?.onToggle(event.modifierFlags.contains(.option))
    }

    override func accessibilityPerformPress() -> Bool {
        model?.onToggle(false)
        return true
    }
}

final class SectionHeaderCell: ListCell {
    static let identifier = NSUserInterfaceItemIdentifier("sectionHeader")

    private let chevron = Chevron()
    private var model: SectionHeaderModel?
    private var line = InlineLayout()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(chevron.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ model: SectionHeaderModel, id: String) {
        let isSameEntry = id == entryID
        entryID = id
        self.model = model
        chevron.layer.isHidden = model.isExpanded == nil
        if let isExpanded = model.isExpanded {
            chevron.update(isOpen: isExpanded, animated: isSameEntry, appearance: effectiveAppearance, scale: scale)
        }
        setAccessibilityLabel("\(model.title), \(model.count)")
        layOut()
    }

    override func layout() {
        super.layout()
        layOut()
    }

    private func layOut() {
        guard let model, bounds.width > 0 else { return }
        let middle = model.topPadding + 10 + NSFont.callout.lineHeight / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.layer.position = NSPoint(x: Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn / 2, y: middle)
        CATransaction.commit()
        line = InlineLayout()
        let iconX = Theme.Inset.fill + Theme.Row.leadingPadding + Theme.Row.markerColumn + (Theme.Row.iconColumn - 15) / 2
        line.place(.icon(model.icon, size: 15), x: iconX, width: 15, centerY: middle, key: "icon")
        let title = Inline.stack(spacing: 6, [
            .text(model.title, font: .calloutSemibold, color: .labelColor),
            .text("\(model.count)", font: .detailDigits),
        ])
        line.place(title, x: Theme.Row.textColumn, width: bounds.width - Theme.Inset.content - Theme.Row.textColumn, centerY: middle, key: "title")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        line.pieces.forEach { $0.draw(scale: scale) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let isExpanded = model?.isExpanded {
            chevron.update(isOpen: isExpanded, animated: false, appearance: effectiveAppearance, scale: scale)
        }
    }

    override func tooltip(at point: NSPoint) -> PlacedTooltip? {
        guard let model, let isExpanded = model.isExpanded else { return nil }
        let title = model.title.lowercased()
        return PlacedTooltip(key: "toggle", text: isExpanded ? "Fold the \(title)" : "Show the \(title)", frame: bounds)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        model?.onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        model?.onToggle?()
        return model?.onToggle != nil
    }
}

// MARK: - Notes and space

final class NoteCell: ListCell {
    static let identifier = NSUserInterfaceItemIdentifier("note")

    private var model: NoteModel?

    func configure(_ model: NoteModel, id: String) {
        entryID = id
        self.model = model
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(model.text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let rect = NSRect(x: model.leading, y: model.top, width: bounds.width - model.leading - model.trailing, height: bounds.height - model.top)
        model.attributedText.draw(with: rect, options: [.usesLineFragmentOrigin])
    }
}

final class SpaceCell: ListCell {
    static let identifier = NSUserInterfaceItemIdentifier("space")
}
