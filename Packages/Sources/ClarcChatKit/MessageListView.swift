// Modifications Copyright 2026 dttxorg (MiniClarc).
// SPDX-License-Identifier: Apache-2.0
//
// Originally: Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// See ../../NOTICE in the repository root for the full modification history.

import SwiftUI
import Combine
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

    /// Read fold threshold from the per-window mirror. 0 disables folding.
    private var foldThreshold: Int { windowState.foldThreshold }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Codex-style per-turn roll-up cards interleaved with the
                // chat bubbles. When at least one phase summary exists
                // (i.e. at least one assistant turn has completed), we
                // render via `chatWithPhases` which prepends each phase
                // card to its assistant message. The legacy
                // "show N earlier messages" fold button is suppressed
                // in that case — phase cards are already collapsed by
                // default and the user expands them individually.
                //
                // When no phase summaries exist (e.g. a session loaded
                // from disk that pre-dates the phase feature), fall
                // back to the old fold-threshold rendering so the chat
                // list is still usable.
                let phaseMessageIDs = Set(chatBridge.phaseSummaries.flatMap { $0.messageIDs })
                let summariesByMessageID = Dictionary(
                    uniqueKeysWithValues: chatBridge.phaseSummaries.flatMap { summary in
                        summary.messageIDs.map { ($0, summary) }
                    }
                )

                // The fold placeholder + message rows are rendered in
                // BOTH paths. The placeholder appears whenever
                // (settledItems.count - foldThreshold) > 0, independent
                // of whether phase summaries exist.
                let foldThresh = max(0, windowState.foldThreshold)
                let hiddenCount = max(0, settledItems.count - foldThresh)

                // 1. Fold placeholder (when threshold is exceeded)
                if foldThresh > 0 && hiddenCount > 0 {
                    foldToggleButton(hiddenCount: hiddenCount)
                }

                // 2. The actual content. Either the phase path (when
                //    phase summaries exist) or the legacy messageRows
                //    path.
                if chatBridge.phaseSummaries.isEmpty {
                    // Legacy: just message rows
                    if hiddenCount > 0 {
                        messageRows(settledItems.suffix(foldThresh))
                    } else {
                        messageRows(settledItems[...])
                    }
                } else {
                    // Phase path with virtualization cap at 100 phases
                    let totalPhases = chatBridge.phaseSummaries.count
                    let visibleEnd = min(foldThresh, 100)
                    let visibleStart = max(0, totalPhases - visibleEnd)
                    chatWithPhases(
                        visibleRange: visibleStart..<totalPhases,
                        phaseSummaries: chatBridge.phaseSummaries,
                        allSummariesByMessageID: summariesByMessageID,
                        allMessages: settledItems,
                        forceCollapse: chatBridge.collapseAllPhases
                    )
                }
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

    /// Render settled messages interleaved with phase cards. Messages whose
    /// id is in `phaseMessageIDs` are emitted as `MessageBubble`s *inside*
    /// the corresponding `PhaseSummaryCard` (when expanded); they are
    /// skipped from the top-level list to avoid duplication. User messages
    /// and orphan (cancelled) assistant messages render as plain bubbles.
    @ViewBuilder
    private func chatWithPhases(
        messages: [ChatMessage],
        phaseMessageIDs: Set<UUID>,
        summariesByMessageID: [UUID: PhaseSummary]
    ) -> some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { _, message in
            if let summary = summariesByMessageID[message.id] {
                PhaseSummaryCard(summary: summary, message: message)
                    .id(summary.id)
            } else {
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
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(elapsed.formattedDuration)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
    }
}

// MARK: - Phase Summary Card

/// Per-turn roll-up card. Collapsed by default — shows a 3-line summary
/// (Phase N header with duration, the change summary, the verification
/// status). Clicking the header expands the card to reveal the
/// underlying assistant message bubble plus per-tool-call log.
///
/// The collapsed-then-expand UX mirrors Codex TUI's per-task roll-up
/// cards. User expands a card to audit what the turn did; the default
/// view stays clean.
struct PhaseSummaryCard: View {
    let summary: PhaseSummary
    let message: ChatMessage

