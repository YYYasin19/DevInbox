import ImageIO
import SwiftUI

/// Icon button that always explains itself: tooltip, accessibility label and optional shortcut.
/// It never takes keyboard focus, so j/k/R/D/S always reach the list.
struct ActionButton: View {
    enum Size {
        /// Inside rows and section headers.
        case compact
        /// In the panel header.
        case regular
    }

    let icon: Icon
    let help: String
    /// Overrides the quiet secondary glyph, e.g. for a pending confirmation.
    var tint: Color?
    var size: Size = .compact
    var shortcut: KeyboardShortcut?
    /// Spins the icon, e.g. while refreshing.
    var isBusy = false
    let action: () -> Void

    init(
        _ icon: Icon,
        help: String,
        tint: Color? = nil,
        size: Size = .compact,
        shortcut: KeyboardShortcut? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.help = help
        self.tint = tint
        self.size = size
        self.shortcut = shortcut
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if isBusy {
                // One turn per second.
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    glyph.rotationEffect(.degrees(turn * 360))
                }
            } else {
                glyph
            }
        }
        .buttonStyle(IconButtonStyle(size: size, tint: tint))
        .keyboardShortcut(shortcut)
        .focusable(false)
        .tooltip(help, isAccessibilityHint: false)
        .accessibilityLabel(help)
    }

    private var glyph: some View {
        IconView(icon: icon, size: size == .compact ? 15 : 17)
    }
}

private struct IconButtonStyle: ButtonStyle {
    let size: ActionButton.Size
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ActionButton.Size
    let tint: Color?

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = size == .compact
            ? CGSize(width: 24, height: Theme.Control.compactHeight)
            : CGSize(width: Theme.Control.regularHeight, height: Theme.Control.regularHeight)
        configuration.label
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(isHovered ? .primary : .secondary))
            .frame(width: frame.width, height: frame.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : .clear)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? Theme.Control.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(Theme.hoverAnimation) { isHovered = hovering && isEnabled }
            }
            .animation(Theme.hoverAnimation, value: configuration.isPressed)
    }
}

/// Text button with a rounded fill, for tabs, segments and filter toggles. Never takes focus.
struct PillButtonStyle: ButtonStyle {
    var isSelected: Bool
    var height: CGFloat = Theme.Control.compactHeight
    var selectedForeground: Color?
    var selectedFill: Color = Theme.Fill.selected

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, style: self)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PillButtonStyle

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let foreground: AnyShapeStyle = if style.isSelected {
            style.selectedForeground.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)
        } else {
            AnyShapeStyle(isHovered ? .primary : .secondary)
        }
        let fill: Color = if style.isSelected {
            style.selectedFill
        } else if configuration.isPressed {
            Theme.Fill.pressed
        } else {
            isHovered ? Theme.Fill.hover : .clear
        }
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: style.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(fill))
            .scaleEffect(configuration.isPressed && !reduceMotion ? Theme.Control.pressedScale : 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(Theme.hoverAnimation) { isHovered = hovering }
            }
            .animation(Theme.hoverAnimation, value: configuration.isPressed)
            .accessibilityAddTraits(style.isSelected ? .isSelected : [])
    }
}

/// Two or more mutually exclusive options as quiet pills; the selected one gets a neutral fill.
struct SegmentedPills<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(PillButtonStyle(isSelected: selection == option.value))
                    .focusable(false)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }
}

extension View {
    /// "3 new" at the top of a list: items that arrived while the panel was open wait behind it, so
    /// rows never move under the pointer.
    func newItemsPill(count: Int, noun: (singular: String, plural: String), action: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            if count > 0 {
                Button(action: action) {
                    Text("\(count) new")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.accentColor))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .tooltip("\(count) \(count == 1 ? noun.singular : noun.plural) arrived while the panel was open. Click to show \(count == 1 ? "it" : "them").")
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: count > 0)
    }
}

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 16
    /// Organizations get rounded squares, like on GitHub.
    var isOrganization = false

    @State private var image: NSImage?

    var body: some View {
        let shape = isOrganization
            ? AnyShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            : AnyShape(Circle())
        let sizedURL = url?.avatarSized(Int(size))
        Group {
            if let image = image ?? sizedURL.flatMap(AvatarCache.shared.cached) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                shape.fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: sizedURL) {
            image = if let sizedURL { await AvatarCache.shared.image(for: sizedURL) } else { nil }
        }
    }
}

