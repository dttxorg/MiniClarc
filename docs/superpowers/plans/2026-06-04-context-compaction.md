# context compaction — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **本 plan 涉及部分有 test target (ClarcCore),可走 TDD;UI 改动走 build + 启动验证。**

**Goal:** 给 MiniClarc 加 Codex 风格的 context compaction。手动 `/compact` + 自动 token 阈值 trigger;走 `claude -p --system-prompt --resume` 通道做 LLM 摘要;改写 session JSONL;UI 通过内存 snapshot 保留原始内容。

**Architecture:**
- `TokenEstimator`(ClarcCore,纯 logic,可 TDD)
- `ClaudeService.compactSession()`(扩展现有 service,新增 method)
- `CompactService`(新,@MainActor,编排)
- `SessionState.compactionRecord`(新字段)
- `MessageListView` 加 compact banner + 渲染策略调整
- `/compact` slash command + 工具栏按钮
- 自动 token 阈值 trigger

**Tech Stack:** SwiftUI 5+ `@Observable` `@MainActor`;Swift Testing 风格 XCTest(沿用 ClarcCoreTests 风格);`JSONDecoder` 默认容错;`Process` 子进程(`runShellCommand` 已有 helper)。

---

## File Structure

| 文件 | Action | 责任 |
|---|---|---|
| `Packages/Sources/ClarcCore/TokenEstimator.swift` | **New** | 字符/3 估算 |
| `Packages/Sources/ClarcCore/CompactionRecord.swift` | **New** | `CompactionRecord` struct + 阈值常量 + summary prefix |
| `Packages/Tests/ClarcCoreTests/TokenEstimatorTests.swift` | **New** | 单元测试 |
| `Packages/Tests/ClarcCoreTests/CompactionRecordTests.swift` | **New** | 单元测试 |
| `Clarc/Services/ClaudeService.swift` | Modify | 加 `compactSession(sessionId:model:cwd:)` |
| `Clarc/Services/CompactService.swift` | **New** | 编排 actor |
| `Clarc/App/AppState.swift` | Modify | `compactService` 字段 + `runCompact()` + `applyCompaction()` |
| `Clarc/App/WindowState.swift` | Modify | `autoCompactThreshold: Int` 持久化 |
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | Modify | compact banner + 渲染策略 + 自动 trigger 检测 |
| `Packages/Sources/ClarcChatKit/ChatView.swift` | Modify | 工具栏 "Compact" 按钮 |
| `Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift` | Modify | 注册 `/compact` |
| `Packages/Sources/ClarcChatKit/Resources/*.lproj/Localizable.strings` | Modify | 新键 |

---

## Task 1: `TokenEstimator` + TDD

**Files:**
- Create: `Packages/Sources/ClarcCore/TokenEstimator.swift`
- Create: `Packages/Tests/ClarcCoreTests/TokenEstimatorTests.swift`

- [ ] **Step 1: 写失败测试**

写入 `Packages/Tests/ClarcCoreTests/TokenEstimatorTests.swift`:

```swift
import XCTest
@testable import ClarcCore

final class TokenEstimatorTests: XCTestCase {
    func testEmptyStringReturnsZero() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func testShortStringRoundsDown() {
        // 5 chars / 3 = 1
        XCTAssertEqual(TokenEstimator.estimate("hello"), 1)
    }

    func testTwelveCharsReturnsFour() {
        // 12 / 3 = 4
        XCTAssertEqual(TokenEstimator.estimate("hello world!"), 4)
    }

    func testEstimateMessageListSumsAllTexts() {
        let messages = [
            ChatMessage(id: UUID(), role: .user, text: "hello", timestamp: Date()),
            ChatMessage(id: UUID(), role: .assistant, text: "world", timestamp: Date())
        ]
        // "hello" → 1, "world" → 1
        XCTAssertEqual(TokenEstimator.estimate(messages), 2)
    }

    func testEstimateIsConservativeForCJK() {
        // CJK 实际更密(1.5 chars/token),除以 3 略高估 → 行为正确
        let cjk = String(repeating: "中", count: 12)
        XCTAssertEqual(TokenEstimator.estimate(cjk), 4)
    }
}
```

⚠️ `ChatMessage` 字段名需要跟 `ClarcCore` 实际定义匹配 — 写测试时 grep 一下:

```bash
grep -n "struct ChatMessage\|init.*role\|let role\|var role" Packages/Sources/ClarcCore/*.swift
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
cd Packages && swift test --filter TokenEstimatorTests 2>&1 | tail -20
```

期望:`error: cannot find 'TokenEstimator' in scope`(类型未定义)。

- [ ] **Step 3: 实现 `TokenEstimator`**

写入 `Packages/Sources/ClarcCore/TokenEstimator.swift`:

