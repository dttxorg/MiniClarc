# turn-block 折叠 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **重要**:本仓库是**无测试套件的 UI app**(`CLAUDE.md` 明说)。`ClarcCore` 有 `Tests/` 但 `ClarcChatKit` 没有 testTarget 且整体 `@MainActor` 隔离。所以"先写失败测试 → 实现"的 TDD 循环替换为 **build 验证 + 启动手测**(`xcodebuild build` + `xcodebuild` build launch)。派生逻辑作为 `Turn` 静态函数,静态保证正确性。

**Goal:** 用可折叠 Turn(user+assistant 配对)替换 v2.4.3 的 `PhaseSummaryCard` 抽象。每轮包成 `TurnBlock`;▶/▼ 切换;30/50 字省略号;历史默认折叠,进行中默认展开;工具栏"全部折叠 / 全部展开"。

**Architecture:**
- 新 `Turn` struct(user message + assistant 块序列 + isCollapsed + isInProgress)
- `Turn.from(items:)` 静态构造(扫描 `settledItems`,user 起头配对,orphan assistant 走虚拟 Turn)
- `MessageListView` 重构:删 `chatWithPhases` / phase 路径,改用 `ForEach(turns) { TurnBlock }`
- 折叠时不构建子树(只渲染摘要 Text)→ 性能不退化
- `ChatBridge.collapseAllTurns` 替代 `collapseAllPhases`
- `WindowState.foldThreshold` 语义保持(从"phase"改"turn",数量级一致)

**Tech Stack:** SwiftUI 5+ (`@Observable`, `@MainActor`),macOS 15+;`.animation` 隐式过渡;`Image(systemName:)` SF Symbols;`JSONDecoder` 默认忽略未知字段(旧 `phaseSummaries` 字段不破坏 decode)。

---

## File Structure

| 文件 | Action | 责任 |
|---|---|---|
| `Packages/Sources/ClarcChatKit/Turn.swift` | **New** | `Turn` struct + 静态 `from(items:isStreaming:foldThreshold:)` 派生 + `previewText(_:max:)` helper |
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | Rewrite | 删 `chatWithPhases` / `foldToggleButton`(旧) / phase 路径分支;加 `turns` 状态 + `TurnBlock` 渲染 + 派生调用 + 动画 |
| `Packages/Sources/ClarcChatKit/ChatBridge.swift` | Modify | 删 `phaseSummaries` / `collapseAllPhases`;加 `collapseAllTurns: Bool` |
| `Packages/Sources/ClarcChatKit/ChatView.swift` | Modify | 工具栏按钮绑 `collapseAllTurns` + foldThreshold slider |
| `Clarc/App/AppState.swift` | Modify | 删 `state.phaseSummaries.append(summary)`(line 1338 附近)及 phase 维护逻辑;`PhaseSummary` 类型如果还引用则删(grep 兜底) |
| `Packages/Sources/ClarcChatKit/Resources/en.lproj/Localizable.strings` | Modify | 加 `"chat.toolbar.collapseAll"`, `"chat.toolbar.expandAll"`, `"chat.fold.preview.ellipsis"` 等 |
| `Packages/Sources/ClarcChatKit/Resources/zh-Hans.lproj/Localizable.strings` | Modify | 同上中文 |
| `Packages/Sources/ClarcChatKit/Resources/ko.lproj/Localizable.strings` | Modify | 同上韩文 |

不新增 SwiftUI 资源(纯代码 SF Symbols)。

---

## Task 1: 新建 `Turn.swift` (含派生 helper)

**Files:**
- Create: `Packages/Sources/ClarcChatKit/Turn.swift`

- [ ] **Step 1: 创建文件,定义 `Turn` struct**

写入 `Packages/Sources/ClarcChatKit/Turn.swift`:

```swift
import Foundation

/// One user turn + the assistant (or tool / thinking) blocks that follow
/// before the next user turn. Owns its own collapsed state.
///
/// The legacy `PhaseSummaryCard` was a similar idea, but grouped by an
/// implicit "phase" that didn't carry clear semantics. Turns are the
/// minimum unit a user actually perceives as a conversation step, so
/// each turn is independently collapsible.
struct Turn: Identifiable, Equatable {
    /// == `userMessage.id`, or a synthesized UUID for orphan turns
    /// (a turn that begins with an assistant message — e.g. the very
    /// first block of a reloaded session).
    let id: UUID

    /// First user message of the turn. For orphan turns this is a
    /// placeholder with empty content.
    let userMessage: ChatMessage

    /// Assistant / tool / thinking blocks belonging to this turn,
    /// in arrival order. Empty for a user-only turn.
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
        ChatMessage(
            id: UUID(),
            role: .user,
            text: "",
            timestamp: Date(),
            // remaining fields default
        )
    }

    /// Build the turn list from a flat sequence of chat messages.
    ///
    /// Rules:
    /// - A user message starts a new turn.
    /// - Following assistant / tool / thinking messages join the
    ///   current turn.
    /// - If the list starts with an assistant message, that becomes
    ///   an orphan turn headed by a placeholder.
    /// - The in-progress turn (last one, with `isStreaming` true on
    ///   the tail assistant block) is forced to expanded.
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
            case .assistant, .toolResult, .thinking:
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
            turns[turns.count - 1] = last
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
        Self.previewText(for: userMessage.text, max: 30)
    }

    /// The text shown in the collapsed header for the assistant row.
    /// Falls back to the last assistant block; if there are none, the
    /// user text is reused so the row is never empty.
    var collapsedAssistantText: String {
        let last = assistantMessages.last?.text ?? userMessage.text
        return Self.previewText(for: last, max: 50)
    }
}
```

- [ ] **Step 2: 验证 ChatMessage 的字段名与 `Turn.orphanUserPlaceholder()` 匹配**

```bash
grep -n "struct ChatMessage" Packages/Sources/ClarcCore/*.swift 2>&1
```

期望:看到 `ChatMessage` 定义,字段含 `id`, `role`, `text`, `timestamp`, `isStreaming`。如果字段名不一致(比如 `content` 而非 `text`),调整 step 1 代码。

- [ ] **Step 3: Build 验证编译通过**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```

期望:`** BUILD SUCCEEDED **`。如果 `ChatMessage` 字段不匹配,会在这里报具体错误,改 step 1 后重跑。

- [ ] **Step 4: Commit**

```bash
git add Packages/Sources/ClarcChatKit/Turn.swift
git commit -m "feat(chat): add Turn model with makeTurns derivation

Replace PhaseSummaryCard concept with per-turn grouping. A turn
consists of one user message plus the assistant/tool/thinking blocks
that follow before the next user. Orphan assistant turns (no
preceding user) are wrapped in a synthetic placeholder turn.

makeTurns(items:isStreamingLast:foldThreshold:) handles the three
fold rules: past turns past the threshold collapse, the in-progress
turn expands, and user-less openings become orphan turns.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `ChatBridge` 字段替换

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/ChatBridge.swift`

- [ ] **Step 1: 删除 `phaseSummaries` 字段,加 `collapseAllTurns`**

读取 `ChatBridge.swift`,找 `phaseSummaries` 字段定义(应是 `var phaseSummaries: [PhaseSummary] = []`)。替换为:

```swift
/// When true, every Turn renders collapsed regardless of individual
/// state. Reset to false on session switch (handled in
/// `MessageListView.task(id: windowState.currentSessionId)`).
var collapseAllTurns: Bool = false
```

如果 `phaseSummaries` 字段被多处赋值/读取,grep 全部位置再统一改:

```bash
grep -n "phaseSummaries\|collapseAllPhases" Packages/Sources/ClarcChatKit/ 2>&1 -r
```

期望:本文件内的 `phaseSummaries` 已删,`collapseAllPhases` 字面量不再存在;但其他文件(Task 3 会改)仍有引用,这是预期的。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```

期望:** 编译失败**,错误信息指出 `MessageListView.swift` 等还在引用 `phaseSummaries` / `collapseAllPhases` —— 这是预期的(Task 3 修)。

- [ ] **Step 3: 暂不 commit(等 Task 3 一起)**

确认 Task 2 失败后,把当前文件**保留在工作区**(不 add),进入 Task 3 一起改。

---

