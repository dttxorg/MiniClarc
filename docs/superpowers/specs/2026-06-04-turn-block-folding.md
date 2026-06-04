# 阶段一 — turn-block 折叠（替换 phase fold）

> **For agentic workers:** REQUIRED SUB-KILL: 阶段二（context compaction）独立成 spec / 计划 / PR；本 spec 不涉及 token 计数、`/compact`、自动 trigger。

**Goal:** 用"按 user 起头配对 assistant 块"的可折叠 Turn 替换 v2.4.3 的 `PhaseSummaryCard` 抽象。每对 user+assistant 包成 `TurnBlock`；▶/▼ 切换；历史默认折叠、当前进行中默认展开；工具栏"全部折叠 / 全部展开"按钮。**纯 UI 改动,不发到 CLI 任何东西。**

**Spec:** `docs/superpowers/specs/2026-06-04-turn-block-folding.md`(本文档)
**Plan:** `docs/superpowers/plans/2026-06-04-turn-block-folding.md`(写完 spec 后由 writing-plans 技能生成)

---

## Context

### 现状(2026-06-04)

v2.4.3 (build 5) / v2.4.4 (build 6) 上了 `PhaseSummaryCard` + `phaseSummaries` 抽象:

- `Packages/Sources/ClarcChatKit/MessageListView.swift:48` 始终走 phase 路径(只要有 ≥1 个完成的 assistant 回合,`chatBridge.phaseSummaries` 就不为空)
- `chatWithPhases` 接收 `visibleRange: Range<Int>`、`forceCollapse: Bool`,内部按 phase 卡片为单位渲染
- `ChatBridge.collapseAllPhases` 一键全折叠临时覆盖
- `WindowState.foldThreshold` 控制"折叠早期 N 个 phase"
- 超过 100 phase 时按 `visibleRange` 截断,渲染占位条"+ 展开 8 个"
- `AppState.swift:1338` `state.phaseSummaries.append(summary)` 总会跑,phase 摘要逻辑是产品语义的一部分

### 为什么替换

Phase 摘要设计意图:把长对话分成"阶段"标签,每阶段一张可折叠卡片。

实际用户感受:
- 折叠按钮被 phase 抽象吞了,想"按 turn 折"的用户找不到入口
- 阶段标签信息密度低,大部分对话没有"分阶段"语义
- v2.4.3 修复本身治标不治本 — 用户真正想要的是"每轮对话可以独立折叠,文字预览,带箭头"

### 为什么不用并存

并存(PhaseSummaryCard 内嵌 Turn)需要维护两套折叠状态、两套 UI 组件,改动面更大、状态同步更脆弱。替换删抽象、单一数据源、单一渲染路径,改动总量更小。

---

## Approach

**3 个核心改动**:

### 1. 新 `Turn` 数据模型

```swift
// 新文件:Packages/Sources/ClarcChatKit/Turn.swift
struct Turn: Identifiable, Equatable {
    let id: UUID                       // = user message id(或合成 UUID for orphan)
    let userMessage: ChatMessage       // 第一个 user 块(可能为 placeholder)
    var assistantMessages: [ChatMessage] // 跟随的 assistant / tool_result / thinking
    var isCollapsed: Bool              // UI 状态
    var isInProgress: Bool             // 最后一个 assistant 块还在 streaming
}
```

构造规则:扫描 `settledItems`,遇到 user 消息就开新 Turn;user 之后的 assistant / tool_result / thinking 并入同 Turn 直到下一个 user;首条 assistant 起头(orphan)放进虚拟 Turn(`id = UUID()`,`userMessage` 用占位空 content message)。

### 2. MessageListView 重构

```swift
@State private var turns: [Turn] = []       // 从 settledItems 派生
@State private var collapseAll: Bool = false  // 全局临时覆盖

ForEach(turns) { turn in
    TurnBlock(turn: turn, forceCollapsed: collapseAll) { /* toggle handler */ }
}
```

**TurnBlock 内部**(伪代码):

```
HStack(alignment: .top) {
    Button { turn.isCollapsed.toggle() } label: {
        Image(systemName: turn.isCollapsed ? "▶" : "▼")
    }.buttonStyle(.plain).frame(width: 16)
    
    VStack(alignment: .leading) {
        if turn.isCollapsed {
            // 折叠:user 前 30 字 + assistant 前 50 字(加省略号)
            Text(turn.userMessage.text.prefix(30) + "…")
                .foregroundStyle(.tertiary)
            Text(turn.assistantMessages.last?.text.prefix(50) + "…")
                .foregroundStyle(.secondary)
        } else {
            // 展开:完整 MessageBubble(s)
            ForEach(turn.assistantMessages) { MessageBubble(msg: $0) }
        }
    }
}
.frame(maxHeight: turn.isCollapsed ? 60 : .infinity)
.animation(.easeInOut(duration: 0.18), value: turn.isCollapsed)
```