    @State private var isExpanded: Bool = false
    @State private var elapsed: Double = 0

    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Pre-compute the "1m 23s" / "45s" duration string from the
    /// snapshot. We bind this once per render; the live update is only
    /// relevant for the currently streaming turn, which doesn't have a
    /// `PhaseSummary` yet, so for completed phases this is static.
    private var durationText: String {
        let s = summary.durationSeconds
        if s < 60 { return "\(Int(s))s" }
        let minutes = Int(s) / 60
        let seconds = Int(s) % 60
        return "\(minutes)m \(seconds)s"
    }

    private var statusIcon: String {
        if summary.failedInvocationCount > 0 { return "exclamationmark.triangle.fill" }
        if summary.unverifiedCommandCount > 0 { return "questionmark.circle" }
        if summary.readyForReview { return "checkmark.seal.fill" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if summary.failedInvocationCount > 0 { return .red }
        if summary.unverifiedCommandCount > 0 { return .orange }
        if summary.readyForReview { return .green }
        return .secondary
    }

    private var statusText: String {
        if summary.failedInvocationCount > 0 {
            return "\(summary.failedInvocationCount) failed"
        }
        if summary.unverifiedCommandCount > 0 {
            return "\(summary.unverifiedCommandCount) unverified"
        }
        if summary.readyForReview {
            let n = summary.toolInvocations.count
            return n == 0 ? "no tool calls" : "\(n) tool\(n == 1 ? "" : "s") ok"
        }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header — always visible. The card has a
            // distinctive left-edge color bar to set it apart from
            // regular MessageBubbles (the fold / roll-up is the new
            // shape and needs to be visually obvious).
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: statusIcon)
                                .font(.system(size: ClaudeTheme.size(13)))
                                .foregroundStyle(statusColor)
                                .frame(width: 16, alignment: .center)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    // "PHASE 1" badge in monospace.
                                    Text("PHASE \(summary.phaseIndex + 1)")
                                        .font(.system(size: ClaudeTheme.size(11), weight: .bold, design: .monospaced))
                                        .foregroundStyle(statusColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(statusColor.opacity(0.12))
                                        )
                                    Text(durationText)
                                        .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                                        .foregroundStyle(ClaudeTheme.textTertiary)
                                    Spacer()
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: ClaudeTheme.size(10)))
                                        .foregroundStyle(ClaudeTheme.textTertiary)
                                }

                                if !summary.changeSummary.isEmpty {
                                    Text(summary.changeSummary)
                                        .font(.system(size: ClaudeTheme.size(11)))
                                        .foregroundStyle(ClaudeTheme.textSecondary)
                                        .lineLimit(1)
                                }

                                HStack(spacing: 6) {
                                    Text(statusText)
                                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                                        .foregroundStyle(statusColor)
                                    if !summary.suggestedNext.isEmpty {
                                        Text("·")
                                            .foregroundStyle(ClaudeTheme.textTertiary)
                                        Text(summary.suggestedNext)
                                            .font(.system(size: ClaudeTheme.size(11)))
                                            .foregroundStyle(ClaudeTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
            )

            // Expanded body — per-tool-call log + the assistant bubble.
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !summary.toolInvocations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.toolInvocations.enumerated()), id: \.offset) { _, invocation in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: invocation.status == .failed
                                          ? "xmark.circle.fill"
                                          : (invocation.status == .unverified ? "questionmark.circle" : "checkmark.circle.fill"))
                                        .font(.system(size: ClaudeTheme.size(10)))
                                        .foregroundStyle(invocation.status == .failed
                                                         ? .red
                                                         : (invocation.status == .unverified ? .orange : .green))
                                        .frame(width: 12)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(invocation.name)
                                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                                        Text(invocation.inputSummary)
                                            .font(.system(size: ClaudeTheme.size(10), design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(ClaudeTheme.surfaceElevated)
                        )
                    }
                    MessageBubble(message: message)
                        .id(message.id)
                }
                .padding(.top, 4)
                .padding(.leading, 11)  // align with header text (3 + 8)
            }
        }
    }
}
