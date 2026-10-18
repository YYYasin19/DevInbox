import SwiftUI

/// The last action, which can still be taken back for a few seconds. Actions happen at once instead of
/// asking first. GitHub can't take "done" back, so whatever goes to GitHub waits in `commit` until
/// the undo window closes, a newer action replaces it, or the panel closes.
@Observable
final class UndoCenter {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let icon: Icon
        let undo: () -> Void
        let commit: () async -> Void
    }

    private(set) var current: Action?

    static let window: Duration = .seconds(5)

    @ObservationIgnored private var timer: Task<Void, Never>?

    /// Shows `action` with its Undo button. The previous action can't be undone anymore and goes through.
    func offer(_ action: Action) {
        commit()
        current = action
        startTimer()
    }

    func undo() {
        guard let action = take() else { return }
        Log.info(.actions, "Undo: \(action.title)")
        action.undo()
    }

    /// Lets the pending action go through now. The returned task finishes when it has, e.g. before quitting.
    @discardableResult
    func commit() -> Task<Void, Never>? {
        guard let action = take() else { return nil }
        return Task { await action.commit() }
    }

    /// While the pointer rests on the toast, it stays.
    func setPaused(_ isPaused: Bool) {
        if isPaused {
            timer?.cancel()
        } else if current != nil {
            startTimer()
        }
    }

    private func take() -> Action? {
        timer?.cancel()
        defer { current = nil }
        return current
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }
}

/// "12 marked as read · Undo" at the bottom of the panel, over the list so nothing moves.
struct UndoToast: View {
    let center: UndoCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let action = center.current {
                toast(for: action)
                    .id(action.id)
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
            }
        }
        .animation(.easeOut(duration: 0.12), value: center.current?.id)
    }

    private func toast(for action: UndoCenter.Action) -> some View {
        HStack(spacing: 8) {
            IconView(icon: action.icon, size: 14)
            Text(action.title)
                .lineLimit(1)
            Button {
                center.undo()
            } label: {
                HStack(spacing: 4) {
                    Text("Undo").fontWeight(.semibold)
                    Text(verbatim: "⌘Z").foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .tooltip("Take it back (⌘Z)")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(Theme.tooltipBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .onHover { center.setPaused($0) }
        .padding(.bottom, 12)
    }
}
