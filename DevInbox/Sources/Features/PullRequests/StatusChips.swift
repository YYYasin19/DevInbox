import AppKit

/// One piece of a pull request's status line. The style sets how loud it is: chips for blockers and
/// decisive outcomes, tinted text for things worth noticing, quiet text and icons for the rest.
struct StatusItem: Identifiable {
    enum Style {
        case chip(Tone)
        case tinted(Tone)
        case neutral
        case icon(Tone)
    }

    let id: String
    var text: String?
    var icon: Icon?
    let style: Style
    let help: String
}

/// Turns a pull request's checks, reviews and mergeability into a short status line. Empty states
/// ("no checks", "no reviews") show nothing, and causes that another item already explains are left out.
enum PullRequestStatus {
    enum Review {
        case approved, changesRequested, needsReviewer, waiting, none
    }

    /// Status of your own pull request, loudest first, with at most two chips. `overrides` are the
    /// Inbox's bot corrections, for counting comments.
    static func items(for pullRequest: PullRequestSummary, overrides: [String: Bool], dateFormat: DateFormat) -> [StatusItem] {
        var chips: [StatusItem] = []
        var tinted: [StatusItem] = []
        var neutral: [StatusItem] = []
        var icons: [StatusItem] = []

        // Drafts aren't up for review yet; only show reviews that already happened.
        let review = pullRequest.isDraft && pullRequest.reviews.isEmpty ? nil : self.review(of: pullRequest)
        let checksState = pullRequest.checks?.state
        let checksItem = checks(pullRequest.checks)
        let conflicts = !pullRequest.isDraft
            && (pullRequest.mergeable == "CONFLICTING" || pullRequest.mergeStateStatus == "DIRTY")
        let ready = !pullRequest.isDraft && !conflicts
            && ["CLEAN", "HAS_HOOKS"].contains(pullRequest.mergeStateStatus)

        if conflicts {
            chips.append(StatusItem(
                id: "conflicts", text: "Conflicts", icon: .warning, style: .chip(.failure),
                help: "This branch has conflicts with \(pullRequest.baseRefName) that must be resolved."
            ))
        }
        if review == .changesRequested {
            chips.append(StatusItem(
                id: "review", text: "Changes requested", icon: .changesRequested, style: .chip(.failure),
                help: reviewHelp(pullRequest)
            ))
        }
        if let checksItem, case .chip = checksItem.style {
            chips.append(checksItem)
        }
        if ready {
            chips.append(StatusItem(
                id: "merge", text: "Ready to merge", icon: .checksPassed, style: .chip(.success),
                help: "Ready to merge into \(pullRequest.baseRefName)."
            ))
        }

        switch review {
        case .approved? where !ready:
            tinted.append(StatusItem(
                id: "review", text: "Approved", icon: .approved, style: .tinted(.success),
                help: reviewHelp(pullRequest)
            ))
        case .needsReviewer?:
            tinted.append(StatusItem(
                id: "review", text: "Needs reviewer", icon: .needsReviewer, style: .tinted(.warning),
                help: reviewHelp(pullRequest)
            ))
        case .waiting?:
            neutral.append(StatusItem(id: "review", text: "Awaiting review", style: .neutral, help: reviewHelp(pullRequest)))
        default:
            break
        }

        // Your own replies and bots' reports don't need an answer.
        let comments = pullRequest.commentsFromOthers(overrides: overrides)
        let commentsHelp = EventTimeline.text(
            comments, title: comments.count == 1 ? "1 comment from others" : "\(comments.count) comments from others", dateFormat: dateFormat
        ).map { $0 + "\n\nYour own and bots' comments aren't counted." }
        if pullRequest.unresolvedThreads > 0 {
            let threads = pullRequest.unresolvedThreads == 1 ? "thread" : "threads"
            tinted.append(StatusItem(
                id: "activity", text: "\(pullRequest.unresolvedThreads) unresolved", icon: .unresolved,
                style: .tinted(.warning),
                help: "\(pullRequest.unresolvedThreads) unresolved review \(threads)" + (commentsHelp.map { "\n\n" + $0 } ?? "")
            ))
        }

        if !pullRequest.isDraft && !conflicts {
            switch pullRequest.mergeStateStatus {
            case "BEHIND":
                tinted.append(StatusItem(
                    id: "merge", text: "Behind \(pullRequest.baseRefName)", icon: .behind,
                    style: .tinted(.warning),
                    help: "The branch is out of date with \(pullRequest.baseRefName)."
                ))
            case "BLOCKED":
                // Failing checks or a missing review already explain most blocks.
                let explained = checksState == .failure || checksState == .pending
                    || [.changesRequested, .needsReviewer, .waiting].contains(review)
                if !explained {
                    tinted.append(StatusItem(
                        id: "merge", text: "Blocked", icon: .lock, style: .tinted(.warning),
                        help: "Merging is blocked by branch protection."
                    ))
                }
            default:
                break // UNSTABLE: mergeable despite optional checks failing; UNKNOWN: still being computed.
            }
        }

        if pullRequest.unresolvedThreads == 0, let commentsHelp {
            icons.append(StatusItem(
                id: "comments", text: "\(comments.count)", icon: .comments, style: .icon(.neutral), help: commentsHelp
            ))
        }
        // Checks last, so CI status forms a column along the trailing edge. "Ready to merge" already says they pass.
        if let checksItem {
            switch checksItem.style {
            case .neutral: neutral.append(checksItem)
            case .icon where !ready: icons.append(checksItem)
            default: break
            }
        }

        return Array(chips.prefix(2)) + tinted + neutral + icons
    }

