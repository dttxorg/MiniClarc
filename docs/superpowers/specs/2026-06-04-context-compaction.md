# 阶段二 — context compaction（对话摘要压缩）

> **For agentic workers:** REQUIRED SUB-SKILL: 阶段一（turn-block 折叠）已合入 `main`（commit `f296209` plan + `667c8e3` spec）。本 spec 依赖阶段一已建立的 `Turn` model + `settledItems` 派生机制,但不要求先实现完阶段一(可以独立并发实现,最后 merge 整合)。

**Goal:** 给 MiniClarc 加 Codex 风格的 context compaction。手动 `/compact` 命令 + 自动 token 阈值 trigger;走 Claude Code CLI 的 `--system-prompt` 通道做 LLM 摘要;改写 session JSONL 节省后续发给 CLI 的 token;UI 通过内存 snapshot 保留原始全部内容供用户查看。

**Spec:** `docs/superpowers/specs/2026-06-04-context-compaction.md`(本文档)
**Plan:** `docs/superpowers/plans/2026-06-04-context-compaction.md`(写完 spec 后由 writing-plans 技能生成)

---

## Context

### 现状(2026-06-04)

MiniClarc 是 **Claude Code CLI 的图形壳**。它不直接调 LLM API,而是 `spawn subprocess` 把请求丢给 `claude` 命令行,接收 NDJSON 流式输出。

`ClaudeService`(`Clarc/Services/ClaudeService.swift`, 771 行)提供的关键能力:

- `runLocalCommand(_:)` (line 255-264) —— 同步跑 `claude -p <command> --output-format text`,返回 string
- `fetchContextPercentage(sessionId:cwd:)` (line 266-285) —— 已有先例用 `claude -p "/context" --output-format text --resume <sessionId>` 探测当前上下文占用
- `send(streamId:prompt:...)` —— 标准流式对话,写 NDJSON 到 stdin
- CLI flags 包括 `--resume <sessionId>`, `--system-prompt <text>`, `--system-prompt-file <path>`, `--input-format stream-json`, `--output-format stream-json`(可被替换为 `text`)

**关键观察**: Claude Code CLI 的 `/compact` 是**它自己的内建命令**(语义由 Claude Code 团队定义,不是 OpenAI Codex 的 compact.rs)。Codex 的 compact.rs 走 OpenAI 客户端内部 LLM 调用 —— MiniClarc 不直接调 LLM,**只能走 Claude Code CLI 这条路**。

### 问题

MiniClarc 现在**没有** compact 能力。session 越长,发给 CLI 的历史越多,token 消耗越高,直到 Claude Code 内部触发它的 `/compact`(这是 Claude Code 自己的行为,MiniClarc 看不到也控制不了)。

### 解决方案(基于决策汇总)

| 维度 | 决策(来自 brainstorming 阶段) |
|---|---|
| **触发** | 手动 `/compact` 命令 + 自动 token 阈值 trigger |
| **API 通道** | 复用 ClaudeService 发起特殊 CLI 调用 —— `claude -p --resume <sid> --system-prompt <summaryPrompt> --output-format text`,通过 `--system-prompt` 注入 "summarize the conversation above" prompt |
| **Token 计数** | 字符 / 4 估算(零依赖) |
| **UX** | JSONL 改写(精简) + UI 内存 snapshot 保留原始全部内容 |
| **架构** | 单分支顺序实现 —— 阶段二在阶段一(turn-block 折叠)合入后开始 |

---

## Approach

**6 个核心改动**:

### 1. `TokenEstimator` —— 字符/4 估算

```swift
// Packages/Sources/ClarcCore/TokenEstimator.swift
struct TokenEstimator {
    /// Rough estimate: 1 token ≈ 4 characters. Returns 0 for empty.
    static func estimate(_ text: String) -> Int {
        max(0, text.count / 4)
    }

    /// Estimate for a list of messages.
    static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimate($1.text) }
    }
}
```

