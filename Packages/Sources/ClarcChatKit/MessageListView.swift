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
    @State private var isOlderCollapsed = true
    @State private var isSessionReady = false
    /// Per-turn collapse override set by the user. `true` = user
    /// collapsed the turn, `false` = user expanded the turn. Absent
    /// = use the default "only the last turn expanded" baseline.
    @State private var collapseOverrides: [UUID: Bool] = [:]

    /// Read fold threshold from the per-window mirror. 0 disables folding.
    private var foldThreshold: Int { windowState.foldThreshold }

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
                            isThinking: chatBridge.isThinking,
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
            isOlderCollapsed = true
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
            // A new turn started — collapse any previously expanded earlier
            // messages so the chat list stays scrollable once the turn
            // adds more entries. Without this, expanding the fold stays
            // sticky for the rest of the session and the list grows
            // unbounded, which is what made the window feel sluggish.
            if !old && new {
                isOlderCollapsed = true
            }
            // Only update when streaming ends — settled list doesn't change at start, so skip
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

    /// Renders the fold placeholder + the per-turn message rows.
    /// The fold placeholder is shown whenever the user has folded
    /// some earlier turns out of view. The label switches between
    /// "Show N earlier turns" and "Collapse earlier turns" based on
    /// the current state.
    private func foldToggleButton(hiddenCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isOlderCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if isOlderCollapsed {
                        Text(String(format: String(localized: "Show %lld earlier turns", bundle: .module), hiddenCount))
                    } else {
                        Text("Collapse earlier turns", bundle: .module)
                    }
                }
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                Image(systemName: isOlderCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
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
        let lastId = visible.last?.id

        if let record = chatBridge.compactionRecord {
            CompactBanner(record: record)
        }

        ForEach(visible) { turn in
            TurnBlock(
                turn: turn,
                forceCollapsed: chatBridge.collapseAllTurns,
                isCollapsed: isTurnCollapsed(turnId: turn.id, isLast: turn.id == lastId),
                onToggle: { toggleCollapse(for: turn.id) }
            )
            .id(turn.id)
        }
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
    private func toggleCollapse(for turnId: UUID) {
        let current = collapseOverrides[turnId] ?? true
        collapseOverrides[turnId] = !current
    }

    /// Build the turn list and apply the virtualization cap. If
    /// the session has been compacted, render the original message
    /// snapshot from `compactionRecord` instead of the live
    /// `settledItems` (which has been replaced with the compacted
    /// list for CLI transmission).
    private func makeVisibleTurns() -> [Turn] {
        let source: [ChatMessage] = chatBridge.compactionRecord?.originalMessages ?? settledItems
        let all = Turn.makeTurns(
            from: source,
            isStreamingLast: chatBridge.isStreaming,
            foldThreshold: windowState.foldThreshold
        )
        // Cap to foldThreshold + 100 visible (virtualization cap).
        let cap = max(0, windowState.foldThreshold) + 100
        if all.count <= cap { return all }
        return Array(all.suffix(cap))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func messageRows(_ messages: some RandomAccessCollection<ChatMessage>) -> some View {
        let groups = groupMessages(Array(messages))
        ForEach(groups) { group in
            if group.isTransientGroup {
                TransientGroupSummaryView(messages: group.messages)
                    .id(group.id)
            } else if let message = group.messages.first {
                MessageBubble(message: message)
                    .id(message.id)
            }
        }
    }

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

/// One collapsible block per user turn. Renders either a 30/50-char
/// preview (collapsed) or the full message bubbles (expanded). The
/// collapsed preview never builds the bubble subtrees, so a long
/// history with many collapsed turns stays cheap.
///
/// Collapse state is sourced from `MessageListView` (it owns the
/// override map so the "only the last turn expanded" baseline can
/// be re-applied when a new user message arrives).
private struct TurnBlock: View {
    let turn: Turn
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

    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.collapsedUserText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
            Text(turn.collapsedAssistantText)
                .font(.system(size: 12))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        // Skip the placeholder for orphan turns
        if !turn.userMessage.content.isEmpty {
            MessageBubble(message: turn.userMessage)
        }
        ForEach(turn.assistantMessages) { msg in
            MessageBubble(message: msg)
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

struct StreamingIndicatorView: View {
    let isThinking: Bool
    var startDate: Date?

    var body: some View {
        HStack(spacing: 8) {
            PulseRingView()
                .id("pulse")

            Group {
                if isThinking {
                    Text("Thinking...", bundle: .module)
                } else {
                    Text("Generating response...", bundle: .module)
                }
            }
            .font(.system(size: ClaudeTheme.size(13)))
            .foregroundStyle(ClaudeTheme.textSecondary)

            Spacer()

            if let startDate {
                ElapsedTimeView(startDate: startDate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
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