    /// Failing checks are a chip, running checks quiet text, passing checks just an icon.
    static func checks(_ checks: ChecksSummary?) -> StatusItem? {
        guard let checks else { return nil }
        switch checks.state {
        case .success:
            return StatusItem(
                id: "checks", icon: .checksPassed, style: .icon(.success),
                help: checks.total == 1 ? "The check passed." : "All \(checks.total) checks passed."
            )
        case .failure:
            return StatusItem(
                id: "checks", text: checks.failing.isEmpty ? "Failing" : "\(checks.failing.count) failing",
                icon: .checksFailing, style: .chip(.failure),
                help: list("Failing checks", checks.failing) + list("\n\nStill running", checks.pending)
            )
        case .pending:
            return StatusItem(
                id: "checks", text: "Running", icon: .clock, style: .neutral,
                help: list("Still running", checks.pending) + list("\n\nAlready failing", checks.failing)
            )
        }
    }

    static func review(of pullRequest: PullRequestSummary) -> Review {
        switch pullRequest.reviewDecision {
        case .approved?: return .approved
        case .changesRequested?: return .changesRequested
        case .reviewRequired?: return pullRequest.requestedReviewers.isEmpty ? .needsReviewer : .waiting
        case nil:
            // Repositories without required reviews have no decision; derive one from the reviews.
            if pullRequest.reviews.contains(where: { $0.state == "CHANGES_REQUESTED" }) { return .changesRequested }
            if pullRequest.reviews.contains(where: { $0.state == "APPROVED" }) { return .approved }
            return pullRequest.requestedReviewers.isEmpty ? .none : .waiting
        }
    }

    private static func reviewHelp(_ pullRequest: PullRequestSummary) -> String {
        var lines: [String] = []
        for review in pullRequest.reviews {
            let state = switch review.state {
            case "APPROVED": "approved"
            case "CHANGES_REQUESTED": "requested changes"
            default: "commented"
            }
            lines.append("@\(review.author?.login ?? "ghost") \(state)")
        }
        let waiting = pullRequest.requestedReviewers.map { reviewer in
            switch reviewer {
            case .user(let actor): "@\(actor.login)"
            case .team(let name, _): "\(name) (team)"
            }
        }
        if !waiting.isEmpty {
            lines.append("Waiting for: " + waiting.joined(separator: ", "))
        }
        if pullRequest.reviewDecision == .reviewRequired {
            lines.append("Branch protection requires an approving review.")
        }
        return lines.isEmpty ? "Nobody has reviewed or been asked to review yet." : lines.joined(separator: "\n")
    }

    private static func list(_ title: String, _ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(12).map { "• \($0)" }
        let more = names.count > 12 ? ["…and \(names.count - 12) more"] : []
        return ([title + ":"] + shown + more).joined(separator: "\n")
    }
}

/// What happened to a pull request after your review, for its row in the history: how it ended, new
/// commits, your threads and what others said. Each tooltip lists its events with who and when.
enum ReviewHistoryStatus {
    /// Your part: how you reviewed, or why the request left the list. Its tooltip tells everything since.
    /// Reviews get GitHub's icons alone, so what happened since has the room.
    static func involvement(of pullRequest: ReviewedPullRequest, dateFormat: DateFormat) -> StatusItem {
        let (text, icon, tone, help): (String?, Icon, Tone, String) = switch pullRequest.involvement {
        case .approved: (nil, .approved, .success, "You approved")
        case .changesRequested: (nil, .changesRequested, .failure, "You requested changes")
        case .commented: (nil, .eye, .neutral, "You reviewed with comments")
        case .reviewDismissed: (nil, .eye, .neutral, "Your review was dismissed, usually because new commits made it stale. You last reviewed")
        case .requestDismissed: ("Dismissed", .xCircle, .neutral, "You dismissed the review request")
        case .requestEnded: ("Not reviewed", .clock, .neutral, "Your review request ended without a review from you: it was withdrawn, or someone else reviewed")
        }
        let story = EventTimeline.text(pullRequest.events, title: "Since then", dateFormat: dateFormat) ?? "Nothing happened since."
        return StatusItem(
            id: "involvement", text: text, icon: icon, style: .icon(tone),
            help: "\(help) · \(dateFormat.timestamp(pullRequest.since))\n\n\(story)"
        )
    }