⚠️ **精确性**: 英文约 4 字符/token;中文 CJK 约 1.5 字符/token(更密);emoji 1 个 = 多个 token。`/4` 估算对英文偏高、中文偏低。**用 1/3 作为保守估计** —— 略微高估比低估好(更早触发 compact,更安全):

```swift
static func estimate(_ text: String) -> Int {
    max(0, text.count / 3)  // 保守估计,略高估
}
```

### 2. `ClaudeService.compactSession(...)` —— 调 CLI 拿摘要

扩展 `ClaudeService`,加:

```swift
/// Run a one-shot compact: ask Claude to summarize the conversation
/// of `sessionId` and return the summary text.
///
/// Implementation: spawn `claude -p --resume <sid> --system-prompt
/// <summaryPrompt> --output-format text --model <model>`, await full
/// stdout, return the text content.
///
/// The summary prompt is a modified version of Codex's compact
/// prompt: "You are performing a CONTEXT CHECKPOINT COMPACTION..."
///
/// - Parameters:
///   - sessionId: existing Claude Code session to summarize
///   - model: which Claude model to use for the summary (typically
///     haiku for speed/cost)
///   - cwd: working directory of the session
func compactSession(
    sessionId: String,
    model: String,
    cwd: String
) async throws -> String
```

实现路径:

```swift
let summaryPrompt = """
You are performing a CONTEXT CHECKPOINT COMPACTION for an existing \
Claude Code session. Produce a handoff summary that another LLM \
can use to resume the task.

Include:
1. Current progress and key decisions made.
2. Important context, constraints, and user preferences.
3. What remains to be done.
4. Any critical data, file paths, or tool outputs needed to continue.

Be concise. The summary will replace the conversation history.
"""

let args = [
    "-p",
    "Summarize the conversation above this point.",
    "--resume", sessionId,
    "--system-prompt", summaryPrompt,
    "--output-format", "text",
    "--model", model
]
let output = try await runShellCommand(binary, arguments: args)
return output.trimmingCharacters(in: .whitespacesAndNewlines)
```

⚠️ **Open question 需实现时验证**:
- `claude -p` + `--system-prompt` + `--resume` 三者能否同时使用?
- `-p` 模式下 `--resume` 是否被忽略?
- 如果组合不允许,fallback 方案:把 "summarize" 文本作为 user 消息写 stdin(用 `--input-format stream-json` 模式),不走 `-p`

实现 Task 2 时**第一步**先手动跑 `claude -p --system-prompt "..." --resume <id> --output-format text` 验证可用性。如果不可用,改走 stdin 注入。

### 3. `CompactService` —— 编排 compact 流程

```swift
// Clarc/Services/CompactService.swift
@MainActor
final class CompactService {
    private let claude: ClaudeService
    private let persistence: PersistenceService
    private let session: SessionState

    /// Run a full compact cycle:
    /// 1. Take a snapshot of the current ChatMessage list (for UI)
    /// 2. Build the message list to send to CLI (full history)
    /// 3. Call `claude.compactSession(...)` and get summary text
    /// 4. Build the new "compacted" history: [initialContext] + [recent user msgs] + [summary]
    /// 5. Persist the new history to JSONL
    /// 6. Update `session.settledItems` to the new history
    /// 7. Store the snapshot + summary in `session.compactionRecord`
    func run() async throws -> CompactionRecord
}

