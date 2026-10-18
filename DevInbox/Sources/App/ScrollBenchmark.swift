#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// `DevInbox --scroll-benchmark [tab]` scrolls a list through its whole length and back in 8pt steps
/// (`BENCH_STEP` changes them) and prints how long each step took to lay out and draw, then quits. A
/// simulated pointer rests over the list, so the highlight moves from row to row like under the mouse
/// (`BENCH_POINTER=0` turns it off). The Inbox is shown whole and expanded, grouped by repository or with `BENCH_GROUPING=latest`
/// by date; Reviews with the history unfolded. Used to find scroll jank; run it under `sample` or
/// Instruments to see where the time goes.
enum ScrollBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--scroll-benchmark")
    }

    private static var tab: PanelTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--scroll-benchmark"), index + 1 < arguments.count else { return .inbox }
        return PanelTab(rawValue: arguments[index + 1]) ?? .inbox
    }

    static func run(model: AppModel) {
        Task {
            for _ in 0..<120 {
                if let session = model.session, session.inbox.lastUpdated != nil, session.pullRequests.lastUpdated != nil,
                   session.pullRequests.historyUpdated != nil, !session.inbox.isRefreshing { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            model.selectedTab = tab
            // The whole inbox, expanded, and the review history unfolded: the worst case. Restored
            // before quitting, since these are the real settings.
            let settings = model.settings
            let original = (settings.collapsedRepositories, settings.inboxGrouping, settings.showsReviewHistory)
            settings.collapsedRepositories = []
            settings.showsReviewHistory = true
            if ProcessInfo.processInfo.environment["BENCH_GROUPING"] == "latest" {
                settings.inboxGrouping = .chronological
            }
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: PanelController.size.width, height: PanelController.size.height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(rootView: PanelRootView(model: model))
            window.contentView = hostingView
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(3)) // avatars

            guard let scrollView = firstScrollView(in: hostingView), let document = scrollView.documentView else {
                print("scroll-benchmark: no scroll view found")
                (settings.collapsedRepositories, settings.inboxGrouping, settings.showsReviewHistory) = original
                NSApp.terminate(nil)
                return
            }
            let clip = scrollView.contentView
            // The document view is much taller than the list, so scroll the list's estimated height.
            let rowCount = model.session.map { session in
                switch tab {
                case .inbox: session.inbox.threads.count
                case .reviews: session.pullRequests.reviewRequests.count + session.pullRequests.history.count
                case .myPullRequests: session.pullRequests.authored.count
                }
            } ?? 0
            let maxOffset = min(max(document.frame.height - clip.bounds.height, 0), CGFloat(rowCount) * 51)
            let passes = Int(ProcessInfo.processInfo.environment["BENCH_PASSES"] ?? "1") ?? 1
            // Flicking a trackpad moves the list much further per frame; BENCH_STEP=48 comes closer to that.
            let step = CGFloat(Double(ProcessInfo.processInfo.environment["BENCH_STEP"] ?? "8") ?? 8)
            let pass = Array(stride(from: 0, through: maxOffset, by: step)) + Array(stride(from: maxOffset, through: 0, by: -step))
            let offsets = Array(repeating: pass, count: passes).flatMap { $0 }

            // A pointer resting over the list, so the highlight moves from row to row as it would
            // under the mouse. BENCH_POINTER=0 measures scrolling alone.
            if ProcessInfo.processInfo.environment["BENCH_POINTER"] != "0" {
                ListSelection.simulatedPointer = CGPoint(x: 200, y: 250)
            }
            var durations: [Double] = []
            for offset in offsets {
                let start = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(clip)
                hostingView.layoutSubtreeIfNeeded()
                hostingView.displayIfNeeded()
                CATransaction.flush()
                durations.append((CACurrentMediaTime() - start) * 1000)
                await Task.yield()
            }

            let sorted = durations.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
            let slow = durations.filter { $0 > 1000 / 120 }.count
            print(String(
                format: "scroll-benchmark %@: %d steps over %.0fpt, mean %.2fms, p50 %.2fms, p95 %.2fms, max %.2fms, over 8.3ms: %d, highlight moves: %d",
                tab.rawValue, durations.count, maxOffset, durations.reduce(0, +) / Double(durations.count),
                percentile(0.5), percentile(0.95), sorted.last ?? 0, slow, ListSelection.changeCount
            ))
            (settings.collapsedRepositories, settings.inboxGrouping, settings.showsReviewHistory) = original
            NSApp.terminate(nil)
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView != nil { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
#endif
