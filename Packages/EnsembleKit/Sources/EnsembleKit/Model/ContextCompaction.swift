import Foundation

extension ContextBreakdown {
    /// Tokens the conversation can still take before the engine compacts it by itself: the free space, or, when
    /// the engine reports no free row, the limit less what is used and the buffer it holds back for compacting.
    /// Nil when the model's window is not known.
    public var tokensBeforeCompacting: Int? {
        guard limitTokens > 0 else { return nil }
        if let free = categories.first(where: { $0.key == "free" }) { return max(0, free.tokens) }
        let buffer = categories.first(where: { $0.key == "buffer" })?.tokens ?? 0
        return max(0, limitTokens - usedTokens - buffer)
    }

    /// One line for the context card: how much room is left before compacting, or that it is due.
    public var compactingLine: String? {
        guard let left = tokensBeforeCompacting else { return nil }
        return left > 0 ? "\(Format.tokens(left)) left before it compacts" : "Compacts on the next turn"
    }
}