struct CompactionRecord: Codable, Equatable {
    let compactedAt: Date
    let summaryText: String
    /// Original ChatMessage list snapshot for UI display.
    let originalMessages: [ChatMessage]
    /// How many messages were in the original history.
    let originalCount: Int
    /// Estimated token count of the original history.
    let originalTokenEstimate: Int
    /// Estimated token count of the new compacted history.
    let newTokenEstimate: Int
}
```

**Token 阈值常量**:
```swift
static let recentUserTokenBudget = 20_000  // Codex 的 20k token 阈值
static let summaryPrefix = """
Another language model started to solve this problem and produced \
a summary of the conversation so far. The summary is provided \
below; please continue from where it left off.

"""
```

**构造新历史的规则**:
1. 找出 `originalMessages` 里所有 user 消息(按时间倒序累加 token,直到超过 20k)
2. 把这些 user 消息从原历史剥离出来
3. 构造新历史:
   ```
   [
     initialContextMessage,        // 来自 session 的初始 context
     ...recentUserMessages,         // token 预算内的最近 user 消息
     summaryMessage                 // role=assistant, content=summaryPrefix + summaryText
   ]
   ```

### 4. `SessionState.compactionRecord` + `SessionState.settledItems` 行为

`SessionState` 加字段:

```swift
/// Non-nil after a compact has been performed. The UI uses this
/// to show the original messages, while the CLI sees the
/// compacted history.
var compactionRecord: CompactionRecord?

