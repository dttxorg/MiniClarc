# 折叠 + 虚拟化 — phase 模式下恢复折叠按钮,虚拟化 rendering 解决"几百条后卡"

> 目标: 修复"折叠按钮在 phase 模式下不工作" + "几百条输出后窗口卡顿"。

## Context

**Bug 1 — 折叠按钮不工作**:
`MessageListView.swift:48` 的判断:

```swift
if chatBridge.phaseSummaries.isEmpty {
    // Legacy fold-by-threshold + 折叠按钮
} else {
    // Codex-style chatWithPhases — 折叠按钮被显式隐藏
}
```

只要有 ≥ 1 个完成的 assistant 回合,`chatBridge.phaseSummaries` 就不为空(因为 `AppState.swift:1338` 的 `state.phaseSummaries.append(summary)` 总会跑),代码永远走 `chatWithPhases` 路径,折叠按钮永远不显示。

注释直接说: "The legacy 'show N earlier messages' fold button is suppressed in that case — phase cards are already collapsed by default and the user expands them individually."

设计意图: phase 卡片默认折叠,等价于"折叠功能"。但**用户感受是"折叠不工作"** — 期望行为是"几百条消息时能折叠早期 N 条"。

**Bug 2 — 几百条后卡顿**:
`chatWithPhases` 在 `VStack` 里渲染每个 phase + 它的 `MessageBubble` + 工具调用。`VStack` 一次 inflate 所有子 view。v2.4.1 试过 `LazyVStack`,但因 crash 在 v2.4.2 回退到 `VStack`。所以"几百条"全部一次性 inflate → 渲染慢 + 内存高 → 窗口卡。

## Approach

**3 个核心改动**:

### 1. 恢复折叠按钮(无论 phase 是否存在)

`MessageListView.swift:48` 的 `if phaseSummaries.isEmpty` 分支改成"折叠按钮始终显示" — 折叠阈值沿用 `windowState.foldThreshold`,phase 模式下:
- 隐藏最早期 N 个 phase(`N = total - foldThreshold`)
- 在最前面加占位条:"已隐藏 N 个 phase,点击展开"
- 占位条 = 一个大按钮(不是 PhaseSummaryCard 那种可展开的卡片)

### 2. 加"一键全折叠 phase"按钮

`ChatBridge` 新增 `collapseAllPhases: Bool`。`MessageListView` 在消息 toolbar(或状态栏)加一个开关按钮,点一下把所有 phase 卡片收起(每个 `PhaseSummaryCard.isExpanded = false`)。再点全开。**不动 phase 卡片自己的 isExpanded 状态** — 是"全局临时覆盖"。

切 session 时重置(`task(id: currentSessionId)` 内)。

### 3. 虚拟化 rendering

- `chatWithPhases` 重构,内部计算 `visiblePhaseRange: Range<Int>`
- 渲染最多 100 个 phase(超出的折叠成占位条"还有 N 个 phase,点击加载更多")
- 占位条逻辑:
  - 隐藏范围 = `0..<hiddenEnd`,渲染范围 = `hiddenEnd..<visibleEnd`
  - 占位条按钮"+ 展开 8 个" = 一次性把 `hiddenEnd` 减 8(或减到 0)
  - 当总 phase 数 <= 100,完全不虚拟化(全显示)
- 虚拟化不依赖 LazyVStack,纯 by-id 渲染 + .id(...),避免上次 crash 复发

## Critical Files

| 文件 | 改动 |
|---|---|
| `Packages/Sources/ClarcChatKit/ChatBridge.swift` | 新增 `var collapseAllPhases: Bool = false` |
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | 重构 `chatWithPhases` + 加 `visiblePhaseRange` 计算属性 + 加占位条 / 折叠按钮渲染 + toolbar 集成 `collapseAllPhases` |

**Out of scope**:
- `AppState` / `WindowState` 不动
- `PhaseSummaryCard` 自身逻辑不动
- `messageRows(legacy)` 路径保留(不变)— 但折叠按钮的渲染逻辑提到外层,让两条路径共享
- `LazyVStack` 不重做(避免上次 crash 复发)
- 释放版本号: v2.4.3 (build 5)

## Detailed Design

### 折叠按钮始终显示(无论 phase)

新逻辑(`MessageListView.swift` body 内):

