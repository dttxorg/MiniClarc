import Foundation
import ClarcCore

/// One user turn plus the assistant blocks that follow before the
/// next user turn. Owns its own collapsed state. The legacy
/// `PhaseSummaryCard` was a similar idea but grouped by an implicit
/// "phase" that didn't carry clear semantics. Turns are the minimum
/// unit a user actually perceives as a conversation step, so each
/// turn is independently collapsible.
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

    /// UI state. Defaults to true for past turns beyond the fold
    /// threshold; false for the in-progress turn.
    var isCollapsed: Bool

    /// True iff the most recent assistant block is still streaming.
    /// Used to force-expand the last turn.
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
    /// - The in-progress turn (last one with `isStreaming == true`
    ///   on the tail assistant block, or `isStreamingLast == true`)
    ///   is forced to expanded.
    /// - Turns whose index is `>= foldThreshold` default to collapsed.
    ///
    /// - Parameters:
    ///   - items: settled messages in arrival order
    ///   - isStreamingLast: whether the tail block is currently
    ///     streaming
    ///   - foldThreshold: 0 = never auto-collapse; N = collapse any
    ///     turn at index >= N
    static func makeTurns(
        from items: [ChatMessage],
        isStreamingLast: Bool,
        foldThreshold: Int
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
                let collapsed = turns.count >= max(0, foldThreshold)
                current = Turn(
                    id: msg.id,
                    userMessage: msg,
                    assistantMessages: [],
                    isCollapsed: collapsed,
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
                        isCollapsed: false,
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

        // Force-expand the in-progress (last) turn.
        if var last = turns.last, last.isInProgress || isStreamingLast {
            last.isCollapsed = false
            if !turns.isEmpty {
                turns[turns.count - 1] = last
            }
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