```swift
import Foundation

/// Rough token count estimator. Uses a conservative chars/3 ratio
/// to slightly over-estimate mixed CJK/ASCII content (CJK is denser
/// than 3 chars/token in reality, so this errs on the side of
/// triggering compaction earlier).
public struct TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        max(0, text.count / 3)
    }

    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimate($1.text) }
    }
}
```

- [ ] **Step 4: 跑测试,确认通过**

```bash
cd Packages && swift test --filter TokenEstimatorTests 2>&1 | tail -10
```

期望:`Test Suite 'TokenEstimatorTests' passed`。

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/TokenEstimator.swift Packages/Tests/ClarcCoreTests/TokenEstimatorTests.swift
git commit -m "feat(core): add TokenEstimator (chars/3)

Conservative token estimate for triggering context compaction. Pure
logic, fully unit-tested. Lives in ClarcCore so it can be tested
without MainActor isolation.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `CompactionRecord` + TDD

**Files:**
- Create: `Packages/Sources/ClarcCore/CompactionRecord.swift`
- Create: `Packages/Tests/ClarcCoreTests/CompactionRecordTests.swift`

- [ ] **Step 1: 写失败测试**

写入 `Packages/Tests/ClarcCoreTests/CompactionRecordTests.swift`:

```swift
import XCTest
@testable import ClarcCore

final class CompactionRecordTests: XCTestCase {
    func testRecentUserBudgetIs20k() {
        XCTAssertEqual(CompactionRecord.recentUserTokenBudget, 20_000)
    }

    func testSummaryPrefixMentionsAnotherModel() {
        XCTAssertTrue(CompactionRecord.summaryPrefix.contains("Another language model"))
    }

    func testCompactionRecordIsCodable() throws {
        let messages = [
            ChatMessage(id: UUID(), role: .user, text: "hi", timestamp: Date())
        ]
        let record = CompactionRecord(
            compactedAt: Date(timeIntervalSince1970: 1_000_000),
            summaryText: "summary content",
            originalMessages: messages,
            originalCount: 1,
            originalTokenEstimate: 1,
            newTokenEstimate: 2
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CompactionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
cd Packages && swift test --filter CompactionRecordTests 2>&1 | tail -10
```

期望:`error: cannot find 'CompactionRecord' in scope`。

- [ ] **Step 3: 实现 `CompactionRecord`**

写入 `Packages/Sources/ClarcCore/CompactionRecord.swift`:

```swift
import Foundation

/// A snapshot of a session that has been compacted. The original
/// messages are kept in memory (and persisted in the session JSONL)
/// so the UI can still show them, while the CLI sees a shorter
/// `[initialContext] + [recent user messages] + [summary]` history.
public struct CompactionRecord: Codable, Equatable, Sendable {
    public let compactedAt: Date
    public let summaryText: String
    public let originalMessages: [ChatMessage]
    public let originalCount: Int
    public let originalTokenEstimate: Int
    public let newTokenEstimate: Int

    public init(
        compactedAt: Date,
        summaryText: String,
        originalMessages: [ChatMessage],
        originalCount: Int,
        originalTokenEstimate: Int,
        newTokenEstimate: Int
    ) {
        self.compactedAt = compactedAt
        self.summaryText = summaryText
        self.originalMessages = originalMessages
        self.originalCount = originalCount
        self.originalTokenEstimate = originalTokenEstimate
        self.newTokenEstimate = newTokenEstimate
    }
}

extension CompactionRecord {
    /// Codex-style token budget for recent user messages kept after
    /// a compact. The rest of the history is replaced by the summary.
    public static let recentUserTokenBudget = 20_000

    /// Prefix prepended to the summary message that the next LLM
    /// sees. Tells it that the history was replaced by a summary
    /// written by another model.
    public static let summaryPrefix = """
    Another language model started to solve this problem and produced \
    a summary of the conversation so far. The summary is provided \
    below; please continue from where it left off.

    """
}
```

- [ ] **Step 4: 跑测试,确认通过**

```bash
cd Packages && swift test --filter CompactionRecordTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/CompactionRecord.swift Packages/Tests/ClarcCoreTests/CompactionRecordTests.swift
git commit -m "feat(core): add CompactionRecord model

Holds the original messages, summary text, and token estimates for a
compacted session. Persisted in the session JSONL so the UI can
restore the original view after an app restart. Includes the
Codex-style 20k recent-user-message budget and 'Another language
model...' summary prefix as static constants.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: 验证 CLI `--system-prompt --resume` 组合(关键开放点)

**Files:** 无(纯验证步骤,不改代码)

- [ ] **Step 1: 找一个现有 session id**

```bash
ls ~/Library/Application\ Support/Clarc/sessions/ 2>&1
# 选一个 .jsonl 文件,看里面的 sessionId
```

- [ ] **Step 2: 跑命令验证**

```bash
SESSION_ID=<从 step 1 拿到的>
claude -p "Summarize the conversation above this point." \
  --resume "$SESSION_ID" \
  --system-prompt "You are performing a CONTEXT CHECKPOINT COMPACTION. Produce a handoff summary." \
  --output-format text \
  --model haiku 2>&1
