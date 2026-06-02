import Foundation
import Combine

/// Tracks the lifecycle of `TaskUpdateMessage` instances — which
/// `id`s we've already seen, their current state, and the user's
/// manual expand/collapse choices.
///
/// This is **not** the render source. `MessageBlock.taskUpdate` is
/// the canonical render source. The store exists so the streaming
/// layer can ask "have I already seen this id?" and so Swift code
/// outside the stream can drive the lifecycle directly.
@MainActor
public final class TaskProgressStore: ObservableObject {

    @Published public private(set) var tasks: [UUID: TaskUpdateMessage] = [:]
    @Published public private(set) var manualExpansion: [UUID: Bool] = [:]

    public init() {}

    // MARK: - Lifecycle

    @discardableResult
    public func start(title: String, summary: String) -> UUID {
        let message = TaskUpdateMessage(title: title, summary: summary, status: .running)
        tasks[message.id] = message
        return message.id
    }

    public func update(
        id: UUID,
        summary: String?,
        details: String?,
        filesChanged: [TaskFileChange]?,
        testResults: [TaskTestResult]?
    ) {
        guard var existing = tasks[id] else { return }
        if let summary { existing.summary = summary }
        if let details { existing.details = details }
        if let filesChanged { existing.filesChanged = filesChanged }
        if let testResults { existing.testResults = testResults }
        tasks[id] = existing
    }

    public func finish(
        id: UUID,
        summary: String?,
        details: String?,
        status: TaskUpdateStatus
    ) {
        guard var existing = tasks[id] else { return }
        existing.status = status
        if let summary { existing.summary = summary }
        if let details { existing.details = details }
        existing.endTime = Date()
        existing.durationSeconds = existing.endTime?.timeIntervalSince(existing.startTime)
        tasks[id] = existing
    }

    public func fail(id: UUID, summary: String?, details: String?) {
        finish(id: id, summary: summary, details: details, status: .failed)
    }

    // MARK: - Parser integration

    /// Insert a `TaskUpdateMessage` from the parser. If the id is
    /// already tracked, preserve the original `startTime` and
    /// recompute `durationSeconds` when applicable.
    public func upsert(_ update: TaskUpdateMessage) -> (wasNew: Bool, merged: TaskUpdateMessage) {
        if let existing = tasks[update.id] {
            var merged = update
            merged.startTime = existing.startTime
            if merged.status != .running, let end = merged.endTime {
                merged.durationSeconds = end.timeIntervalSince(merged.startTime)
            }
            tasks[update.id] = merged
            return (false, merged)
        } else {
            tasks[update.id] = update
            return (true, update)
        }
    }

    // MARK: - Expansion state

    public func isExpanded(_ update: TaskUpdateMessage) -> Bool {
        if let manual = manualExpansion[update.id] { return manual }
        switch update.status {
        case .running, .failed: return true
        case .done: return false
        }
    }

    public func setExpanded(_ expanded: Bool, for id: UUID) {
        manualExpansion[id] = expanded
    }
}