    /// For the row's time: when there's been nothing since, the time is when you were last involved.
    static func timeHelp(for pullRequest: ReviewedPullRequest) -> String {
        guard pullRequest.events.isEmpty else { return "Last activity" }
        return switch pullRequest.involvement {
        case .approved, .changesRequested, .commented, .reviewDismissed: "You reviewed"
        case .requestDismissed: "You dismissed the request"
        case .requestEnded: "The request ended"
        }
    }

    /// How it ended, new commits, your threads, others' reviews, then comments: when space runs out,
    /// the last ones fold into "+N".
    static func items(for pullRequest: ReviewedPullRequest, dateFormat: DateFormat) -> [StatusItem] {
        var items: [StatusItem] = []
        let isOpen = pullRequest.state == .open || pullRequest.state == .draft
        let since = switch pullRequest.involvement {
        case .requestDismissed: "Since you dismissed the request"
        case .requestEnded: "Since the request ended"
        default: "Since your review"
        }
        let events = pullRequest.events

        if !isOpen {
            let merged = pullRequest.state == .merged
            let verb = merged ? "Merged" : "Closed"
            let by = pullRequest.finishedBy?.login
            // The author's name is already on the row.
            let byAuthor = by != nil && by == pullRequest.author?.login
            let at = pullRequest.finishedAt.map { " · \(dateFormat.timestamp($0))" } ?? ""
            items.append(StatusItem(
                id: "outcome", text: by.map { byAuthor ? verb : "\(verb) by \($0)" } ?? verb,
                style: .tinted(merged ? .merged : .failure),
                help: (by.map { "\(verb) by @\($0)\(byAuthor ? ", the author" : "")" } ?? verb) + at
            ))
        }

        if pullRequest.hasNewCommits {
            let pushes = events.filter { $0.kind == .committed || $0.kind == .forcePushed }
            let commits = pushes.count { $0.kind == .committed }
            // Commits the author dated before your review but pushed after it only show as a moved branch.
            let text = switch commits {
            case 0: "Updated"
            case 1: "1 new commit"
            default: "\(commits) new commits"
            }
            items.append(StatusItem(
                id: "commits", text: text, icon: .commit, style: isOpen ? .tinted(.attention) : .neutral,
                help: EventTimeline.text(pushes, title: since, dateFormat: dateFormat) ?? "\(since), the branch changed: rebased or force-pushed."
            ))
        }

        if let threads = pullRequest.yourThreads {
            let open = threads.total - threads.resolved
            let help = switch (threads.total, open) {
            case (1, 0): "Your review thread is resolved."
            case (1, _): "Your review thread is still open."
            case (_, 0): "All \(threads.total) of your review threads are resolved."
            default: "\(threads.resolved) of your \(threads.total) review threads \(threads.resolved == 1 ? "is" : "are") resolved, \(open) still open."
            }
            items.append(StatusItem(
                id: "threads", text: "\(threads.resolved)/\(threads.total) resolved", icon: open == 0 ? .check : .unresolved,
                style: .tinted(open == 0 ? .success : .warning), help: help
            ))
        }

        let reviews = events.filter { [.approved, .changesRequested, .reviewed].contains($0.kind) }
        if let latest = reviews.last, let help = EventTimeline.text(reviews, title: since, dateFormat: dateFormat) {
            let login = latest.actor?.login ?? "ghost"
            let item: (verb: String, icon: Icon, style: StatusItem.Style) = switch latest.kind {
            case .approved: ("approved", .approved, .tinted(.success))
            case .changesRequested: ("requested changes", .changesRequested, .tinted(.failure))
            default: ("reviewed", .eye, .neutral)
            }
            items.append(StatusItem(id: "reviews", text: "\(login) \(item.verb)", icon: item.icon, style: item.style, help: help))
        }

        let comments = events.filter { $0.kind == .commented || $0.kind == .replied }
        if let help = EventTimeline.text(comments, title: since, dateFormat: dateFormat) {
            items.append(StatusItem(id: "comments", text: "\(comments.count)", icon: .comments, style: .icon(.neutral), help: help))
        }
        return items
    }
}

