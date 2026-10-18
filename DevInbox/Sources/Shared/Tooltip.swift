import SwiftUI

/// Tooltips with the timing from the design skills. The first one waits a moment, so sweeping the
/// pointer across the panel doesn't flash tooltips; once one is showing, moving to the next control
/// shows its tooltip at once and without animation. The system tooltip waits well over a second and
/// can't be tuned, which made controls look unexplained.
@Observable
final class TooltipCenter {
    struct Tip: Equatable {
        let id: UUID
        let text: String
        let anchor: CGRect
        /// Above the control when there's no room below it.
        let isAbove: Bool
    }

    nonisolated static let coordinateSpace = "tooltip"
    /// Long enough that passing over a control doesn't trigger it.
    static let delay: Duration = .milliseconds(500)
    /// A tooltip hidden this recently makes the next one appear at once.
    static let warmWindow: TimeInterval = 0.4

    private(set) var tip: Tip?
    /// True when the current tip replaced another one and appears without animation.
    private(set) var appearsInstantly = false
    /// The host's size, to decide whether a tip fits below its control.
    @ObservationIgnored var hostSize: CGSize = .zero

    @ObservationIgnored private var pending: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var hiddenAt: Date = .distantPast
    @ObservationIgnored private var lastMouseLocation = NSEvent.mouseLocation
    /// After a click, the clicked control stays quiet until the pointer leaves it.
    @ObservationIgnored private var suppressedID: UUID?

    /// `location` is the pointer in the host's coordinate space; the tip appears just below it.
    func pointerMoved(id: UUID, text: String, at location: CGPoint) {
        // Content scrolling under a resting pointer isn't a hover.
        let screenLocation = NSEvent.mouseLocation
        guard screenLocation != lastMouseLocation else { return }
        lastMouseLocation = screenLocation
        guard tip?.id != id, pending?.id != id, suppressedID != id else { return }

        pending?.task.cancel()
        pending = nil
        // The pointer counts as 18pt tall, so the tip clears the cursor.
        let anchor = CGRect(x: location.x, y: location.y, width: 0, height: 18)
        let next = Tip(id: id, text: text, anchor: anchor, isAbove: anchor.maxY + 40 > hostSize.height)
        if tip != nil || Date.now.timeIntervalSince(hiddenAt) < Self.warmWindow {
            show(next, instantly: true)
        } else {
            pending = (id, Task { [weak self] in
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                self?.show(next, instantly: false)
            })
        }
    }

    func pointerLeft(id: UUID) {
        if suppressedID == id { suppressedID = nil }
        if pending?.id == id {
            pending?.task.cancel()
            pending = nil
        }
        if tip?.id == id { hide() }
    }

    /// Clicks, key presses and scrolling hide the tooltip, like the system's.
    func dismiss() {
        suppressedID = tip?.id ?? pending?.id
        pending?.task.cancel()
        pending = nil
        hide()
        hiddenAt = .distantPast // the next tooltip waits again
    }

    private func show(_ next: Tip, instantly: Bool) {
        pending = nil
        appearsInstantly = instantly
        tip = next
    }

    private func hide() {
        guard tip != nil else { return }
        tip = nil
        hiddenAt = .now
    }
}

extension View {
    /// Shows `text` as a tooltip after a short delay, instantly when another tooltip was just showing.
    /// Needs a `tooltipHost()` above it; without one it falls back to the system tooltip.
    func tooltip(_ text: String, isAccessibilityHint: Bool = true) -> some View {
        modifier(TooltipModifier(text: text, isAccessibilityHint: isAccessibilityHint))
    }

    /// Draws the tooltips of everything inside. Put it on the root of each window.
    func tooltipHost() -> some View {
        modifier(TooltipHost())
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    let isAccessibilityHint: Bool

    @Environment(TooltipCenter.self) private var center: TooltipCenter?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else if let center {
            // Anchored at the pointer rather than the view's frame: tracking every anchor's frame
            // made each scroll step update a few hundred geometry observers.
            content
                .onContinuousHover(coordinateSpace: .named(TooltipCenter.coordinateSpace)) { phase in
                    switch phase {
                    case .active(let location): center.pointerMoved(id: id, text: text, at: location)
                    case .ended: center.pointerLeft(id: id)
                    }
                }
                .onDisappear { center.pointerLeft(id: id) }
                .accessibilityHint(isAccessibilityHint ? text : "")
        } else {
            content.help(text)
        }
    }

}

private struct TooltipHost: ViewModifier {
    @State private var center = TooltipCenter()
    @State private var eventMonitor: Any?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TooltipCenter.coordinateSpace))
            .environment(center)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { center.hostSize = $0 }
            .overlay {
                TooltipLayout(tip: center.tip) {
                    if let tip = center.tip {
                        TooltipBubble(text: tip.text)
                            .id(tip.id)
                            .transition(transition(for: tip))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: center.tip)
                .allowsHitTesting(false)
            }
            .onAppear {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [center] event in
                    MainActor.assumeIsolated { center.dismiss() }
                    return event
                }
            }
            .onDisappear {
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                eventMonitor = nil
            }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Grows out of its control, 150ms ease-out in and a quick fade out. A tip that replaces another
    /// appears at once.
    private func transition(for tip: TooltipCenter.Tip) -> AnyTransition {
        if center.appearsInstantly { return .identity }
        let grow: AnyTransition = reduceMotion ? .identity : .scale(scale: 0.97, anchor: tip.isAbove ? .bottom : .top)
        return .asymmetric(
            insertion: .opacity.combined(with: grow),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
}

/// Centers the tip under (or above) its control and keeps it inside the window.
private struct TooltipLayout: Layout {
    let tip: TooltipCenter.Tip?

    private static let margin: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let maxWidth: CGFloat = 260

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tip, let bubble = subviews.first else { return }
        let width = min(Self.maxWidth, bounds.width - 2 * Self.margin)
        let size = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let x = min(max(tip.anchor.midX - size.width / 2, Self.margin), bounds.width - Self.margin - size.width)
        let y = tip.isAbove ? tip.anchor.minY - Self.gap - size.height : tip.anchor.maxY + Self.gap
        bubble.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + max(y, Self.margin)),
            proposal: ProposedViewSize(size)
        )
    }
}

struct TooltipBubble: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Theme.tooltipBackground, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}