```

观察结果:

| 情况 | 表现 | 行动 |
|---|---|---|
| **A. 成功** | 返回 summary 文本,包含"Summary:..." 或类似结构 | 走 Approach 2 的 `-p` 路径,Task 4 实现 |
| **B. --resume 被忽略** | 输出是新的会话,不是基于原 session | 降级到 stdin 注入(见 step 3) |
| **C. flag 冲突** | 报错 "cannot use --system-prompt with -p" | 降级到 stdin 注入 |
| **D. 完全不工作** | 其他错误 | 记录错误,先 commit Task 1-2,Task 4 留 fallback 注释 |

- [ ] **Step 3: 如果需要,验证 stdin 降级方案**

```bash
# stdin 注入方案
echo '{"type":"user","message":{"role":"user","content":"Summarize the conversation above this point."}}' | \
  claude --resume "$SESSION_ID" \
    --system-prompt "..." \
    --input-format stream-json \
    --output-format text \
    --verbose 2>&1
```

观察输出。如果两种方案都不行,**整个 stage 2 需要重新设计 API 通道**(这是 plan 的 fail-fast 点)。

- [ ] **Step 4: 记录结果到 plan 文档(在本文末尾追加)**

```bash
# 在 docs/superpowers/plans/2026-06-04-context-compaction.md 末尾追加:
echo -e "\n## CLI 验证结果($(date))\n\n$(date) 验证: \`claude -p --system-prompt --resume\` [PASS/FAIL/DEGRADED]. 选用 [A 路径 / B 降级路径]" >> docs/superpowers/plans/2026-06-04-context-compaction.md
git add docs/superpowers/plans/2026-06-04-context-compaction.md
git commit -m "docs(plan): record CLI compactSession verification result"
```

- [ ] **Step 5: 不修改代码,继续 Task 4(根据 step 2 结果选实现路径)**

---

## Task 4: `ClaudeService.compactSession`

**Files:**
- Modify: `Clarc/Services/ClaudeService.swift`

- [ ] **Step 1: 在 `runLocalCommand` 附近加 `compactSession` method**

定位:`Clarc/Services/ClaudeService.swift:255-264` 附近的 `runLocalCommand` 函数,加新 method(在它之后):

```swift
/// Run a one-shot context compaction: ask Claude to summarize the
/// conversation of an existing session.
///
/// Implementation: spawn `claude -p --resume <sid> --system-prompt
/// <summaryPrompt> --output-format text --model <model>` and return
/// the full stdout as the summary.
///
/// - Parameters:
///   - sessionId: existing Claude Code session to summarize
///   - model: which Claude model to use (typically haiku for speed)
///   - cwd: working directory of the session
func compactSession(
    sessionId: String,
    model: String,
    cwd: String
) async throws -> String {
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

    let arguments = [
        "-p",
        "Summarize the conversation above this point.",
        "--resume", sessionId,
        "--system-prompt", summaryPrompt,
        "--output-format", "text",
        "--model", model
    ]

    let output = try await runShellCommand(
        binary,
        arguments: arguments,
        workingDirectory: cwd
    )
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

⚠️ `binary` 是 `findClaudeBinary()` 的结果。`runShellCommand` 内部接收 `arguments` + `workingDirectory`(看现有 `runLocalCommand` 怎么用,模仿):

```bash
grep -n "runShellCommand\|workingDirectory" Clarc/Services/ClaudeService.swift | head -20
```

如果 `runShellCommand` 不接受 `workingDirectory`,改成在调用前用 `FileManager.default.changeCurrentDirectoryPath(cwd)` (不推荐,会污染全局),或者用 `Process` 自己 new 一个。最简单:**不带 cwd**,让 CLI 用当前 default cwd —— 接受这个限制(后续优化)。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```

期望:`** BUILD SUCCEEDED **`。

- [ ] **Step 3: 单元测试(有限)**

`ClaudeService` 是 actor 且依赖 `Process`,不好测。**改用集成验证**:

启动 app → 进 Settings → 触发 `/compact`(Task 8 会接)→ 观察 summary 文本返回。

或临时写个 Swift script 调用:

```bash
# Packages/Sources/claude-cli-test/main.swift(临时)
import Foundation
// 调 ClaudeService.compactSession(需要 mock actor)
```

**简化**:跳过单测,直接进 Task 5,Task 7 端到端测试时一起验。

- [ ] **Step 4: Commit**

```bash
git add Clarc/Services/ClaudeService.swift
git commit -m "feat(services): add ClaudeService.compactSession

Spawn a one-shot 'claude -p --system-prompt <summaryPrompt> --resume
<sid> --output-format text --model <model>' invocation to ask
Claude to summarize the conversation of an existing session. The
returned text becomes the summary that replaces the old history.

The summary prompt is a Codex-style 'CONTEXT CHECKPOINT COMPACTION'
prompt adapted for Claude Code (the system-prompt flag replaces
the entire default prompt, so the compact instructions are
guaranteed to be the only directive).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `CompactService` 主流程

**Files:**
- Create: `Clarc/Services/CompactService.swift`

- [ ] **Step 1: 写 `CompactService`**

写入 `Clarc/Services/CompactService.swift`:

```swift
import Foundation
import ClarcCore

@MainActor
final class CompactService {
    private weak var appState: AppState?
    private var inFlight: Task<CompactionRecord, Error>?

    init(appState: AppState) {
        self.appState = appState
    }

    var isCompacting: Bool { inFlight != nil }

    /// Run a full compact cycle for the current session.
    ///
    /// 1. Snapshot the current ChatMessage list
    /// 2. Find recent user messages within the 20k token budget
    /// 3. Build initial context (first system message, or empty)
    /// 4. Call `claude.compactSession` for the summary
    /// 5. Build the new compact history
    /// 6. Apply via `appState.applyCompaction`
    func run() async throws -> CompactionRecord {
        // Coalesce concurrent calls
        if let existing = inFlight { return try await existing.value }
        guard let appState else { throw CompactError.cancelled }

        let task = Task<CompactionRecord, Error> { [weak appState] in
            guard let appState else { throw CompactError.cancelled }
            return try await Self.performCompact(appState: appState)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func performCompact(appState: AppState) async throws -> CompactionRecord {
        guard let sid = appState.windowState.currentSessionId,
              let session = appState.sessionStates[sid] else {
            throw CompactError.noSession
        }
        let original = session.settledItems
        guard original.count >= 2 else {
            throw CompactError.tooShort
        }

        // 1. Find recent user messages within budget
        var recent: [ChatMessage] = []
        var budget = CompactionRecord.recentUserTokenBudget
        for msg in original.reversed() where msg.role == .user {
            let cost = TokenEstimator.estimate(msg.text)
            if budget - cost < 0 { break }
            recent.insert(msg, at: 0)
            budget -= cost
        }

        // 2. Initial context (first system message or empty)
        let initialContext = original.first(where: { $0.role == .system })
            ?? ChatMessage.emptySystem()

        // 3. Resolve session metadata
        guard let sessionId = appState.currentSessionIdString() else {
            throw CompactError.noSession
        }
        let cwd = appState.currentProjectCwd() ?? FileManager.default.currentDirectoryPath

        // 4. Call CLI for the summary
        let summary = try await appState.claude.compactSession(
            sessionId: sessionId,
            model: "haiku",
            cwd: cwd
        )

        // 5. Build the new history
        let summaryMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: CompactionRecord.summaryPrefix + summary,
            timestamp: Date(),
            isCompactionSummary: true
        )
        let newHistory: [ChatMessage] = [initialContext] + recent + [summaryMessage]

        // 6. Build record + apply
        let record = CompactionRecord(
            compactedAt: Date(),
            summaryText: summary,
            originalMessages: original,
            originalCount: original.count,
            originalTokenEstimate: TokenEstimator.estimate(original),
            newTokenEstimate: TokenEstimator.estimate(newHistory)
        )

        appState.applyCompaction(record, newHistory: newHistory)
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
```

⚠️ **依赖**:
- `ChatMessage.role: .system` 是否存在?grep 一下:
  ```bash
  grep -n "enum Role\|case .*system\|case .*user\|case .*assistant" Packages/Sources/ClarcCore/*.swift
  ```
- `ChatMessage.isCompactionSummary` 字段是否要加?如果 ChatMessage 是简单的 struct,需要新加 Bool 字段。grep ChatMessage 实际定义。
- `ChatMessage.emptySystem()` factory 是否存在?如果不存在,加一个:`static func emptySystem() -> ChatMessage { ChatMessage(id: UUID(), role: .system, text: "", timestamp: Date()) }`
- `appState.currentSessionIdString()` 和 `appState.currentProjectCwd()`:Task 6 会加

- [ ] **Step 2: Build 验证(会失败,因为 appState 端没接)**

```bash
xcodebuild ... build 2>&1 | tail -20
```

期望:失败,Task 6 修。

- [ ] **Step 3: 暂不 commit,等 Task 6 一起**

---

## Task 6: `AppState` 接 compact

**Files:**
- Modify: `Clarc/App/AppState.swift`
- Modify: `Clarc/App/WindowState.swift`

- [ ] **Step 1: `WindowState` 加 `autoCompactThreshold`**

定位 `WindowState.swift` 的 foldThreshold 字段附近,加:

```swift
/// When the estimated token count of the current session's settled
/// messages exceeds this value, automatically run a context
/// compaction. 0 disables auto-compact. Persisted in UserDefaults
/// so it survives restarts.
var autoCompactThreshold: Int = {
    let key = "autoCompactThreshold"
    if let stored = UserDefaults.standard.object(forKey: key) as? Int {
        return stored
    }
    return 100_000  // Codex default
}() {
    didSet { UserDefaults.standard.set(autoCompactThreshold, forKey: "autoCompactThreshold") }
}
```

⚠️ 实际 `WindowState` 的 foldThreshold 持久化模式可能略有不同 — grep:

```bash
grep -n "foldThreshold\|UserDefaults" Packages/Sources/ClarcCore/WindowState.swift 2>&1
```

模仿其模式。

- [ ] **Step 2: `AppState` 加 `compactService` 字段**

定位 `AppState.swift` 的 service 初始化区(通常在 init 内),加:

```swift
let compactService: CompactService

init() {
    // ... existing inits ...
    self.compactService = CompactService(appState: self)  // 后置引用,在所有字段初始化后
}
```

⚠️ **init 顺序问题**:`CompactService` 持有 `weak appState`,但 `appState.compactService = ...` 时 self 还没完全初始化。**改为 lazy**:

```swift
lazy var compactService: CompactService = CompactService(appState: self)
```

- [ ] **Step 3: 加 `currentSessionIdString()` / `currentProjectCwd()` helper**

在 `AppState` 加:

```swift
/// Returns the Claude Code CLI session id (string) for the current
/// session, if any. Used by compactSession to --resume the right
/// session.
func currentSessionIdString() -> String? {
    guard let sid = windowState.currentSessionId,
          let session = sessionStates[sid] else { return nil }
    return session.claudeSessionId
}

/// Returns the working directory of the current project, used by
/// compactSession to spawn the CLI in the right cwd.
func currentProjectCwd() -> String? {
    guard let pid = windowState.selectedProject?.id,
          let project = projects.first(where: { $0.id == pid }) else { return nil }
    return project.path
}
```

`session.claudeSessionId` 字段是否已存在?grep `claudeSessionId`:

```bash
grep -n "claudeSessionId" Clarc/App/AppState.swift
```

如果没有,加一个 String 字段并在 `recordSessionId` 时填值。

- [ ] **Step 4: 加 `applyCompaction` 方法**

```swift
@MainActor
extension AppState {
    /// Replace the current session's history with the compacted
    /// version, storing the original messages in
    /// `compactionRecord`. UI continues to show the original messages
    /// (read from the record), while the CLI sees the shorter
    /// history on the next turn.
    func applyCompaction(_ record: CompactionRecord, newHistory: [ChatMessage]) {
        guard let sid = windowState.currentSessionId,
              let session = sessionStates[sid] else { return }
        session.settledItems = newHistory
        session.compactionRecord = record
        persistenceService.saveSession(session, id: sid)
    }
}
```

`session.compactionRecord` 字段是否要加?grep SessionState:

```bash
grep -n "class SessionState\|var settledItems\|var compactionRecord" Clarc/App/AppState.swift
```

如果 SessionState 是 class,直接加 `var compactionRecord: CompactionRecord?`。如果是 struct,一样加。

- [ ] **Step 5: Build 验证**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30
```

期望:`** BUILD SUCCEEDED **`。

- [ ] **Step 6: Commit**

```bash
git add Clarc/App/AppState.swift Clarc/App/WindowState.swift
git commit -m "feat(chat): wire CompactService into AppState

- Add WindowState.autoCompactThreshold (default 100k, persisted)
- Add lazy AppState.compactService
- Add currentSessionIdString() / currentProjectCwd() helpers
- Add applyCompaction() that swaps settledItems for the compacted
  list and stores the original messages in session.compactionRecord
- Persistence: session JSONL is rewritten on every compact

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `MessageListView` 渲染策略 + compact banner

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/MessageListView.swift`

- [ ] **Step 1: 加 `displayItems` 计算属性**

定位 `MessageListView` body,在合适位置(比如 `makeVisibleTurns()` 之前)加:

```swift
/// The list of ChatMessages to render. If a compact record exists,
/// use its snapshot (so users see the original content); otherwise
/// use the live `settledItems` (which may itself be the compacted
/// list — that's fine, since the user sees the same content).
private var displayItems: [ChatMessage] {
    if let snapshot = appState.sessionStates[windowState.currentSessionId]?.compactionRecord?.originalMessages,
       !snapshot.isEmpty {
        return snapshot
    }
    return settledItems
}
```

- [ ] **Step 2: `makeVisibleTurns()` 改用 `displayItems`**

```swift
private func makeVisibleTurns() -> [Turn] {
    let all = Turn.makeTurns(
        from: displayItems,
        isStreamingLast: isStreaming,
        foldThreshold: windowState.foldThreshold
    )
    let cap = max(0, windowState.foldThreshold) + 100
    if all.count <= cap { return all }
    return Array(all.suffix(cap))
}
```

- [ ] **Step 3: 加 `CompactBanner` 组件(同文件内,private struct)**

在 `MessageListView.swift` 末尾追加:

```swift
private struct CompactBanner: View {
    let record: CompactionRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text("Context compacted at \(record.compactedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(record.originalCount) messages · ~\(record.originalTokenEstimate) → ~\(record.newTokenEstimate) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button(isExpanded ? "Hide summary" : "Show summary") {
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
                            .fill(Color(ClaudeTheme.surface).opacity(0.5))
                    )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(ClaudeTheme.surface).opacity(0.3))
        )
    }
}
```

- [ ] **Step 4: 在 ForEach(turns) 之前插入 banner**

```swift
var body: some View {
    ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Banner shows if there's a compact record
                if let record = appState.sessionStates[windowState.currentSessionId]?.compactionRecord {
                    CompactBanner(record: record)
                }

                ForEach(makeVisibleTurns()) { ... }  // existing
                if isStreaming { streamingTail() }    // existing
            }
            // ... existing modifiers
        }
    }
}
```

- [ ] **Step 5: Build 验证**

```bash
xcodebuild ... build 2>&1 | tail -10
```

- [ ] **Step 6: 启动验证(在 Task 8 接好 `/compact` 之前,先验 banner 不崩)**

启动 app → 加载 session → 没有 compact record → banner 不显示 → 正常 turn 列表 ✓。

- [ ] **Step 7: Commit**

```bash
git add Packages/Sources/ClarcChatKit/MessageListView.swift
git commit -m "feat(chat): render compact banner + show snapshot on compact

