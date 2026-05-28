import SwiftUI
import ClarcCore

/// Renders an assistant `thinking` block. Auto-expands while it is streaming
/// so the user can read the reasoning live; once a duration is recorded the
/// view stays expanded if the user hasn't interacted, then auto-collapses on
/// the next render — clicking the header overrides either state and sticks.
struct ThinkingBlockView: View {
    let block: MessageBlock
    let isMessageStreaming: Bool

    @State private var userToggle: Bool? = nil
    @State private var isCopied = false
    @State private var isHovering = false

    private var isThisBlockStreaming: Bool {
        isMessageStreaming && block.thinkingDuration == nil && !block.isThinkingRedacted
    }

    private var isExpanded: Bool {
        userToggle ?? isThisBlockStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { body(content: thinkingText) }
        }
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.surfacePrimary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .onChange(of: block.thinkingDuration) { _, newValue in
            // Auto-collapse on stream completion, but only if the user has not
            // already expressed a preference by clicking the header.
            if newValue != nil && userToggle == nil {
                userToggle = false
            }
        }
    }

    private var thinkingText: String {
        block.thinking ?? ""
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                userToggle = !isExpanded
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: block.isThinkingRedacted ? "lock.fill" : "brain")
                    .font(.system(size: ClaudeTheme.messageSize(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                headerLabel
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer(minLength: 6)
                if !block.isThinkingRedacted {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(9), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(block.isThinkingRedacted)
    }

    @ViewBuilder
    private var headerLabel: some View {
        if block.isThinkingRedacted {
            Text("Encrypted thought (redacted)", bundle: .module)
        } else if isThisBlockStreaming {
            Text("Thinking…", bundle: .module)
        } else if let duration = block.thinkingDuration {
            Text(String(format: String(localized: "Thought for %@", bundle: .module),
                        duration.formattedDuration))
        } else {
            Text("Thought", bundle: .module)
        }
    }

    @ViewBuilder
    private func body(content: String) -> some View {
        if content.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .overlay(ClaudeTheme.border)
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(ClaudeTheme.border)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                    Text(content)
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .italic()
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if isHovering && !isMessageStreaming {
                    Button {
                        copyToClipboard(thinkingText, feedback: $isCopied)
                    } label: {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
        }
    }
}