```swift
if !chatBridge.phaseSummaries.isEmpty {
    // === Phase 模式 ===
    let totalPhases = chatBridge.phaseSummaries.count
    let foldThresh = windowState.foldThreshold
    let hiddenPhases = max(0, totalPhases - foldThresh)
    let visibleEnd = min(foldThresh, 100)  // 虚拟化 cap

    // 1. 占位条 (如果隐藏了 phase)
    if hiddenPhases > 0 {
        phaseFoldPlaceholder(
            hiddenCount: hiddenPhases,
            isExpanded: !isOlderCollapsed,
            onToggle: { withAnimation { isOlderCollapsed.toggle() } }
        )
    }

    // 2. chatWithPhases 渲染 (内部用 visibleEnd 截断)
    chatWithPhases(
        visibleRange: (totalPhases - visibleEnd)..<totalPhases,
        phaseSummaries: chatBridge.phaseSummaries,
        allSummariesByMessageID: summariesByMessageID,
        allMessages: settledItems,
        forceCollapse: chatBridge.collapseAllPhases
    )
} else {
    // === Legacy 模式 (保留原行为) ===
    if windowState.foldThreshold > 0 && settledItems.count > foldThreshold {
        // ... 原有的 fold 按钮 + suffix/prefix
    } else {
        messageRows(settledItems[...])
    }
}
```

### `chatWithPhases` 签名扩展

```swift
private func chatWithPhases(
    visibleRange: Range<Int>,
    phaseSummaries: [PhaseSummary],
    allSummariesByMessageID: [UUID: PhaseSummary],
    allMessages: [ChatMessage],
    forceCollapse: Bool
) -> some View {
    ForEach(Array(phaseSummaries[visibleRange].enumerated()), id: \.element.id) { _, summary in
        // ... 渲染 PhaseSummaryCard 或 MessageBubble
        // 如果 forceCollapse, 用 .environment(\.phaseForceCollapse, true) 注入
    }
}
```

### 一键全折叠

`ChatBridge.collapseAllPhases` 在 `MessageListView.task(id: windowState.currentSessionId)` 块重置为 false。

`PhaseSummaryCard` 接收 `forceCollapse: Bool` 环境值,如果为 true 临时把 isExpanded 强制设为 false(不修改存储的状态)。**这是临时 UI 状态,不影响用户单独点 phase 卡片的展开行为**。

### 占位条组件

```swift
private func phaseFoldPlaceholder(
    hiddenCount: Int,
    isExpanded: Bool,
    onToggle: @escaping () -> Void
) -> some View {
    Button(action: onToggle) {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            Text(isExpanded
                 ? String(format: String(localized: "Collapse %lld earlier phases", bundle: .module), hiddenCount)
                 : String(format: String(localized: "Show %lld earlier phases", bundle: .module), hiddenCount))
        }
        // ... 同原折叠按钮样式
    }
    .buttonStyle(.plain)
}
```

## Risk

| 风险 | 等级 | 缓解 |
|---|---|---|
| 折叠按钮 + phase 卡片视觉混乱 | 中 | 严格按渲染顺序,占位条在最前 |
| `collapseAllPhases` 状态不同步 | 中 | 切 session 重置;PhaseSummaryCard 接 forceCollapse 临时态 |
| 100 cap 阻挡用户看更早内容 | 低 | 占位条"+ 展开 8 个" |
| 重构 `chatWithPhases` 破坏现有 phase 卡片渲染 | 中 | 保留原 PhaseSummaryCard 内部逻辑,只改外层调用 |
| chatWithPhases 接收更多参数后调用点变多 | 低 | 仍只在 MessageListView 内部调用 |

## Verification

1. `xcodebuild ... build` ✓
2. 启动 → 加 phase 卡片 → 折叠按钮出现 → 点"折叠" → 早期 phase 隐藏,占位条出现 ✓
3. 点"一键全折叠" → 所有 phase 卡片收起 ✓
4. 加一个"超过 100 phase"的 session → 验证虚拟化生效 ✓
5. 切 session → `collapseAllPhases` 重置 ✓
6. 端到端启动测试 + 上传 v2.4.3 release ✓

## Self-Review

- **Spec coverage**: 折叠按钮恢复 ✓ / 一键全折叠 ✓ / 虚拟化 ✓
- **Placeholder scan**: 无 TBD
- **Internal consistency**: 折叠逻辑两条路径(legacy + phase)都覆盖
- **Scope check**: 2 文件改动(ChatBridge, MessageListView)+ 1 文件版本号(commit)
- **Ambiguity check**: "全折叠" 定义为临时 UI 覆盖(不修改存储的 isExpanded 状态)— 明确
