// Modifications Copyright 2026 dttxorg (MiniClarc).
// SPDX-License-Identifier: Apache-2.0
//
// Originally: Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// See ../../NOTICE in the repository root for the full modification history.

import Foundation
import ClarcCore

/// Per-window observable bridge between chat views (ClarcChatKit) and the app-layer services.
///
/// The app target creates one `ChatBridge` per window, sets up action handlers, and keeps the
/// streaming state properties updated. Chat views consume this object via the SwiftUI environment.
@Observable
@MainActor
public final class ChatBridge {

    // MARK: - Streaming State (pushed by AppState)

    public var messages: [ChatMessage] = []
    public var isStreaming: Bool = false
    public var isThinking: Bool = false
    /// Live streaming-progress signals used by the streaming
    /// indicator to prove the agent is still working (instead of
    /// looking frozen during long silent gaps). All derived from
    /// `StreamingTail` / `SessionStreamState` and pushed by
    /// `AppState.startBridgeObservation`.
    //
    // `streamingTick` is bumped on every observed change so SwiftUI
    // views that read it re-evaluate at the same cadence the CLI
    // pushes deltas — this is what makes the live counter "tick"
    // like Codex's token count.
    public var activeToolName: String? = nil
    public var streamingOutputChars: Int = 0
    public var streamingToolsExecuted: Int = 0
    public var streamingThinkingSeconds: TimeInterval = 0
    public var streamingTick: Int = 0
    /// When true, every Turn in the chat list is rendered collapsed
    /// regardless of its own `isCollapsed` state. This is a per-window,
    /// transient UI state — toggled by a "collapse all" button in the
    /// message toolbar. It does NOT mutate per-turn stored state.
    /// Reset to false when the window switches sessions.
    public var collapseAllTurns: Bool = false
    /// Non-nil after a context compaction. The original messages are
    /// kept here so the UI can continue to show them, while
    /// `messages` holds the compacted list that gets sent to the CLI
    /// on the next turn. Pushed from `AppState` via
    /// `SessionStreamState.compactionRecord`.
    public var compactionRecord: CompactionRecord?
    /// Auto-compact when total estimated tokens of the live
    /// `messages` exceed this value. 0 = disabled. Pushed from
    /// `AppState.autoCompactThreshold`.
    public var autoCompactThreshold: Int = 0
    public var streamingStartDate: Date?
    public var lastTurnContextUsedPercentage: Double?
    public var modelDisplayName: String = ""
    public var sessionStats: ChatSessionStats = ChatSessionStats()
    public var autoPreviewSettings: AttachmentAutoPreviewSettings = AttachmentAutoPreviewSettings()
    public weak var taskProgressStore: TaskProgressStore?
    /// LLM-generated one-sentence summaries for completed phases,
    /// used by `PhaseBlock` / `PhaseTitleRow`. Weak because the
    /// store is owned by `WindowState`.
    public weak var phaseSummaryStore: PhaseSummaryStore?

    // MARK: - Action Handlers (set up by the app target)

    public var sendHandler: (() async -> Void)?
    public var cancelStreamingHandler: (() async -> Void)?
    public var sendSlashCommandHandler: ((String) async -> Void)?
    public var runTerminalCommandHandler: ((String) async -> Void)?
    public var editAndResendHandler: ((UUID, String) async -> Void)?
    public var forkFromHereHandler: ((UUID) async -> Void)?
    public var fetchRateLimitHandler: (() async -> RateLimitUsage?)?
    /// Trigger a context compaction for the current session. Wired
    /// up by `AppState.setupChatBridge` to call
    /// `compactService.run(in: window)`.
    public var compactHandler: (() async -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - Action Methods

    public func send() async {
        await sendHandler?()
    }

    public func cancelStreaming() async {
        await cancelStreamingHandler?()
    }

    public func sendSlashCommand(_ command: String) async {
        await sendSlashCommandHandler?(command)
    }

    public func runTerminalCommand(_ command: String) async {
        await runTerminalCommandHandler?(command)
    }

    public func editAndResend(messageId: UUID, newContent: String) async {
        await editAndResendHandler?(messageId, newContent)
    }

    public func forkFromHere(messageId: UUID) async {
        await forkFromHereHandler?(messageId)
    }

    public func fetchRateLimit() async -> RateLimitUsage? {
        await fetchRateLimitHandler?()
    }

    /// Manually trigger context compaction for the current session.
    public func compact() async {
        await compactHandler?()
    }
}