## Task 3: 重构 `MessageListView`

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/MessageListView.swift`

- [ ] **Step 1: 删 `chatWithPhases` 函数(line 247-296 附近)**

整段删 `private func chatWithPhases(...)` 函数(包含其下方的 `ForEach` body)。如果函数体里有 `phaseForceCollapse` 环境值注入,一并删。

- [ ] **Step 2: 删 `foldToggleButton(hiddenCount:)` 旧版(line 159 附近)**

只删函数体,**保留函数声明作为锚点**(或者整个删——下面会重建新版本)。

> 注:spec 里 `foldToggleButton` 是 v2.4.3 占位条样式。本任务用更小的 `chevron` 按钮 + TurnBlock 内部渲染,所以整个删旧版,新版不通过独立函数,而是 TurnBlock 自己内联。

- [ ] **Step 3: 替换 body 中"phaseSummaries.isEmpty"分支**

`MessageListView.swift:48` 附近的 body 应改为:

```swift
var body: some View {
    ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let visibleTurns = makeVisibleTurns()
                ForEach(visibleTurns) { turn in
                    TurnBlock(
                        turn: turn,
                        forceCollapsed: chatBridge.collapseAllTurns
                    )
                }
                if isStreaming { streamingTail() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // ... existing .onChange / .onAppear / .task modifiers
    }
}

private func makeVisibleTurns() -> [Turn] {
    let all = Turn.makeTurns(
        from: settledItems,
        isStreamingLast: isStreaming,
        foldThreshold: windowState.foldThreshold
    )
    // Cap to foldThreshold + 100 visible (old phase-fold cap reused).
    let cap = max(0, windowState.foldThreshold) + 100
    if all.count <= cap { return all }
    return Array(all.suffix(cap))
}
```

具体 `ScrollViewReader` / `ScrollView` / `streamingTail()` 实现:从原文件 body 抄,**只替换内部 VStack 内容**。`settledItems` / `isStreaming` 是现有 `@State` / 计算属性,名字可能略有差异,grep 一下原文件确认:

```bash
grep -n "settledItems\|isStreaming" Packages/Sources/ClarcChatKit/MessageListView.swift | head -20
```

- [ ] **Step 4: 加 `TurnBlock` 渲染组件(同文件内,private struct)**

在 `MessageListView.swift` 文件末尾追加:

```swift
private struct TurnBlock: View {
    let turn: Turn
    let forceCollapsed: Bool

    private var isCollapsed: Bool {
        forceCollapsed || turn.isCollapsed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    // mutate via binding — see Step 5 for binding wiring
                    turn.isCollapsed.toggle()
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
                .fill(Color(ClaudeTheme.surface))
        )
    }

    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.collapsedUserText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(turn.collapsedAssistantText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User bubble
            MessageBubble(message: turn.userMessage)
            // Assistant blocks
            ForEach(turn.assistantMessages) { msg in
                MessageBubble(message: msg)
            }
        }
    }
}
```

⚠️ **binding 问题**:`Turn` 是 value type,`turn.isCollapsed.toggle()` 不能直接回写到父 view 的 `turns` 数组。改写为传 binding:

把 `TurnBlock` 签名改为接收 `Binding<Turn>`,并把 toggle 改为:

```swift
private struct TurnBlock: View {
    @Binding var turn: Turn
    let forceCollapsed: Bool

    private var isCollapsed: Bool {
        forceCollapsed || turn.isCollapsed
    }

    var body: some View {
        // ... same as above, but Button body:
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                turn.isCollapsed.toggle()
            }
        } label: { ... }
    }
}
```

调用点:

```swift
ForEach($visibleTurns) { $turn in
    TurnBlock(turn: $turn, forceCollapsed: chatBridge.collapseAllTurns)
}
```

`$visibleTurns` 是 `@State [Turn]` 的 binding,`ForEach` over binding 需要 `Turn` 是 `Identifiable`(已是)+ ForEach on binding 是 SwiftUI 5+ 支持的。

- [ ] **Step 5: 删 phase 相关的环境值注入和 import(如果有)**

```bash
grep -n "phaseForceCollapse\|PhaseSummary\|phaseSummaries" Packages/Sources/ClarcChatKit/MessageListView.swift
```

期望:zero hits(本文件内不再引用)。如果有:`Edit` 删除。

- [ ] **Step 6: Build 验证**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40
```

期望:`** BUILD SUCCEEDED **`。如果有错,常见原因:
- `MessageBubble` 初始化签名不匹配(参数名/类型),检查原 `MessageBubble` 调用点(原代码里应该用 `message: msg` 或类似)
- `ClaudeTheme.surface` 字段名不对,grep `ClaudeTheme.surface` 确认
- `Turn` struct 字段名拼写

