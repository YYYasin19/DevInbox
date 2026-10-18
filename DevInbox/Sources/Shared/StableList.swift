import Foundation

/// A list that holds still while someone's looking at it. Refreshes update the items it shows in place
/// and drop the ones that are gone, but new items wait in `held` until `showAll()`, so rows never move
/// under the pointer.
nonisolated struct StableList<Item: Identifiable> where Item.ID: Hashable {
    /// What the panel shows.
    private(set) var shown: [Item] = []
    /// Everything fetched, in the fetched order.
    private(set) var all: [Item] = []

    /// Items that arrived while holding, in the fetched order.
    var held: [Item] {
        let shownIDs = Set(shown.map(\.id))
        return all.filter { !shownIDs.contains($0.id) }
    }

    /// Takes a fresh list. While `holding`, the shown items keep their order and take the fresh
    /// values; an empty list has nothing to keep still and shows everything.
    mutating func update(_ fetched: [Item], holding: Bool) {
        all = fetched
        guard holding, !shown.isEmpty else {
            shown = fetched
            return
        }
        let fresh = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        shown = shown.compactMap { fresh[$0.id] }
    }

    mutating func showAll() {
        shown = all
    }

    /// A local change, like marking read or done, applies to both lists.
    mutating func modify(_ change: (inout [Item]) -> Void) {
        change(&shown)
        change(&all)
    }

    struct Position {
        var shown: Int?
        var all: Int?
    }

    /// Where items are now, to put them back with `reinsert(_:at:)` after removing them.
    func positions(of ids: Set<Item.ID>) -> [Item.ID: Position] {
        var positions: [Item.ID: Position] = [:]
        for (index, item) in shown.enumerated() where ids.contains(item.id) { positions[item.id, default: Position()].shown = index }
        for (index, item) in all.enumerated() where ids.contains(item.id) { positions[item.id, default: Position()].all = index }
        return positions
    }

    /// Puts removed items back where they were, e.g. on undo. Items that came back in the meantime
    /// stay where they are now.
    mutating func reinsert(_ items: [Item], at positions: [Item.ID: Position]) {
        let present = Set(all.map(\.id))
        let missing = items.filter { !present.contains($0.id) }
        // In ascending order, the positions from before the removal line up again.
        func insert(into list: inout [Item], at index: (Position) -> Int?) {
            let placed = missing
                .compactMap { item in positions[item.id].flatMap(index).map { (item, $0) } }
                .sorted { $0.1 < $1.1 }
            for (item, index) in placed {
                list.insert(item, at: min(index, list.count))
            }
        }
        insert(into: &shown, at: \.shown)
        insert(into: &all, at: \.all)
    }

    #if DEBUG
    /// Pretends the first `count` items arrived while holding, for snapshots.
    mutating func holdBack(_ count: Int) {
        shown.removeFirst(min(count, shown.count))
    }
    #endif
}
