import AppKit
import SwiftUI

/// The menu bar item, drawn like Itsycal's date: a filled pill with its content cut out. As a template
/// image it takes the menu bar's own color, so it stays legible on any wallpaper, light or dark.
struct StatusPill: View {
    let unread: Int
    let reviews: Int

    var body: some View {
        HStack(spacing: 5) {
            if unread > 0 || reviews == 0 {
                segment(icon: .inbox, count: unread)
            }
            if unread > 0 && reviews > 0 {
                Capsule().frame(width: 1.5, height: 9)
            }
            if reviews > 0 {
                segment(icon: .eyeFill, count: reviews)
            }
        }
        .foregroundStyle(.black) // opaque, so the cut-out leaves nothing behind
        .padding(.horizontal, 8)
        .frame(height: 17)
        .blendMode(.destinationOut)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black))
        .compositingGroup()
    }

    private func segment(icon: Icon, count: Int) -> some View {
        HStack(spacing: 3) {
            IconView(icon: icon, size: 12)
            Text(verbatim: count > 999 ? "999+" : "\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    static func image(unread: Int, reviews: Int, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: StatusPill(unread: unread, reviews: reviews))
        renderer.scale = scale
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }
}
