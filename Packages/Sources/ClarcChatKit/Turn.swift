import Foundation
import ClarcCore

/// One user turn plus the assistant blocks that follow before the
/// next user turn. Collapse state is owned by `MessageListView`,
/// not by the `Turn` value itself, so that re-deriving the turn
/// list (e.g. when a new user message arrives) can apply the
/// "only the last turn expanded" baseline uniformly.
struct Turn: Identifiable, Equatable {
    /// == `userMessage.id`, or a synthesized UUID for orphan turns
    /// (a turn that begins with an assistant message — e.g. the very
    /// first block of a reloaded session).
    let id: UUID

    /// First user message of the turn. For orphan turns this is a
    /// placeholder with empty content.
    let userMessage: ChatMessage

    /// Assistant blocks (each may carry thinking + text + tool call
    /// sub-blocks) belonging to this turn, in arrival order. Empty
    /// for a user-only turn.
    var assistantMessages: [ChatMessage]

    /// True iff the most recent assistant block is still streaming.
    /// Used to force-expand the last turn even if the default rule
    /// would collapse it.
    var isInProgress: Bool
}

extension Turn {
    /// Build a placeholder user message used as the head of an
    /// orphan turn (one that begins with an assistant message).
    static func orphanUserPlaceholder() -> ChatMessage {
        ChatMessage(role: .user, content: "")
    }

    /// Build the turn list from a flat sequence of chat messages.
    ///
    /// Rules:
    /// - A user message starts a new turn.
    /// - Following assistant messages join the current turn (their
    ///   blocks may include thinking / text / tool call sub-blocks).
    /// - If the list starts with an assistant message, that becomes
    ///   an orphan turn headed by a placeholder.
    ///
    /// Collapse state is **not** baked into the `Turn` value
    /// itself. The `MessageListView` owns it. The static helper
    /// only derives the structural grouping + streaming flag.
    ///
    /// - Parameters:
    ///   - items: settled messages in arrival order
    ///   - isStreamingLast: whether the tail block is currently
    ///     streaming
    static func makeTurns(
        from items: [ChatMessage],
        isStreamingLast: Bool
    ) -> [Turn] {
        var turns: [Turn] = []
        var current: Turn? = nil

        func flushCurrent() {
            if let c = current { turns.append(c) }
            current = nil
        }

        for msg in items {
            switch msg.role {
            case .user:
                flushCurrent()
                current = Turn(
                    id: msg.id,
                    userMessage: msg,
                    assistantMessages: [],
                    isInProgress: false
                )
            case .assistant:
                if current == nil {
                    // Orphan: assistant block with no preceding user.
                    let placeholder = Turn.orphanUserPlaceholder()
                    current = Turn(
                        id: UUID(),
                        userMessage: placeholder,
                        assistantMessages: [msg],
                        isInProgress: msg.isStreaming
                    )
                } else {
                    current?.assistantMessages.append(msg)
                    if msg.isStreaming {
                        current?.isInProgress = true
                    }
                }
            }
        }
        flushCurrent()

        // Mark the last turn as in-progress when the caller told
        // us the tail block is still streaming.
        if isStreamingLast, var last = turns.last {
            last.isInProgress = true
            turns[turns.count - 1] = last
        }
        return turns
    }

    /// Truncate a string to `max` characters (not bytes) and append
    /// "…" if truncated. Character-based truncation is safe for
    /// CJK and emoji.
    static func previewText(for text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max)) + "…"
    }

    /// The text shown in the collapsed header for the user row.
    var collapsedUserText: String {
        Self.previewText(for: userMessage.content, max: 30)
    }

    /// The text shown in the collapsed header for the assistant row.
    /// Falls back to the last assistant block; if there are none, the
    /// user text is reused so the row is never empty.
    var collapsedAssistantText: String {
        let last = assistantMessages.last?.content ?? userMessage.content
        return Self.previewText(for: last, max: 50)
    }
}
