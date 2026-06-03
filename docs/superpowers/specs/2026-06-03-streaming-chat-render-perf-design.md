# 性能优化:Streaming 期间 chat 渲染路径

> 目标:让"对话变多、streaming 期间 UI 卡顿"问题显著改善,主要在 chat 渲染路径上。
> 范围:**仅优化 streaming 期间 chat 渲染路径**——不动 `AppState`、`ChatBridge` interface、`WindowState`、markdown 解析、sidebar、file tree。
> 数据规模参考:3 个项目、每个 1-2 个 session(用户报告)。卡顿不是数据量级问题,是 streaming 期间主线程负担过重问题。

## Context

**用户报告**:
- 3 个项目,每个 1-2 个 session(数据量不大)
- "全场景都卡"——但**最明显是 streaming 期间**
- 表现:**滚动不跟手、输入/发送有延迟**、CPU 没明显飙高(说明不是计算密集,而是 view diff 抖动)
- "代码块多时更明显" — 暗示 markdown 解析 / 复杂 bubble 渲染是热点之一

**已识别的根因链**(`MessageListView.swift`):

1. `MessageListView` 的 body 直接读 `chatBridge.messages`(`MessageListView.swift:13` `@Environment(ChatBridge.self)`)
2. streaming 期间,`.task(id: chatBridge.isStreaming)` 每 50ms 跑一次 `rebuildSettledItems`(`MessageListView.swift:174-181`),把整个 settled 列表重建
3. 父层 `VStack(spacing: 16)` 不是 `LazyVStack`,所有 bubble 一次性 participate layout
4. `MarkdownView` 的 `RenderGroupCache` 在 streaming 期间几乎完全 miss(text 持续变)
5. `MessageBubble` 内 7 个 `@State`(`isCopied`、`cursorVisible`、`isEditing`、`editText`、`isLongTextExpanded`、`hoveredBlockId`、`isHoveringUserBubble`),每个 bubble 一个独立 state holder

**根因结论**:streaming 期间,主线程被"每 50ms 重建整棵 settled 列表 + 解析整个 markdown + diff 全部 bubble"占据,导致 UI 事件得不到响应。

**预期结果**(可被肉眼/简单测量验证):
- streaming 期间 sidebar 切换、点击 input box 响应延迟 < 100ms
- 滚动不跟手的"口口感"消失
- Time Profiler 显示 Main Thread 的"SwiftUI / MessageListView body"调用频次显著下降

## Approach

**A + B 组合,streaming message 与 settled 消息同层布局**(用户确认):

### Fix 1 — 删掉 50ms 轮询,settledItems 只在离散事件更新

`MessageListView.swift:174-181`:
- 删掉 `.task(id: chatBridge.isStreaming)` 内的 50ms 轮询 `rebuildSettledItems`
- 保留 `rebuildSettledItems` 在以下离散时机被调用:
  - `task(id: currentSessionId)` 切 session(line 150-168,已有)
  - `onChange(of: isStreaming)` end 分支(line 182-188,已有)
  - **新增**:streaming 期间,新 message count 变化时(用户发问、tool_result 推进)才 rebuild

**为什么可行**:
- streaming text delta 时,`chatBridge.messages.count` 不变(同一个 streaming message 在被更新 blocks,不是 append 新 message)
- 唯一会改变 settled list 内容的事件 = 新 message 进入(用户发问 = count+1、tool_result 推送 = 既有 message 更新 blocks 但不增加 count → 需要单独触发)
- `StreamingMessageView.swift:402` 已有 `onChange(of: messages.count)`,作为新增 message 的同步点

**具体改动**:
- `MessageListView.swift` 内 `StreamingMessageView { rebuildSettledItems(); if isNearBottom { scrollToBottomDebounced() } }` 块(line 113-116)— **这是关键点**。这里把"每次 count 变 → 重建 settled 列表 + 滚动"挪到外层 `MessageListView`,让 `StreamingMessageView` 不再承担这个 callback
- 把 `rebuildSettledItems` 的调用挪到 `MessageListView` 的 `.onChange(of: chatBridge.messages.count)`

**针对 `tool_result` 不增加 count 的明确处理**:在迁移时验证 `processStream` 内 `result` 事件是否会触发 `messages.last` 的 `isStreaming` 翻转或 `blocks` 改变(经 `ChatMessage` 是值类型,blocks 改变意味着 `Equatable` 失配 → SwiftUI 重渲染 `StreamingMessageView`,但**不会**触发 `MessageListView` 的 onChange)。因此 `MessageListView` 额外加一个 `.onChange(of: chatBridge.messages.last?.blocks.count)` 兜底,只在 streaming 期间 last message 的 block 数量增长时 rebuild(例如 tool_result 追加一个 block 到当前 streaming message)。`focusMode` / 折叠 / phase summary 的渲染都基于 `settledItems`,所以这个兜底点必须保留。

### Fix 2 — `VStack` 改 `LazyVStack`

`MessageListView.swift:27` (第一个 `VStack`)、`:106` (streaming 的第二个 `VStack`):
- `VStack(spacing: 16)` → `LazyVStack(spacing: 16)`
- 屏幕外 bubble 懒加载,大幅降低 view 数量