/// Events for a tooltip: "• @alice pushed 2 commits · Oct 12, 4:03 PM", oldest first.
enum EventTimeline {
    /// Commits in a row by the same person share a line. Nil without events.
    static func text(_ events: [TimelineEvent], title: String, dateFormat: DateFormat) -> String? {
        guard !events.isEmpty else { return nil }
        var lines: [(event: TimelineEvent, commits: Int)] = []
        for event in events {
            if event.kind == .committed, let last = lines.last, last.event.kind == .committed, last.event.actor?.login == event.actor?.login {
                lines[lines.count - 1] = (event, last.commits + 1)
            } else {
                lines.append((event, event.kind == .committed ? 1 : 0))
            }
        }
        let shown = lines.suffix(12).map { line in
            let verb = line.commits > 1 ? "pushed \(line.commits) commits" : line.event.verb(viewer: "")
            let who = line.event.actor.map { "@\($0.login) \(verb)" } ?? verb.prefix(1).uppercased() + verb.dropFirst()
            return "• \(who) · \(dateFormat.timestamp(line.event.date))"
        }
        let earlier = lines.count > 12 ? ["…and \(lines.count - 12) earlier"] : []
        return ([title + ":"] + earlier + shown).joined(separator: "\n")
    }
}

extension StatusItem {
    /// Drawn in a detail line, with its explanation as tooltip.
    var inline: Inline {
        let item: Inline = switch style {
        case .chip(let tone):
            .chip(text ?? "", icon: icon, tone: tone)
        case .tinted(let tone):
            label(symbolColor: tone.symbolColor, textColor: tone.foregroundColor)
        case .neutral:
            label(symbolColor: .secondaryLabelColor, textColor: .secondaryLabelColor)
        case .icon(let tone):
            .stack(spacing: 2, [
                icon.map { Inline.icon($0, size: 13, color: tone.symbolColor) },
                text.map { Inline.text($0, font: .detailDigits) },
            ].compactMap { $0 })
        }
        return item.fixedSize().tooltip(help)
    }

    private func label(symbolColor: NSColor, textColor: NSColor) -> Inline {
        .stack(spacing: 3, [
            icon.map { Inline.icon($0, size: 13, color: symbolColor) },
            text.map { Inline.text($0, color: textColor) },
        ].compactMap { $0 })
    }
}

/// When the row is too narrow, the quietest items (at the end) give way first and "+N" lists them in
/// its tooltip. Chips always stay.
enum StatusLine {
    static func inline(_ items: [StatusItem]) -> Inline {
        let chipCount = items.prefix { if case .chip = $0.style { true } else { false } }.count
        return .firstFitting((chipCount...items.count).reversed().map { count in
            var pieces = items.prefix(count).map(\.inline)
            if count < items.count {
                let hidden = items.dropFirst(count)
                pieces.append(Inline.text("+\(hidden.count)", font: .detailDigits).fixedSize().tooltip(hidden.map(\.help).joined(separator: "\n")))
            }
            return .stack(spacing: 8, pieces)
        })
    }
}

/// Stack position as quiet context ("2/3"); the tooltip shows the whole chain.
struct StackLabel {
    let stack: StackInfo
    let number: Int

    var inline: Inline {
        Inline.stack(spacing: 3, [
            .icon(.stack, size: 12),
            .text("\(stack.position)/\(stack.count)", font: .detailDigits),
        ])
        .fixedSize()
        .tooltip(help)
    }

    private var help: String {
        let lines = stack.entries.enumerated().map { index, entry in
            let state = switch entry.state {
            case .open: "open"
            case .draft: "draft"
            case .merged: "merged"
            case .closed: "closed"
            }
            let marker = entry.number == number ? "▸" : "  "
            return "\(marker) \(index + 1). #\(entry.number) \(state)\(entry.number == number ? "  ← this PR" : "")"
        }
        let source = stack.isNative ? "" : "\n\nDerived from branch names (base → head)."
        return "Part of a stack, bottom to top:\n" + lines.joined(separator: "\n") + source
    }
}

enum DiffSizeLabel {
    /// Monochrome: red and green are reserved for CI and review state.
    static func inline(additions: Int, deletions: Int) -> Inline {
        Inline.text("+\(additions) −\(deletions)", font: .detailDigits)
            .fixedSize()
            .tooltip("\(additions) lines added, \(deletions) removed")
    }
}
