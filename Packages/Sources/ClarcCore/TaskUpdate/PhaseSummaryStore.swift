import Foundation

/// In-memory cache of LLM-generated one-sentence summaries for
/// completed phases. Keyed by phase id (the closing
/// `TaskUpdateMessage.id`, or a stable `fallback-<firstBlockId>`
/// string for phases without a task update).
///
/// This is **not** persisted — it lives only for the current app
/// session. The canonical phase data still lives in
/// `ChatMessage.blocks`; the store just holds the async-generated
/// summary text so the UI can show it next to the phase header.
///
/// Writes are coalesced: a pending request for a given id blocks
/// duplicate requests until it completes, so a phase that the view
/// re-derives several times while streaming only triggers one
/// summarisation call.
@MainActor
public final class PhaseSummaryStore: ObservableObject {

    @Published public private(set) var summaries: [String: String] = [:]
    @Published public private(set) var pending: Set<String> = []
    @Published public private(set) var failed: Set<String> = []

    public init() {}

    public func summary(for phaseId: String) -> String? {
        summaries[phaseId]
    }

    public func isPending(_ phaseId: String) -> Bool {
        pending.contains(phaseId)
    }

    public func hasFailed(_ phaseId: String) -> Bool {
        failed.contains(phaseId)
    }

    /// Record a generated summary. Called by the summarisation
    /// service after a successful LLM call.
    public func setSummary(_ summary: String, for phaseId: String) {
        summaries[phaseId] = summary
        pending.remove(phaseId)
        failed.remove(phaseId)
    }

    /// Mark a phase as summarising (blocks duplicate requests).
    /// Returns false if a request is already in flight or the
    /// summary is already known.
    @discardableResult
    public func markPending(_ phaseId: String) -> Bool {
        if summaries[phaseId] != nil || pending.contains(phaseId) { return false }
        pending.insert(phaseId)
        return true
    }

    /// Mark a phase as failed (e.g. the LLM call threw). The caller
    /// may retry later by calling `markPending` again.
    public func markFailed(_ phaseId: String) {
        pending.remove(phaseId)
        failed.insert(phaseId)
    }

    /// Clear all summaries (e.g. on session switch).
    public func clear() {
        summaries.removeAll()
        pending.removeAll()
        failed.removeAll()
    }
}