/// Keeps decoded avatars in memory. `AsyncImage` loads again, and flashes its placeholder, every
/// time a lazy row scrolls back into view.
final class AvatarCache {
    static let shared = AvatarCache()

    private let images = NSCache<NSURL, NSImage>()
    private var loads: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let load = loads[url] { return await load.value }
        let load = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = await Self.decode(data) else { return nil }
            return NSImage(cgImage: decoded, size: .zero)
        }
        loads[url] = load
        let image = await load.value
        loads[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Decodes the PNG up front and off the main thread; otherwise the first draw of each new row
    /// decoded it on the main thread while scrolling.
    @concurrent
    private nonisolated static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Compact ages like "10h" or "3d" for rows, refreshed by the panel's minute clock, and the exact
/// date for their tooltips.
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// "Latest activity: 2 days ago · Oct 12, 2026 at 4:03 PM".
    static func help(_ prefix: String, date: Date, now: Date, format: DateFormat) -> String {
        "\(prefix): \(Self.format(date, relativeTo: now)) · \(format.timestamp(date))"
    }

    /// The row's time, with the exact date as tooltip.
    static func trailing(_ date: Date, help prefix: String, in context: ListContext) -> RowModel.Trailing {
        .time(compact(date, relativeTo: context.now, format: context.dateFormat), help: help(prefix, date: date, now: context.now, format: context.dateFormat))
    }

    /// "2 days ago", for tooltips and sentences.
    static func format(_ date: Date, relativeTo now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
    }

    /// "now", "5m", "10h", "3d", "2w", then the date. Repeated on every row, so it has to be short.
    static func compact(_ date: Date, relativeTo now: Date, format: DateFormat) -> String {
        let seconds = now.timeIntervalSince(date)
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(7 * day): return "\(Int(seconds / day))d"
        case ..<(28 * day): return "\(Int(seconds / (7 * day)))w"
        default: return format.day(date, relativeTo: now)
        }
    }
}

/// The state icon at the start of a row: what it is, colored by its state.
struct SubjectIcon {
    let type: SubjectType
    let state: SubjectState?

    var inline: Inline {
        .icon(icon, size: 17, color: color).tooltip(help)
    }

    private var icon: Icon {
        switch type {
        case .pullRequest:
            switch state {
            case .merged: .merged
            case .closed, .closedNotPlanned: .pullRequestClosed
            case .draft: .pullRequestDraft
            default: .pullRequest
            }
        case .issue:
            switch state {
            case .closed: .checkCircle
            case .closedNotPlanned: .notPlanned
            default: .issueOpen
            }
        case .release: .tag
        case .discussion: .discussion
        case .commit: .commit
        case .checkSuite: .workflowRun
        case .dependabotAlerts, .vulnerabilityAlert, .advisory: .security
        default: .bell
        }
    }

    private var color: NSColor {
        switch (type, state) {
        case (.dependabotAlerts, _), (.vulnerabilityAlert, _), (.advisory, _): Tone.failure.symbolColor
        case (_, .open?): Tone.success.symbolColor
        case (_, .merged?): Tone.merged.symbolColor
        case (.issue, .closed?): Tone.merged.symbolColor
        case (_, .closed?): Tone.failure.symbolColor
        default: .secondaryLabelColor
        }
    }

    private var help: String {
        let stateText: String? = switch state {
        case .open?: "Open"
        case .draft?: "Draft"
        case .merged?: "Merged"
        case .closed?: type == .issue ? "Closed as completed" : "Closed"
        case .closedNotPlanned?: "Closed as not planned"
        case nil: nil
        }
        return [type.label, stateText].compactMap { $0 }.joined(separator: " · ")
    }
}

struct EmptyStateView: View {
    let icon: Icon
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            IconView(icon: icon, size: 30)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 280)
        .offset(y: -16) // optically centered: a little above the middle
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the first load failed: nothing loaded isn't the same as nothing to do.
struct LoadFailedView: View {
    let error: GitHubError
    let what: String

    var body: some View {
        EmptyStateView(
            icon: error == .offline ? .offline : .warning,
            title: "Couldn't load your \(what)",
            message: "\(error.localizedDescription) DevInbox keeps trying."
        )
    }
}

/// Shown until the first data arrives.
struct LoadingView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .offset(y: -16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small rounded key hint like "⏎" or "S".
struct KeyHint: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.tertiary))
    }
}
