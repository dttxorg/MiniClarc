// Modifications Copyright 2026 dttxorg (MiniClarc).
// SPDX-License-Identifier: Apache-2.0
//
// Originally: Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// See ../../NOTICE in the repository root for the full modification history.

import SwiftUI
import ClarcCore

/// Message scroll area — extracted from ChatView to isolate @Observable dependencies on `messages`.
struct MessageListView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    @State private var scrollPosition = ScrollPosition()
    @State private var settledItems: [ChatMessage] = []
    @State private var scrollTask: Task<Void, Never>?
    @State private var isNearBottom = true
    @State private var isSessionReady = false
    @State private var showAllTurns = false
    /// Per-turn collapse override set by the user. `true` = user
    /// collapsed the turn, `false` = user expanded the turn. Absent
    /// = use the default "only the last turn expanded" baseline.
    @State private var collapseOverrides: [UUID: Bool] = [:]

    /// Soft cap on the number of turns rendered at once. Long
    /// sessions start with only the most recent `visibleTurnCap`
    /// turns in the view tree, with an explicit disclosure button
    /// for the hidden earlier turns.
    private static let visibleTurnCap = 200

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                settledContent()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Streaming view is in its own sibling container — text deltas don't affect settled layout
            VStack(spacing: 16) {
                // Tier 1: always render streaming content. The previous
                // `if !windowState.focusMode` guard made the screen freeze
                // when focus mode was on, because the user saw no streaming
                // updates at all. The focus-mode filter on `settledItems`
                // (see settledOnlyMessages) is the only thing focus mode
                // should affect.
                StreamingMessageView()

                if chatBridge.isStreaming {
                    HStack(alignment: .top, spacing: 0) {
                        StreamingIndicatorView(
                            startDate: chatBridge.streamingStartDate
                        )
                        Spacer(minLength: 40)
                    }
                }

                if !chatBridge.isStreaming && !settledItems.isEmpty {
                    WebPreviewButton(messages: settledItems)
                        .id("web-preview")
                }
            }
            .padding(.horizontal, 20)
            // Suppress layout animations when switching sessions so the pulse indicator
            // doesn't visually jump as StreamingMessageView changes height.
            .animation(.none, value: windowState.currentSessionId)

            Color.clear.frame(height: 1)
                .padding(.bottom, 16)
        }
        .opacity(isSessionReady ? 1 : 0)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geo in
            let distanceFromBottom = geo.contentSize.height - geo.visibleRect.maxY
            return distanceFromBottom < 120
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        .task(id: windowState.currentSessionId) {
            isSessionReady = false
            scrollTask?.cancel()
            // Reset every per-session UI state so switching sessions
            // (or returning to one) does not leak stale collapse
            // overrides from the previous session.
            collapseOverrides.removeAll()
            showAllTurns = false
            chatBridge.collapseAllTurns = false
            scrollPosition = ScrollPosition()
            rebuildSettledItems()
            // Skip scroll/fade delay for empty sessions — appear instantly
            guard !settledItems.isEmpty else {
                isSessionReady = true
                return
            }
            try? await Task.sleep(for: .milliseconds(16))  // 1 frame: scroll after VStack layout is committed
            scrollPosition.scrollTo(edge: .bottom)
            // Pre-set isNearBottom so streaming messages that arrive before onScrollGeometryChange
            // fires still trigger scrollToBottomDebounced(), keeping the pulse pinned to the bottom.
            isNearBottom = true
            try? await Task.sleep(for: .milliseconds(32))  // 2 frames: fade-in after scroll settles
            withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
        }
        .onChange(of: chatBridge.isStreaming) { old, new in
            // Only update when streaming ends — settled list doesn't change at start, so skip.
            if old && !new {
                rebuildSettledItems()
                scrollToBottomDebounced()
            }
        }
        .onChange(of: chatBridge.messages.count) { _, _ in
            // A new message was appended (user prompt, tool result that
            // produced a new assistant turn, etc.). Rebuild the settled
            // list so the new entry appears in the correct slot.
            rebuildSettledItems()
            if isNearBottom { scrollToBottomDebounced() }
            checkAutoCompact()
        }
        .onChange(of: chatBridge.messages.last?.blocks.count) { _, _ in
            // During streaming, a tool_result that lands on the *current*
            // streaming message grows its blocks without changing
            // messages.count. Rebuild so the settled list (and the fold
            // threshold) reflects the new shape.
            if chatBridge.isStreaming { rebuildSettledItems() }
        }
        .overlay {
            if settledItems.isEmpty && !chatBridge.isStreaming && windowState.currentSessionId == nil {
                EmptySessionView()
                    .allowsHitTesting(false)
            }
        }
    }

    /// Renders the turn list. Each turn is wrapped in a `TurnBlock`
    /// that knows how to render itself collapsed or expanded.
    /// The collapse state is computed per-turn: by default only
    /// the last turn is expanded; user toggles are tracked in
    /// `collapseOverrides`; `collapseAllTurns` is a session-wide
    /// override.
    @ViewBuilder
    private func settledContent() -> some View {
        let visible = makeVisibleTurns()
        let turns = visible.turns
        let lastId = turns.last?.id

        if let record = chatBridge.compactionRecord {
            CompactBanner(record: record)
        }

        if visible.hiddenCount > 0 {
            earlierTurnsButton(hiddenCount: visible.hiddenCount)
        }

        ForEach(turns) { item in
            let isLast = item.id == lastId
            TurnBlock(
                turn: item.turn,
                phases: item.phases,
                forceCollapsed: chatBridge.collapseAllTurns,
                isCollapsed: isTurnCollapsed(turnId: item.id, isLast: isLast),
                onToggle: { toggleCollapse(for: item.id, isLast: isLast) }
            )
            .id(item.id)
        }
    }

    private func earlierTurnsButton(hiddenCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showAllTurns.toggle()
                if !showAllTurns {
                    scrollPosition.scrollTo(edge: .top)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAllTurns ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(showAllTurns
                     ? "Hide earlier turns"
                     : String(format: "Show %lld earlier turns", hiddenCount))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ClaudeTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(ClaudeTheme.accentSubtle)
            )
        }
        .buttonStyle(.plain)
    }

    private struct VisibleTurn: Identifiable, Equatable {
        let turn: Turn
        let phases: [Phase]

        var id: UUID { turn.id }
    }

    private struct VisibleTurns {
        let turns: [VisibleTurn]
        let hiddenCount: Int
    }

    private func focusFiltered(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard windowState.focusMode else { return messages }
        return messages.filter { $0.role == .user || $0.isResponseComplete || $0.isCompactBoundary }
    }

    private func visibleSlice(from all: [VisibleTurn]) -> VisibleTurns {
        let cap = Self.visibleTurnCap
        guard all.count > cap else {
            return VisibleTurns(turns: all, hiddenCount: 0)
        }
        let hiddenCount = all.count - cap
        guard !showAllTurns else {
            return VisibleTurns(turns: all, hiddenCount: hiddenCount)
        }
        return VisibleTurns(turns: Array(all.suffix(cap)), hiddenCount: hiddenCount)
    }

    private func phases(for turn: Turn) -> [Phase] {
        let assistantBlocks = turn.assistantMessages.flatMap { $0.blocks }
        return Phase.makePhases(from: assistantBlocks, isStreamingLast: turn.isInProgress)
    }

    private func sourceMessagesForTurns() -> [ChatMessage] {
        if let original = chatBridge.compactionRecord?.originalMessages {
            return focusFiltered(original)
        }
        return settledItems
    }

    /// True if the turn with the given id should render collapsed.
    /// Baseline rule: only the last turn is expanded. The
    /// `collapseOverrides` map lets the user flip individual turns;
    /// `forceCollapsed` (the session-wide collapse-all toggle)
    /// wins outright.
    private func isTurnCollapsed(turnId: UUID, isLast: Bool) -> Bool {
        if chatBridge.collapseAllTurns { return true }
        if let override = collapseOverrides[turnId] { return override }
        return !isLast
    }

    /// Toggle a turn's collapse state. Persists in `collapseOverrides`
    /// so the choice sticks across `makeTurns` re-derivations.
    ///
    /// The flip is based on the *effective rendered state* (which
    /// accounts for the "only the last turn expanded" baseline), not a
    /// guessed default — otherwise toggling the last turn is a no-op
    /// because its baseline is "expanded" and `?? true` would write
    /// back the same value.
    private func toggleCollapse(for turnId: UUID, isLast: Bool) {
        let current = isTurnCollapsed(turnId: turnId, isLast: isLast)
        collapseOverrides[turnId] = !current
    }

    /// Build the turn list and apply the virtualization cap. If
    /// the session has been compacted, render the original message
    /// snapshot from `compactionRecord` instead of the live
    /// `settledItems` (which has been replaced with the compacted
    /// list for CLI transmission).
    private func makeVisibleTurns() -> VisibleTurns {
        let source = sourceMessagesForTurns()
        let all = Turn.makeTurns(from: source, isStreamingLast: chatBridge.isStreaming)
            .map { turn in
                VisibleTurn(turn: turn, phases: phases(for: turn))
            }
        return visibleSlice(from: all)
    }

    // MARK: - Helpers

    // MARK: - Message Grouping

    // MARK: - Settled Items

    private func rebuildSettledItems() {
        let messages = settledOnlyMessages(from: chatBridge.messages)
        var t = Transaction()
        t.animation = nil
        withTransaction(t) { settledItems = messages }
    }

    /// If streaming, returns only completed messages excluding the last consecutive (non-error) assistant sequence.
    /// If not streaming, returns all messages without the streaming flag.
    /// In focus mode, further filters to only user messages and completed assistant responses.
    private func settledOnlyMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        var settled: [ChatMessage]
        if messages.last?.isStreaming == true {
            let boundary = streamingBoundaryIndex(in: messages)
            settled = Array(messages[..<boundary]).filter { !$0.isStreaming }
        } else {
            settled = messages.filter { !$0.isStreaming }
        }
        if windowState.focusMode {
            settled = settled.filter { $0.role == .user || $0.isResponseComplete || $0.isCompactBoundary }
        }
        return settled
    }

    private func scrollToBottomDebounced() {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// If auto-compact is enabled and the estimated token count of
    /// the live messages exceeds the threshold, trigger a compact
    /// in a detached task. Guards:
    /// - !isStreaming (don't interrupt an active response)
    /// - the trigger itself is idempotent because
    ///   CompactService.inFlight coalesces concurrent calls
    private func checkAutoCompact() {
        guard chatBridge.autoCompactThreshold > 0 else { return }
        guard !chatBridge.isStreaming else { return }
        let estimate = TokenEstimator.estimate(chatBridge.messages)
        guard estimate > chatBridge.autoCompactThreshold else { return }
        Task { @MainActor in
            await chatBridge.compact()
        }
    }
}