/// Mirror of `originalMessages` from the most recent compact.
/// `settledItems` itself is replaced with the compacted list, so
/// `MessageListView` shows the original messages by reading this
/// snapshot when it's non-nil, instead of `settledItems` directly.
```

⚠️ **UI 渲染策略**:
- `settledItems` 改为存储**精简后**的历史
- 如果 `compactionRecord != nil`,`MessageListView` 渲染 `compactionRecord.originalMessages`(显示完整原始内容给用户)
- 在原始消息列表**之前**插入一个特殊"compact banner" 卡片:"[Context compacted at 14:32, N→M tokens, summary]" 折叠可查看摘要

### 5. `/compact` slash 命令

`SlashCommandManagerView` / `SlashCommandBar` 加新条目:

```swift
SlashCommand(
    name: "compact",
    aliases: ["/compact"],
    description: "Compact the current session context",
    handler: { appState in
        Task { @MainActor in
            do {
                try await appState.compactService.run()
            } catch {
                appState.showError(error)
            }
        }
    }
)
```

UI 表现:在工具栏加一个 "Compact" 按钮(在 `/compact` slash 之外),快速入口。

### 6. 自动 token 阈值 trigger

`WindowState` 加字段:

```swift
/// Auto-compact when total estimated tokens of `settledItems` exceeds
/// this value. 0 = disabled. Default 100_000 (Codex default).
var autoCompactThreshold: Int = 100_000
```

`MessageListView` 在 `.onChange(of: settledItems.count)` 内增加检测:

```swift
.onChange(of: settledItems.count) { _, _ in
    rebuildTurns()
    let estimate = TokenEstimator.estimate(settledItems)
    if windowState.autoCompactThreshold > 0
        && estimate > windowState.autoCompactThreshold
        && !isCompactingInProgress
        && !chatBridge.isStreaming
    {
        Task { @MainActor in
            await appState.compactService.run()  // silent auto-compact
        }
    }
}
```

`!isStreaming` 触发条件避免在 streaming 中打断用户。

`isCompactingInProgress` 状态:让状态栏 / toolbar 显示 "Compacting..." 提示,避免重复触发。

---

## Critical Files

| 文件 | Action | 责任 |
|---|---|---|
| `Packages/Sources/ClarcCore/TokenEstimator.swift` | **New** | `TokenEstimator` struct + 字符/3 估算 |
| `Packages/Sources/ClarcCore/CompactionRecord.swift` | **New** | `CompactionRecord` struct(Codable) + 阈值常量 |
| `Clarc/Services/ClaudeService.swift` | Modify | 加 `compactSession(sessionId:model:cwd:) async throws -> String` |
| `Clarc/Services/CompactService.swift` | **New** | `CompactService` actor 编排 compact 流程 |
| `Clarc/App/AppState.swift` | Modify | 加 `compactService: CompactService` 字段 + `runCompact()` 入口 + `isCompactingInProgress: Bool` |
| `Clarc/App/WindowState.swift` | Modify | 加 `autoCompactThreshold: Int` + UserDefaults 持久化 |
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | Modify | 加 compact banner 卡片 + 自动 trigger 检测;`settledItems` 渲染逻辑改为优先读 `compactionRecord.originalMessages` |
| `Packages/Sources/ClarcChatKit/ChatView.swift` | Modify | 工具栏加 "Compact" 按钮 |
| `Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift` | Modify | 注册 `/compact` slash command |
| `Packages/Sources/ClarcChatKit/Resources/*.lproj/Localizable.strings` | Modify | 加 "Compact", "Compacting...", "Show summary" 等键 |

**Out of scope**(不实现):
- 调 Anthropic API 直接做摘要(已决策:走 CLI `--system-prompt`)
- 多 session 跨 session 共享 summary
- 用户可配置 summary prompt 文本(写死 Codex 同款)

---

## Detailed Design

### `TokenEstimator`(已确定,见 Approach 1)

```swift
public struct TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        max(0, text.count / 3)
    }

    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimate($1.text) }
    }
}
```

放在 `ClarcCore` 而非 `ClarcChatKit`,因为它是纯 logic(无 UI 依赖)+ ClarcCore 有 testTarget → **可以走 TDD 路径**。

### `CompactionRecord`(已确定,见 Approach 4)

```swift
public struct CompactionRecord: Codable, Equatable, Sendable {
    public let compactedAt: Date
    public let summaryText: String
    public let originalMessages: [ChatMessage]
    public let originalCount: Int
    public let originalTokenEstimate: Int
    public let newTokenEstimate: Int
}
```

`Sendable` 因为会跨 actor 传递(`CompactService` 走 actor,渲染在 MainActor)。

### `ClaudeService.compactSession`

⚠️ **实现前必做**:手动跑命令验证 `claude -p --system-prompt ... --resume <sid>` 可用:

```bash
# 找一个现有 session id(从 ~/Library/Application Support/Clarc/sessions/ 找)
claude -p "Summarize the conversation above." \
  --resume <sid> \
  --system-prompt "You are performing a CONTEXT CHECKPOINT COMPACTION. ..." \
  --output-format text \
  --model haiku
```

如果 `--resume` + `-p` 不兼容(常见:-p 是 print mode,可能忽略 resume),fallback:

```bash
# 用 --input-format stream-json 把 prompt 写 stdin
claude --resume <sid> \
  --system-prompt "..." \
  --output-format text \
  --input-format stream-json \
  --verbose
# 然后写 stdin: {"type":"user","message":{"role":"user","content":"Summarize..."}}
```

实现时**优先用 `-p` 模式**(最简单),跑不通再降级。

### `CompactService.run` 主流程

```swift
@MainActor
final class CompactService {
    private let appState: AppState
    private var inFlight: Task<CompactionRecord, Error>?

    var isCompacting: Bool { inFlight != nil }

    func run() async throws -> CompactionRecord {
        // Reuse in-flight if already running
        if let existing = inFlight { return try await existing.value }

        let task = Task<CompactionRecord, Error> { [weak appState] in
            guard let appState else { throw CompactError.cancelled }

            // 1. Snapshot original messages
            let original = await appState.sessionStates[appState.windowState.currentSessionId]?.settledItems ?? []
            guard original.count >= 2 else {
                throw CompactError.tooShort  // 不压缩 < 2 条消息
            }

            // 2. Find recent user messages within 20k token budget
            var recent: [ChatMessage] = []
            var budget = 20_000
            for msg in original.reversed() where msg.role == .user {
                let cost = TokenEstimator.estimate(msg.text)
                if budget - cost < 0 { break }
                recent.insert(msg, at: 0)
                budget -= cost
            }

            // 3. Build initial context (first system-like message if any)
            let initialContext = original.first(where: { $0.role == .system }) ?? ChatMessage.emptySystem()

            // 4. Get session id + cwd
            guard let sessionId = await appState.currentSessionIdString() else {
                throw CompactError.noSession
            }
            let cwd = await appState.currentProjectCwd()

            // 5. Call CLI
            let summary = try await appState.claude.compactSession(
                sessionId: sessionId,
                model: "haiku",
                cwd: cwd
            )

            // 6. Build new history
            let summaryMessage = ChatMessage(
                id: UUID(),
                role: .assistant,
                text: CompactionRecord.summaryPrefix + summary,
                timestamp: Date(),
                isCompactionSummary: true
            )
            let newHistory: [ChatMessage] = [initialContext] + recent + [summaryMessage]

            // 7. Persist + update state
            let record = CompactionRecord(
                compactedAt: Date(),
                summaryText: summary,
                originalMessages: original,
                originalCount: original.count,
                originalTokenEstimate: TokenEstimator.estimate(original),
                newTokenEstimate: TokenEstimator.estimate(newHistory)
            )

            await appState.applyCompaction(record, newHistory: newHistory)

            return record
        }

        inFlight = task
        defer { inFlight = nil }
        return try await task.value
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
```

### `AppState.applyCompaction`

```swift
@MainActor
extension AppState {
    func applyCompaction(_ record: CompactionRecord, newHistory: [ChatMessage]) {
        guard let sid = windowState.currentSessionId,
              let session = sessionStates[sid] else { return }
        session.settledItems = newHistory
        session.compactionRecord = record
        // 持久化
        persistenceService.saveSession(session, id: sid)
    }
}
```

### `MessageListView` 渲染逻辑调整

```swift
private var displayItems: [ChatMessage] {
    // 优先用 snapshot(如果 compact 过)
    if let snapshot = appState.sessionStates[windowState.currentSessionId]?.compactionRecord?.originalMessages {
        return snapshot
    }
    return settledItems
}
```

**Compact banner**: 在 `displayItems` 之前插入一个特殊卡片:

```swift
if let record = session.compactionRecord {
    CompactBanner(record: record)
}

private struct CompactBanner: View {
    let record: CompactionRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Context compacted at \(record.compactedAt.formatted(date: .omitted, time: .shortened))")
                Spacer()
                Text("\(record.originalCount) → \(TokenEstimator.estimate(record.originalMessages) - record.newTokenEstimate) tokens saved")
                    .foregroundStyle(.tertiary)
                Button(isExpanded ? "Hide summary" : "Show summary") {
                    isExpanded.toggle()
                }
            }
            if isExpanded {
                Text(record.summaryText)
                    .padding(8)
                    .background(Color.surface)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface.opacity(0.5)))
    }
}
```

### `/compact` slash command

加到现有 `SlashCommandManagerView` 注册表(具体位置 grep):

```bash
grep -n "SlashCommand(" Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift
```

注册:

```swift
SlashCommand(
    name: "compact",
    description: "Compact context for the current session",
    handler: { @MainActor in
        do {
            _ = try await appState.compactService.run()
        } catch {
            appState.showError(error)
        }
    }
)
```

### 自动 trigger

`MessageListView` 内的检测(见 Approach 6)。**注意**: streaming 期间**不**触发(避免冲突);多个并发 trigger 由 `inFlight` 锁去重。

---

## Risk

| 风险 | 等级 | 缓解 |
|---|---|---|
| `claude -p --system-prompt --resume` 不兼容 | 高 | 手动验证;不可用时降级到 stdin 注入(`--input-format stream-json`) |
| 摘要质量差(模型拒绝 / 输出格式乱) | 中 | 用 haiku 便宜模型;失败重试 1 次;失败抛错给用户而不是静默 |
| compact 中途 session 切换 → 状态错乱 | 中 | `inFlight` 用 session id 隔离;切换时 cancel 旧 task |
| 自动 trigger 在 streaming 中触发 → 状态损坏 | 高 | `!isStreaming` 守卫;`isCompactingInProgress` 去重 |
| JSONL 改写后原始消息丢失 | 中 | compactionRecord.originalMessages 留 snapshot 在内存 + 写入 session JSONL 的 `compactionRecord` 字段(下次启动可恢复 UI) |
| 字符/3 估算对中文/代码不准 | 中 | 文档化限制;后续可换 Anthropic count_tokens API(本次不做) |
| Summary prompt 注入后,Claude Code 自己的 `/compact` 行为冲突 | 中 | 用 `-p` + 自定义 prompt 走单次调用,不走 interactive mode;CLI 不会触发内建 `/compact` |
| 摘要文本超长(> 10k token) | 低 | 不限制(摘要本身就是要替代长历史的) |
| `compactionRecord.originalMessages` 内存占用大 | 低 | 仅在内存,UI 折叠时不展开(性能 OK);不写到 NSUserDefaults |
| `CompactService` actor 隔离 + `AppState` 是 MainActor 的交互 | 中 | `CompactService` 也标 `@MainActor`,避免跨 actor 状态错乱 |
| 手动 `/compact` 期间用户又发新消息 | 中 | streaming 检测 + `inFlight` 锁;用户消息排队等 compact 完成后处理 |

---

## Verification

1. **TokenEstimator 单测**(在 `Packages/Tests/ClarcCoreTests/TokenEstimatorTests.swift`):
   - `estimate("hello")` → 1 (5 chars / 3 = 1)
   - `estimate("")` → 0
   - `estimate(longString)` → 正确
2. **Build**:
   ```bash
   xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
   ```
3. **手动验证 CLI 命令可用**:在 terminal 跑 `claude -p --system-prompt ... --resume <sid> --output-format text` —— 确认返回 summary 文本
4. **手动 trigger** `/compact`:发 10 条消息 → 工具栏 / slash `/compact` → 看到 banner + 消息列表保持显示 + JSONL 改写
5. **自动 trigger**:在 Settings 把 `autoCompactThreshold` 调到 100 → 发够多消息(估算 > 100 token) → 自动 compact 触发,状态栏显示 "Compacting..."
6. **容错**:
   - 摘要失败 → 抛错,`inFlight` 清空,UI 显示 toast
   - session 太短(< 2 条) → "对话太短,无需压缩"
   - streaming 中触发 → 不响应
7. **JSONL 持久化**:compact 后退出 app → 重启 → 看到 banner + 原始消息(从 JSONL 的 `compactionRecord.originalMessages` 恢复)
8. **end-to-end**:完成 v2.5.0(v2.5.1?)的 release

---

## Self-Review

1. **Spec coverage**:
   - 手动 `/compact` → Approach 5 ✓
   - 自动 token 阈值 → Approach 6 ✓
   - CLI `--system-prompt` 通道 → Approach 2 ✓
   - 字符/3 估算 → Approach 1 ✓
   - JSONL 改写 → Approach 3 + 4 ✓
   - UI snapshot → Approach 4 ✓
   - summary prefix → Approach 3 ✓

2. **Placeholder scan**: 无 TBD/TODO。CLI 命令组合兼容性是 **Open question 需实现时验证**,在 Approach 2 + Risk 表都标了。

3. **Internal consistency**:
   - `CompactionRecord` 字段在 Approach 4 定义,Plan / Risk / Verification 引用一致
   - `TokenEstimator.estimate(_:)` 签名在 Approach 1 + Verification 一致
   - `CompactService.run()` 抛错类型在 Approach 3 + Risk 表一致

4. **Scope check**: 单个 PR 内可独立完成。6 个核心改动涉及 10 个文件,但每个文件改动面不大(主要是新加 method / 字段)。Diff 估计 600-900 行。

5. **Ambiguity check**:
   - "autoCompactThreshold = 0" → 明确"禁用"
   - "20k token 预算" → 来自 Codex 决策,改 `CompactionRecord.recentUserTokenBudget` 常量
   - "summaryPrefix 拼接位置" → 明确"在 summary message 文本前,作为 prefix"
   - "summary model" → 明确"haiku"(便宜快速)
   - "streaming 中触发" → 明确"!isStreaming 守卫,isCompactingInProgress 去重"
