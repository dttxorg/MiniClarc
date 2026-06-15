import Foundation
import ClarcCore

/// One unit of work inside a user turn — the Codex-style "phase".
///
/// A phase is the chunk of work the assistant does between two
/// `taskUpdate` boundaries (or, when the LLM doesn't emit task
/// updates, between two tool-call sequences). It owns:
///
/// - a `title` (from the closing `taskUpdate`, or derived from the
///   tool calls / first text line as a fallback);
/// - a `status` (`.running` while the phase is still streaming,
///   `.done`/`.failed` when its `taskUpdate` closes it);
/// - the `blocks` that belong to it (thinking, tool calls, text).
///
/// `Phase` is a **pure UI derivation** — it is rebuilt from a turn's
/// blocks every time the view re-evaluates and is never persisted.
/// The canonical data lives in `ChatMessage.blocks` / the
/// `taskUpdate` blocks themselves.
struct Phase: Identifiable, Equatable {
    /// Stable identity derived from the closing task update id when
    /// available, otherwise from the first block id. Stability
    /// across re-derivations is what keeps SwiftUI `ForEach` (and
    /// the per-phase `@State` collapse flag) from resetting.
    let id: String

    /// Heading shown in the phase header. From `taskUpdate.title`
    /// when the phase was closed by one, otherwise a fallback
    /// summary of the work it contains.
    let title: String

    /// Optional one-line summary (taskUpdate.summary) shown next to
    /// the title. Empty for fallback phases.
    let summary: String

    /// Lifecycle state. `.running` for the open trailing phase while
    /// streaming, `.done`/`.failed` once a taskUpdate closes it.
    let status: TaskUpdateStatus

    /// Elapsed/final duration when a taskUpdate provided one.
    let durationSeconds: TimeInterval?

    /// The closing task update, if any. Used by the phase header to
    /// render status + files + tests via the existing
    /// `TaskUpdateCard`.
    let taskUpdate: TaskUpdateMessage?

    /// Blocks that belong to this phase (thinking, tool calls,
    /// text). In arrival order.
    let blocks: [MessageBlock]

    /// True for the open trailing phase while the turn is streaming.
    let isInProgress: Bool

    /// A short, human label for the kind of work a fallback phase
    /// did — used when there is no taskUpdate title. Returns a count
    /// of tool calls plus the first text line if any.
    var fallbackSubtitle: String {
        Self.subtitleForFallback(blocks: blocks)
    }
}

private extension Phase {
    /// Shared subtitle helper so `makePhase` can compute the title
    /// for a fallback phase without constructing a throwaway value.
    static func subtitleForFallback(blocks: [MessageBlock]) -> String {
        let toolCount = blocks.filter { $0.isToolCall }.count
        let firstText = blocks.first(where: { $0.isText })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = firstText.isEmpty ? "" : " · " + String(firstText.prefix(40))
        if toolCount == 0 {
            return firstText.isEmpty ? "" : String(firstText.prefix(60))
        }
        return "\(toolCount) tool\(toolCount == 1 ? "" : "s")\(head)"
    }
}

extension Phase {
    /// Derive the phase list from a turn's blocks.
    ///
    /// Boundary rule: a `taskUpdate` block **closes** the current
    /// phase (it is the assistant's "I finished this chunk of work"
    /// signal — it arrives *after* the thinking/tool calls it
    /// summarises). The blocks accumulated since the previous
    /// boundary — plus the taskUpdate itself — form one phase, and
    /// the taskUpdate supplies its title/status/duration.
    ///
    /// Blocks after the last taskUpdate (or all of them, when the
    /// LLM never emits one) form a trailing phase:
    /// - while streaming, it is the `.running` phase the user is
    ///   watching;
    /// - otherwise it is a `.done` fallback phase titled from its
    ///   tool calls / first text line.
    ///
    /// - Parameters:
    ///   - blocks: the turn's blocks in arrival order
    ///   - isStreamingLast: whether the owning turn's tail block is
    ///     still streaming (drives the trailing phase's `status`)
    static func makePhases(from blocks: [MessageBlock], isStreamingLast: Bool) -> [Phase] {
        guard !blocks.isEmpty else { return [] }

        var phases: [Phase] = []
        var accumulator: [MessageBlock] = []

        func flush(with closing: TaskUpdateMessage?, isInProgress: Bool) {
            // A phase is only interesting if it has work to show OR
            // a closing task update. Skip empty leading accumulators
            // (e.g. when two taskUpdates arrive back to back).
            let owned = closing.map { _ in true } ?? !accumulator.isEmpty
            guard owned else { return }
            phases.append(makePhase(
                blocks: accumulator,
                closing: closing,
                isInProgress: isInProgress
            ))
        }

        for block in blocks {
            if let update = block.taskUpdate {
                // taskUpdate closes the accumulated phase. It is
                // included in the phase's blocks so the card can
                // still render inline if desired, and it supplies
                // the title/status.
                accumulator.append(block)
                flush(with: update, isInProgress: false)
                accumulator = []
            } else {
                accumulator.append(block)
            }
        }
        // Trailing phase: blocks after the last taskUpdate.
        flush(with: nil, isInProgress: isStreamingLast)

        return phases
    }

    private static func makePhase(
        blocks: [MessageBlock],
        closing: TaskUpdateMessage?,
        isInProgress: Bool
    ) -> Phase {
        let id: String
        let title: String
        let summary: String
        let status: TaskUpdateStatus
        let durationSeconds: TimeInterval?

        if let closing {
            id = closing.id.uuidString
            title = closing.title.isEmpty ? "Phase" : closing.title
            summary = closing.summary
            status = closing.status
            durationSeconds = closing.durationSeconds
                ?? closing.endTime?.timeIntervalSince(closing.startTime)
        } else {
            // Fallback phase (no taskUpdate). Derive a stable id and
            // a title from the work it contains.
            id = "fallback-" + (blocks.first?.id ?? UUID().uuidString)
            let subtitle = subtitleForFallback(blocks: blocks)
            return Phase(
                id: id,
                title: subtitle.isEmpty ? "Working…" : subtitle,
                summary: "",
                status: isInProgress ? .running : .done,
                durationSeconds: nil,
                taskUpdate: nil,
                blocks: blocks,
                isInProgress: isInProgress
            )
        }

        return Phase(
            id: id,
            title: title,
            summary: summary,
            status: status,
            durationSeconds: durationSeconds,
            taskUpdate: closing,
            blocks: blocks,
            isInProgress: isInProgress
        )
    }
}
