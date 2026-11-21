import Foundation

/// Stepping through sessions in sidebar order (Next session, Previous session).
public enum SessionCycling {
    /// The id `step` places after `current` in `order`, wrapping at both ends. With nothing selected, or a
    /// selection that is not in the list, a forward step lands on the first id and a backward step on the last.
    /// Nil when there is nowhere else to go (no sessions, or only the selected one).
    public static func neighbour(of current: String?, in order: [String], step: Int) -> String? {
        guard !order.isEmpty, step != 0 else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return step > 0 ? order.first : order.last
        }
        let count = order.count
        let target = order[((index + step) % count + count) % count]
        return target == current ? nil : target
    }
}
