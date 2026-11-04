/// Chooses which menu-bar items redraw on a tick.
///
/// Each status item update costs about 3 ms inside AppKit, because macOS snapshots the item and
/// sends it to `MenuBarAgent`. That leaves room for one update per sample within the CPU target.
/// See docs/m1-findings.md.
public enum StatusUpdatePolicy {
    public struct Candidate: Sendable, Equatable {
        public let index: Int
        /// Tick of the item's last redraw, or nil if it has never been drawn.
        public let lastUpdate: UInt64?

        public init(index: Int, lastUpdate: UInt64?) {
            self.index = index
            self.lastUpdate = lastUpdate
        }
    }

    /// `pending` holds items whose appearance changed. Undrawn items all go at once, because a
    /// blank menu-bar slot is worse than the cost. Otherwise the longest-waiting item goes.
    public static func itemsToUpdate(pending: [Candidate]) -> [Int] {
        let undrawn = pending.filter { $0.lastUpdate == nil }.map(\.index)
        if !undrawn.isEmpty { return undrawn }
        let oldest = pending.min { ($0.lastUpdate ?? 0) < ($1.lastUpdate ?? 0) }
        return oldest.map { [$0.index] } ?? []
    }
}
