import Foundation
import ClarcCore

@MainActor
final class CompactService {
    private weak var appState: AppState?
    private var inFlight: Task<CompactionRecord, Error>?

    init(appState: AppState) {
        self.appState = appState
    }

    /// True while a compact is in progress. Used by callers to
    /// disable trigger buttons and to coalesce auto-trigger calls.
    var isCompacting: Bool { inFlight != nil }

    /// Run a full compact cycle for the session that's currently
    /// selected in the given window.
    ///
    /// 1. Snapshot the current ChatMessage list
    /// 2. Find recent user messages within the 20k token budget
    /// 3. Call `claude.compactSession` for the summary
    /// 4. Build the new compact history = recent user messages + summary
    /// 5. Apply via `appState.applyCompaction`
    func run(in window: WindowState) async throws -> CompactionRecord {
        // Coalesce concurrent calls
        if let existing = inFlight { return try await existing.value }
        guard let appState else { throw CompactError.cancelled }

        let task = Task<CompactionRecord, Error> { [weak appState] in
            guard let appState else { throw CompactError.cancelled }
            return try await Self.performCompact(appState: appState, window: window)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func performCompact(
        appState: AppState,
        window: WindowState
    ) async throws -> CompactionRecord {
        guard let sid = window.currentSessionId,
              let session = appState.sessionStates[sid] else {
            throw CompactError.noSession
        }
        let original = session.allMessages
        guard original.count >= 2 else {
            throw CompactError.tooShort
        }

        // 1. Find recent user messages within budget
        var recent: [ChatMessage] = []
        var budget = CompactionRecord.recentUserTokenBudget
        for msg in original.reversed() where msg.role == .user {
            let cost = TokenEstimator.estimate(msg.content)
            if budget - cost < 0 { break }
            recent.insert(msg, at: 0)
            budget -= cost
        }

        // 2. Resolve cwd for the CLI invocation
        let cwd: String? = {
            guard let pid = window.selectedProject?.id,
                  let project = appState.projects.first(where: { $0.id == pid }) else { return nil }
            return project.path
        }()

        // 3. Call CLI for the summary. The session id doubles as
        //    the Claude CLI session id (see ClaudeService.fetchContextPercentage).
        let summary = try await appState.claude.compactSession(
            sessionId: sid,
            model: "haiku",
            cwd: cwd
        )

        // 4. Build the new history
        let summaryMessage = ChatMessage(
            role: .assistant,
            content: CompactionRecord.summaryPrefix + summary,
            isCompactBoundary: true
        )
        let newHistory: [ChatMessage] = recent + [summaryMessage]

        // 5. Build record + apply
        let record = CompactionRecord(
            compactedAt: Date(),
            summaryText: summary,
            originalMessages: original,
            originalCount: original.count,
            originalTokenEstimate: TokenEstimator.estimate(original),
            newTokenEstimate: TokenEstimator.estimate(newHistory)
        )

        appState.applyCompaction(record, newHistory: newHistory, in: window)
        return record
    }
}

enum CompactError: Error, LocalizedError {
    case tooShort
    case noSession
    case cancelled

    var errorDescription: String? {
        switch self {
        case .tooShort: return "对话太短,无需压缩"
        case .noSession: return "未找到当前 session"
        case .cancelled: return "压缩已取消"
        }
    }
}