- [ ] **Step 7: 启动 app 验证折叠交互**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
open /Users/zhuli/Library/Developer/Xcode/DerivedData/Clarc-*/Build/Products/Debug/Clarc.app
```

(路径里的 `*` 是 xcodebuild 自动生成的 hash 目录;或者用 `xcrun simctl` 等)

启动后:
1. 选个项目,发 user 消息 → 看到 1 个 Turn,默认展开
2. 再发 1 条 → 看到 2 个 Turn,第 1 个折叠、第 2 个展开
3. 点 ▶ 箭头 → 折叠的 Turn 展开,看到 30/50 字省略号消失
4. 点 ▼ → 折叠回去,看到省略号摘要
5. 切到另一个 session → 状态清空
6. 退出

- [ ] **Step 8: Commit**

```bash
git add Packages/Sources/ClarcChatKit/MessageListView.swift Packages/Sources/ClarcChatKit/ChatBridge.swift
git commit -m "refactor(chat): replace phase-fold with per-turn folding

Drop PhaseSummaryCard abstraction in favor of one collapsible block
per user turn. Each TurnBlock carries its own isCollapsed state, a
chevron toggle, and a 30/50-char text preview when collapsed.

When collapsed, the body does not construct MessageBubble subtrees;
only the preview Text views are rendered, so a long history with
many collapsed turns stays cheap.

The ChatBridge.collapseAllTurns flag (replacing collapseAllPhases)
provides a session-level override that resets on session switch.
foldThreshold keeps its meaning (collapse past N turns) but is
applied to turns instead of phases.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: 删 `AppState` 里 phase 维护逻辑

**Files:**
- Modify: `Clarc/App/AppState.swift`

- [ ] **Step 1: 找 phase 维护代码位置**

```bash
grep -n "phaseSummaries\|PhaseSummary" Clarc/App/AppState.swift
```

期望:看到 `state.phaseSummaries.append(summary)`(line 1338 附近)和可能的 `PhaseSummary` struct 引用。

- [ ] **Step 2: 删 `phaseSummaries.append` 调用和附近 phase 维护代码**

定位后,**只删维护逻辑**(append / reset / clear 之类),**不要删其他相邻功能**。如果 `PhaseSummary` struct 本身定义在 `AppState.swift` 内,整段删。如果在另一个文件:

```bash
grep -rn "struct PhaseSummary" Clarc/ Packages/Sources/ 2>&1
```

跟着删掉。

> **范围限定**:本任务只删 phase 抽象的"写入端"。如果 `PhaseSummary` 仅作为 `Codable` 残留(为兼容旧 JSONL),保留类型 + 标 `@available(*, deprecated)`,但本文档选择"JSONDecoder 默认忽略未知字段" → 可以彻底删 `PhaseSummary` 类型,旧 JSONL 的 `phaseSummaries` 字段会被 decoder 直接忽略。

- [ ] **Step 3: 全文 grep 兜底**

```bash
grep -rn "phaseSummaries\|PhaseSummary\|phaseForceCollapse" Clarc/ Packages/Sources/ 2>&1
```

期望:**zero hits**。任何残留都会让后续 build 失败或运行时崩,这里抓干净。

- [ ] **Step 4: Build 验证**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```

期望:`** BUILD SUCCEEDED **`。

- [ ] **Step 5: 启动验证旧 session 仍能加载**

如果有旧 session JSONL(含 `phaseSummaries` 字段):

1. 启动 app → 选历史 session → 验证消息列表正常显示(turn-block 形式)
2. 退出

如果 `JSONDecoder` 真的对未知字段报错(默认不应该,但保险),加 fallback:

```swift
// PersistenceService 里,decode 旧 schema 时:
do {
    return try decoder.decode(SessionFile.self, from: data)
} catch DecodingError.keyNotFound(...) {
    // 旧 schema 缺字段 → 重试,缺失字段给默认值
}
```

但 **先不写** — Task 3 build 通过就证明不抛错。如果启动加载旧 session 崩了,再加。

- [ ] **Step 6: Commit**

```bash
git add Clarc/App/AppState.swift
git commit -m "refactor(chat): drop PhaseSummary maintenance

AppState no longer appends to phaseSummaries as assistant turns
complete. The PhaseSummary struct is removed entirely; legacy
session JSONL with the field is silently ignored by JSONDecoder
(unknown fields are dropped by default).