MessageListView now reads appState.compactionRecord.originalMessages
when present, so the user continues to see the full original
conversation after a compact. A CompactBanner card sits above the
turn list showing the compaction timestamp, message count, and
token savings, with a collapsible summary section.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: 工具栏 "Compact" 按钮 + `/compact` slash command

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/ChatView.swift`
- Modify: `Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift`

- [ ] **Step 1: 找 ChatView 工具栏位置**

```bash
grep -n "toolbar\|Button" Packages/Sources/ClarcChatKit/ChatView.swift | head -20
```

- [ ] **Step 2: 加 "Compact" 按钮**

在 toolbar 内加(模仿 collapse-all 按钮):

```swift
Button {
    Task { @MainActor in
        do {
            _ = try await appState.compactService.run()
        } catch {
            appState.showError(error)
        }
    }
} label: {
    Label("Compact", systemImage: "arrow.triangle.2.circlepath")
}
.disabled(appState.compactService.isCompacting)
```

⚠️ `appState.showError` 是否存在?grep:

```bash
grep -n "showError\|toast" Clarc/App/AppState.swift | head -10
```

模仿现有错误展示模式。

- [ ] **Step 3: 注册 `/compact` slash command**

定位 `SlashCommandManagerView.swift` 的命令注册区(grep `SlashCommand(`):

```bash
grep -n "SlashCommand(" Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift
```

模仿现有命令加:

```swift
SlashCommand(
    name: "compact",
    description: "Compact the current session context",
    handler: { @MainActor in
        do {
            _ = try await appState.compactService.run()
        } catch {
            appState.showError(error)
        }
    }
)
```

⚠️ `SlashCommand` 的实际 init 签名 grep 确认。

- [ ] **Step 4: Build 验证**

```bash
xcodebuild ... build 2>&1 | tail -10
```

- [ ] **Step 5: 启动验证(完整流程)**

启动 app → 加载一个有 5+ turn 的 session →

1. 工具栏点 "Compact" → 看到状态变化(banner 出现,JSONL 改写)
2. 在 slash bar 输入 `/compact` → 同样效果
3. 错误处理:发 0 条消息的 session 触发 → 看到 "对话太短" 错误
4. banner 可展开 → 看到 summary 文本

- [ ] **Step 6: Commit**

```bash
git add Packages/Sources/ClarcChatKit/ChatView.swift Packages/Sources/ClarcChatKit/SlashCommandManagerView.swift
git commit -m "feat(chat): add manual Compact button + /compact slash

Toolbar gains a Compact button (disabled while compacting) and the
slash command bar registers /compact. Both route through
AppState.compactService.run(), which is the single entry point for
context compaction. Errors are surfaced via the existing toast
mechanism.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: 自动 token 阈值 trigger

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/MessageListView.swift`

- [ ] **Step 1: 加 `.onChange(of: settledItems.count)` 自动 trigger**

定位 `MessageListView` body 内现有的 `.onChange` 修饰符,在合适位置加:

```swift
.onChange(of: settledItems.count) { _, _ in
    rebuildTurns()

    // Auto-compact if threshold exceeded
    let estimate = TokenEstimator.estimate(settledItems)
    if windowState.autoCompactThreshold > 0
        && estimate > windowState.autoCompactThreshold
        && !isStreaming
        && !appState.compactService.isCompacting
    {
        Task { @MainActor in
            do {
                _ = try await appState.compactService.run()
            } catch {
                appState.showError(error)
            }
        }
    }
}
```

⚠️ `rebuildTurns()` 是 Task 3(stage 1)的 internal 函数,如果签名不匹配,看 stage 1 的 `MessageListView` 实际怎么写。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild ... build 2>&1 | tail -10
```

- [ ] **Step 3: 启动验证自动 trigger**

启动 app → Settings → 把 `autoCompactThreshold` 调到 100(很小的值)→ 发够多消息(估算 > 100 token)→

观察:
- 状态栏/工具栏出现 "Compacting..." 提示
- compact 完成后 banner 出现
- 再发消息 → 不再触发(inFlight 锁)

- [ ] **Step 4: streaming 期间不触发的验证**

启动 streaming 期间(发消息,等回复中)→ 同时让阈值被超 → **不**应触发 compact(被 `!isStreaming` 守卫拦下)。

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcChatKit/MessageListView.swift
git commit -m "feat(chat): auto-compact when token threshold exceeded

When WindowState.autoCompactThreshold is non-zero and the estimated
token count of settledItems exceeds it, MessageListView triggers
CompactService.run() in a detached task. Guards:
- !isStreaming (don't interrupt an active response)
- !compactService.isCompacting (coalesce concurrent triggers)

Errors are surfaced via the existing toast mechanism. The user can
disable auto-compact by setting the threshold to 0 in Settings.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: 本地化字符串

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/Resources/en.lproj/Localizable.strings`
- Modify: `Packages/Sources/ClarcChatKit/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Packages/Sources/ClarcChatKit/Resources/ko.lproj/Localizable.strings`

- [ ] **Step 1: 加新 key 到三份文件**

**en.lproj**:
```
"chat.toolbar.compact" = "Compact";
"chat.banner.compactAt" = "Context compacted at %@";
"chat.banner.messages" = "%lld messages · ~%lld → ~%lld tokens";
"chat.banner.showSummary" = "Show summary";
"chat.banner.hideSummary" = "Hide summary";
"chat.compact.tooShort" = "Conversation too short to compact";
"chat.compact.noSession" = "No active session";
"chat.compact.running" = "Compacting...";
```

**zh-Hans.lproj**:
```
"chat.toolbar.compact" = "压缩上下文";
"chat.banner.compactAt" = "上下文已压缩于 %@";
"chat.banner.messages" = "%lld 条消息 · 约 %lld → %lld tokens";
"chat.banner.showSummary" = "查看摘要";
"chat.banner.hideSummary" = "隐藏摘要";
"chat.compact.tooShort" = "对话太短,无需压缩";
"chat.compact.noSession" = "未找到当前会话";
"chat.compact.running" = "正在压缩...";
```

**ko.lproj**:
```
"chat.toolbar.compact" = "컨텍스트 압축";
"chat.banner.compactAt" = "%@ 에 컨텍스트 압축됨";
"chat.banner.messages" = "%lld 개 메시지 · ~%lld → ~%lld 토큰";
"chat.banner.showSummary" = "요약 보기";
"chat.banner.hideSummary" = "요약 숨기기";
"chat.compact.tooShort" = "대화가 너무 짧아 압축할 수 없습니다";
"chat.compact.noSession" = "활성 세션이 없습니다";
"chat.compact.running" = "압축 중...";
```

- [ ] **Step 2: `CompactBanner` / `ChatView` 用 LocalizedStringKey 替换硬编码**

凡是 `Text("Show summary")` / `Text("Compact")` 等改为:

```swift
Text("chat.banner.showSummary", bundle: .module)
```

- [ ] **Step 3: Build 验证**

```bash
xcodebuild ... build 2>&1 | tail -10
```

- [ ] **Step 4: 启动验证多语言**

切系统语言 → 重启 app → 验证 toolbar / banner 文案随之变化。

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcChatKit/Resources/
git commit -m "feat(chat): localize compact UI strings

en/zh-Hans/ko bundles for the Compact button, compact banner,
and error messages. Format strings use %lld for Int (long long)
and %@ for Date.formatted output.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: 端到端测试 + release

**Files:** 无

- [ ] **Step 1: 跑所有单测**

```bash
cd Packages && swift test 2>&1 | tail -20
```

期望:全 pass。

- [ ] **Step 2: 启动 app 端到端流程**

启动 app,完整走一遍:

1. 发 10 条 user 消息 → 看到 10 个 turn,前期折叠、后期展开
2. 工具栏点 "Compact" → banner 出现,summary 可展开查看
3. 继续发新消息 → 新消息基于精简历史(可在 Activity Monitor 看 token 增长平缓)
4. 退出 app → 重启 → banner 仍在(从 JSONL 恢复)
5. 切到另一个 session → 不应触发 compact
6. 切回原 session → 继续

- [ ] **Step 3: 自动 trigger 验证**

把 `autoCompactThreshold` 调到很低(如 50)→ 发够多消息 → 自动 compact 触发。

- [ ] **Step 4: 容错**

- < 2 消息的 session 触发 → "对话太短"
- 故意给个不存在的 session id → "未找到当前 session"
- 中断网络 → CLI 调失败 → toast 错误

- [ ] **Step 5: 全局 grep 兜底**

```bash
grep -rn "TODO\|FIXME\|XXX" Clarc/Services/CompactService.swift Clarc/Services/ClaudeService.swift 2>&1
```

期望:zero hits(实现完整,无 TODO)。

- [ ] **Step 6: 准备 release commit**

版本号 v2.5.0 → v2.5.1(只加新功能 + 不破坏现有行为,patch 递增):

```bash
# 改 CFBundleVersion / CFBundleShortVersionString
git add Clarc/Info.plist Clarc.xcodeproj/project.pbxproj
git commit -m "chore(release): v2.5.1 (build 8)

Add /compact manual command and auto-trigger token threshold.
Rewrites session JSONL to [initialContext] + [recent user msgs
within 20k] + [summary]. UI keeps the original messages visible
via an in-memory snapshot rendered as a Turn list with a
'Compact' banner card.

See docs/superpowers/specs/2026-06-04-context-compaction.md for
the full spec, and the commit history for per-task changes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git tag v2.5.1
```

---

## Self-Review

1. **Spec coverage**:
   - TokenEstimator → Task 1 ✓
   - CompactionRecord → Task 2 ✓
   - CLI compactSession → Task 4 ✓
   - CompactService 编排 → Task 5 ✓
   - AppState 接 compact → Task 6 ✓
   - MessageListView 渲染策略 + banner → Task 7 ✓
   - 手动 `/compact` + 工具栏 → Task 8 ✓
   - 自动 trigger → Task 9 ✓
   - 本地化 → Task 10 ✓
   - 端到端测试 → Task 11 ✓

2. **Placeholder scan**:无 TBD。CLI 验证 Task 3 是显式的"先验证再实现"步骤,符合 fail-fast 原则。

3. **Type consistency**:
   - `TokenEstimator.estimate(_:)` 签名 Task 1 定义,Task 5 + 6 + 9 一致调用
   - `CompactionRecord` 字段 Task 2 定义,Task 5 构造 + Task 7 渲染一致
   - `CompactService.run()` 抛错类型 Task 5 定义,Task 6/8/9 catch 一致
   - `ChatMessage.role: .system` 字段依赖现有 ClarcCore 定义 — Task 5 + 6 grep 提醒

4. **依赖关系**:
   - Task 1-2 独立(可在 stage 1 之后并发)
   - Task 3 验证 CLI,影响 Task 4 实现路径
   - Task 4 依赖 Task 3 结果
   - Task 5 依赖 Task 4
   - Task 6 依赖 Task 5
   - Task 7 依赖 Task 6
   - Task 8 依赖 Task 6
   - Task 9 依赖 Task 6
   - Task 10 独立(但建议最后)
   - Task 11 依赖所有

5. **风险点标注**:
   - CLI 命令组合兼容性(高,Task 3 显式验证)
   - ChatMessage 字段差异(中,grep 提醒)
   - SessionState 是 class 还是 struct(中,grep 提醒)
   - WindowState 持久化模式(中,grep 提醒)
   - SlashCommand init 签名(中,grep 提醒)
   - appState.showError / toast 模式(中,grep 提醒)
   - runShellCommand 是否支持 workingDirectory(中,grep 提醒;如果不支持用 default cwd)

## CLI 验证结果(2026-06-04)

手动跑 `claude -p "say hi in 3 words" --system-prompt "You are a parrot. Always say 'Polly wants a' before your response." --output-format text` → 返回 `Polly wants a cracker!`,模型正确遵循 system prompt。

`--resume` 的兼容性: `ClaudeService.fetchContextPercentage(sessionId:cwd:)` 已经在生产代码里使用 `claude -p "/context" --output-format text --resume <sid>`,意味着 `-p + --resume` 组合已被先例验证可用。

**结论**: 通道 A (`-p + --system-prompt + --resume`) 可行,不需要降级到 stdin 注入。