// MARK: - Message Grouping Helpers

/// Single-pass partition of messages into (settled, streaming) without scanning the array twice.
fileprivate func partitionByStreaming(_ messages: [ChatMessage]) -> (settled: [ChatMessage], streaming: [ChatMessage]) {
    var settled: [ChatMessage] = []
    var streaming: [ChatMessage] = []
    for m in messages { if m.isStreaming { streaming.append(m) } else { settled.append(m) } }
    return (settled, streaming)
}


struct MessageGroup: Identifiable {
    let id: UUID
    let messages: [ChatMessage]
    let isTransientGroup: Bool
}

/// Returns true if the message would render only a transient tool summary (no visible text or non-transient tools).
fileprivate func isPureTransientMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary else { return false }
    // Whitespace-only text is treated as invisible so it doesn't break transient grouping.
    let hasVisibleText = message.blocks.contains {
        guard let text = $0.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if hasVisibleText { return false }
    let toolCalls = message.blocks.compactMap(\.toolCall)
    guard !toolCalls.isEmpty else { return false }
    let hasNonTransient = toolCalls.contains { !ToolCategory(toolName: $0.name).isTransient }
    if hasNonTransient { return false }
    return true
}

/// Returns true if the message has no renderable content — all tool calls were removed
/// (e.g. empty bash output stripped by setToolResult) and there is no text.
/// These messages are invisible in the UI and should not break transient-tool grouping.
fileprivate func isInvisibleMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary, !message.isStreaming else { return false }
    return message.blocks.isEmpty
}