Turn state is now derived from settledItems in MessageListView
and does not need to be persisted separately.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `ChatView` 工具栏绑定 `collapseAllTurns`

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/ChatView.swift`

- [ ] **Step 1: 找现有工具栏代码**

```bash
grep -n "collapseAllPhases\|foldThreshold\|toolbar" Packages/Sources/ClarcChatKit/ChatView.swift 2>&1
```

期望:看到现有 `ChatView` 顶部的 toolbar / 按钮 HStack,以及 v2.4.3 接的 `chatBridge.collapseAllPhases`。

- [ ] **Step 2: 替换 `collapseAllPhases` → `collapseAllTurns`**

把现有 toolbar 里所有 `chatBridge.collapseAllPhases` 引用改为 `chatBridge.collapseAllTurns`。如果按钮 label 是 hard-coded 英文,改为走 Localizable(下面 Task 6 加 key)。

- [ ] **Step 3: 验证 foldThreshold slider 行为**

现有 slider 绑 `windowState.foldThreshold`,本任务不动 slider,只确认它仍然控制"折叠早期 N 个 turn":

- `foldThreshold = 0` → 所有 turn 默认展开
- `foldThreshold = 3` → 第 4 条及之后 turn 默认折叠
- 切 session → slider 行为不变(WindowState 是 per-window)

启动 app,改 slider,观察 TurnBlock 数量与折叠状态符合预期。

- [ ] **Step 4: Build + 启动**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -10
open /path/to/Clarc.app
```

期望:启动 OK,工具栏"全部折叠"按钮在 toggle 时,所有 TurnBlock 立即收起 / 展开。

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcChatKit/ChatView.swift
git commit -m "refactor(chat): wire toolbar to collapseAllTurns

The chat view toolbar's collapse-all / expand-all button now drives
chatBridge.collapseAllTurns. Behavior is identical to the previous
collapseAllPhases (one-shot UI override, resets on session switch)
but the target of the override is per-turn instead of per-phase.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: 本地化字符串

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/Resources/en.lproj/Localizable.strings`
- Modify: `Packages/Sources/ClarcChatKit/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Packages/Sources/ClarcChatKit/Resources/ko.lproj/Localizable.strings`

- [ ] **Step 1: 在三份 Localizable.strings 加新 key**

先查现有 v2.4.3 用的 key(命名风格):

```bash
grep -i "phase\|collapse" Packages/Sources/ClarcChatKit/Resources/en.lproj/Localizable.strings
```

加新 key,保持命名一致(例:`chat.toolbar.collapseAllTurns`):

**en.lproj**:
```
"chat.toolbar.collapseAllTurns" = "Collapse all turns";
"chat.toolbar.expandAllTurns" = "Expand all turns";
"chat.turn.collapsedAria" = "Turn collapsed";
"chat.turn.expandedAria" = "Turn expanded";
```

**zh-Hans.lproj**:
```
"chat.toolbar.collapseAllTurns" = "折叠所有对话轮次";
"chat.toolbar.expandAllTurns" = "展开所有对话轮次";
"chat.turn.collapsedAria" = "对话轮次已折叠";
"chat.turn.expandedAria" = "对话轮次已展开";
```

**ko.lproj**:
```
"chat.toolbar.collapseAllTurns" = "모든 대화 턴 접기";
"chat.toolbar.expandAllTurns" = "모든 대화 턴 펴기";
"chat.turn.collapsedAria" = "대화 턴 접힘";
"chat.turn.expandedAria" = "대화 턴 펼쳐짐";
```

⚠️ **strings 文件格式**:`"key" = "value";`,**必须有分号结尾**。如果文件使用 `/* */` 注释风格,不要破坏。

- [ ] **Step 2: 把 `Text("...")` 字面量替换为 `Text(LocalizedStringKey(...))` 或 `Text("...", bundle: .module)`**

`TurnBlock` / `ChatView` 里如果有 hard-coded `Text("折叠所有")` 等,改为:

```swift
Text("chat.toolbar.collapseAllTurns", bundle: .module)
```

如果走 SwiftUI 自动 localization,直接 `Text("chat.toolbar.collapseAllTurns")` 即可(只要 Localizable.strings 里有 key,SwiftUI 会查表)。

- [ ] **Step 3: Build + 启动验证**

```bash
xcodebuild ... build 2>&1 | tail -10
open /path/to/Clarc.app
```

切系统语言到 en / zh-Hans / ko 三次(或在 app 设置里),验证 toolbar 文字 / 折叠状态文案随之变化。

- [ ] **Step 4: Commit**

```bash
git add Packages/Sources/ClarcChatKit/Resources/
git commit -m "feat(chat): localize turn-fold toolbar labels

