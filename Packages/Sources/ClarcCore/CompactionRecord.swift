import Foundation

/// A snapshot of a session that has been compacted. The original
/// messages are kept in memory (and persisted in the session JSONL)
/// so the UI can still show them, while the CLI sees a shorter
/// `[initialContext] + [recent user messages] + [summary]` history.
public struct CompactionRecord: Codable, Equatable, Sendable {
    public let compactedAt: Date
    public let summaryText: String
    public let originalMessages: [ChatMessage]
    public let originalCount: Int
    public let originalTokenEstimate: Int
    public let newTokenEstimate: Int

    public init(
        compactedAt: Date,
        summaryText: String,
        originalMessages: [ChatMessage],
        originalCount: Int,
        originalTokenEstimate: Int,
        newTokenEstimate: Int
    ) {
        self.compactedAt = compactedAt
        self.summaryText = summaryText
        self.originalMessages = originalMessages
        self.originalCount = originalCount
        self.originalTokenEstimate = originalTokenEstimate
        self.newTokenEstimate = newTokenEstimate
    }
}

extension CompactionRecord {
    /// Codex-style token budget for recent user messages kept after
    /// a compact. The rest of the history is replaced by the summary.
    public static let recentUserTokenBudget = 20_000

    /// Prefix prepended to the summary message that the next LLM
    /// sees. Tells it that the history was replaced by a summary
    /// written by another model.
    public static let summaryPrefix = """
    Another language model started to solve this problem and produced \
    a summary of the conversation so far. The summary is provided \
    below; please continue from where it left off.

    """
}