**性能考量**:折叠状态时**不构建子 view tree**(只渲染摘要 Text),展开后才构建 `MessageBubble`。这样大量 turn 折叠时不会因为隐藏内容付出渲染代价。

### 3. 状态管理

| 状态 | 位置 | 说明 |
|---|---|---|
| `turns: [Turn]` | `MessageListView @State` | 派生自 `settledItems`(在 `.onChange(of: settledItems.count)` 重建) |
| `collapseAll: Bool` | `ChatBridge` | 切 session 时 `.task(id: sessionId)` 内 reset = false |
| `foldThreshold: Int` | `WindowState`(不变) | 阈值;超过 N 条历史的 Turn `isCollapsed = true`(首屏之外的) |
| 首条 / 进行中 turn | 派生 | `turns.last?.isInProgress == true` → 不折叠 |

streaming 期间不重建 `turns` 数组,只更新 `turns.last?.isInProgress` 标记(避免每次 delta 触发整列表重渲染)。

---

## Critical Files

| 文件 | Action | 责任 |
|---|---|---|
| `Packages/Sources/ClarcChatKit/Turn.swift` | **New** | `Turn` struct + 派生 helper |
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | Rewrite | 删 `chatWithPhases` / phase 路径 / `foldToggleButton` 旧版;加 Turn 列表 + `TurnBlock` + 派生 logic |
| `Packages/Sources/ClarcChatKit/ChatBridge.swift` | Modify | 删 `phaseSummaries` / `collapseAllPhases`;加 `collapseAllTurns` |
| `Packages/Sources/ClarcChatKit/ChatView.swift` | Modify | 工具栏按钮绑 `collapseAllTurns` + foldThreshold slider |
| `Clarc/App/AppState.swift` | Modify | 删 `state.phaseSummaries.append(summary)` 附近 phase 维护;`PhaseSummary` JSONL 字段保持可读但忽略(容错解码) |
| `Packages/Sources/ClarcChatKit/Resources/*.lproj/Localizable.strings` | Modify | 加 "全部折叠" / "全部展开" / "折叠较早消息" 等新键 |

**Out of scope**(阶段二处理):
- Token 估算(`TokenEstimator`)
- `/compact` slash command
- 自动 token 阈值 trigger
- JSONL 改写
- `CompactService` / `ClaudeService` 特殊 prompt 通道
- `summaryPrefix` 字面量使用

**保留**:
- `WindowState.foldThreshold`(改语义:从"折叠早期 N 个 phase"改为"折叠早期 N 个 turn")
- `MessageBubble` 内部 phase 相关环境值:如果 grep 出来有引用,要么删要么注入替代(留待实现期决定)

---

## Detailed Design

### 派生 Turn 列表

```swift
// MessageListView body 内
private func rebuildTurns(from items: [ChatMessage], threshold: Int) -> [Turn] {
    var turns: [Turn] = []
    var current: Turn? = nil
    
    for msg in items {
        switch msg.role {
        case .user:
            if let c = current { turns.append(c) }
            current = Turn(
                id: msg.id,
                userMessage: msg,
                assistantMessages: [],
                isCollapsed: turns.count >= threshold,  // 历史折叠
                isInProgress: false
            )
        case .assistant, .toolResult, .thinking:
            if current == nil {
                // orphan assistant 起头 → 虚拟 Turn
                let placeholder = ChatMessage.placeholder()
                current = Turn(
                    id: UUID(),
                    userMessage: placeholder,
                    assistantMessages: [msg],
                    isCollapsed: false,
                    isInProgress: msg.isStreaming
                )
            } else {
                current?.assistantMessages.append(msg)
                if msg.isStreaming { current?.isInProgress = true }
            }
        }
    }
    if let c = current { turns.append(c) }
    
    // 最后一条 turn(进行中)强制展开
    if var last = turns.last, last.isInProgress {
        last.isCollapsed = false
        turns[turns.count - 1] = last
    }
    
    return turns
}
```

### streaming 期间不重建

```swift
.onChange(of: settledItems.count) { _, _ in
    turns = rebuildTurns(from: settledItems, threshold: windowState.foldThreshold)
}

// 单独的轻量更新:streaming delta 时只改 isInProgress 标记
.onChange(of: chatBridge.isStreaming) { _, streaming in
    if var last = turns.last {
        last.isInProgress = streaming
        turns[turns.count - 1] = last
    }
}
```

### 折叠按钮:30/50 字省略号

```swift
private func previewText(for text: String, max: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= max { return trimmed }
    return String(trimmed.prefix(max)) + "…"
}
```

`prefix(_:)` 默认按 Character(对中文/emoji 安全)。如果你想按字节 — 改成 `String(trimmed.prefix(max))` 对 ASCII 仍可接受,不做特殊处理。

### 工具栏(ChatView 顶部)

```swift
HStack(spacing: 8) {
    Button(collapseAllTurns ? "全部展开" : "全部折叠") {
        chatBridge.collapseAllTurns.toggle()
    }
    
    // foldThreshold slider(沿用 WindowState.foldThreshold)
    Slider(value: ..., in: 0...50, step: 1)
    Text("折叠较早: \(windowState.foldThreshold)")
}
```