Add new Localizable.strings keys for the collapse-all / expand-all
toolbar button and turn collapse accessibility hints across en,
zh-Hans, and ko bundles.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: 端到端冒烟测试 + 性能验证

**Files:** 无

- [ ] **Step 1: 加载含 50+ turn 的 session**

(可以手动发消息构造,或者找一个历史 session)

启动 app,加载这个 session,验证:
- 早期 turn 默认折叠
- 后期 turn(超过 foldThreshold)折叠
- 当前 in-progress turn 展开
- 全部折叠 / 全部展开 按钮工作
- 滚动不卡顿(目视 60fps 流畅)

- [ ] **Step 2: streaming 期间观察 Turn 派生行为**

发 user 消息,等 assistant streaming,观察:
- Turn 数量稳定(不发新 user 不会开新 turn)
- 新 delta 实时进入 `turns.last.assistantMessages`
- 不卡顿(隐式动画不触发,只是 MessageBubble 内容更新)

- [ ] **Step 3: 容错测试:加载旧 phase 字段的 session**

如果手头没有旧 session,造一个:用 `git stash` 切到 v2.4.3 commit,跑 app 产生 session JSONL,再切回。启动 app 加载它,验证:
- 不崩
- Turn 列表正常显示
- 旧 `phaseSummaries` 字段被忽略

- [ ] **Step 4: 全局 grep 兜底**

```bash
grep -rn "PhaseSummary\|phaseSummaries\|phaseForceCollapse\|chatWithPhases" Clarc/ Packages/Sources/ 2>&1
```

期望:**zero hits**。

- [ ] **Step 5: 准备 release commit**

按 CLAUDE.md 的发版规则,版本号从 v2.4.4 → v2.5.0(删抽象 + 功能替换是小版本):

```bash
# 编辑 version 字段(在 Clarc/Info.plist 或 xcodeproj project.pbxproj)
# 改 CFBundleVersion 和 CFBundleShortVersionString

git add Clarc/Info.plist Clarc.xcodeproj/project.pbxproj
git commit -m "chore(release): v2.5.0 (build 7)

Replace phase-fold with per-turn folding. Drop PhaseSummary
abstraction. See docs/superpowers/specs/2026-06-04-turn-block-folding.md
for the full spec and commit history for per-task changes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git tag v2.5.0
```

---

## Self-Review

1. **Spec coverage**:
   - Turn model + 派生 → Task 1 ✓
   - ChatBridge 字段替换 → Task 2 ✓
   - MessageListView 重构 + TurnBlock → Task 3 ✓
   - AppState phase 维护删 → Task 4 ✓
   - 工具栏绑定 → Task 5 ✓
   - 本地化 → Task 6 ✓
   - 端到端 + 性能 + 容错 → Task 7 ✓

2. **Placeholder scan**:无 TBD。每步有具体代码 + 具体命令 + 期望输出。

3. **Type consistency**:
   - `Turn` 字段(id / userMessage / assistantMessages / isCollapsed / isInProgress)在 Task 1 定义,Task 3 binding 用同一套字段名
   - `ChatBridge.collapseAllTurns` 在 Task 2 定义,Task 5 引用同一字段名
   - `MessageBubble(message:)` 初始化签名:Task 3 调用,需要 grep 原 `MessageBubble` 实际签名匹配(Step 3 注释里有提醒)

4. **依赖关系**:Task 1 独立;Task 2-3 互相依赖(一起 commit);Task 4 依赖 Task 3(否则 phase 维护写入的 `phaseSummaries` 不存在会编译失败);Task 5 依赖 Task 2;Task 6 独立;Task 7 依赖所有。

5. **风险点标注**:
   - `ChatMessage` 字段名差异(Step 1.2 提醒 grep)
   - `MessageBubble` 初始化签名(Step 3.3 提醒 grep)
   - 旧 session JSONL 容错(Step 4.5 提醒先不写,崩了再加)
   - `ClaudeTheme.surface` 字段(Step 3.4 提醒 grep)