**为什么可行**:
- `MessageGroup.id` 稳定(`MessageListView.swift:325` `accumulator[0].id`),`MessageBubble.id(message.id)` 稳定
- `PhaseSummaryCard.id(summary.id)` 稳定
- keyed diff 可用

**已知风险**(已识别,见下文 Risk):
- `LazyVStack` 内 ScrollView 的 `defaultScrollAnchor(.bottom)` 行为与 `VStack` 略有不同——需肉眼验证
- 跨行/跨屏的 spacing 行为可能细微变化——肉眼验证

### Fix 3 — `settledOnlyMessages` 简化

`MessageListView.swift:249-261`:
- 现状:根据 `chatBridge.messages.last?.isStreaming` 切两套 filter 逻辑
- 改后:streaming 期间不再 `rebuildSettledItems`,所以这个函数的 streaming 分支只在 streaming **结束**时被调用一次,逻辑简化但行为不变
- 验证点:`focusMode` 的 filter(line 257-259)仍要工作

### 不动

- `MessageBubble.swift` 的 7 个 `@State` — 改 `cursorVisible` 优化属于另一个独立议题,且改 LazyVStack 后 bubble 数量已降低
- `MarkdownView.swift` 的解析逻辑 — 缓存 hit rate 提升后,主线程压力已经显著下降
- `AppState`、`ChatBridge`、`WindowState` — 这次范围明确不动
- FileTreeView、GitStatusView、HistoryListView — 范围外

## Critical Files to Modify

| 文件 | 改动 |
|---|---|
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | 删 50ms 轮询、改 `VStack` 为 `LazyVStack`、挪 `rebuildSettledItems` 触发点 |

仅 1 个文件,影响面收窄到 chat 渲染。`StreamingMessageView.swift` 内部不动(只是 `onStructureChanged` callback 调用方位置变化)。

## Data Flow (改后)

```
chatBridge.messages 变更
  ↓
.onChange(of: messages.count) 触发
  ├─ rebuildSettledItems()              ← 整列表一次性更新
  └─ if isNearBottom: scrollToBottom    ← 仅触底时滚动
  ↓
StreamingMessageView 自己的 body 渲染(独立,只读 messages)
  ├─ activeMessages 切分逻辑不变
  └─ text delta → AttributedString 更新,settled 节点零开销

streaming text delta(同一 message.blocks 更新):
  ├─ messages.count 不变 → 不触发 settled rebuild
  └─ StreamingMessageView 内的 Text 自然 diff 重绘
```

**关键性质**:streaming 期间 text delta 不再触发 settled 列表的 SwiftUI diff。

## Risk

| 风险 | 等级 | 缓解 |
|---|---|---|
| `LazyVStack` 替换 `VStack` 后 layout 微变 | 中 | 肉眼对比 4 种状态(空、已加载、streaming、scrolled up) |
| 删 50ms 轮询后,tool_result 推进时(不增加 count)settled 列表不及时更新 | 中 | 验证 `processStream` 的所有事件,确认 tool_result 事件会让 `messages.count` 或 `isStreaming` 变化 |
| streaming 期间 `settledItems` 不再增长,fold threshold 行为可能漂移 | 低 | fold threshold 只在 settled 部分比较,streaming tail 单独渲染,逻辑分开 |
| `defaultScrollAnchor(.bottom)` 在 `LazyVStack` 下的行为差异 | 低 | 已知 ScrollPosition 行为;肉眼验证 |
| `PhaseSummaryCard` 内嵌 `MessageBubble` 的 id 冲突 | 低 | 现有 `.id(message.id)` 写法不变,PhaseSummaryCard 的 `summary.id` 不冲突 |
| `focusMode` filter(line 257-259)行为 | 低 | 函数保留,只是调用频率变低 |

## Verification

### 1. Build(必要)

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

期望 `** BUILD SUCCEEDED **`。

### 2. 肉眼 / 交互验证(主要)

按用户场景复现:
1. 启动 app,选 1 个项目,选 1 个 session
2. 发一条消息让 Claude 开始 streaming
3. **观察**:
   - 滚动 streaming 期间的 chat 区域——文字跟手,无 jank
   - streaming 期间点 sidebar 切到另一个 session — 响应应该 < 100ms
   - streaming 期间点 input box 输入 — 输入应该无延迟
4. 同样场景对比改前(用 `git stash` 暂存这次的修改后跑)

### 3. Instruments(可选,如果用户想量化)

- 启动 Instruments → Time Profiler → attach to Clarc
- 触发 streaming(让 Claude 输出 30 秒)
- 对比改前/改后 Main Thread 的"SwiftUI / MessageListView"符号占比
- 预期:streaming 期间,改前 Main Thread 持续高 SwiftUI 占用;改后应该见到周期性"长尾"被切碎

## Out of Scope(本次明确不做)

- `MessageBubble` 内部 `cursorVisible` 优化
- `MarkdownView` 增量解析
- `AppState` 拆分、ChatBridge interface 变更
- FileTreeView / GitStatusView / HistoryListView 优化
- PersistenceService.saveSession 异步化

如果 Fix 1+2+3 后仍有可感知的卡顿,这些是后续 spec 的候选。

## Rollback

单文件改动,`git revert` 即可回滚,无 schema 变更,无数据迁移。