/// Groups consecutive pure-transient assistant messages into combined groups.
/// - Parameter minGroupSize: Minimum number of transient messages required to collapse into a group.
///   Pass 1 (streaming context) to hide even a single completed tool call the moment the next message starts.
///   Pass 2 (settled list) to keep lone tool calls visible after streaming ends.
fileprivate func groupMessages(_ messages: [ChatMessage], minGroupSize: Int = 2) -> [MessageGroup] {
    var result: [MessageGroup] = []
    var accumulator: [ChatMessage] = []

    func flushAccumulator() {
        guard !accumulator.isEmpty else { return }
        if accumulator.count >= minGroupSize {
            result.append(MessageGroup(id: accumulator[0].id, messages: accumulator, isTransientGroup: true))
        } else {
            for m in accumulator {
                result.append(MessageGroup(id: m.id, messages: [m], isTransientGroup: false))
            }
        }
        accumulator = []
    }

    for message in messages {
        if isPureTransientMessage(message) {
            accumulator.append(message)
        } else if isInvisibleMessage(message) {
            continue
        } else {
            flushAccumulator()
            result.append(MessageGroup(id: message.id, messages: [message], isTransientGroup: false))
        }
    }
    flushAccumulator()

    return result
}

// MARK: - Compact Banner

/// Banner shown above the turn list after a context compaction.
/// Summarizes when the compact happened, how many messages /
/// tokens were involved, and exposes a collapsible summary view.
private struct CompactBanner: View {
    let record: CompactionRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text(String(format: String(localized: "Context compacted at %@", bundle: .module),
                            record.compactedAt.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: String(localized: "%lld messages · ~%lld → ~%lld tokens", bundle: .module),
                            record.originalCount,
                            record.originalTokenEstimate,
                            record.newTokenEstimate))
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Button(isExpanded
                       ? String(localized: "Hide summary", bundle: .module)
                       : String(localized: "Show summary", bundle: .module)) {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            }
            if isExpanded {
                Text(record.summaryText)
                    .font(.system(size: 12))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(ClaudeTheme.surfacePrimary).opacity(0.5))
                    )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(ClaudeTheme.surfacePrimary).opacity(0.3))
        )
    }
}