`foldThreshold = 0` 表示"全部展开"(不折叠任何 turn)。

### 容错解码旧 JSONL

旧 session 文件里可能有 `phaseSummaries` 字段。在 `PersistenceService` decode 时:

```swift
// 忽略未知字段(不抛错)
let decoder = JSONDecoder()
decoder.usesDiscriminatorForTypeLookup = true  // Swift 5.5+ 默认行为
// PhaseSummary 类型如果还有保留 struct(为了不破坏 decode),加 @available(*, deprecated)
```

策略:在 `ChatMessage` / `SessionFile` 的 `Codable` 扩展里不写 `phaseSummaries` 字段,decoder 忽略未声明字段即可。如果 `PhaseSummary` 类型完全删,decoder 不会读到 → 无需额外工作。

---

## Risk

| 风险 | 等级 | 缓解 |
|---|---|---|
| 删 phase 后现有 session JSONL 含 phase 元数据 → decode 失败 | 中 | `JSONDecoder` 默认忽略未知字段,无需迁移 schema;如果 decode 真的失败,降级为"无摘要" |
| 用户既有记忆里"phase 卡片"视觉消失 | 中 | commit message / release notes 显式说明:"phase fold 替换为 turn-block 折叠,每对 user+assistant 独立可折叠" |
| `Turn` 派生从 settledItems 重建:每次 streaming delta 都重算 → 性能回退 | 中 | 只在 `.onChange(of: settledItems.count)` 重算,streaming delta 用 `chatBridge.isStreaming` 单独更新最后一条 turn 的 `isInProgress` |
| 折叠时高度跳变(隐式动画可能在大量 turn 时掉帧) | 中 | 限制 turn 渲染数 = foldThreshold + 100 cap(沿用 v2.4.3 思路);折叠时不构建子树,只渲染摘要 Text |
| `MessageBubble` 内部对 phase 环境值(`\.phaseForceCollapse`)有依赖 | 中 | grep 一下;如果有,要么注入替代环境值要么删;编译失败会逼出位置 |
| `AppState.swift:1338` 附近 phase 维护逻辑删不干净 | 低 | grep `phaseSummaries` / `PhaseSummary` 全文,确保 zero hit(编译失败兜底) |
| `foldThreshold` 语义改变(从"phase"改"turn")让现有用户的 settings 行为变 | 中 | 实际效果一致(都是"折叠早期 N 条"),数量级相近;不破坏 API,只改注释 |
| 大量 turn 时(>100)仍可能卡 | 中 | 复用 v2.4.3 的虚拟化 cap:`visibleEnd = min(threshold + 100, total)` |

---

## Verification

1. `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`
2. 启动 → 新 session → 发 1 条 user 消息 → 1 turn 出现,默认展开 ✓
3. assistant 还在 streaming 时 → turn 默认展开,新 delta 实时进入 `assistantMessages` ✓
4. streaming 完成 → 发第 2 条 user 消息 → 第 1 条 turn 自动折叠(foldThreshold 触发),第 2 条展开 ✓
5. 折叠态显示 30/50 字省略号 + ▶ 箭头 ✓
6. 点 ▶ → 展开 + 完整 MessageBubble + 动画过渡 ✓
7. 工具栏"全部折叠" → 所有 turn 收起 ✓
8. 工具栏"全部展开" → 所有 turn 展开 ✓
9. 切 session → `collapseAllTurns` reset = false ✓
10. 加载含旧 phase 字段的 session JSONL → 解码不崩,显示为无 phase 元数据的 turn 列表 ✓
11. streaming 期间 delta 频繁到达 → 不卡顿(grep `MessageListView` 渲染 trace)✓
12. 端到端启动测试 + 上传 GitHub release,版本号 2.5.0(因为是功能替换 + 删抽象,小版本递增)

---

## Self-Review

1. **Spec coverage**: turn-block 折叠 ✓ / ▶/▼ 箭头 ✓ / 30/50 字省略号 ✓ / 默认折叠规则 ✓ / 工具栏按钮 ✓
2. **Placeholder scan**: 无 TBD/TODO
3. **Internal consistency**: Turn 派生规则(用户起头 / orphan 虚拟 Turn / 进行中不折叠)统一;状态管理三处(turns / collapseAll / foldThreshold)职责分明
4. **Scope check**: 单文件改动 5 个 + 新文件 1 个,控制在 400-600 行 diff(纯 UI + 删抽象)
5. **Ambiguity check**:
   - "orphan assistant 起头" → 明确"虚拟 Turn 占位"
   - "30/50 字" → 明确按 Character 算(中文/emoji 安全)
   - "foldThreshold 语义" → 明确"从 phase 改为 turn,数量级一致"
   - "进行中 turn" → 明确"turns.last?.isInProgress == true → 强制展开"