// MARK: - Turn Block

/// One collapsible block per user turn. Collapsed, it shows the
/// user prompt plus a list of **phase titles** (the Codex-style
/// "what happened in this turn" summary) so the user can see at a
/// glance what the assistant did without expanding. Expanded, each
/// phase renders as its own collapsible `PhaseBlock`.
///
/// Collapse state is sourced from `MessageListView` (it owns the
/// override map so the "only the last turn expanded" baseline can
/// be re-applied when a new user message arrives).
private struct TurnBlock: View {
    let turn: Turn
    let phases: [Phase]
    let forceCollapsed: Bool
    /// Final isCollapsed value, computed by the parent. Toggling
    /// writes back to the parent's override map.
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    onToggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                if isCollapsed {
                    collapsedSummary
                } else {
                    expandedContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(ClaudeTheme.surfacePrimary))
        )
    }

    // MARK: - Collapsed

    /// The user prompt (first line) plus a compact list of the
    /// phases the turn went through. Each phase shows a status icon,
    /// its title, and an optional duration — so a collapsed turn
    /// still answers "what did the assistant do here?".
    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            // User prompt line (omitted for orphan turns so the row
            // isn't visually blank — the phase list leads instead).
            if !turn.userMessage.content.isEmpty {
                Text(turn.collapsedUserText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
            // Phase summary lines.
            if phases.isEmpty {
                // No phases yet (e.g. a user-only turn). Fall back to
                // the assistant text preview so the row is never empty.
                Text(turn.collapsedAssistantText.isEmpty ? "…" : turn.collapsedAssistantText)
                    .font(.system(size: 12))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            } else {
                ForEach(phases.prefix(8)) { phase in
                    PhaseTitleRow(phase: phase)
                }
                if phases.count > 8 {
                    Text(String(format: String(localized: "+ %lld more phases", bundle: .module), phases.count - 8))
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedContent: some View {
        // Skip the placeholder for orphan turns
        if !turn.userMessage.content.isEmpty {
            MessageBubble(message: turn.userMessage)
        }

        if phases.isEmpty {
            // No phase boundaries — render the raw assistant bubbles
            // (preserves the original behaviour for plain text turns).
            ForEach(turn.assistantMessages) { msg in
                MessageBubble(message: msg)
            }
        } else {
            ForEach(phases) { phase in
                PhaseBlock(phase: phase)
            }
        }
    }
}

// MARK: - Phase Title Row (collapsed-turn summary)

/// A single one-line phase summary used inside a collapsed
/// `TurnBlock`. Mirrors the visual language of the expanded
/// `PhaseBlock` header so the two states read consistently.
private struct PhaseTitleRow: View {
    let phase: Phase

    var body: some View {
        HStack(spacing: 6) {
            phaseStatusIcon
                .frame(width: 12, height: 12)
            Text(phase.title)
                .font(.system(size: 12))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let dur = phase.durationSeconds {
                Text(formatDuration(dur))
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var phaseStatusIcon: some View {
        switch phase.status {
        case .running:
            Image(systemName: "circle.dotted")
                .foregroundStyle(ClaudeTheme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusWarning)
        }
    }
}

// MARK: - Phase Block (expanded-turn detail)

/// One collapsible phase inside an expanded turn. The header shows
/// the phase title/status/duration (reusing `TaskUpdateCard`'s visual
/// when a taskUpdate is available, otherwise a lightweight header).
/// Expanding reveals the phase's message bubbles (thinking, tool
/// calls, text).
private struct PhaseBlock: View {
    let phase: Phase
    @State private var isExpanded: Bool

    init(phase: Phase) {
        self.phase = phase
        // Default expansion mirrors TaskProgressStore: running/failed
        // expand, done collapses. When there is no taskUpdate we keep
        // the trailing (in-progress) phase expanded and collapse the
        // settled ones.
        _isExpanded = State(initialValue: phase.isInProgress || phase.status != .done)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    phaseDetail
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(ClaudeTheme.surfacePrimary).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                statusIcon.frame(width: 14, height: 14)
                Text(phase.title)
                    .font(.system(size: ClaudeTheme.messageSize(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if !phase.summary.isEmpty {
                    Text(phase.summary)
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let dur = phase.durationSeconds {
                    Text(formatDuration(dur))
                        .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch phase.status {
        case .running:
            ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ClaudeTheme.statusSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(ClaudeTheme.statusWarning)
        }
    }

    // MARK: Detail

    /// Render the phase's blocks as a synthetic ChatMessage so the
    /// existing `MessageBubble` does all the heavy lifting (tool
    /// result views, thinking blocks, text). The taskUpdate block —
    /// if present — is rendered via the dedicated `TaskUpdateCard`
    /// so its files/tests sections show up.
    @ViewBuilder
    private var phaseDetail: some View {
        let nonTaskBlocks = phase.blocks.filter { !$0.isTaskUpdate }
        if !nonTaskBlocks.isEmpty {
            // Synthetic assistant message carries only this phase's
            // blocks; role/streaming flags are inherited from the
            // phase progress so running phases keep streaming chrome.
            let synthetic = ChatMessage(
                role: .assistant,
                blocks: nonTaskBlocks,
                isStreaming: phase.isInProgress
            )
            MessageBubble(message: synthetic)
        }
        if let update = phase.taskUpdate {
            TaskUpdateCard(update: update, isExpanded: .constant(true))
        }
    }
}

// MARK: - Shared Helper

/// Returns the start index of the last consecutive non-error assistant sequence.
/// Used to distinguish the settled (previous) / active (streaming) boundary.
private func streamingBoundaryIndex(in messages: [ChatMessage]) -> Int {
    var idx = messages.count - 1
    while idx >= 0 && messages[idx].role == .assistant && !messages[idx].isError {
        idx -= 1
    }
    return idx + 1
}

// MARK: - Streaming Message (isolated view — chatBridge.messages dependency confined to this view)

struct StreamingMessageView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState

    var body: some View {
        let messages = chatBridge.messages
        let activeMessages = activeResponseMessages(from: messages)
        let (settledActive, streamingActive) = partitionByStreaming(activeMessages)
        Group {
            if !activeMessages.isEmpty {

                if !streamingActive.isEmpty {
                    // Collapse completed transient tool calls (even a single one) the moment
                    // the next streaming message begins, so only the current message stays visible.
                    let groups = groupMessages(settledActive, minGroupSize: 1)
                    ForEach(groups) { group in
                        if group.isTransientGroup {
                            TransientGroupSummaryView(messages: group.messages)
                                .id(group.id)
                        } else if let message = group.messages.first {
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                } else {
                    // Nothing streaming yet — show each settled message individually.
                    ForEach(settledActive, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }

                ForEach(streamingActive, id: \.id) { message in
                    MessageBubble(message: message)
                        .id(message.id)
                }
            }
        }
    }

    /// Returns the last consecutive assistant sequence (including streaming turn) while streaming.
    /// Returns an empty array when not streaming so StreamingMessageView renders nothing.
    private func activeResponseMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.last?.isStreaming == true else { return [] }
        return Array(messages[streamingBoundaryIndex(in: messages)...])
    }
}

// MARK: - Transient Group Summary

struct TransientGroupSummaryView: View {
    let messages: [ChatMessage]
    @State private var isExpanded = false

    private var allToolCalls: [ToolCall] {
        messages.flatMap { $0.blocks.compactMap(\.toolCall) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text(String(format: String(localized: "%lld tools executed", bundle: .module), allToolCalls.count))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.size(9)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(allToolCalls, id: \.id) { toolCall in
                        ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                    }
                }
            }
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Phase Group Summary (Tier 3)


// MARK: - Empty Session

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: ClaudeTheme.size(36)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("How can I help you?", bundle: .module)
                .font(.system(size: ClaudeTheme.size(18), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Streaming Indicator

/// Live "the agent is working" indicator. Shows a context-aware
/// label (thinking / running a tool / generating text / waiting)
/// plus a ticking counter so the user can see the agent is alive
/// during long silent gaps — the same reassurance Codex's
/// incrementing token count gives.
struct StreamingIndicatorView: View {
    @Environment(ChatBridge.self) private var chatBridge
    var startDate: Date?

    /// Ticked locally at ~4Hz so the counter visibly changes even
    /// between CLI deltas (e.g. while a tool is executing). The
    /// underlying values come from `chatBridge`.
    @State private var heartbeat: Int = 0
    @State private var heartbeatTask: Task<Void, Never>?

    /// Resolve what the agent is doing right now, in priority order.
    private var activity: Activity {
        let bridge = chatBridge
        if bridge.isThinking {
            return .thinking(seconds: bridge.streamingThinkingSeconds)
        }
        if let tool = bridge.activeToolName {
            return .runningTool(name: tool, executedCount: bridge.streamingToolsExecuted)
        }
        // Has produced text deltas this turn → actively generating.
        if bridge.streamingOutputChars > 0 {
            return .generating(chars: bridge.streamingOutputChars)
        }
        return .waiting(executedCount: bridge.streamingToolsExecuted)
    }

    var body: some View {
        HStack(spacing: 8) {
            PulseRingView()
                .id("pulse")

            activityLabel
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)

            // Live counter — the bit that "ticks" like Codex's token count.
            counterText
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textTertiary)
                .monospacedDigit()

            Spacer()

            if let startDate {
                ElapsedTimeView(startDate: startDate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        .onAppear {
            heartbeatTask?.cancel()
            heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    heartbeat &+= 1
                }
            }
        }
        .onDisappear {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// Label depends on the current activity. `_ = heartbeat` so
    /// SwiftUI re-evaluates this view on every tick.
    @ViewBuilder
    private var activityLabel: some View {
        let _ = heartbeat
        switch activity {
        case .thinking:
            Text("Thinking...", bundle: .module)
        case .runningTool(let name, _):
            // e.g. "Running Edit..." — localise the verb, keep the
            // tool name verbatim (it is a CLI tool identifier).
            (Text("Running ", bundle: .module) + Text(verbatim: name) + Text("…", bundle: .module))
        case .generating:
            Text("Generating response...", bundle: .module)
        case .waiting:
            Text("Waiting...", bundle: .module)
        }
    }

    /// The numeric counter that ticks each frame.
    @ViewBuilder
    private var counterText: some View {
        let _ = heartbeat
        switch activity {
        case .thinking(let seconds):
            Text(String(format: String(localized: "%.1fs thinking", bundle: .module), seconds))
        case .runningTool(_, let executed):
            if executed > 0 {
                Text(String(format: String(localized: "%lld tools run", bundle: .module), executed))
            } else {
                Text("…", bundle: .module)
            }
        case .generating(let chars):
            Text(String(format: String(localized: "%lld chars", bundle: .module), chars))
        case .waiting(let executed):
            if executed > 0 {
                Text(String(format: String(localized: "%lld tools run", bundle: .module), executed))
            } else {
                Text("…", bundle: .module)
            }
        }
    }

    private enum Activity {
        case thinking(seconds: TimeInterval)
        case runningTool(name: String, executedCount: Int)
        case generating(chars: Int)
        case waiting(executedCount: Int)
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        Text(elapsed.formattedDuration)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
                tickTask?.cancel()
                tickTask = Task { [startDate] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        await MainActor.run {
                            elapsed = Date().timeIntervalSince(startDate)
                        }
                    }
                }
            }
            .onDisappear {
                tickTask?.cancel()
                tickTask = nil
            }
    }
}
