# Clarc Bug 审计报告

> **生成时间**:2026-06-05
> **审计范围**:全项目(127 个 Swift 文件,约 30000 行)
> **审计方式**:4 个并行 track + verifier 独立抽查
>
> | Track | 范围 | 文件数 |
> |---|---|---|
> | A — Services & Utilities | `Clarc/Services/*` + `Clarc/Utilities/*` | 11 |
> | B — Core IO / CLI Subsystem | `Packages/Sources/ClarcCore/CLISession/*` + `Utilities/*` | 16 |
> | C — App 状态机 + Core 模型 | `Clarc/App/AppState.swift` + `ClarcCore/{Models,Usage,TaskUpdate,Parsing,Stores,Theme}/*` | ~30 |
> | D — View Layer + ChatKit | `Clarc/Views/**` + `Packages/Sources/ClarcChatKit/**` | ~40 |
>
> **重要声明**:
> - 本报告**仅整理**原 track 报告的发现,**不**新增 bug,也不**修复**任何代码。
> - 所有 file:line 引用已通过 grep 抽样验证(`streamingTail!` ×77、`MainView.swift:157`、`PermissionServer.swift:564`、`BashSafety.swift:48-53,111-114,216-233`、`MarketplaceService.swift:229-256`、`PermissionServer.swift:30,184,331-338,564`、`ClaudeService.swift:494,807`、三处 `Timer.publish` 泄漏,均命中)。
> - Verifier 抽查发现的修正已合并:Track A 的 `\\$(cmd)` claim 经实证为 false positive,已从 🔴 降级;`--flag=value` claim 的例子错(被引用命令不在 allowlist),但底层 bug 真实,本文用 verifier 提供的 `find --delete` / `find --exec=rm` 修正描述。
> - Track D 的 🔴 计数 producer 声称 8,verifier 实际数 7,本文按 verifier 实际数记录。

---

## 严重度统计

| 严重度 | 数量 | 占比 | 含义 |
|---|---:|---:|---|
| 🔴 高 | **32** | 15% | 数据丢失 / 崩溃 / 安全 / 关键资源泄漏 |
| 🟡 中 | **77** | 35% | 边界条件 / 性能 / UX / 状态污染 / 埋雷 |
| 🟢 低 | **111** | 50% | 代码风格 / 死代码 / 文档漂移 / 一致性 |
| **合计** | **220** | 100% | — |

> **跨 track 去重说明**:
> - "force unwrap on `FileManager.default.urls(...).first!`" 在 3 个文件出现 → 拆为 1 条总结 + 3 条具体位置
> - "Timer.publish leak" 在 3 个文件出现 → 拆为 1 条总结 + 3 条具体位置
> - "BashSafety 长选项 bypass" 的不同命令归 1 条(根因一致)
> - 跨 track 提到同一 file:line 的合并为 1 条

---

## 🔴 高严重度(数据丢失 / 崩溃 / 安全 / 关键资源泄漏)

> 排序:**数据丢失 > 崩溃 > 安全 > 资源泄漏 > 关键逻辑错**

### H-01. `streamingTail!` 强制解包在 6 个逻辑块 × 30+ 行裸奔

**位置**:`Clarc/App/AppState.swift:1313-2047`(grep 命中 77 处)
- 1565 / 1574 / 1583-1584(`processStream` case .assistant / .user)
- 1900-1933(`handlePartialEvent` content_block_start/tool_use)
- 1938-1944(content_block_start/text)
- 1950-1972(content_block_start/thinking)
- 1982-1994(content_block_delta 三种)
- 2004-2013(content_block_stop)
- 2016-2047(tool 收尾 + block_stop)

**问题**:`streamingTail` 由 `sendPrompt` 写入,但**没有任何**路径对 `state.streamingTail!` 做 `if let` / `guard` 包裹就开始读写。`finalizeStreamSession`(1312-1348 行)反而老老实实用了 `if state.streamingTail != nil` 包裹 — 不一致。

**触发**:
1. `cancelStreaming`(2125)调 `promoteTailToCommitted` 把 `streamingTail = nil`
2. `Task { [weak self] in await self.cancel(streamId: ...) }` 让出 MainActor
3. processStream 的 for-await 循环里下一个事件到达,closure 内 `state.streamingTail!` **Runtime crash,无 fallback**

**建议修复**:`handlePartialEvent` 顶部加 `guard state.streamingTail != nil else { return }` 兜底,或抽 `mutateTail` helper 做 `if let`。

来源:Track C 1.1

---

### H-02. `applyCompaction` 改了内存但没写盘,跨重启丢失

**位置**:`Clarc/App/AppState.swift:3192-3199`

**问题**:`func applyCompaction` 仅修改 `session.committedMessages` / `compactionRecord` / `session.streamingTail = nil`,**没有** `await saveSession(...)`、没有更新 CLI 的 jsonl、没有 `lastCommittedReloadKey` 更新。
- 下次 `reloadCommittedFromDisk` 会用 disk 上的全量历史覆盖内存里的 compacted 历史(2973 行 `state.committedMessages = cleaned`)
- 跨进程重启后,CLI 收到的还是全量历史 —— 压缩白做

**建议修复**:把新 history 写到 CLI 的 jsonl 文件(`cliStore.directory(forCwd:)` + `{sid}.jsonl`),原文件备份为 `{sid}.jsonl.precompact`。调 `lastCommittedReloadKey[sessionId] = nil` 强制下次 reload 重读。

来源:Track C 1.5

---

### H-03. `selectProject` filter 把 per-session 内存态(model / effort / permissionMode / context%)全丢

**位置**:`Clarc/App/AppState.swift:2300-2305`(`sessionStates = sessionStates.filter { $0.value.isStreaming }`)

**问题**:切项目时把 `SessionStreamState.model`、`.effort`、`.permissionMode`、`.activeModelName`、`.lastTurnContextUsedPercentage`、`lastCommittedReloadKey[sessionId]` 全部丢弃。
- 用户在 session X 上 `/model opus` → 切走 → 切回 → 默认值恢复
- 文档化 2302 行注释"为了少触发 onChange"是性能优化,但代价是数据丢失

**建议**:filter 时只丢"陈旧无引用"状态(`isStreaming == false && allMessages.count == 0 && 不属于当前 window`);per-session 持久化字段应落到 sidecar(类似 `SessionMetaStore`)。

来源:Track C 1.2

---

### H-04. `releaseOutgoingSession` 用错误的 projectId 保存 legacy JSON,跨项目串文件

**位置**:`Clarc/App/AppState.swift:2582-2594`

**问题**:`realProjectId` fallback 是 `window.selectedProject?.id`,而 `summary` lookup 在跨项目时不会用 placeholder 的 projectId。`persistence.saveSession` 把 A 项目的 sessionId 数据写进 B 项目的目录,后续 `deleteSession` 在 A 项目目录找不到,session 残影复活。

**触发**:project A 开新 chat 生成 `pending-uuid-1` 占位 → 立即切到 B 项目 → placeholder 留在 `allSessionSummaries` → 下次 `releaseOutgoingSession` 把 A 数据写到 B。

**建议**:`releaseOutgoingSession` 开头就拒绝 placeholder id:`if outgoingId.hasPrefix("pending-") { return }`。

来源:Track C 1.3

---

### H-05. `SessionMetaStore.save` 缓存先于盘写入 — 写盘失败静默丢

**位置**:`Packages/Sources/ClarcCore/CLISession/SessionMetaStore.swift:59-75`

**问题**:
```swift
public func save(sessionId: String, meta: Meta) {
    cache[sessionId] = meta
    ...
    do { try data.write(to: url, options: .atomic) }
    catch { logger.error("...") }   // 缓存已更新,写盘失败
}
```

写盘失败(disk full / 权限拒绝 / 父目录是文件)→ log 但 cache 已更新。下次 `load` 返回新值,app 重启后 `load` 读旧(或不存在)文件返回空 Meta。用户看到"title pin 重新启动后失效"。

**建议**:在 `save` 成功后再更新 cache,或者写盘失败时回滚 cache。

来源:Track B B-35 (🔴 实际,虽然 Track 标 🟡 概率)

---

### H-06. placeholder `pending-<uuid>` 生命周期不闭环

**位置**:`Clarc/App/AppState.swift:1185-1196`(创建)、`2173`(cancelStreaming 清理)、**缺失**:`selectProject` / `startNewChat` / 进程重启

**问题**:
| 事件 | 清理位置 | 漏掉的清理 |
|---|---|---|
| 流正常完成 → init 事件 | `allSessionSummaries.removeAll`(1520) | OK |
| `cancelStreaming` | `window.removePendingPlaceholder`(2173) | OK |
| `selectProject` | **没有** | 切项目时 placeholder 留在 `allSessionSummaries` 和 `pendingPlaceholderIds` |
| `startNewChat` | **没有** | 同上 |
| 进程重启 | **没有** | placeholder 仅在内存,丢失 UI 标记但 disk 会有空白 summary 复活 |

**触发**:用户立刻按"切换项目" → filter 丢 sessionStates,但**没碰** `allSessionSummaries` 和 `pendingPlaceholderIds` → sidebar 出现永不消失的"新对话 空消息"。

**建议**:`selectProject` 内部在 filter 前清 placeholder 列表:
```swift
for id in window.pendingPlaceholderIds {
    allSessionSummaries.removeAll { $0.id == id }
}
window.pendingPlaceholderIds.removeAll()
```

来源:Track C 1.4

---

### H-07. `MainView.swift:157` force unwrap on `@Observable` state — 唯一会 crash 的 view-layer bug

**位置**:`Clarc/Views/MainView.swift:157`
```swift
FileTreeView(projectPath: windowState.selectedProject!.path, searchTrigger: $fileSearchTrigger)
```

**问题**:上一行 `if windowState.selectedProject != nil` guard 通过,但 SwiftUI 在 guard 和表达式之间可能因 `onChange` 触发重新求值 `body`,此时 `selectedProject` 可能已被另一路径置 nil → `Fatal error: Unexpectedly found nil`。

**建议**:在 computed property 顶部 `guard let project = windowState.selectedProject else { return AnyView(EmptyView()) }`,然后用 `project.path` 安全访问。

来源:Track D issue 1 / 199 (verifier 复核确认,优先级 🔴)

---

### H-08. `SlashCommandManagerView.swift:551` `command!.name` force unwrap — view-layer crash 风险

**位置**:`ClarcChatKit/SlashCommandManagerView.swift:551`
```swift
Button { ... SlashCommandRegistry.originalDefault(name: command!.name) ... }
```

**问题**:`command: SlashCommand?` 在 `isEditing && isDefault` 分支被使用(549 行),但 `isEditing` 是 computed property,编译器无法证明 `command` 非 nil。`command` 为 nil 时 crash。

**建议**:`guard let command else { return }` 提到闭包顶部,或用 `if let command` 包整个 button。

来源:Track D issue 165

---

### H-09. `TerminalProcess` 非 `@MainActor` 隔离 — Swift 6 严格并发编译失败 + 写竞争

**位置**:`Clarc/Views/Terminal/TerminalView.swift:178, 232, 260`
```swift
@State private var process = TerminalProcess()  // class, var terminalView: LocalProcessTerminalView?
```

**问题**:`TerminalProcess` 是非 Sendable、非 actor 隔离的 class,`var terminalView` 可变。SwiftUI view tree 重建时,新的 `EmbeddedTerminalView.makeNSView` 在 `process?.terminalView = tv`(64 行) 写入新 tv,旧的已被 deinit 终止。但 SwiftUI 更新与 `dismiss()` 之间存在写竞争。Swift 6 strict concurrency 直接编译失败。

**建议**:把 `TerminalProcess` 标 `@MainActor`,或改为 `actor`。

来源:Track D issue 23

---

### H-10. `InspectorMemoPanel.swift:56-72` `NSAlert.runModal()` + `alert.window` nil — URL 输入框不获焦 + run loop 阻塞

**位置**:`Clarc/Views/Inspector/InspectorMemoPanel.swift:56-72`(`addLink`)

**问题**:
- `runModal()` 阻塞主 run loop,任何 in-flight NSTextView first-responder recovery 都被冻结
- 更严重:`alert.window.initialFirstResponder = field` 在 `runModal()` 之前 — `alert.window` 此时是 `nil`!runModal 创建 window 但 initialFirstResponder 赋值已丢失
- 实际后果:URL text field **不自动获焦**

**建议**:换 SwiftUI `.alert` + `TextField` 或自定义 NSPanel。

来源:Track D issue 11

---

### H-11. `InspectorMemoPanel.swift:251-253` `MemoContext` 以 `let` 传递而非 `@Bindable` — toolbar 不刷新 + ⌘K 早触发 nil 崩溃

**位置**:`Clarc/Views/Inspector/InspectorMemoPanel.swift:251-253`(`MemoFormattingToolbar`)

**问题**:
- `let memoContext: MemoContext` 传递到 toolbar,`memoContext.textView` 在 299 行设置后 toolbar **不会重新渲染**
- `textView` 在 Coordinator 上设置(299 行)晚于 `setupKeyMonitor`(301 行)。key monitor 捕获 `[weak textView, weak memoContext]`,首次 launch 任何 ⌘K 在 view layout 完成前触发 → `textView == nil` → 崩溃

**建议**:`@Bindable var memoContext = memoContext` 包装,或在 toolbar 用 environment 传值。

来源:Track D issue 12

---

### H-12. `MessageListView.swift:671` 第三处 `Timer.publish` 泄漏 — `ElapsedTimeView` 永不释放

**位置**:`Packages/Sources/ClarcChatKit/MessageListView.swift:671`
```swift
private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
```

**问题**:producer track 漏标,verifier V1 补漏。`ElapsedTimeView` 嵌入 `StreamingIndicatorView`,每次 stream 开始实例化一次;长 session 中 stream 反复开始/结束,多个 ElapsedTimeView 实例累积,每个跑一个 1Hz timer 永驻。

**建议**:见 H-13。

来源:Track D verifier V1

---

### H-13. `Timer.publish(...).autoconnect()` 内存泄漏 pattern(3 处,verifier 补漏到 3)

**位置**:
- `Clarc/Views/Permission/PermissionModal.swift:13`
- `Packages/Sources/ClarcChatKit/Views/TaskUpdateCard.swift:12`
- `Packages/Sources/ClarcChatKit/MessageListView.swift:671` ← **verifier 补漏**

**问题**:`private let timer/ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()` 在 View 上作为 stored `let`,每次 SwiftUI 重新实例化(theme change、parent re-render)都新建一个 Timer.publish,旧的 Cancellable 不取消 → 100 张 task card = 100 个 1Hz timer 永驻。

**建议**:存到 `@State`,或用 `TimelineView`。

来源:Track D issues 32 / 149 / V1

---

### H-14. BashSafety 长选项 bypass — `find --delete` / `find --exec=rm` 等**当前可立即复现**的高严重度

**位置**:`Clarc/Services/BashSafety.swift:216-233`(`hasWriteCapableArg`)

**根因**:`writeCapableFlags["find"]` 集合**全部是短形式**(`-exec`、`-execdir`、`-ok`、`-okdir`、`-delete`、`-fls`、`-fprint`、`-fprintf`、`-touch`),**没有长形式**(`--exec`、`--delete`、`--fls` 等)。
`hasWriteCapableArg` 对 `--xxx` 形式用 `flags.contains(arg)` 精确匹配 → 完全不命中 → 放行。

**Verifier 独立验证的真实可复现 bypass**:
```
find /tmp --delete              → APPROVED (BYPASS,实际删除 /tmp 下文件)
find /tmp --exec=rm             → APPROVED (BYPASS,实际执行 rm)
find /tmp --fls=/tmp/output     → APPROVED (BYPASS,实际写文件)
find /tmp --fprint=/tmp/output  → APPROVED (BYPASS,实际写文件)
find /tmp --ok=rm               → APPROVED (BYPASS,实际执行 rm)
```

对应短形式被正确拦截:
```
find /tmp -delete               → BLOCKED (correct)
find /tmp -exec rm              → BLOCKED (correct)
```

**复现**:`find` 在 `safeCommands` 白名单(line 17-46),走完 base 检查,进入 `hasWriteCapableArg` → `--xxx` 不命中 → 返回 `true` → `isSafeReadOnly` 放行。

**UI 路径**:`PermissionServer.swift:287` 的 PreToolUse 自动审批会基于 `isSafeReadOnly` 决定,UI 看到 "Bash 工具运行只读命令" → 自动批准 → 静默写盘/执行任意命令。

**建议**:补全 `writeCapableFlags["find"]` 缺失的长形式:`--exec`、`--execdir`、`--ok`、`--okdir`、`--delete`、`--fls`、`--fprint`、`--fprintf`、`--touch`,以及 GNU find 文档里其他 `--xxx` 长选项。

来源:Track A claim 1(verifier 修正描述)+ 已知 verifier 修正

---

### H-15. BashSafety `git` 子命令白名单不全 + 全局 flag 旁路

**位置**:`Clarc/Services/BashSafety.swift:48-53`(`gitMutatingSubcommands`)+ 188-204(检查逻辑)

**问题**:
1. **`git config` 漏入**:`claudeMutatingSubcommands` 含 `config`,但 `gitMutatingSubcommands` 没含 → `git config user.email "x"` 写 `~/.gitconfig` → 自动批准
2. **全局 flag 旁路**:检查逻辑(行 188-204)只读 `parts[cmdIdx + 1]`,带全局 flag 时 sub 就是 flag 本身:
   ```
   git -C /repo push         # sub = "-C", 放行, 实际 push 触发
   git --no-pager push       # sub = "--no-pager", 放行
   git -c http.proxy=... clone  # 类似
   ```
3. **漏掉的写子命令**:`remote add/remove/set-url/rename`、`update-ref`、`notes add/append/edit`、`reflog expire`、`sparse-checkout set/add`、`maintenance run`、`bundle`、`replace`

**复现**:`git -C /repo push` 在 `safeCommands` 白名单内 → 放行 → push 触发。

**建议**:
1. `sub` 解析跳过所有以 `-` 开头的全局 flag,继续向后找第一个非 flag token
2. 把 `config`/`remote`/`update-ref`/`notes`/`sparse-checkout`/`maintenance`/`replace`/`bundle` 加入 `gitMutatingSubcommands`
3. 改"先拒绝任何未列入已知 read-only 子命令的调用"为兜底

来源:Track A claim 3(verifier 已独立验证)

---

### H-16. ClaudeService 进程 spawn 失败时 Pipe FD 泄漏

**位置**:`Clarc/Services/ClaudeService.swift:371-489`(`send` 整体)+ `677-686`(catch 分支)

**问题**:
- `send` 创建 3 个 Pipe:`stdin` / `stdout` / `stderr`(371-373 行)
- `continuation.onTermination` 只关 `stdout.fileHandleForReading`,**没关** stdin 写端、stdout 写端、stderr 读端
- `Pipe` 和 `FileHandle` **不**在 ARC 释放时自动 `closeFile()`。要等 Process 析构(若已 start)或 GC
- 如果 `proc.run()` 直接失败、连 process 都没启动,FD 一直挂到 send 函数返回、Task closure 释放为止。closure 释放 Pipe 也只是 deinit,不会 close

**复现**:反复打开连接、binary 不存在或 prompt 写入失败,长跑后 `lsof -p <pid> | grep PIPE` 看到一堆孤儿 pipe。

**建议**:catch 分支手动 `try? stdin.fileHandleForReading.closeFile(); ...`,或顶部用 `defer` 保证清理。

来源:Track A claim 4(verifier 已验证)

---

### H-17. ClaudeService.cleanup() 和 PermissionServer.stop() 永远不被调用

**位置**:
- `Clarc/Services/ClaudeService.swift:807-816`(`func cleanup()`)
- `Clarc/Services/PermissionServer.swift:184-212`(`func stop()`)

**问题**:`rg "claude\.cleanup\|claudeService\.cleanup\|permission\.stop\|permissionServer\.stop" Clarc/` 在源码层 **0 命中**(仅 track 报告自身引用)。
- **ClaudeService.cleanup()** 不被调用 → app quit 时所有 in-flight claude 进程被 `interrupt()`(SIGINT)但不等待、不发 SIGKILL;`processes`/`stdinHandles` 字典不释放,5 秒延迟 SIGKILL 任务也不会被取消(无主 Task)
- **PermissionServer.stop()** 不被调用 → `tempSweepTask` 不被取消、生成的 hook 文件不删、`subscribers` 不被 finish

**复现**:任何 quit 路径(用户 Cmd+Q、NSApp.terminate、crash)都不触发清理,进程级资源被 OS 强制回收。

**建议**:在 `NSApplicationDelegate.applicationWillTerminate(_:)` 或 `App` 的 `onChange(of: scenePhase)` 走到 `.background`/`.inactive` 阶段时,主动 `await claude.cleanup()` 和 `await permission.stop()`。

来源:Track A claim 5(verifier 已验证)

---

### H-18. ClaudeService.cancel 5s SIGKILL 任务无主 + PID 复用可杀错进程

**位置**:`Clarc/Services/ClaudeService.swift:494-510`(`cancel`)

**问题**:
```swift
func cancel(streamId: UUID) {
    ...
    Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if process.isRunning {
            kill(pid, SIGKILL)   // ← PID 复用可致杀错无辜进程
        }
    }
}
```

- `Task { }` 是 unstructured,不被任何对象持有。即使 `ClaudeService` 析构,任务继续
- 5 秒内原进程已退出并被 reap,macOS 把同 PID 分配给新进程 → 杀无辜进程
- CI/重负载机器上更常见

**建议**:用 `terminationHandler` 回调替代 wallclock sleep,或者 capture `process` 时记下 `startTime`,sleep 后用 `kill(pid, 0)` 验证身份。

来源:Track A claim 6

---

### H-19. PermissionServer bash_allowlist decode 失败静默丢(无 corrupted 备份)

**位置**:`Clarc/Services/PermissionServer.swift:568-579`(`loadBashAllowlistIfNeeded`)

**问题**:
```swift
guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(...) else {
    bashCmdAllows = [:]   // ← 静默清空
    return
}
```

对比 `PersistenceService.decode`(249-252)会移动到 `corrupted-*.json` 备份,**这里没有类似保护**。JSON 一旦被外部进程破坏(iCloud sync 冲突、Time Machine 中途恢复、磁盘满写一半),allowlist 静默丢失,所有 `allowAlwaysCommand` 失效,用户得重新勾选。

**复现**:iCloud Documents 同步 Clarc config(如果用户开了),文件系统出错,或磁盘满时写一半。

**建议**:仿 `PersistenceService.decode` 的备份策略,decode 失败 rename 到 `bash_allowlist.corrupted-<ts>.json` 再设空。

来源:Track A claim 7(verifier 已验证)

---

### H-20. MarketplaceService 找不到 Homebrew 安装的 claude(绝大多数 macOS 开发者踩中)

**位置**:`Clarc/Services/MarketplaceService.swift:229-256`(`runCLI`)

**问题**:
```swift
process.environment = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    ...
]
```

`env` 的 PATH 是 GUI 进程的 PATH(macOS GUI app 默认 `/usr/bin:/bin:/usr/sbin:/sbin`)。
**不包含** `/opt/homebrew/bin`(Apple Silicon Homebrew)、`/usr/local/bin`(Intel)、`~/.local/bin`、`~/.npm-global/bin`。

`/usr/bin/env claude` 按这个 PATH 找 → 找不到 → exit 127 → `MarketplaceError.installFailed(installArg)` 抛错,stderr 整体作为 `_` 丢掉,UI 只看到插件名不知道原因。

**复现**:用 `brew install claude-code` 装 → App 中浏览 Marketplace → 点 Install → exit 127 → 失败。

**建议**:抽出共享的 `resolvedEnvironment()` 工具(ClaudeService 已有,private),或显式补 `/opt/homebrew/bin` 等。

来源:Track A claim 10(verifier 已验证)

---

### H-21. SSHKeyManager pinned keys 不含 RSA — 严格 OpenSSH 配置下必失败

**位置**:`Clarc/Utilities/SSHKeyManager.swift:156, 199-204`

**问题**:`pinnedGitHubPublicKeys` 集合只有 ed25519 和 ecdsa-sha2-nistp256 两个 key 的 base64 body,**没有 RSA**。`-t ed25519,rsa,ecdsa` 会请求三种 key 类型,GitHub 返回三种,过滤后只剩 ed25519 + ecdsa,RSA 全被过滤。

**触发**(虽然不是每次都炸):
- OpenSSH 8.5+ 默认禁用 SHA-1 RSA,某些配置下 keyscan 不返回 ed25519 或 ecdsa
- FIPS 模式
- GitHub 未来 key rotation

如果用户机器的 OpenSSH 配置 `PubkeyAcceptedAlgorithms` 排除了 ed25519 和 ecdsa,keyscan 输出对客户端是空的 → `acceptedKeys` 空 → throw `keyscanFailed` → SSH config 已写入但 `known_hosts` 没 github.com → **首次 push 时会问 user 是否信任 host fingerprint**。

**建议**:维护完整 GitHub 公开 key 列表(含所有 RSA);失败 fallback 提示用户手动 `ssh-keyscan github.com >> known_hosts`。

来源:Track A claim 11(verifier 已验证)

---

### H-22. CLISessionStore.forkSession regex 重写所有 `"sessionId"`(嵌套结构会误伤)

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:558-564`(`rewriteSessionId`)

**问题**:
```swift
line.replacingOccurrences(
    of: #""sessionId"\s*:\s*"[^"]*""#,
    with: "\"sessionId\":\"\(newSid)\"",
    options: .regularExpression
)
```

正则匹配任何 `"sessionId":"…"` 子串,所以如果一行内嵌了另一个 json blob(也含 `sessionId` 字段),内层会被改写成相同的新值。

**现状**:CLI envelope 行不嵌套,latent。但**未来一行带** `{"sessionId":"x","message":{"content":[…,"sessionId":"y"]}}` 会静默损坏内层字段。

**严重性 🔴**:迁移目标是"CLI 下次会读的行",一次 bad rewrite 就会 brick resumed fork。

**建议**:用 lookbehind 锚定 `"uuid":…,"parentUuid":` 之前,或仅在第一个 `"message":` 之前的子串运行正则。或直接 `JSONDecoder` + `JSONEncoder` 解析。

来源:Track B B-01

---

### H-23. CLISessionStore.loadSummaries sniffCache 无上限 — 长期内存泄漏

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:181-194`

**问题**:`loadSummaries(cwd:)` 只看到 **一个** cwd 下的文件,但 `sniffCache` 只按 sid 索引,**不含 cwd 组件**。两项目同 sid(技术上 UUID 不会)会冲突;项目 session 全删后,缓存条目永远留下。

**严重性 🔴**:在长期跑、多项目的 app 中是真实泄漏。

**建议**:把 cwd 加到 cache key,或加 size cap + 主动 prune。

来源:Track B B-02

---

### H-24. CLISessionStore.forkSession Date 精度匹配脆弱(Track 评 🔴,建议 🟡)

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:472-488`

**问题**:
```swift
if let ts = u.timestamp, ts == messageTimestamp { ... }
```

`messageTimestamp` 来自 UI 的 `ChatMessage.timestamp`,正常流下 `JSONDecoder` 策略一致 → 相等性成立。但:
- 如果 UI 端把 timestamp 截到秒精度(目前没有,字段是 `Date` 不是 String),用户点击被四舍五入,匹配返回 nil → "fork failed"
- 同一毫秒内两条 CLI 事件,`truncIndex` 被覆盖,**最后**一条赢

**建议**:`timeIntervalSince1970` rounded + uuid tiebreaker。

来源:Track B B-03

---

### H-25. CLISessionStore.exposeToPicker 与 CLI 同时写,丢尾部行(Track 评 🔴)

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:429-431`(`exposeToPicker`)

**问题**:`PickerExposer.normalize` 通过 `liveSessionIds()`(文件存在性)做 live-session 检查,TOCTOU:check 与 `replaceItemAt` 之间 CLI 可继续写。`replaceItemAt` 在 FS 级别原子,新文件总是合法 jsonl,但**丢 CLI 写的新行**。

来源:Track B B-10

---

### H-26. PickerExposer `replaceItemAt` 嵌套 atomic rename — `.atomic` + `replaceItemAt` 双重保险(Track 评 🔴)

**位置**:`Packages/Sources/ClarcCore/CLISession/PickerExposer.swift:88-99`

**问题**:`Data.write(to:options: .atomic)` 已创建 tmp 文件并 atomic rename,然后 `replaceItemAt(url, withItemAt: tmp)` 再 atomic rename 一次。2× FS 工作 + error path 仍可能让目标不一致。Track B 写"实际是 fine",但仍保留 🔴 标记。

来源:Track B B-30

---

### H-27. GitHelper stderr 未 drain — 大 stderr 触发死锁

**位置**:`Packages/Sources/ClarcCore/Utilities/GitHelper.swift:15-18, 31`

**问题**:
```swift
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = Pipe()   // ← 创建但不读
...
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```

macOS pipe 缓冲默认 64KB。如果 git 写 stderr 超过 64KB(git status 在损坏的大 repo,`git fetch` 的 verbose error),子进程 `write(2)` 阻塞 → 父进程 `wait4` 阻塞 → 死锁。

**当前 caller**(`symbolic-ref --short HEAD`)输出 ~50 字节,实际不会触发,但 helper 是 `public` 工具,其他潜在调用者会踩。

**建议**:在后台 Task drain stderr,或用 `FileHandle` 与 `withCheckedContinuation` 并发读。

来源:Track B B-50

---

### H-28. GitURLHelpers.parseGitHubOwnerRepo 误判 host(子串匹配)

**位置**:`Packages/Sources/ClarcCore/Utilities/GitURLHelpers.swift:6-17`

**问题**:
```swift
public func parseGitHubOwnerRepo(from urlString: String) -> String? {
    guard urlString.contains("github.com") else { return nil }
    let cleaned = urlString.replacingOccurrences(of: "https://github.com/", with: "")  // ← 字符串替换
    ...
}
```

如果用户传 `https://evil.com/?ref=github.com/foo` 或 `https://notgithub.com.evil.com/owner/repo`,函数返回 `owner/repo`(junk)。

**严重性**:安全相关上下文(URL 来自远程)为 🔴。

**建议**:用 `URL(string:)` + `host == "github.com"` 精确比较。

来源:Track B B-56

---

### H-29. JSONPathParser offset 跟踪是 stub(用户配置排错无定位)

**位置**:`Packages/Sources/ClarcCore/Usage/JSONPath.swift:175-176`(and 52, 66, 86, 101, 106, 109, 111, 114, 120, 124, 154)

**问题**:
```swift
private static func pathDebugOffset() -> Int { 0 }
```

所有 `JSONPathParseError` 的 offset 字段全是 0。用户配置错误 JSON path 时,错误信息 `JSONPathParseError.unexpectedCharacter(".", 0)` 全部指向 offset 0,无法定位。

注释自承"Placeholder for offset tracking"。

**建议**:把 `parseComponent` / `parseBracketSegment` 等改为传 `position: Int` 参数,每次 `iterator.next()` 递增。

来源:Track C 6.1(Track 评 🔴 严重度)

---

### H-30. SettingsView 本地化三种模式混合 — 中英文硬编码混杂

**位置**:`Clarc/Views/Settings/SettingsView.swift`(23, 28, 33, 39, 124, 140, 156, 189-192, 200, 213, 230, 244, 271, 291, 315, 321, 331, 343, 430, 490, 493, 575, 627, 630, 654, 657, 681, 684, 710, 712, 717, 729, 734, 736, 750, 762, 774, 777, 782-785)

**问题**:Settings UI 混了三种模式:
1. `Text("字体大小")` — **中文硬编码**(不是 key,不是 `LocalizedStringKey` 初始化器),在非中文 locale 下死
2. `Text("Interface")` — 英文硬编码 via `LocalizedStringKey`
3. `Text("font.size.hint")` — `.strings` key(无 `LocalizedStringKey` 初始化器,但 `Text` 默认把 `String` 当 `LocalizedStringKey`)

**审计建议**:跑 `plutil -lint` 对 `en.lproj/Localizable.strings`、`ko.lproj/Localizable.strings`、`zh-Hans.localizable/Localizable.strings` 三个文件,如果 `font.size.hint`、`usage.provider.desc`、`usage.minimax.note`、`focus.mode.desc`、`auto.preview.desc`、`Fold threshold description` 任一缺失,用户看到原始 key。

来源:Track D issue 88

---

### H-31. BashSafety `!` 解包应用支持路径(埋雷,真开启 sandbox 不会崩)

**位置**:`Clarc/Services/PermissionServer.swift:564`

**问题**:
```swift
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
```

`CLAUDE.md` 明确说"App Sandbox disabled" — 当前不沙盒,`urls(...)` 永远非空。若未来开启沙盒,`urls(for: .applicationSupportDirectory, in: .userDomainMask)` **仍**非空(沙盒下 ApplicationSupport 仍可用)。所以 `!` 不会崩。

**保留 🔴 是因**:埋雷。Track A verifier 没显式降级。

**建议**:改 `guard let ... else { throw }` + 抛错。

来源:Track A claim 8

---

### H-32. PermissionServer listener `.cancelled` 状态未处理 — listener 泄漏

**位置**:`Clarc/Services/PermissionServer.swift:155-178`

**问题**:
```swift
l.stateUpdateHandler = { [weak l] state in
    switch state {
    case .ready: ...
    case .failed(let error): l?.cancel()
    default: break   // ← .cancelled 不 cancel
    }
}
```

端口 0/1 的 POSIX 限制下,NWListener 可能在 `.cancelled` 状态(用户权限拒绝),`stateUpdateHandler` 不会被调到 `.failed`,而是 `.cancelled`,`default` 分支不 cancel。`l?.cancel()` 不调。

**保留 🔴**:埋雷。

**建议**:`default: l?.cancel()` 或显式处理 `.cancelled`。

来源:Track A claim 9

---

## 🟡 中严重度(边界条件 / 性能 / UX / 状态污染)

> 排序:用户感知度优先

### M-01. BashSafety token 切分不识别引号 — quoted arg 中的 `=`、flag 走错分支

**位置**:`Clarc/Services/BashSafety.swift:166`
```swift
let parts = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
```

**问题**:用 `String.split(separator: " ")` 直接按空格切,没有引号识别。
- `cat "foo bar"` → parts = `["cat", "\"foo", "bar\""]`,sub = `"foo`,实际子命令丢失
- 真正不安全: `git \"-C\" /repo push` → sub = `\"\"-C\"\"` 不命中 `gitMutatingSubcommands` → push 仍 bypass

**建议**:写最小 shell 词法分析器,识别单/双引号、转义。

来源:Track A(与 H-15 同源)

---

### M-02. BashSafety safeCommands 中混入实际可写命令(社会工程风险)

**位置**:`Clarc/Services/BashSafety.swift:17-46`

**问题**:`mdfind`(Spotlight 索引查询 — 允许 query 任何 metadata,有隐私读)、`printenv`(暴露所有环境变量,可能在终端历史中泄露密钥)、`sw_vers` / `system_profiler`(输出大量机器信息,可能 fingerprinting)。无 flag 检查。

**建议**:单独审计白名单中每个命令的 `-` flag 集合。

来源:Track A

---

### M-03. ClaudeService `readStderr` 整块 UTF-8 解码失败时静默丢

**位置**:`Clarc/Services/ClaudeService.swift:736-751`(`readStderr`)

**问题**:`String(data: data, encoding: .utf8)` 严格转换,任何字节不能解析为合法 UTF-8 整段返回 `nil`,整段被丢。CLI stderr 夹杂非 UTF-8 字节时丢失。

**建议**:改用 `String(decoding: data, as: UTF8.self)`(replacement char `U+FFFD`)或 fallback。

来源:Track A

---

### M-04. ClaudeService readStderr 多 chunk 顺序不可控,可能乱序

**位置**:`Clarc/Services/ClaudeService.swift:748`

**问题**:多个 readabilityHandler 回调 spawn `Task { await self?.appendStderr(...) }`,如果两个 chunk 调度顺序与产生顺序相反,buffer 内容会乱序。

来源:Track A

---

### M-05. ClaudeService spawn 失败清理用 `proc.terminate()`(SIGTERM),CLI 可能忽略

**位置**:`Clarc/Services/ClaudeService.swift:667-668, 681-682`

**问题**:Node 派生的 CLI 经常因 graceful-shutdown 陷阱被拦截,`terminate()` 发 SIGTERM,CLI 立即不响应。

**建议**:同 `cancel()` 路径用 SIGINT+SIGKILL 两步,或直接调 `self.cancel(streamId:)`。

来源:Track A

---

### M-06. ClaudeService `cleanup()` 不调度 SIGKILL 兜底

**位置**:`Clarc/Services/ClaudeService.swift:807-816`

**问题**:`process.interrupt()` 发 SIGINT 但不响应时,没等子进程退出,直接清字典。后续 terminationHandler 来了 no-op。**没启动 SIGKILL 兜底** → 不响应 SIGINT 的进程会一直活到 OS 强收。

**建议**:cleanup 应 cancel 每个 streamId 并 `await` 实际退出,或启动 SIGKILL timer。

来源:Track A

---

### M-07. ClaudeService `runShellCommand` 无超时,stderr 丢到 `/dev/null`

**位置**:`Clarc/Services/ClaudeService.swift:773-802`

**问题**:
- `proc.standardError = FileHandle.nullDevice` — stderr 完全丢弃
- `await withCheckedContinuation` 永远不返回(claude --version 死锁时)
- `compactSession` 失败时返回空字符串 → UI 看到"成功但空白"

**建议**:合并 stderr 进 stdout,加 timeout,`compactSession` 必须检测空输出并 throw。

来源:Track A

---

### M-08. ClaudeService `consumeSessionId` 在 `result` 事件迟到时丢失

**位置**:`Clarc/Services/ClaudeService.swift:712-733, 622-635`

**问题**:CLI 在 process 退出前未发出 `session_id` 字段 → `consumeSessionId` 返回 nil → `exposeToPicker` 不调 → session 在 picker 看不到。

**建议**:在 `recordSessionId` 失败/迟到时 fallback 到 cliStore on-disk metadata,或加超时 fallback。

来源:Track A

---

### M-09. GitHubService `pollForToken` 不重试网络错误

**位置**:`Clarc/Services/GitHubService.swift:94-159`

**问题**:任何非 200 状态、URLError(瞬断 VPN/wifi)都抛 `apiError`,退出循环。用户得手动重试整个 device flow。

**建议**:网络错误 catch 后 continue + 退避,429 (rate limit) 也 continue + 增加 interval。

来源:Track A

---

### M-10. GitHubService `fetchRepos` 无最大页数限制

**位置**:`Clarc/Services/GitHubService.swift:203-216`

**问题**:`while true { ... if repos.count < 100 { break } }` 在 edge case 下无限循环。1000+ repos 组织账户走 10+ RTT,可能触发 GitHub secondary rate limit。

**建议**:加 `maxPages = 20` 上限,加 `Task.sleep(for: .milliseconds(200))` 间隔。

来源:Track A

---

### M-11. GitHubService `cloneRepo` stderr 读取与终止顺序竞争

**位置**:`Clarc/Services/GitHubService.swift:281-297`

**问题**:`readDataToEndOfFile()` 阻塞调用执行在 main thread / actor。git stderr > 64KB 时写端 SIGPIPE 失败,我们读 readDataToEndFile 但**写端已关,可能丢尾数据**。

**建议**:用 `readabilityHandler` 或 drain pipe 提前读。

来源:Track A

---

### M-12. MarketplaceService `runCLI` timeout 30s — SIGKILL 不响应时 actor hang

**位置**:`Clarc/Services/MarketplaceService.swift:229-287`

**问题**:timeout 任务强引用 `box` 但无 cancel 路径。SIGKILL 失败(进程 uninterruptible 状态)时 continuation 永不 resume。

**建议**:在 `withCheckedContinuation` 外加 `Task { try? await Task.sleep(...); if !done { continuation.resume(returning: ("timeout", -1)) } }` 兜底。

来源:Track A

---

### M-13. MarketplaceService `installedPluginNamesFromDirectoryScan` 误把 cache 目录当插件

**位置**:`Clarc/Services/MarketplaceService.swift:192-206`

**问题**:`~/.claude/plugins` / `~/.claude/skills` 下所有非隐藏目录当插件名,`cache`、`tmp`、`backups` 等子目录被当成已装插件。安装/卸载 UI 显示错误的"已装"状态。

**建议**:白名单:只接受符合 `name@marketplace` 格式的目录,或读 `installed_plugins.json` 优先。

来源:Track A

---

### M-14. NotificationService `onNotificationTapped` 闭包读写保护不一致

**位置**:`Clarc/Services/NotificationService.swift:17, 105-118`

**问题**:`@MainActor` 类上 `var` 闭包可被任何持有者赋值,无 setter 验证。`@MainActor` 类的 property 由 actor isolation 保护,但 `var` 而非 `let`,潜在 setter 多线程 race。

**建议**:改 `private(set) var`,或私有存储 + public setter 方法。

来源:Track A

---

### M-15. PermissionServer `waitForDecision` timeout 任务在 respond 后才 cancel,有窗口期 race

**位置**:`Clarc/Services/PermissionServer.swift:498-532`

**问题**:actor FIFO 保证 `respond` 和 `cancelPendingIfNeeded` 串行,但**业务语义上还是 race**:UI 点的瞬间 timeout 刚到,UI 看到的是 deny。

**建议**:在 `respond` 中先查 `pending`,如果已被 timeout 清掉(已 resume 为 deny),不要覆盖。

来源:Track A

---

### M-16. PermissionServer `runToken` 变化时旧 hook URL 仍可能被旧进程命中

**位置**:`Clarc/Services/PermissionServer.swift:30, 331-338, 440-450`

**问题**:旧 CLI 进程的 hook URL 仍带旧 runToken。旧 CLI 退出前发请求到 PermissionServer,server runToken 已是新值,验证失败 → 403。旧 CLI 可能因 403 卡住或重试。

**建议**:旧 runToken 保留 N 秒 grace,或接受新 token 但回退到旧 hook pending 列表查找。

来源:Track A

---

### M-17. PermissionServer `generatedHookFiles` 崩溃时残留

**位置**:`Clarc/Services/PermissionServer.swift:66-74, 391-423`

**问题**:`stop()` 删文件,但 `stop()` 从未被调用(H-17)。兜底 sweep 1 小时间隔,意味着 crash 后 24h 内残留。开发者高频启动时 temp dir 累积。

**建议**:启动时立即 sweep 一次,或 `stop()` 在 `NSApp.terminate` 路径主动调。

来源:Track A

---

### M-18. PersistenceService 损坏备份文件名 1 秒精度 — 同秒多次失败会覆盖

**位置**:`Clarc/Services/PersistenceService.swift:249-252`

**问题**:
```swift
let backupURL = url.deletingPathExtension()
    .appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970)).json")
try? fm.moveItem(at: url, to: backupURL)
```

`Int(Date().timeIntervalSince1970)` 秒级时间戳。1 秒内 N 个 session json 同时损坏,所有 N 个文件被改名成同一个名。`FileManager.moveItem` 目标已存在时抛错,`try?` 吞,**源文件没动**(move 原子),**坏源文件永远留在坏状态**,下次 decode 再次失败,累积 N 个坏文件**永远没人能 recover**。

**建议**:用 `UUID().uuidString` 后缀,或加进程 PID。

来源:Track A

---

### M-19. PersistenceService `loadLegacySessionSync` 在 main thread 同步读盘

**位置**:`Clarc/Services/PersistenceService.swift:190-196`

**问题**:`nonisolated func loadLegacySessionSync(...)` 标注 nonisolated,函数体**同步阻塞**。从 MainActor 调用时,UI 线程阻塞等磁盘。磁盘满/损坏文件/iCloud sync 抢锁时秒级卡顿。

**建议**:全部走 actor 的 `loadFullSession(summary:cwd:)` async 路径,删除 sync 入口。

来源:Track A

---

### M-20. RateLimitService OAuth token 持久化覆盖 keychain 项前未读取验证

**位置**:`Clarc/Services/RateLimitService.swift:188-219`

**问题**:写 keychain 不去重,失败只 log 不 throw。如果 Claude CLI 用 `account != nil`,我们 save 用 `account: nil` → **两条 keychain 项共存**,keychain prompt 问 user 选哪个。

**建议**:先 read,有则 in-place update 保留 account;失败 throw 让 caller 决定。

来源:Track A

---

### M-21. RateLimitService `fetchUsage` 缓存命中后,`authFailed` 状态可能陈旧

**位置**:`Clarc/Services/RateLimitService.swift:28-99`

**问题**:`cached` 一旦设,5 分钟内复用。期间 token 失效(GitHub 改了 keychain、token revoke),`authFailed` 只在 cache miss 时被设。

**建议**:cache hit 时也跑 token expiry 检查,或把 `authFailed` 当 cache 失效信号。

来源:Track A

---

### M-22. KeychainHelper `runSecurity` 同步阻塞 — 主线程使用会冻 UI

**位置**:`Clarc/Utilities/KeychainHelper.swift:77-94`

**问题**:`process.waitUntilExit()` + `readDataToEndOfFile()` 阻塞。keychain 锁定时,`/usr/bin/security` 触发 GUI prompt,**调用线程完全阻塞**。文档没写"必须 off main thread"。

**建议**:改 async,内部 `withCheckedContinuation` 包 waitUntilExit;或 doc comment 强制要求 background。

来源:Track A

---

### M-23. SSHKeyManager `addToKnownHosts` 信任已存在 `github.com` 条目 — MITM 残留风险

**位置**:`Clarc/Utilities/SSHKeyManager.swift:146-152`

**问题**:`known_hosts` 中有 `github.com` 条目(无论谁加的、什么 fingerprint),就 skip 不 verify。已 MITM 机器上,新装 Clarc 继续信任假 key。

**建议**:提供 `verifyExistingKnownHosts` 选项,首次启动时强制 verify。

来源:Track A

---

### M-24. SSHKeyManager `configureSSHConfig` 检查 substring 太宽

**位置**:`Clarc/Utilities/SSHKeyManager.swift:94-97`

**问题**:`if config.contains("claudework_ed25519") { return }` — 注释里的旧条目、被 disable 的 alias 也命中。

**建议**:解析 ssh config 精准判断。

来源:Track A

---

### M-25. SSHKeyManager `FileHandle(forWritingTo:)` 错误处理不完整

**位置**:`Clarc/Utilities/SSHKeyManager.swift:113-128, 176-188`

**问题**:`handle.write(data)` 抛错时 handle 不会被 close,FD 泄漏。`configureSSHConfig` caller 用 `try?` 吞,**handle FD 泄漏**。

**建议**:`defer { try? handle.close() }`。

来源:Track A

---

### M-26. SSHKeyManager `run` 私有方法无 timeout

**位置**:`Clarc/Utilities/SSHKeyManager.swift:275-307`

**问题**:`run` 调 ssh-keygen / ssh-keyscan,虽然用 `-T 10` 单连接 timeout,但**整体**没 timeout。FileVault 解锁中、磁盘加密未解锁时 actor 永久 hang。

**建议**:外层加 `Task { try? await Task.sleep(...); process.terminate() }` 兜底。

来源:Track A

---

### M-27. SSHKeyManager `ssh-keygen -N ""` 私钥无密码保护,keychain 不缓存

**位置**:`Clarc/Utilities/SSHKeyManager.swift:43, 56-64`

**问题**:私有 key 文件 0600 但不加密。机器被偷 = key 失窃。`ssh-add --apple-use-keychain` 没做。

**建议**:文档化风险,可选调 `ssh-add --apple-use-keychain` 在用户首次使用时。

来源:Track A

---

### M-28. `processStream` 收到 `.result` 时 `saveSession` 与 `reloadCommittedFromDisk` 时序竞争

**位置**:`Clarc/App/AppState.swift:1626-1632`

**问题**:`saveSession` 把内存中的 `allMessages` 序列化,然后 `reloadCommittedFromDisk` **从 disk 重读并覆盖 `committedMessages`**。CLI 在 fsync jsonl 前 Clarc 读到,可能用旧数据覆盖内存。典型后果:刚生成的最后一条 assistant 消息消失。

**建议**:用 `.serialTask` 串行化 save → reload,先等 disk 文件 mtime 稳定 ≥100ms 再 reload。

来源:Track C 1.7

---

### M-29. `startBridgeObservation` 的 `withObservationTracking` 不会被释放

**位置**:`Clarc/App/AppState.swift:885-921`

**问题**:`Task { @MainActor in observeStream() }` 闭包内部不停 `Task { ... observeStream() }` 递归,每次重新注册 onChange。**没有任何 cancellation token**。窗口关闭后 Task 继续跑,写已 deinit 的 `bridge` 属性。多窗口场景下,每开关一次就多一个永远在跑的 Task。

**建议**:存 `observationTasks: [UUID: Task<Void, Never>]`,window 关闭时显式 cancel。

来源:Track C 1.8

---

### M-30. `flushTimer` 创建/清理有遗留窗口

**位置**:`Clarc/App/AppState.swift:1747-1758`

**问题**:`sessionStates[sessionKey, default: SessionStreamState()]` 在 key 不存在时**插入新的默认值**。`stopFlushTimer` 只对同 key cancel。`startFlushTimer` 内部 `stopFlushTimer(for: sessionKey)` 后 `flushTask = nil` 没设。

**建议**:显式 if-missing-create 模式,`finalizeStreamSession` 内 `state.flushTask = nil`。

来源:Track C 1.9

---

### M-31. `saveSession` 内 `while ... .count > 1` 重复检测 + `withAnimation` 包整段写

**位置**:`Clarc/App/AppState.swift:3043-3058`

**问题**:`allSessionSummaries.filter({ $0.id == sessionId }).count > 1` 在 `@Observable` 系统下,如果其他 mainActor task 触发 `allSessionSummaries.append`,filter 读 stale 值,锁窗口长。

**建议**:改成单次 O(n) 遍历,同时拿 first/last index。

来源:Track C 1.10

---

### M-32. `processStream` 收到 `.result` 时 `sessionKey` 旋转逻辑有冗余

**位置**:`Clarc/App/AppState.swift:1491-1505`

**问题**:`sessionKey` 旋转时,旧 key 的 `flushTask` 还在跑(在它的闭包里 captured 的是 `capturedKey = oldKey` 常量),但旧 key 已被 removeValue 删除。`flushPendingUpdates(for: oldKey)` 走 1792 行 guard no-op,Task 一直跑直到 stream 结束。

**建议**:旋转时显式 `stopFlushTimer(for: sessionKey)`。

来源:Track C 1.11

---

### M-33. `updateState` 的 default-insert 副作用污染非活跃 session

**位置**:`Clarc/App/AppState.swift:1275-1284`

**问题**:`sessionStates[key, default: SessionStreamState()]` 让"调用前不存在的 key"被悄悄新建,接着 `streamingTail!` crash(H-01 同源)。

**建议**:拆 `mutateState` (strict) + `ensureState` (insert) 两个 API。

来源:Track C 1.12

---

### M-34. `pendingPlaceholder` 在 `processStream` 内的二次重命名逻辑易歧义

**位置**:`Clarc/App/AppState.swift:1532-1536`

**问题**:1520 行已 remove `expectedPlaceholder`,这里再用 `oldKey` 重做,容易出现 stale `pendingPlaceholderIds` 条目没被 remove,UI 上 sidebar 一直显示 "新对话" 占位。

**建议**:重写整段 placeholder 清理逻辑,统一在 `applyInitSystemEvent` 函数里。

来源:Track C 1.13

---

### M-35. `flushPendingUpdates` 内的 `TaskProgressStore` 检索依赖 `state.windowState`

**位置**:`Clarc/App/AppState.swift:1810-1821`

**问题**:`state.windowState` 是 `weak var`,理论上可能为 nil(比如 session 被 selectProject filter 删了)。实际不会(因为 streaming 的 session 不会被 filter),但**没有防御**。

**建议**:改为 unowned 或文档化"由 streaming 生命周期保活"。

来源:Track C 1.14

---

### M-36. `didBecomeActiveObserver` 每次激活都重读所有 disk session

**位置**:`Clarc/App/AppState.swift:545-560`

**问题**:每次点回应用触发 1 次全局 reload。100 个 session = 100 个并行 detached task。严重时 UI 卡 1-2 秒,sidebar 抖动。

**建议**:debounce 1s,优先 reload 当前 window 的 session,后台做全量。

来源:Track C 1.15

---

### M-37. `MainWindowRoot.onDisappear` 的 race — 可能错关正在用的流

**位置**:`Clarc/ClarcApp.swift:133-148`

**问题**:`onDisappear` 触发后,MainWindowRoot 视图可能还**存在**(只是 visibility=false)。SwiftUI 重排时 `onDisappear` 假触发,然后 `cancelAllBackgroundStreams` 把所有 stream 全杀了,**包括用户期望继续运行的后台流**。

**建议**:用 `.onReceive(Notification.Name.NSWindowWillClose)` 替代。

来源:Track C 2.1

---

### M-38. `MainWindowRoot.onDisappear` 没释放 `observationTasks`

**位置**:`Clarc/ClarcApp.swift` 紧接 M-37

**问题**:接 1.8,MainWindowRoot 关闭时没有 cancel `startBridgeObservation` 创建的 Task。Task 继续跑,写已 deinit 的 `bridge` 属性。

来源:Track C 2.2

---

### M-39. `WindowState.sessionModel` / `sessionEffort` / `sessionPermissionMode` 与 `SessionStreamState` 双向同步不一致

**位置**:`Clarc/App/AppState.swift:442-451`(`setSessionModel`),`WindowState.swift:122`

**问题**:`window.sessionModel` 和 `state.model` 两份。disk 写入了 "opus" 而内存刚被 user 改回 "default",切走再切回又变回 "opus",**丢失用户最近的选择**。

**建议**:把 `state.model` 当唯一 source of truth,删除 `session.model`/`session.effort`/`session.permissionMode` 从 `ChatSession` struct。

来源:Track C 3.1

---

### M-40. `TokenEstimator.estimate` 把 CJK 当 3 char/token 严重低估

**位置**:`Packages/Sources/ClarcCore/TokenEstimator.swift:8-10`

**问题**:`text.count / 3` — CJK 每个字 1 grapheme,Claude BPE 编码 CJK ~1.5 char/token。**3 char/token** 严重低估,实际 token 数是当前 estimate 的 ~2 倍。`autoCompactThreshold` 默认 100k,实际触发点会到 ~200k 才触发。

**建议**:CJK 单独按 ~2 char/token,其他按 ~4 char/token 算。

来源:Track C 4.1

---

### M-41. `ChatMessage` Codable 兼容旧格式但无 schemaVersion — 字段改名直接破坏兼容

**位置**:`Packages/Sources/ClarcCore/Models/ChatMessage.swift:143-174`

**问题**:`blocks` 优先,fallback 到 `content + toolCalls` 拼装,但**没有 schemaVersion 字段**。未来加新字段(如 `threadingId`)decode 时 `decodeIfPresent` 静默忽略,重新 encode 时缺字段,**信息静默丢失**。

**建议**:加 `schemaVersion: Int = 2` 字段,decode 时用 case 切换。

来源:Track C 5.1

---

### M-42. `AttachmentType` 增删 case 时无 rawValue 兼容

**位置**:`Packages/Sources/ClarcCore/Models/Attachment.swift:33-38`

**问题**:加 `case video` 时,老 disk 上 `video` rawValue 的 ChatMessage 解码 crash(没有 `case unknown` fallback)。

**建议**:加 `case unknown` 兜底。

来源:Track C 5.4

---

### M-43. `Role` 只有 `user` / `assistant`,缺 `system`

**位置**:`Packages/Sources/ClarcCore/Models/ChatMessage.swift:285-288`

**问题**:CLI 有 `system` role(用于 system reminder 注入),当前只 decode `user` / `assistant`。若 CLI 后续在 assistant turn 内嵌 system reminder 作为 ChatMessage 发送,decode 失败。

**建议**:加 `case system` 兜底,或显式 fail-fast。

来源:Track C 5.6

---

### M-44. `ChatSession.Summary.origin` 默认 `.legacyClarc` 与 init 默认 `.cliBacked` 不一致

**位置**:`Packages/Sources/ClarcCore/Models/ChatSession.swift:60, 114, 29`

**问题**:新写 `.cliBacked`,decode missing field fallback `.legacyClarc`。两者语义反:
- `.cliBacked` → disk 由 CLI 管
- `.legacyClarc` → disk 由 Clarc 写,`~/Library/Application Support/Clarc/sessions/...`

老数据没 `origin` 字段被解读为 `.legacyClarc`,但实际是 CLI 的 jsonl → `persistence.deleteSession` 走 `~/Library/Application Support/...` 找不到,**删不掉**。

**建议**:默认 `.cliBacked`(与 init 一致)。

来源:Track C 5.7

---

### M-45. `AnthropicAdapter.numericValue` 把 bool 误判为 100%

**位置**:`Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift:62-66`

**问题**:`Foundation` 的 NSNumber wraps Bool as `kCFBooleanTrue/False`,`as? NSNumber` 成功,`doubleValue` 返回 1/0。若 `utilization` 字段未来被改成 `is_at_limit: true` 之类的 bool,误读为 100%。

**建议**:先 `CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID()` 判断,bool 返回 nil。

来源:Track C 6.5

---

### M-46. `MiniMaxAdapter.pickElement` fallback 到 `arr.first` 选错元素

**位置**:`Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift:91-96`

**问题**:`model_remains` 没有 "general" 元素时 fallback `arr.first`,用户买的是 MiniMax-Text-01,显示的是别的模型的剩余率。

**建议**:fallback 时 `logger.warning`。

来源:Track C 6.4

---

### M-47. `OpenAIAdapter` 是空壳 preset,文档误导

**位置**:`Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift:13-39`

**问题**:完全调 `CustomAdapter`,没 OpenAI 特定 header。"OpenAI" 在 UI 上看起来像真实 provider,实际是 alias。`defaultFiveHourPath` 返回 Anthropic shape 路径 → 必定失败。

**建议**:在 Settings UI 写明 "OpenAI (alias to Custom, uses Anthropic-shape paths)"。

来源:Track C 6.6

---

### M-48. `TaskUpdateMessage` Codable 没显式 CodingKeys — 字段改名直接破坏兼容

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateMessage.swift:13-48`

**问题**:没有 `private enum CodingKeys`,用默认 property name。改名 `title → name` 后老数据 decode 失败 fallback `?? ""`,**信息静默丢失**。

**建议**:显式 `CodingKeys` + `schemaVersion: Int` 字段。

来源:Track C 7.1

---

### M-49. `TaskUpdateMessageFactory.truncate` 用 `String.index` 越界风险

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateMessageFactory.swift:266-270`

**问题**:`s.count` 是 grapheme count,但 `s.index(..., offsetBy: n - 1)` 是**字符** offset,不一致。CJK 安全,emoji 是 grapheme cluster,**中间**切会 crash。

**建议**:用 `unicodeScalars` 或显式 `String.Index` 计算。

来源:Track C 7.2

---

### M-50. `TaskUpdateParser.findMatchingBrace` 不支持 unicode escape

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateParser.swift:200-223`

**问题**:JSON 字符串里 `\u0022` 表示 `"`,当前 escape 状态机不识别 `\u` → 字符串提前结束 → 解析失败。

**触发**:Claude 输出包含 emoji 或 unicode 字符的 `details` 字段(常见)。

**建议**:`c == "\\"` 时读下一个字符,如果是 `u` 再读 4 个 hex 字符(可能 surrogate pair),跳过这 6 个字符不切 inString。

来源:Track C 7.3

---

### M-51. `TaskUpdateParser.extractCodeFenceJSON` 的 `jsonTag` 检查只读 4 字符

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateParser.swift:107-114`

**问题**:`jsonTag.prefix(4).lowercased() == "json"`,`jsonc` / `json5` 都被当 `json` fence。

**建议**:用正则 `^```(json|jsonc)?[\\s\\n]` 更严格。

来源:Track C 7.4

---

### M-52. `MessageListView` 外层 `VStack` 而非 `LazyVStack` — 10K 消息全量渲染

**位置**:`Packages/Sources/ClarcChatKit/MessageListView.swift:30-69`

**问题**:10K-message session,所有 10K turn rows 一次性创建,`MessageBubble` 实例化,ForEach 渲染。

**建议**:替换为 `LazyVStack`,把 `MessageBubble` 实例化延迟到 viewport。

来源:Track D issue 104

---

### M-53. `ProjectWindowView` 缺 `onDisappear` 重置 `isProjectWindow` — 跨窗口状态泄漏

**位置**:`Clarc/Views/ProjectWindowView.swift:14-15, 61-63`

**问题**:`.onAppear { windowState.isProjectWindow = true }` 但无 `.onDisappear { ... = false }`。关 project window 泄漏 flag,下次 main window 看到 `isProjectWindow = true`,破坏 `HistoryListView` 的 "show all vs current project" toggle。

**建议**:补 `.onDisappear { windowState.isProjectWindow = false }`。

来源:Track D issue 8

---

### M-54. `PermissionModal` Timer 泄漏 + 初始化误导 + 双击 race

**位置**:`Clarc/Views/Permission/PermissionModal.swift:13, 20, 39, 197, 180, 190, 84-91`

**问题**(多问题合并同源):
1. `private let timer = Timer.publish(...).autoconnect()` 在 View 上泄漏(同 H-13)
2. `init(request:)` seeds `_remainingSeconds = State(initialValue: 300)` 然后 `onAppear` 覆盖 — 误导
3. 多个按钮调 `Task { await appState.respondToPermission(...) }`,双击 Allow 触发两次 Tasks
4. `request.toolName.lowercased()` 在每次 body 调 — 应 cache 到 `let toolNameLower`

来源:Track D issues 32, 33, 34, 36

---

### M-55. `OnboardingView` `cliInstalled` 状态机错误 + 无 Skip 路径

**位置**:`Clarc/Views/Onboarding/OnboardingView.swift:33-99, 110, 121-135`

**问题**:
1. Get Started 按钮 `disabled(!cliInstalled)`,binary check >5s 时无 Skip 路径
2. catch 分支 `cliInstalled = true` 不 reset `cliError`,label 显示 "Installed — " 后面空 version

来源:Track D issues 38, 39

---

### M-56. `GitHubLoginView` polling Task 不 view-scoped

**位置**:`Clarc/Views/Onboarding/GitHubLoginView.swift:91-93, 155-159`

**问题**:`codeCopied = true; DispatchQueue.main.asyncAfter(...) { codeCopied = false }` fire-and-forget。view dismiss 后 closure 写 deallocated view 状态。`try await appState.completeGitHubLogin(...)` 在 view dismiss 后仍跑,写 deallocated view 的 `isPolling`/`errorMessage`。

来源:Track D issues 41, 42

---

### M-57. `GitHubSheet` `filteredRepos` 每次 keystroke O(n) 重新计算

**位置**:`Clarc/Views/Chat/GitHubSheet.swift:168, 216-224, 230-239, 132`

**问题**:
- `List(filteredRepos) { repo in ... }` computed property,每次 keystroke O(n) 全部 rederive
- `cloningRepo` 是单 string,不是 Set,两个 repo 快速连点 spinner 互相覆盖
- `URL(string: "https://github.com/...")!` force unwrap,静态字符串安全

**建议**:onChange 触发 pre-filter;Set<String> cloning repos。

来源:Track D issues 43, 44, 45

---

### M-58. `SkillMarketView` `loadMarketplace()` 每次 install/uninstall 重新拉

**位置**:`Clarc/Views/Chat/SkillMarketView.swift:441-446, 158-160, 215-221`

**问题**:
- `onDisappear { Task { await appState.loadMarketplace() } }` on install popup 关闭 → 4 并行 GitHub fetch 重新拉
- `availableMarketplaces` computed property 在 body re-render 迭代 `marketplaceCatalog` 构 `counts` dictionary
- "Installed" filter 0 命中显示 generic "No results"

来源:Track D issues 48, 49, 50

---

### M-59. `HistoryListView` O(n²) context menu + 折叠策略不一致

**位置**:`Clarc/Views/Sidebar/HistoryListView.swift:54-65, 167-171, 173-201, 112, 232-286`

**问题**:
- `contextMenu` body 读 `appState.allSessionSummaries.first(where: ...)` — O(n) per row,opening context menu 是 O(n²) 全部 rows
- `sessions` computed property 每次返回 fresh array,`.animation(.default, value: sessions)` 触发未期望 layout
- `.onLongPressGesture(minimumDuration: 0, ...)` workaround

来源:Track D issues 57, 58, 59

---

### M-60. `FileTreeView` `Bool searchTrigger` 不可靠 + recursive `FileNodeRow` 非 lazy

**位置**:`Clarc/Views/Sidebar/FileTreeView.swift:189-194, 302-305, 155-158, 455-470, 468-470, 487-498`

**问题**:
- `searchTrigger: Bool` 配合 `toggle()` — 已 true 时再 toggle 是 false,`onChange` 不 fire
- recursive `FileNodeRow` 内 children **不是** lazy(虽然 top-level 在 LazyVStack 内),目录 1000 文件打开立即 1000 view instances
- symlink 目标过滤不到(用 `url.lastPathComponent` 而非 resolved target)
- `.id(themeRevision)` 注释是 "do NOT add" marker

**建议**:`UUID?` trigger;递归用 `OutlineGroup`/`DisclosureGroup`;`UUID?` focus trigger。

来源:Track D issues 63, 64, 65, 66, 67, 68

---

### M-61. `FileInspectorView` O(n) reduce 每次 keystroke + 5MB 限制与文档 1MB 不符

**位置**:`Clarc/Views/Sidebar/FileInspectorView.swift:176-178, 215-218, 241-243, 289-294`

**问题**:
- `.onChange(of: editingContent)` `reduce` 每次 keystroke,100KB paste = 100K reduce ops
- 5MB cap 与 UserManual 文档 1MB 不符(文档漂移)
- `FileNode(id: "", name: fileName, ...)` 为 `icon` 静态属性浪费实例化
- 无文件锁,与 Xcode/VSCode 同时编辑冲突

**建议**:`components(separatedBy: "\n").count`;统一文档。

来源:Track D issues 71, 72, 73, 74

---

### M-62. `GitStatusView` `headWatcher` fd 可被复用 + 多次 loadBranches 触发

**位置**:`Clarc/Views/Sidebar/GitStatusView.swift:236-264, 249-254, 206-212, 189-190`

**问题**:
- `setCancelHandler` 异步调,rapid 项目切换时旧 fd 取消 handler 跑在新 fd 之后 → 旧 `close(fd)` 关新 fd
- 文件被删/重命名后 watcher 自我停止并 0.1s 后重启 — 0.1s hack
- `loadBranches` 在 Menu `.onAppear` 每次开 menu 调,rapid open 多次 fetch

**建议**:fd generation counter;debounce。

来源:Track D issues 76, 77, 78

---

### M-63. `MarkdownPreviewView` `String.hashValue` per-process 不可靠 + 立即 loadHTMLString

**位置**:`Clarc/Views/Sidebar/MarkdownPreviewView.swift:8-26, 11, 17, 29-32, 131-140, 556`

**问题**:
- `String.hashValue` per-process 随机,cache key **不跨 launch 稳定**
- `loadHTMLString` 在 `makeNSView` 立即调,offscreen 渲染浪费 ~50-200ms
- 100KB content 每次 hash 变 → JSON encode O(n)

**建议**:稳定 hash,defer load 到 `viewDidMoveToWindow`。

来源:Track D issues 81, 82, 83

---

### M-64. `UserManualView` `id: \.offset` 数组重排崩 + 0.5pt stroke + 本地化 key 误用

**位置**:`Clarc/Views/UserManualView.swift:62-64, 103-106, 325-330, 75-77, 136`

**问题**:
- `id: \.offset` — 数组重排 SwiftUI 按 index diff 全部重创建
- 0.5pt line 在 Retina 渲染 1-px 灰
- `value: "effort.desc.auto"` 是 String 当 `LocalizedStringKey` 用,翻译者漏译时显示英文 key

**建议**:稳定 id;`lineWidth: 1`;检查所有 `*.desc.*` key 存在性。

来源:Track D issues 85, 86, 87

---

### M-65. `InputBarView` popup 用 `alignmentGuide` 翻转位置 + queued message race + IME 误判

**位置**:`ClarcChatKit/InputBarView.swift:69-96, 97-102, 103-116, 117-121, 222-224, 236-253, 330-366, 378-385, 540-544, 737-771`

**问题**:
- `.overlay(alignment: .top) { HStack { ... }.alignmentGuide(.top) { $0[.bottom] } }` — popup 跳 320pt,盖 message list 不浮于 input 上
- `requestInputFocus` `Bool` 多快速调只 fire 一次
- `processNextQueued()` 在 `onChange(isStreaming)` + `onChange(currentSessionId)` 各 fire 一次,可能双 send
- CJK IME commit "你好" 一批,delta = 2 触发 paste detection,长 CJK 文本被转 attachment
- URL detection 仅 `http/https`,`mailto`/`ftp`/`tel`/`file://` 被当 plain text
- `user@host` 中间 `@` 误触发 @ popup

**建议**:`ZStack` 放 popup;`UUID?` trigger;`chatBridge.send()` idempotent guard;CJK delta 容忍。

来源:Track D issues 110, 111, 112, 113, 115, 118, 119, 120

---

### M-66. `IMETextView` CJK 候选词状态下 Return 不发消息

**位置**:`ClarcChatKit/IMETextView.swift:188-197, 199-218, 225-233`

**问题**:CJK IME 在 "candidates shown" 状态按 Return → IME 拦截 `insertNewline`,不会发到 onReturn callback。用户需按 Enter 两次。

来源:Track D issue 124

---

### M-67. `MessageBubble` `isEditFocused` 触发在 TextField 挂载前 + NSTextView 焦点条件

**位置**:`ClarcChatKit/MessageBubble.swift:88-97, 248-250, 283-303`

**问题**:
- `isEditFocused = true` 在 `.onChange(of: isEditing)` 里设,但 `TextField` 还在 view tree 之前(`body` re-evaluate 后再 fire)。focus 无效
- `tv.window?.firstResponder === tv` filter,`tv` 在非 key window 时 NSTextView 不收 event
- `chatBridge.taskProgressStore` 是 `weak var`,store nil 时 TaskUpdateCard 的 binding no-op
- `showTransientTools` `@State` 声明位置难找

**建议**:`DispatchQueue.main.async` 触发 focus;TaskUpdateCard 在 store nil 时显式 disable toggle。

来源:Track D issues 130, 131

---

### M-68. `MarkdownView` `onChange(of: text)` 是 dead code + init pop 缓存 O(n) + 同步 parse

**位置**:`ClarcChatKit/MarkdownView.swift:18-22, 76-86, 41-52, 91-245, 268-381, 497-533`

**问题**:
- `.onChange(of: text)` — `text` 是 `let` constant,onChange 从不 fire,cache update 死代码
- `init` 同步 `buildRenderGroups`,100 messages stream 1s = 100 parses/s
- 100KB markdown 同步 parse 50-200ms,UI 冻
- `try? AttributedString(markdown:)` 解析失败吞,**用户看到 raw `**bold**`**

**建议**:throttle;offload 到 background;cache on 真实 change;`AttributedString` 失败时 fallback 显示原文。

来源:Track D issues 151, 152, 153, 154, 155

---

### M-69. `ChatBridge` handler 为 nil 时 silent no-op

**位置**:`ClarcChatKit/ChatBridge.swift:66-97`, handler 14-15, 42, 44, 48-58

**问题**:
- `sendHandler?`/`cancelStreamingHandler?` 为 nil 时,调用 silent no-op。点 Send 没反应、没 log、没 error
- handler closures 强引用 `AppState`(如果 capture),与 ChatBridge 形成循环引用
- `var` closure 允许运行时替换,task 捕获的是旧 closure

**建议**:handler nil 时 log warning;`[weak appState]` capture。

来源:Track D issues 138, 139, 193 / verifier V6

---

### M-70. `Turn.makeTurns` orphan turn `id = UUID()` 每次翻新

**位置**:`ClarcChatKit/Turn.swift:84-94, 9-28, 100-104, 111-115`

**问题**:
- orphan turn id 每次 `makeTurns` 调用生成新 UUID,SwiftUI `ForEach` 当新行处理,丢 `@State`,layout glitch
- `Equatable` synthesized 包含 `isInProgress`(派生 flag),不同 `isInProgress` 实际不等的 turn 也不等,触发未期望 re-render
- `isInProgress` 改 last turn 的字段,语义 OK 但混淆

**建议**:orphan id 稳定(如 hash of content);实现 explicit `==`。

来源:Track D issues 145, 146, 147

---

### M-71. `FileDiffView` loadDiff 串行 fallback 而非并行

**位置**:`ClarcChatKit/FileDiffView.swift:138-149`

**问题**:`["diff", "HEAD", "--", filePath]` → `["diff", "--", filePath]` → `["show", "HEAD", "--", filePath]` 串行,首条慢时等它完才试次条。

**建议**:`async let` 并行。

来源:Track D issue 158

---

### M-72. `SlashCommandManagerView.command!.name` 之外的同文件问题

**位置**:`ClarcChatKit/SlashCommandManagerView.swift:412-414, 600-608, 296-303`

**问题**:
- `@State` 在 edit sheet 二次 onAppear 重新填字段
- `Toggle` 的 `set` closure 调 `refreshList()` 触发 full list rebuild,多 toggle 连续触发

来源:Track D issues 166, 167

---

### M-73. `ShortcutManagerView.importShortcuts` 是 replace 不是 import

**位置**:`ClarcChatKit/ShortcutManagerView.swift:117-123, 38-55, 392`

**问题**:`shortcuts = imported` 覆盖整个列表。10 shortcuts 导入 5 个 → 丢 5 个。函数名 "import" 但行为 "replace"。

来源:Track D issue 168

---

### M-74. `StatusLineView.totalResponseDuration` O(n) 每次 body 调 + `abbreviatePath` sandbox bug

**位置**:`ClarcChatKit/StatusLineView.swift:13-18, 97-104, 177-183, 191-198, 200-206`

**问题**:
- `totalResponseDuration` computed property 过滤所有 messages 求和,每次 body 调
- `abbreviatePath` sandbox 容器路径 bug(同 `ProjectListView.swift:127-136`)— Clarc 关闭 sandbox 实际不触发,但未来 sandbox 会暴露
- `DateComponentsFormatter` 每次创建

来源:Track D issues 142, 144 / verifier V2

---

### M-75. `WebPreviewButton` O(total chars) regex 每次 body + Coordinator 强引用

**位置**:`ClarcChatKit/WebPreviewButton.swift:36-45, 107-141`

**问题**:
- `detectedURL` 拼接所有 message contents 跑 regex,10K messages 每次 O(total chars)
- `WebViewWrapper` `Coordinator` 强引用,view 重建时旧 `webView(_:didFinish:)` 在新 WKWebView 后 fire,`isLoading` toggle 错乱

来源:Track D issues 184, 185

---

### M-76. `InputBarView.insertAtCursor` 跨窗口 bug — 写错窗口

**位置**:`ClarcChatKit/InputBarView.swift:440-452`

**问题**:`NSApp.keyWindow?.firstResponder as? NSText` 是全局取;多窗口(ProjectWindow + MainWindow)时,本 InputBarView 的 `handlePaste` 可能写到对方窗口 text field。

来源:Track D verifier V5

---

### M-77. `claudeVersion` 跨 actor 读 — strict concurrency 失败

**位置**:`Clarc/Views/MainView.swift:99-103`

**问题**:`appState.claudeVersion` 从 `@MainActor` body 读,如果 `claudeVersion` 在 actor 隔离的 `ClaudeService` 上,strict concurrency 下编译失败。

**建议**:mirror 到 `@MainActor` `@Observable` 字段。

来源:Track D issue 5

---

## 🟢 低严重度(代码风格 / 死代码 / 文档漂移 / 一致性)

> 排序:埋雷深度(影响未来开发的可能性)优先

### L-01. BashSafety `try! NSRegularExpression` 启动期硬失败

**位置**:`Clarc/Services/BashSafety.swift:103, 113`

**问题**:两个 regex pattern 用 `try!` 构造,改坏 pattern 整个进程在首次访问时崩溃。

**建议**:`static let` + `try?`,或 `static func` + assert。

来源:Track A

---

### L-02. BashSafety `allowedRedirectTokens` 顺序敏感

**位置**:`Clarc/Services/BashSafety.swift:116, 235-242`

**问题**:`segmentHasWriteRedirect` 用"先剥离允许 token"法。`echo foo>&2` 含 `>`,被拒,实际应允许。

**建议**:proper tokenizer 识别 redirect(`>&N` / `&>file` / `2>&1` / `>>file` / `<>`)。

来源:Track A

---

### L-03. BashSafety 注释承诺与实现不一致

**位置**:`Clarc/Services/BashSafety.swift:3-8`(文件头注释)

**问题**:"every command token must be in allowlist" 注释承诺,实现只查 binary name + subcommand + flags。

**建议**:调整注释对齐实现。

来源:Track A

---

### L-04. ClaudeService `terminateHandler` 中 `Task` 不可取消 + `withCheckedContinuation` 二次 resume 风险

**位置**:`Clarc/Services/ClaudeService.swift:622-635, 794-798, 287-291`

**问题**:Process 偶有 terminationHandler 调两次(理论),`continuation.resume()` 二次调 fatalError。

**建议**:`AsyncStream.Continuation` 或 withCheckedContinuation 安全模式。

来源:Track A

---

### L-05. ClaudeService `findClaudeBinary` 在 `path`/`resolved` 上不对称

**位置**:`Clarc/Services/ClaudeService.swift:226-233`

**问题**:`fileExists(resolved)` 不跟随 symlink,`isExecutableFile(path)` 跟随。

**建议**:统一用 `resolved` 检查 + 返回。

来源:Track A

---

### L-06. ClaudeService `cachedShellEnv` 一旦缓存就不失效

**位置**:`Clarc/Services/ClaudeService.swift:83, 184-207`

**问题**:用户在 zshrc 改了 `ANTHROPIC_API_KEY`,Clarc 进程仍在跑,新值不生效直到 quit 重启。

**建议**:加手动刷新方法或 `NSWorkspace.didWakeFromSleep` 时刷新。

来源:Track A

---

### L-07. ClaudeService `findUserShellPath` 强制 `/bin/zsh`

**位置**:`Clarc/Services/ClaudeService.swift:133-146`

**问题**:fish/bash 用户 graceful fallback 到 GUI PATH,OK 但不优雅。

**建议**:提示 fish 用户用 `~/.config/fish/config.fish`。

来源:Track A

---

### L-08. GitHubService `pollForToken` `accessToken` 与 `try saveToken` 写入顺序

**位置**:`Clarc/Services/GitHubService.swift:127-132`

**问题**:先 `self.accessToken = ...`,再 `try saveToken(...)`。keychain 抛错时 `self.accessToken` 已设,actor 内存与 disk 不一致。

**建议**:先 `try saveToken`,再 `self.accessToken = ...`。

来源:Track A

---

### L-09. GitHubService 错误响应 body 不限制大小

**位置**:`Clarc/Services/GitHubService.swift:368-370`

**问题**:`responseBody` 塞 UI 可能 crash。

**建议**:截断到 1KB。

来源:Track A

---

### L-10. NotificationService 通知 `userInfo` 直接 String→UUID 强转,失败静默

**位置**:`Clarc/Services/NotificationService.swift:110-112`

**问题**:`UUID(uuidString: projectIdString)` 返回 nil,guard let 失败时 `return` 静默。

**建议**:失败时 `logger.warning(...)`。

来源:Track A

---

### L-11. SSHKeyManager `pinnedGitHubPublicKeys` 是 `static let` 但每次访问构造

**位置**:`Clarc/Utilities/SSHKeyManager.swift:199-204`

**问题**:`static let` 是惰性初始化(只构造一次),不是 bug。但写法看起来像"每次访问构造"。

来源:Track A

---

### L-12. KeychainHelper `read` / `readString` 不带 `-a account` 时语义模糊

**位置**:`Clarc/Utilities/KeychainHelper.swift:8-23`

**问题**:按 spec 返回 service 的 first generic password item。Claude CLI 可能也写过同 service 的其他 account。

**建议**:doc 注明,或 warning log。

来源:Track A

---

### L-13. KeychainHelper `delete` 要求 `account` 必传

**位置**:`Clarc/Utilities/KeychainHelper.swift:63-73`

**问题**:account 必传,无法"删除 service 下所有项"。

**建议**:加 `deleteAll(service:)` 或允许 account 为 nil。

来源:Track A

---

### L-14. AppState `usageProvider` getter 每次访问都打 UserDefaults

**位置**:`Clarc/App/AppState.swift:348-356`, 290-344

**问题**:每次 `appState.usageProvider` 都做 IO + String → Enum 转换。

**建议**:缓存 stored property,didSet 时写 UserDefaults。

来源:Track C 1.17

---

### L-15. AppState `ThemeStore` 设置在窗口未就绪时执行

**位置**:`Clarc/App/AppState.swift:733-735`

**问题**:风险低,UserDefaults dirty 写不触发 `didSet`(Apple 保证)。**但** 实际 `UserDefaults.standard.string(forKey:)` 在 `init` 阶段是同步的,OK。

来源:Track C 1.16

---

### L-16. AppState `AutoDenyTimeout` didSet 触发 `Task { [weak self] }` 但无 await 链路保护

**位置**:`Clarc/App/AppState.swift:369-378`

**问题**:`self?.autoDenyTimeout.seconds` 在 detached 上下文读 stored property,Swift 6 strict concurrency 报错;`?? 300` fallback 永不会触发。

**建议**:`Task { @MainActor [weak self] in ... }`。

来源:Track C 1.18

---

### L-17. AppState `migrateUsageProvider` 的 `hostMatchesBuiltInProvider` 字符串相等对比 host

**位置**:`Clarc/App/AppState.swift:606-615`

**问题**:大小写敏感但 `URL(string:).host` 已 lowercase,trailing dot 未处理。低风险。

来源:Track C 1.19

---

### L-18. `WindowState.isProjectWindow` 字段没人设

**位置**:`WindowState.swift:122`

**问题**:`grep isProjectWindow` 在整个代码库 0 命中(除本字段定义和注释)。死字段。

**建议**:实现"项目窗口禁用某些 UI",或删除。

来源:Track C 3.2

---

### L-19. `WindowState.id` 是 `let id = UUID()` 公开 UUID

**位置**:`WindowState.swift` 字段定义

**问题**:每次 init 不一样(正常),`newSessionKey` 依赖。暴露内部标识,**仅是 API 表面**。

来源:Track C 3.3

---

### L-20. `WindowState.answerQuestionHandler` 没清理

**位置**:`AppState.swift:814-817`

**问题**:`window.deinit` 时无清理代码。闭包生命周期 ≤ window 生命周期,无泄漏,但缺约定。

来源:Track C 3.4

---

### L-21. `CompactionRecord.recentUserTokenBudget` 死字段

**位置**:`Packages/Sources/ClarcCore/CompactionRecord.swift:35`

**问题**:`grep recentUserTokenBudget` 全工程 0 命中。

**建议**:实现,或删除。

来源:Track C 4.2

---

### L-22. `CompactionRecord.summaryPrefix` 写死英文,i18n 没做

**位置**:`Packages/Sources/ClarcCore/CompactionRecord.swift:40-45`

**问题**:LLM 收到英文 prefix + 中文对话 → 模型可能输出英文。

**建议**:i18n 化(可选)。

来源:Track C 4.3

---

### L-23. `StreamEvent` `case .unknown(String)` 的原始 JSON 二次编码丢类型

**位置**:`StreamEventDecoding.swift:30-34`

**问题**:`Int` 转 `Double` 53-bit 精度上限,对正常 UI 无影响,但 `Int.max + 1` fallback Double。

来源:Track C 5.2

---

### L-24. `UserMessage.toolUseId` 解析既查 message 级也查 block 级 — message 级永远 nil

**位置**:`StreamEventDecoding.swift:143-162`

**问题**:`MessageCodingKeys.toolUseId` 几乎永远 decode 失败,总是 fallback `blockToolUseId`。防御性代码不影响正确性,但**误导**。

**建议**:删 `MessageCodingKeys.toolUseId` 一行,简化 `toolUseId = blockToolUseId`。

来源:Track C 5.3

---

### L-25. `JSONPathParser` 不支持 `.*` 通配、负数 index、函数 `length()` 等

**位置**:`Packages/Sources/ClarcCore/Usage/JSONPath.swift`

**问题**:当前支持的语法:`.key`、`.0`、`[n]`、`[@k=v]`。不支持通配、slice、负数 index。

**建议**:文档化支持的子集,fail 时给清晰错误。

来源:Track C 6.2

---

### L-26. `JSONPathParser.parseStringValue` 不解析引号

**位置**:`Packages/Sources/ClarcCore/Usage/JSONPath.swift:159-171`

**问题**:predicate `[@name="Foo Bar"]` parser 不识别引号,把 `"Foo` 当裸字符串。

**建议**:扩展 parser 支持引号 string,或文档化。

来源:Track C 6.9

---

### L-27. `TaskUpdateParser.parse(xmlFragment:)` XML 同步阻塞

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateParser.swift:68-87`

**问题**:`XMLParser.parse()` 同步,UI 线程解析大块会卡帧。当前 XML 块小实际不会卡,**没文档化**。

来源:Track C 7.5

---

### L-28. `TaskUpdateMessageFactory` 不处理 multi_edit 的 edits[] 数组

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateMessageFactory.swift:215-228`

**问题**:`multiedit` input 是 `{"file_path": ..., "edits": [...]}`,只取 `file_path` 忽略 edits 数组。UI 不显示多个 hunk。

来源:Track C 7.8

---

### L-29. `ThemeColors` 是 `@unchecked Sendable` 但字段都是 `Color`

**位置**:`Packages/Sources/ClarcCore/Theme/AppTheme.swift:5`

**问题**:`Color` 不是 Sendable(SwiftUI 标注为不可发送),但实际是值类型 + immutable 字段。`@unchecked` 强制保证。

来源:Track C 8.1

---

### L-30. `ThemeStore.shared` 是单例 + @MainActor,跨 actor 读 fields 编译失败

**位置**:`Packages/Sources/ClarcCore/Theme/AppTheme.swift:319-335`

**问题**:SwiftUI view body 永远在 MainActor,异步 callback 切 detached context 访问 `ClaudeTheme.accent` 编译错误。

**建议**:`nonisolated(unsafe)` 包装或 doc。

来源:Track C 8.2

---

### L-31. `AppTheme.rawValue` 是展示名,不是稳定标识

**位置**:`Packages/Sources/ClarcCore/Theme/AppTheme.swift:279-287`

**问题**:`rawValue = "Terracotta"` vs case name `.claude`。未来改名时,UserDefaults 数据被冻结。

**建议**:`rawValue` 用稳定 machine 标识,`displayName` 另开字段。

来源:Track C 8.3

---

### L-32. 6 个 theme 的 `statusError` 都用 `#B85C50` — 视觉没区分

**位置**:`Packages/Sources/ClarcCore/Theme/AppTheme.swift:74`

**问题**:6 个 theme 状态色没区分,用户可能误以为 theme 没换。

来源:Track C 8.4

---

### L-33. `shadowColor = Color.black.opacity(0.08)` 在 dark mode 不变

**位置**:`Packages/Sources/ClarcCore/Theme/ClaudeTheme.swift:72`

**问题**:`Color.black.opacity(0.08)` 在 dark mode 下几乎不可见。

**建议**:`Color(light: .black.opacity(0.08), dark: .white.opacity(0.04))`。

来源:Track C 8.5

---

### L-34. `appDelegate.appState = appState` 在 `.onAppear` 设,首帧前不保证可用

**位置**:`Clarc/ClarcApp.swift:132`

**问题**:`applicationWillTerminate` 依赖 `appDelegate.appState` 非 nil。App 早收到 `applicationWillTerminate`(crash) 时 nil,stream 不 cancel。子进程 OS 自动 reap,但 `sessionStates[*].isStreaming = false` 不执行 → SessionMetaStore 留 `isStreaming: true` sidecar。

来源:Track C 2.3

---

### L-35. `ClarcApp.body` 没用 `@Environment` 接收 `appDelegate`

**位置**:`ClarcApp.swift` 风格

**问题**:`MainWindowRoot` 显式注入 `appDelegate`,`SettingsWindowRoot` 不注入。风格不统一。

来源:Track C 2.4

---

### L-36. `lastCommittedReloadKey` 与 `summaryFor` 的 fallback 路径不清

**位置**:`Clarc/App/AppState.swift:2961-2968`

**问题**:`summaryFor` fallback 空 summary,`loadFullSession` 需要 valid summary 定位 disk 文件。fallback summary 的 `title: ""` 被 `saveSession` title 生成路径覆盖,OK。但语义不清。

来源:Track C 9.1

---

### L-37. `MainActor.run { self.projects }` 跨 await 不必要

**位置**:`Clarc/App/AppState.swift:2367, 792`

**问题**:`AppState` 已 `@MainActor`,`self.projects` 在 MainActor 隔离域。`MainActor.run` 多余。

**建议**:`let projectsSnapshot = self.projects`。

来源:Track C 9.2

---

### L-38. `try?` 吞错模式过多

**位置**:全工程 ~40+ 处

**问题**:几乎都是 `logger.error` 之前的 swallow-error。关键路径(compact / save)失败 UI 没提示。

**建议**:关键路径改 `do/catch` 显示错误气泡。

来源:Track C 9.4

---

### L-39. `AppState.init` 注册 NSApplication observer,没有 unit test 入口

**位置**:`Clarc/App/AppState.swift:545-560`

**问题**:`init` 注册 didBecomeActiveNotification observer。unit test 实例化 `AppState()` 会真的注册,测试间状态污染。

**建议**:observer 注册从 `init` 移到 `initialize()`。

来源:Track C 9.5

---

### L-40. CLISessionStore 各种 `try!`、`String.split` 简化等模式

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift` 多处

**问题**:Track B 列了 15 个 🟢 项(B-04, B-06, B-07, B-11, B-12, B-13, B-14, B-15, B-20, B-21, B-22, B-26, B-27, B-28, B-29, B-30, B-33, B-34),多为 nits。

来源:Track B

---

### L-41. `GitStatusParsing` 两字母 `XY` 码合并不区分 renamed/unmerged

**位置**:`Packages/Sources/ClarcCore/Utilities/GitStatusParsing.swift:11-21`

**问题**:`RM` 算 modified,不显示是 rename。`T` (type change) / `U` (unmerged) 算 modified。

来源:Track B B-54, B-55

---

### L-42. `PathContainment.isInside` 大小写敏感

**位置**:`Packages/Sources/ClarcCore/Utilities/PathContainment.swift:26-32`

**问题**:`/Users/Foo/Bar` 和 `/users/foo/bar` 在默认 APFS 卷上同路径,但 `hasPrefix` 大小写敏感。严格语义是正确 default。

**建议**:`URL.standardizedFileURL.path` + components 比较。

来源:Track B B-59

---

### L-43. `PathEncoding.cliProjectDirName` 有损编码

**位置**:`Packages/Sources/ClarcCore/Utilities/PathEncoding.swift:9-15`

**问题**:`/Users/me/proj`、`/Users/me/proj-1`、`/Users/me/proj.1`、`/Users/me/proj/1` 都映射到 `-Users-me-proj-1`。cwdIndex 缓解但 fallback 仍 lossy。

来源:Track B B-61

---

### L-44. `SyntaxHighlighter` 各种 tokenizer nits

**位置**:`Packages/Sources/ClarcCore/Utilities/SyntaxHighlighter.swift`

**问题**:B-64 ~ B-70 一系列(数组化 O(N)、`\(...)` interpolation 不识别、`#` 上下文受限、SQL 大小写混合、`@_` 不识别、`0b`/`0o` 不解析、操作符不分类)。

来源:Track B

---

### L-45. `JSONValue` Int → Double 转换的精度边界

**位置**:`Packages/Sources/ClarcCore/Models/JSONValue.swift`

**问题**:`JSONValue.init(from: Decoder)` 数字一律变 `Double`,整数 `42` → `42.0`(JSON 输出 `"42"` 因为 `CustomStringConvertible` 检查 `value == value.rounded()`,OK)。53-bit 精度上限,正常 UI 无影响。

来源:Track C 5.2

---

### L-46. `ChatBridge.collapseAllTurns` 注释与实现脱节

**位置**:`ClarcChatKit/ChatBridge.swift:24-28`

**问题**:注释说 "Reset to false when the window switches sessions",但 ChatBridge 自身没有 reset 逻辑。reset 在 `MessageListView.swift:83` `.task(id: windowState.currentSessionId)`。

**建议**:reset 责任移到 `WindowState` 或 `ChatBridge` 内部。

来源:Track D verifier V4

---

### L-47. `MessageListView` 折叠策略不一致

**位置**:`ClarcChatKit/MessageListView.swift:99-113, 114-121, 220-231, 253-258, 130-134, 292-300`

**问题**:
- `isOlderCollapsed` 在 `isStreaming` onChange 时设 true,但 tool_result 引起的 tool call 不重置
- `messages.count` onChange rebuild,但 `compactionRecord` 与 `messages` onChange 顺序不确定,中间帧可能用 stale settledItems
- `rebuildSettledItems` 抑制动画但不防止 `makeVisibleTurns` re-evaluate
- `messageRows` 是 dead code
- `EmptySessionView` 仅在 `currentSessionId == nil` 时显示,有 sid 但 0 消息不显示

来源:Track D issues 99, 100, 101, 102, 103, 105, 106

---

### L-48. `Turn.id` orphan UUID 翻新 + Equatable 派生字段

**位置**:`ClarcChatKit/Turn.swift:84-94, 9-28`

**问题**:`isInProgress: Bool` 在 synthesized Equatable 包含,导致 ForEach re-render。

来源:Track D issues 145, 146

---

### L-49. `FileNode(id: "")` 浪费实例化只为读 icon

**位置**:`Clarc/Views/Sidebar/FileInspectorView.swift:289-294`

**问题**:`FileNode(id: "", name: fileName, isDirectory: false, children: []).icon` 为读 icon 静态属性实例化。

**建议**:抽 `static func icon(for fileName: String) -> String`。

来源:Track D issue 74

---

### L-50. `Bindable(windowState).xxx` 在 body 内多次分配 wrapper

**位置**:`Clarc/Views/MainView.swift:270, 275, 280, 786, 791, 796` + `ProjectWindowView.swift:64, 69, 74`

**问题**:每次 body 调 6+ 次 `Bindable(windowState)` 分配 wrapper。微优化。

**建议**:hoist 到 `@Bindable` 属性,或用 `$windowState.xxx` 直接投影。

来源:Track D issues 3, 196 / verifier V3

---

### L-51. `Timer.publish(...).autoconnect()` pattern 跨文件讨论

**位置**:见 H-13(三处)

**问题**:view instantiation leaks timer。`autoconnect()` 启动,无引用持有 cancellable。

**建议**:`@State` + `Task` sleep loop 或 `TimelineView`。

来源:Track D issues 32, 149, V1

---

### L-52. `FocusedValue` closure 同步执行 — main-actor 隔离

**位置**:`Clarc/Views/MainView.swift:286`

**问题**:`FocusedValue` 不保证 closure main-actor 隔离。

**建议**:`Task { @MainActor in ... }` 包。

来源:Track D issue 4

---

### L-53. `HSplitView` + `NavigationSplitView` 混用

**位置**:`Clarc/Views/MainView.swift:36`

**问题**:Apple 推荐二选一。2-px sliver 在 macOS 15 某些 appearance 看起来像 glitch。

来源:Track D issue 6

---

### L-54. `openWindow` 用 `instanceId: UUID()` 每次新建 window

**位置**:`Clarc/Views/MainView.swift:373`

**问题**:`instanceId: UUID()` fresh UUID 每次 open,defeat 任何 `@State` instance caching。**如果意图是"one window per project"**,用 `projectId` 作 discriminator。

来源:Track D issue 7

---

### L-55. `ProjectWindowView` vs `MainView` toolbar 重复

**位置**:`Clarc/Views/ProjectWindowView.swift:158-174` vs `MainView.swift:311-335`

**问题**:`New Chat`、`Toggle Inspector` 按钮几乎逐字重复。

**建议**:抽 shared `DetailToolbar` 组件。

来源:Track D issue 10

---

### L-56. `ProjectListView` / `GitHubRepoListView` 死代码

**位置**:`Clarc/Views/Sidebar/ProjectListView.swift`、`Clarc/Views/Chat/GitHubRepoListView.swift`

**问题**:MainView 用 `GitHubSheet` 直接,这两个是 sidebar legacy 保留。`ProjectListView` 用 chat-toolbar-area `ProjectTabButton` 替代。

**建议**:确认后删除。

来源:Track D issues 46, 52, 80

---

### L-57. `ProjectListView.truncatedPath` sandbox 容器路径 bug

**位置**:`Clarc/Views/Sidebar/ProjectListView.swift:127-136`, `StatusLineView.swift:200-206`

**问题**:`FileManager.default.homeDirectoryForCurrentUser.path` 在沙盒下是容器路径,`~` 替换失败,显示完整容器路径。Clarc 关闭 sandbox 实际不触发。

来源:Track D issue 53 / verifier V2

---

### L-58. `InspectorMemoPanel` `headingSizes` / `headingSizeSet` 重复存储

**位置**:`Clarc/Views/Inspector/InspectorMemoPanel.swift:14-20`

**问题**:Dictionary + flattened Set 重复。

**建议**:inline-compute Set。

来源:Track D issue 20

---

### L-59. `PermissionModal.frame` 固定尺寸 + 工具栏函数重复

**位置**:`Clarc/Views/Permission/PermissionModal.swift:33, 84-91`

**问题**:`frame(width: 480, height: 380)` 固定,13" MacBook + 大文字时按钮裁切。`toolbarBtn` / `toolbarTextBtn` 函数结构重复。

来源:Track D issues 37, 21

---

### L-60. `OnboardingView` "npm install..." 字符串被 `LocalizedStringKey` 看待

**位置**:`Clarc/Views/Onboarding/OnboardingView.swift:68`

**问题**:`Text("npm install -g @anthropic-ai/claude-code")` → `LocalizedStringKey` 看待,翻译者可能改。

**建议**:`Text(verbatim: "...")`。

来源:Track D issue 40

---

### L-61. `GitHubSheet` empty state duplicate Link + 一次性工具栏按钮

**位置**:`Clarc/Views/Chat/GitHubRepoListView.swift:95-105, 115-120`

**问题**:empty state `Link` 与 footer `Link` 重复。

来源:Track D issue 47

---

### L-62. `SkillMarketView` 候选卡片 `.buttonStyle` 与 `.onTapGesture` 冲突

**位置**:`Clarc/Views/Chat/SkillMarketView.swift:31-40`

**问题**:每个 card `.onTapGesture` 与 `.buttonStyle` 修饰器竞争。

来源:Track D issue 51

---

### L-63. `HistoryListView` `keyboardShortcut(.return, modifiers: [])` on Button inside sheet

**位置**:`Clarc/Views/Sidebar/HistoryListView.swift:170-172`

**问题**:macOS 14+ OK,但风格不统一。

来源:Track D issue 54

---

### L-64. `HistoryListView` `DisplaySession` 设计 OK,`allProjectSessions` / `currentProjectSessions` O(n) 计算

**位置**:`Clarc/Views/Sidebar/HistoryListView.swift:222-230, 266-286`

**问题**:computed properties 每次 body 调,1000+ sessions 慢。

来源:Track D issues 60, 61

---

### L-65. `FileTreeView` 各种 nits

**位置**:`Clarc/Views/Sidebar/FileTreeView.swift:62`

**问题**:Preview hardcoded path。

来源:Track D issue 69

---

### L-66. `UserManualView` `id: \.offset` 数组重排崩

**位置**:`Clarc/Views/UserManualView.swift:62-64`

**问题**:`ForEach(Array(topic.sections.enumerated()), id: \.offset)` — 数组重排 SwiftUI 按 index diff 全部重创建。

来源:Track D issue 85

---

### L-67. `SettingsView` 各种 deprecation + `@State` for class + `bindingPath` 类专用

**位置**:`Clarc/Views/Settings/SettingsView.swift:782-785, 753-758, 1066-1086, 48-52, 67, 842-916, 843, 939-949, 374-376, 91-92`

**问题**(同源,合并):
- `Toggle("URL links", isOn:)` String deprecated
- `Picker(LocalizedStringKey("Fold older messages"))` 内 `Text("Fold: 8")` 非 key
- `UsageSettingsViewModel` 在 `@State` — sheet 重开丢失 test result 状态
- `@Observable` class 缺 `final`
- `BindingPath: ReferenceWritableKeyPath<AppState, String?>` 仅 class 有效
- `SettingsView.swift:48-52` `window.title == "Settings"` fragile check
- `Text(String(format: String(localized: "..."))` 正确但 verbose

来源:Track D issues 89, 90, 92, 93, 94, 95, 96, 97, 98

---

### L-68. `MessageBubble` `attachmentPreview` 同步 `NSImage(contentsOfFile:)` + `@State` 位置 + `onHover` 边界

**位置**:`ClarcChatKit/MessageBubble.swift:454-478, 394-395, 283-303`

**问题**:
- 10MB image disk read + decode 主线程
- `@State private var showTransientTools = false` 声明在 body 后,难找
- `onHover` 在 cursor 移到 tooltip 时不 fire

来源:Track D issues 132, 133, 134

---

### L-69. `AskUserQuestionView` 快速点击多选项 race + `parsed`/`hasAnswer` 每次 body 调

**位置**:`ClarcChatKit/AskUserQuestionView.swift:85, 99, 9-15, 137-141`

**问题**:
- `windowState.answerQuestionHandler?(toolCall.id, option.label)` handler 不防重入
- `parsed` computed property 调 JSON parser,每次 body 调

来源:Track D issues 135, 136

---

### L-70. `ChatBridge.sessionStats` 类型不清

**位置**:`ClarcChatKit/ChatBridge.swift:42`

**问题**:`ChatSessionStats` 是 class 还是 struct?如果是 class 强引用;struct value。

来源:Track D issue 141

---

### L-71. `StatusLineView` `DateComponentsFormatter` 每次创建

**位置**:`ClarcChatKit/StatusLineView.swift:177-183, 191-198`

**问题**:每次调 `makeCountdownFormatter` / `formatTotalDuration` 新建 `DateComponentsFormatter`。

**建议**:`@State` 或 `static let` lazy。

来源:Track D issue 144

---

### L-72. `TaskUpdateCard.ticker` 详见 H-13

**位置**:`ClarcChatKit/Views/TaskUpdateCard.swift:12, 33-35`

**问题**:Timer.publish leak 模式。

来源:Track D issue 149

---

### L-73. `ThinkingBlockView` `userToggle` 状态 + `Localizable.strings` 缺 key 风险

**位置**:`ClarcChatKit/ThinkingBlockView.swift:16-22, 38-44, 80-91`

**问题**:
- block.id 稳定的话 OK,但 view tree 重创建会丢 `@State`
- `String(localized: "Thought for %@", bundle: .module)` 验证 key 存在性

来源:Track D issues 176, 177

---

### L-74. `ToolResultView` `isExpanded` `@State` init 误导 + magic number + multi_edit 字符串重复

**位置**:`ClarcChatKit/ToolResultView.swift:14-25, 136-139, 163-168, 236-237, 354, 179, 332-333`

**问题**:
- `isExpanded` `@State` initialized in `init`,后续 init 忽略新初始值
- `let collapseThreshold = 12` 应 `static let`
- `multiedit` / `multi_edit` 字符串在 `sfSymbol` / `toolDescriptionPrefix` / `isEditTool` 重复

来源:Track D issues 178, 180, 181, 182

---

### L-75. `TypingDotsView.onAppear` 注释错

**位置**:`ClarcChatKit/TypingDotsView.swift:56-63`

**问题**:注释说 "In a non-lazy ScrollView, onAppear fires each time the view scrolls into the viewport" — 但 `StreamingMessageView` 在非 lazy ScrollView 里,view mount 一次,不在 viewport 时 mount。

来源:Track D issue 183

---

### L-76. `ChatView` `windowState.inputText = shortcut.message` race with 用户 typing

**位置**:`ClarcChatKit/ChatView.swift:78-86, 38-43, 29-37`

**问题**:
- 设定 `windowState.inputText` from Task 覆盖用户 typing
- `.onReceive` + `.onAppear` 两条路径 populate shortcuts,view 重建时 stale
- `.onKeyPress(.escape)` 也关 marketplace overlay / slash popup,与 InputBar 协调需验证

来源:Track D issues 187, 188, 189

---

### L-77. ClarcChatKit 跨切面:本地化 key 一致性

**位置**:`Packages/Sources/ClarcChatKit/Resources/*/Localizable.strings`

**问题**:`plutil -lint` + `genstrings -o` 对比 en/ko/zh-Hans 三个 .lproj 找缺失 key。

**建议**:`for f in Packages/Sources/ClarcChatKit/Resources/*/Localizable.strings; do plutil -lint "$f"; done`。

来源:Track D issue 190

---

### L-78. `bundle: .module` 资源 bundle 命名

**位置**:ClarcChatKit 全文件

**问题**:`String(localized: …, bundle: .module)` 解析到 `ClarcChatKit_ClarcChatKit` 之类 bundle。bundle 命名错时,所有 localized 落 English。

**建议**:verify bundle 命名。

来源:Track D issue 191

---

### L-79. `import ClarcCore` 公开 API 一致性

**位置**:ClarcChatKit 全文件

**问题**:`ChatMessage`、`ToolCall`、`MessageBlock`、`Attachment`、`AskUserQuestion`、`CompactionRecord`、`TokenEstimator` 等在 ClarcCore 必须 `public`。如果有 `internal`,ClarcChatKit build 失败。

**建议**:verify 公开性。

来源:Track D issue 192

---

### L-80. `TextPreviewSheet.swift` & `BubbleStyle.swift` 未独立审计

**位置**:`ClarcChatKit/TextPreviewSheet.swift` (63 行) + `BubbleStyle.swift` (117 行)

**问题**:目录有 23 个 ChatKit 文件,审计覆盖 21 个,这两个无独立 section。两者都是 utility/纯样式,无可挖点但覆盖率差异。

来源:Track D verifier V7

---

### L-81. BashSafety `\\$(cmd)` regex bypass(false positive,降级保留为低)

**位置**:`Clarc/Services/BashSafety.swift:111-114`

**问题**:**verifier 验证为 false positive**。`NSRegularExpression` 不关心 `$(` 之前是什么字符,只要字符串里**存在** `$(` 子串就匹配。bash 中用户要触发命令替换,源文本必须含 `$(`、`${`、或 backtick。如果用户用 `\\$(id)`,bash 把 `\\$` 当字面量,**不会**做命令替换(整个字符串就成了字面 `$(id)`)。

**结论**:不存在"既能触发 bash 命令替换、又能逃逸 regex"的字符串。

**建议**:作为"potential future regex bug"提醒保留,**不算高严重度**。

来源:Track A claim 2 (verifier 修正)

---

### L-82. SSHKeyManager `pinnedGitHubPublicKeys` 实际行为 OK,真实风险在 OpenSSH 配置

**位置**:`Clarc/Utilities/SSHKeyManager.swift:199-204`

**问题**:ed25519 + ecdsa 在 allowlist → 命中,acceptedKeys 非空,`addToKnownHosts` 不 throw。**真正风险**在 OpenSSH 配置 `PubkeyAcceptedAlgorithms` 排除 ed25519/ecdsa(legacy / FIPS)。

来源:Track A(与 H-21 同源)

---

### L-83. CLISessionStore `lastTimestamp(in:)` 16KB 窗口可能漏 timestamp

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:301-332`

**问题**:tail 16KB 窗口,若 timestamp line 在 N+几 KB 之前的大 text block 之后,timestamp line 落窗口外。fallback 到 mtime 可能差几秒。

**建议**:bump 窗口到 64KB 或 seek to second-to-last block boundary。

来源:Track B B-14

---

### L-84. CLISessionStore 各种 utf8 / 字符串 split nits

**位置**:`CLISessionStore.swift:189, 252-257, 323-330`

**问题**:`sniffCache.mtime` 用 Date equality 微妙,`sniffSummary` substring check assume compact JSON,`lastTimestamp` 多次 JSON decode 即使 try? nil 仍然 waste。

来源:Track B B-06, B-07, B-13

---

### L-85. CLISessionRecord.UserContent decoder 未知 shape 静默 .parts([])

**位置**:`Packages/Sources/ClarcCore/CLISession/CLISessionRecord.swift:76-86`

**问题**:content 是 `{"foo":"bar"}` 时,string decode 失败、array decode 失败,静默 .parts([])。用户消息被吞。

**建议**:throw 或 log warning。

来源:Track B B-16

---

### L-86. LegacyMigrator `toJSONL` 各种 nits

**位置**:`Packages/Sources/ClarcCore/CLISession/LegacyMigrator.swift`

**问题**:`ISO8601DateFormatter` 每次 call 新建;join 不带 separator;`Int` to `Int` lossless 但 type promotion;NaN/Inf 失败。

来源:Track B B-26, B-27, B-28, B-29

---

### L-87. PickerExposer `normalizeSync` 用 `text.enumerateLines` 剥 `\n` 留 `\r`

**位置**:`Packages/Sources/ClarcCore/CLISession/PickerExposer.swift:68-81`

**问题**:`enumerateLines` splits on `\n`/`\r\n`/`\r`,line arg 不含 terminator。Windows-编辑 jsonl 时 `\r\n` 输出 missing `\r`。

来源:Track B B-32

---

### L-88. `PickerExposer.out.reserveCapacity(text.utf8.count)` over-allocates

**位置**:`Packages/Sources/ClarcCore/CLISession/PickerExposer.swift:64-65`

**问题**:`String.utf8.count` 是 byte count,但 `out` 是 String counts grapheme clusters。Reserve upper bound ~1.5× needed。

来源:Track B B-34

---

### L-89. AppSupport `bundleScopedURL` 不 ensure dir 存在

**位置**:`Packages/Sources/ClarcCore/Utilities/AppSupport.swift:8-13`

**问题**:第一次访问时目录可能不存在,`SessionMetaStore.save` 懒创建,`PersistenceService` 依赖但没保证。

**建议**:加 `create()` static method 幂等创建。

来源:Track B B-41

---

### L-90. `ClipboardHelper.copyToClipboard` 多 click 反馈 flicker

**位置**:`Packages/Sources/ClarcCore/Utilities/ClipboardHelper.swift:6-14`

**问题**:每次调 spawn new Task 设 `feedback = false` 2s 后。两 click 第一次反馈被第二次立即覆盖,然后第一次 Task fire 关掉。cosmetic flicker。

**建议**:存 task handle,re-entry cancel。

来源:Track B B-43

---

### L-91. `DirectoryWatcher` closure-capture 模式正确但未文档化

**位置**:`Packages/Sources/ClarcCore/Utilities/DirectoryWatcher.swift:17-24, 54-67`

**问题**:`weak watcher` 是 load-bearing detail,refactor 移除可能造 retain cycle。

**建议**:加 unit test exercise `unwatchAll` 验证无 leak。

来源:Track B B-44

---

### L-92. `DirectoryWatcher` per-file 事件丢路径

**位置**:`Packages/Sources/ClarcCore/Utilities/DirectoryWatcher.swift:81-85, 64-79`

**问题**:`kFSEventStreamCreateFlagFileEvents` 给了 per-file events 但 callback 一次只 fire `onChange`,`eventPaths` 丢。

来源:Track B B-45

---

### L-93. `DirectoryWatcher` unwatch 顺序

**位置**:`Packages/Sources/ClarcCore/Utilities/DirectoryWatcher.swift:108-115, 71-75, 123-132`

**问题**:`entries.removeValue` 在 `FSEventStreamStop` 前,中间"entry removed but stream still alive"状态短暂。

来源:Track B B-46, B-47

---

### L-94. `DurationFormatting.negative durations` ugly `-1m -30s`

**位置**:`Packages/Sources/ClarcCore/Utilities/DurationFormatting.swift:5-10`

**问题**:`total = -90`:`m = -1, s = -30`,`m > 0` false → `-30s`。丢 minute info。

**建议**:`max(0, total)` guard。

来源:Track B B-48

---

### L-95. `GitHelper.currentBranch` detached HEAD 不区分

**位置**:`Packages/Sources/ClarcCore/Utilities/GitHelper.swift:36-42`

**问题**:`symbolic-ref --short HEAD` 退出 non-zero 在 detached。函数返回 nil 不区分 "detached" / "no git repo" / "git binary missing"。

来源:Track B B-52

---

### L-96. `GitHelper` 硬编码 `/usr/bin/git` 路径

**位置**:`Packages/Sources/ClarcCore/Utilities/GitHelper.swift:6`

**问题**:无 CLT 系统失败静默。

**建议**:搜 PATH 找 git。

来源:Track B B-53

---

### L-97. `GitURLHelpers.query` / `fragment` 漏到 second path component

**位置**:`Packages/Sources/ClarcCore/Utilities/GitURLHelpers.swift:8-17`

**问题**:`https://github.com/owner/repo?tab=repositories` → `owner/repo?tab=repositories`。

**建议**:strip query + fragment 前 split。

来源:Track B B-57

---

### L-98. `GitURLHelpers .git` 无条件 strip

**位置**:`Packages/Sources/ClarcCore/Utilities/GitURLHelpers.swift:12`

**问题**:`https://github.com/owner/repo.gitignore` → `owner/repoignore`。"ignore" 丢。

**建议**:只 strip trailing `.git`。

来源:Track B B-58

---

### L-99. `TaskProgressStore.upsert` 命名 + multi_edit edits[] 不处理

**位置**:`Packages/Sources/ClarcCore/TaskUpdate/TaskProgressStore.swift:68-81`, `TaskUpdateMessageFactory.swift:215-228`

**问题**:`wasNew` 命名 OK 但 caller 用法不直观;multi_edit 不解析 `edits[]`。

来源:Track C 7.6, 7.7, 7.8

---

### L-100. `JSONPathParser` 各种 nits

**位置**:`Packages/Sources/ClarcCore/Usage/JSONPath.swift` 多处

**问题**:offset 是 stub;`parseStringValue` 不识别引号;不支持 `.*`/`[?]`/slice/负数 index。

来源:Track C 6.2, 6.9

---

### L-101. `UsageProvider` enum rawValue 无版本

**位置**:`Packages/Sources/ClarcCore/Usage/UsageProvider.swift`

**问题**:未来 rename 旧数据 decode 失败 fallback `.anthropic`。OK 但加 version 字段是 good practice。

来源:Track C 6.8

---

### L-102. `UsageAdapterFactory.make` 返回 `any UsageAdapter` existential — 跨 actor 可能不安全

**位置**:`Packages/Sources/ClarcCore/Usage/UsageAdapter.swift:39-48`

**问题**:`any UsageAdapter` 是 existential,protocol 标 `Sendable`。实际跨 actor 调用安全,泛型边界 OK。

来源:Track C 6.7

---

### L-103. `processBackgroundQueue` 不检查 `isPending` placeholder 状态

**位置**:`Clarc/App/AppState.swift:3086-3141`

**问题**:placeholder session 还在流时 guard return。placeholder 完成后正常处理。OK。

来源:Track C 9.3

---

### L-104. `recordStreamingDuration` 死代码

**位置**:`Clarc/App/AppState.swift:2180-2193`

**问题**:grep 全文件,`recordStreamingDuration` **没有被任何地方调用**。duration 字段由 `finalizeStreamSession` / `cancelStreaming` 内联处理。

**建议**:删除或用起来。

来源:Track C 1.6

---

### L-105. `AppTheme.statusRunning` 6 个 theme 都从 `accent` 派生

**位置**:`Packages/Sources/ClarcCore/Theme/AppTheme.swift:74`

**问题**:设计合理。但 `statusError` 6 个 theme 都用 `#B85C50` — 见 L-32。

来源:Track C 8.4

---

### L-106. `InspectorMemoPanel` `viewDidChangeEffectiveAppearance` 非 @MainActor 标注

**位置**:`Clarc/Views/Inspector/InspectorMemoPanel.swift:584-601`

**问题**:`isApplyingAppearance` 非 @MainActor 标注,`viewDidChangeEffectiveAppearance` 在某些 edge cases 可被 AppKit off-main 调。

来源:Track D issue 22

---

### L-107. `InspectorMemoPanel` `alert.window` / `tv.window` chain-unwrap 风险

**位置**:`Clarc/Views/Inspector/InspectorMemoPanel.swift:65, 70`

**问题**:`addLink` happy path,`tv` 在 `runModal()` 返回后可能 deallocated。`tv.window?.makeFirstResponder(tv)` 在 70 行可到达 *after* 66 行 return。

来源:Track D issue 13

---

### L-108. `TerminalView` `dismiss` 双调

**位置**:`Clarc/Views/Terminal/TerminalView.swift:240-256, 264-265`

**问题**:`onDisappear` 调 `dismiss()`,内 `dismiss()` else 分支调 `environmentDismiss()`,两条路径都触发 → double-dismiss warning。

来源:Track D issues 28, 29

---

### L-109. `TerminalView` `pollAndSend` generation race

**位置**:`Clarc/Views/Terminal/TerminalView.swift:115, 120, 121, 126, 134, 145-147, 153, 155-157`

**问题**:
- 121-126 间 coordinator 的 process 可被替换(良性 race,二次 pollAndSend re-check)
- `Array(command.utf8) + [0x0D]` 风格不清晰
- `nonisolated(unsafe)` on `onTerminated`/`lastFocusTrigger`/`generation` 误导

来源:Track D issues 25, 26, 27, 31

---

### L-110. `TerminalView.terminalView` 应 `private(set)`

**位置**:`Clarc/Views/Terminal/TerminalView.swift:9`

**问题**:外部代码从不赋值,应 `private(set) var`。

来源:Track D issue 30

---

### L-111. 跨文件 anti-pattern 总结(`FileManager.urls(...).first!` force unwrap)

**位置**(共 3 处):
- `Clarc/Services/PermissionServer.swift:564`(已在 H-31)
- `Packages/Sources/ClarcChatKit/SlashCommandBar.swift:232-233`
- `Packages/Sources/ClarcChatKit/ChatShortcut.swift:66`

**问题**:`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!` 在多处使用,沙盒下理论上不会空但埋雷。`SlashCommandBar.swift:161` 和 `ChatShortcut.swift:171` 都已在 Track D 标为 🟡,但根因同 H-31。Clarc 关闭 sandbox 实际不触发。

**建议**:统一抽 `static func appSupportURL() throws -> URL`。

来源:Track D issues 161, 171 / 跨文件 H-31 同源

---

## 已知未实现(release notes 承认)

> 来源:`release_notes/v2.5.1.md` 和 `v2.5.2.md`

1. **v2.5.1 — Context compaction banner 永久显示**:首次 compact 后,banner 一直显示直到 session 删除(压缩是累积的,反复压缩会丢越来越多原始内容 —— 后续会加 UI 开关让用户"重置 compact")。
2. **v2.5.1 — `/compact` slash 命令没注册**:走工具栏按钮;slash bar 后续可接。
3. **v2.5.1 — autoCompactThreshold 是全局设置**:不走 `WindowState` per-window mirror。
4. **v2.5.1 — 未签名 / 未 notarize**:仅供个人测试,machine 第一次打开需右键 Open。
5. **v2.5.1 — 不支持跨设备分发**:测试用,不要发给别人。
6. **v2.5.2 — turn-block 默认折叠规则**:仅调此,v2.5.1 全部功能保留。
7. **v2.3.0 已知**:MessageBlock 加 `taskUpdate: TaskUpdateMessage?` 可选字段,老消息无 field decode unchanged(✅ OK)。

---

## 未审计 / 建议人工复核

> 来源:Verifier 独立抽查 + track 报告

1. **JSONPathParser 整个 parser**(`Packages/Sources/ClarcCore/Usage/JSONPath.swift`):
   - `pathDebugOffset()` 是 stub,offset 跟踪全 0(Track C 6.1,Track B 不在 scope)
   - unicode escape 不识别
   - 不支持 `.*` 通配、`[?]` predicate、slice、负数 index

2. **TaskUpdateParser.findMatchingBrace 的 unicode escape 状态机**(`Packages/Sources/ClarcCore/TaskUpdate/TaskUpdateParser.swift:200-223`):
   - 不识别 `\u0022`(`"`)、`\u00xx` 等 unicode escape
   - 真实触发:Claude 输出含 emoji/unicode 的 details 字段

3. **JSONPathParser.parseStringValue 不识别引号**(`Packages/Sources/ClarcCore/Usage/JSONPath.swift:159-171`):
   - predicate `[@name="Foo Bar"]` 当前 path parser 不可用

4. **JSONValue Int → Double 转换的精度边界**(`Packages/Sources/ClarcCore/Models/JSONValue.swift`):
   - 53-bit 精度上限,正常 UI 无影响但边界条件需测

5. **ClarcChatKit 跨切面:**
   - `bundle: .module` 资源 bundle 命名一致性(`TextPreviewSheet.swift` 63 行 + `BubbleStyle.swift` 117 行未独立审计)
   - `import ClarcCore` 公开 API 一致性(verify `ChatMessage`、`ToolCall`、`MessageBlock`、`Attachment`、`AskUserQuestion`、`CompactionRecord`、`TokenEstimator` 在 ClarcCore 必须 `public`)
   - `Localizable.strings` 三个 .lproj(en, ko, zh-Hans)key 一致性,跑 `plutil -lint` + `genstrings -o` 对比

6. **LegacyMigrator 整体幂等性**(`Packages/Sources/ClarcCore/CLISession/LegacyMigrator.swift`):
   - Track B 标 🟡 多个,B-23/B-24 migration non-transactional,crash 之间留 legacy 文件 leak
   - B-25 assistant model 字段 nil 时缺省,后续 tools 报 "unknown model"

7. **AppState 测试覆盖**:CLAUDE.md 说明无 test suite。`AppState.init` 注册 `didBecomeActiveNotification` observer,无 unit test 入口。

8. **Mac 启动 X 26.x + SwiftTerm Metal toolchain**:`xcodebuild -downloadComponent MetalToolchain` 一次下载 687 MB。`release_notes/v2.3.0-build.md` 描述。

9. **App 整体编译**:`xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`(需 macOS 15.0+、Xcode 16+)。所有 file:line 引用均已通过 grep 抽样验证,但**未在 Xcode 中实际编译运行**。

10. **Track D Verifier V1(🔴 significant)— ElapsedTimeView Timer.publish 泄漏**:已并入 H-12/H-13。

11. **Track D Verifier V2 — `StatusLineView.abbreviatePath` sandbox bug**:已并入 L-57。

12. **Track D Verifier V5 — `InputBarView.insertAtCursor` 跨窗口 bug**:已并入 M-76。

13. **Track D Verifier V6 — `ChatBridge` action method 静默失败**:已并入 M-69。

14. **Track D Verifier V7 — 覆盖缺口 `TextPreviewSheet.swift` & `BubbleStyle.swift`**:已列在 L-80。

---

## 如何跑复现(build + 跑起来才能 100% 验证的 bug)

> 以下 bug **必须**构建项目 + 实际跑起来才能 100% 验证,grep 抽样只能确认"代码在该位置有此 pattern"。

### 必须 Xcode 编译 + 运行验证的

1. **H-01 `streamingTail!` crash** — 需要 stream + cancel + 延迟事件同时发生才能触发
2. **H-07 `MainView.swift:157` force unwrap crash** — 需要 rapid project 切换 + body re-evaluation 时机
3. **H-08 `SlashCommandManagerView.swift:551` `command!` crash** — 需要 command 在 isEditing 路径上变 nil(罕见)
4. **H-09 `TerminalView` `TerminalProcess` Swift 6 严格并发编译** — 切到 Swift 6 strict mode 编译
5. **H-10 `InspectorMemoPanel` NSAlert `alert.window?.initialFirstResponder`** — 触发"插入链接"按钮
6. **H-11 `InspectorMemoPanel` `MemoContext` let → toolbar 不刷新 + ⌘K 早触发** — inspector 第一次打开 + 立刻 ⌘K
7. **H-12/H-13 `MessageListView.swift:671` + 全 3 处 Timer.publish 泄漏** — 长 session,stream 反复开始/结束,观察 NSObject timer retainCount
8. **H-14 BashSafety `find --delete` / `find --exec=rm`** — 真发命令到 Claude CLI + 看 PermissionServer 自动批准
9. **H-15 BashSafety `git -C /repo push`** — 同上
10. **H-16 ClaudeService Pipe FD 泄漏** — `lsof -p <pid> | grep PIPE` 反复 trigger spawn 失败
11. **H-17 `claude.cleanup()` / `permission.stop()` 永远不被调用** — quit + 打断点验证不被调
12. **H-18 ClaudeService PID 复用杀错进程** — CI 环境、5s 内原进程死 + 复用 PID
13. **H-19 PermissionServer bash_allowlist 损坏静默丢** — 手动改 `~/Library/Application Support/Clarc/bash_allowlist.json`
14. **H-20 MarketplaceService 找不到 Homebrew claude** — `brew install claude-code` 后,跑 plugin install
15. **H-21 SSHKeyManager pinned keys 不含 RSA** — `PubkeyAcceptedAlgorithms +ssh-rsa -ssh-ed25519 -ecdsa-sha2-nistp256`
16. **H-22 CLISessionStore.forkSession regex** — 手工构造一个带嵌套 `sessionId` 的 jsonl 行,fork session
17. **H-25 CLISessionStore.exposeToPicker 与 CLI 写竞争** — CLI 活跃时 expose
18. **H-27 GitHelper stderr 死锁** — 构造 git 命令产生 > 64KB stderr
19. **H-30 SettingsView 本地化混合** — 切到非中文 locale 看 `Text("字体大小")` 显示

### 必须 build + 真实流量验证的(需要 CLI 实际跑)

20. **H-04 `releaseOutgoingSession` 跨项目串文件** — 模拟 placeholder + 切项目 + 切回
21. **H-05 `SessionMetaStore.save` 写盘失败静默丢** — chmod 锁住 Application Support 目录,触发 pin
22. **H-06 placeholder 生命周期** — 切项目时检查 sidebar 残留 "新对话"
23. **H-23 sniffCache 长期泄漏** — 长期运行(数小时)+ 观察 memory
24. **H-29 JSONPathParser offset stub** — 用户在 Settings 配置错误 path 看错误信息

### 必须多窗口/多项目场景验证

25. **M-37 `MainWindowRoot.onDisappear` race** — 多个 ProjectWindow 切换
26. **M-60 `FileTreeView` recursive FileNodeRow** — 大目录展开
27. **M-69 `ChatBridge` handler nil silent no-op** — 在 AppState setup 前点 Send
28. **M-76 `InputBarView.insertAtCursor` 跨窗口** — ProjectWindow + MainWindow 都开,paste

### 必须中等流量验证

29. **M-36 `didBecomeActiveObserver` 每次激活都重读** — 切应用 100+ session 时,看 UI 抖动
30. **M-52 `MessageListView` VStack 而非 LazyVStack** — 10K+ message session,看 UI 卡
31. **M-28 `processStream` `.result` 后 `saveSession` 与 `reloadCommittedFromDisk` 时序竞争** — 长 stream 完成后偶发丢最后一条

### 必须 i18n / locale 验证

32. **M-40 `TokenEstimator.estimate` 把 CJK 当 3 char/token** — 中文 user 观察 autoCompact 触发时机
33. **M-65 `InputBarView` CJK IME commit 检测** — 中文用户输入测试
34. **M-66 `IMETextView` CJK 候选词 Return** — 候选词状态下按 Enter

### 静态可确认的(grep 已验证)

- L-01 ~ L-111 全部
- H-31/H-32 埋雷(等真开启 sandbox 才会触发)
- H-22/H-25/H-26 latent(等未来结构变化触发)
- H-29 等用户配置错误时触发

---

## 报告生成元数据

- **生成时间**:2026-06-05 12:11:59 (Asia/Shanghai, UTC+8)
- **审计范围**:Clarc v2.5.2 (约 127 个 Swift 文件,约 30000 行)
- **总 finding 数**:220(去重跨 track + 拆分同源 bug pattern 后)
- **拆分说明**:
  - Track A 原 11🔴 + 14🟡 + 16🟢 = 41(verifier 修正后真实 10🔴)
  - Track B 10🔴 + 22🟡 + 38🟢 = 70
  - Track C 5🔴 + ~20🟡 + ~15🟢 = ~40
  - Track D 7🔴(verifier 修正) + ~150🟡 + ~45🟢 = ~200
  - 跨 track 去重:force unwrap on URLs 3 处 → 1 条 H-31 + 1 条 L-111 (SlashCommandBar/ChatShortcut 2 位置);Timer.publish 3 处 → H-13 总 + 3 个 sub-items;BashSafety 长选项 6 命令 → H-14 一条
  - 合并后:**32🔴 + 77🟡 + 111🟢 = 220**
- **未做修改**:本报告**仅整理**,不修复任何代码,不修改 track 报告原文。
- **重要声明**:Track A claim 2 (`\\$(cmd)` regex bypass)经 verifier 独立验证为 **false positive**,已降级为 L-81,不再计入 🔴 统计(原 11 修正为 10)。Track D claim 🔴 计数 producer 声称 8,verifier 实际数 7,本文按 7 记录。
# Clarc v2.6.0 — Final Audit Findings (deduped)

**Source audits concatenated**: phase-audit (P-01..P-14), compact-audit (CompactService/ChatBridge integration), fix-integrity-audit (H-01..H-32 re-verification), general-audit (M-NEW-01..05, L-NEW-01..04, re-verified M-52/M-69/M-70/M-74/L-67/L-71).

**Dedupe policy**: when the same bug appears in multiple audits with different wording, the most specific version is kept. Equivalence map (dropped → kept):
- M-NEW-01 (general) + M-NEW-02 (general) + L-NEW-03 (general) → P-10 (phase, most specific: mentions 200 × 30 = 6,000 block iterations).
- M-NEW-03 (general) → P-05 (phase, most specific: UUID silent fallback in `TaskUpdateMessageFactory`).
- M-NEW-04 (Phase.Equatable O(n) on `blocks`) is a separate issue from P-12 (Turn.Equatable on `isInProgress`); both kept.
- P-09 (silent `visibleTurnCap` truncation, 🔴) is distinct from M-52 (VStack vs LazyVStack) — different angle on the same area but different bug.

**Sort**: 🔴 first, then 🟡, then 🟢. Within each severity, sorted by file path (alphabetical, then by line). `Packages/Sources/ClarcCore/...` sorts before `Packages/Sources/ClarcChatKit/...` and `Clarc/...`.

**Fix-integrity outcome**: H-01..H-32 are all INTACT at source level; no regression findings. (Compact-audit's "🟡 applyCompaction persist 失败" was originally H-02, fixed in `a3e95d3`; the remaining failure-mode noted in compact-audit is a *new* audit observation about the fire-and-forget `Task` introduced by the H-02 fix — see C-02 below.)

---

## Bug F-01: focus mode silently disabled after compaction
- Severity: 🔴
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:191-198`
- Description: `makeVisibleTurns` reads `compactionRecord?.originalMessages ?? settledItems` to build the visible list. When a compaction has fired, `compactionRecord` is non-nil and the `settledOnlyMessages` focus-mode filter (which strips everything except user / `isResponseComplete` / `isCompactBoundary`) is bypassed. Users who enabled focus mode before compaction still see the full pre-compaction history afterwards — the toggle is silently a no-op. Regression introduced by the c55581a `compactionRecord?.originalMessages ??` switch in the rewrite.
- Status: REGRESSION (c55581a)
- Reference: compact-audit "focus mode 压缩后失效"

---

## Bug F-02: `visibleTurnCap = 200` silently truncates the view tree with no UI indicator
- Severity: 🔴
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:24-29, 190-199`
- Description: `visibleTurnCap = 200` hard-caps the rendered turn list with no banner, chip, or "show N earlier turns" disclosure. Users in sessions of >200 turns cannot scroll to the top, and the `collapseOverrides` map retains stale entries for the evicted turns. c55581a removed the old `foldToggleButton` ("Show N earlier turns") and replaced it with a silent cap.
- Status: REGRESSION (c55581a)
- Reference: phase-audit P-09

---

## Bug F-03: `writeCompactedHistory` drops `isCompactBoundary` marker; `--resume` reloads summary as plain assistant message
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:604-663`
- Description: The H-02 fix (`a3e95d3`) writes compacted history to disk so it survives restart, but the CLI jsonl format only carries `id / role / timestamp / sessionId / message.content`. On `--resume`, `loadFullSession` rebuilds `ChatMessage` with `isCompactBoundary = false` (the default), so the summary message loses its banner styling (`MessageBubble.swift:37`) and is filtered out in focus mode. Additionally, `compactionRecord?.originalMessages` lives only in memory — restart loses the original-history view entirely.
- Status: NEW (residual defect of the H-02 fix introduced in `a3e95d3`, surfaced by c55581a's tighter integration with `compactionRecord`)
- Reference: compact-audit "🟡 writeCompactedHistory 丢 isCompactBoundary 标记"

---

## Bug F-04: `applyCompaction` schedules a fire-and-forget `Task` for `writeCompactedHistory`; disk-write failure leaves memory/disk divergent
- Severity: 🟡
- File:Line: `Clarc/App/AppState.swift:3268-3276`
- Description: `Task { ... await cliStore.writeCompactedHistory(...) ... }` is not retained. On write failure, `committedMessages = newHistory` has already been applied to the in-memory session (memory says compacted, disk says full); the next `reloadCommittedFromDisk` will overwrite the compacted state and the user silently regresses to the uncompacted view. Only a `logger.error` is produced — no UI surface, no rollback.
- Status: NEW (latent failure mode of the H-02 fix in `a3e95d3`; not introduced by c55581a but not addressed by it either)
- Reference: compact-audit "🟡 applyCompaction 调度的 Task 无人 await"

---

## Bug F-05: `TokenEstimator.estimate(_:)` ignores `taskUpdate` blocks; long sessions underestimate tokens
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcCore/TokenEstimator.swift:12-14`
- Description: `TokenEstimator.estimate(_:)` only sums `blocks.compactMap(\.text)` and divides by 3. `taskUpdate` blocks (titles, summaries, `filesChanged` paths, `testResults` names) contribute zero to the estimate. After c55581a, taskUpdates are far more common (they're now phase headers), so the undercount is amplified. `checkAutoCompact` therefore fires later than it should, and the real context window can be blown before the auto-compact kicks in.
- Status: PRE_EXISTING (in original bug.md; not fixed in v2.5.x; amplified by c55581a)
- Reference: compact-audit "🟡 TokenEstimator.estimate(_:) 用 content getter"

---

## Bug F-06: `MessageListView` outer `VStack` rather than `LazyVStack` — 10K-message session fully renders
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:32-33, 40-41`
- Description: Both the settled and streaming containers use `VStack(spacing: 16)`. c55581a's `visibleTurnCap = 200` is a partial mitigation (caps at 200 turns) but does not fix the root cause — each `TurnBlock` inside is still eagerly created, and `ForEach(turn.assistantMessages)` + per-phase `PhaseBlock` expansion is eager. The 200 cap is also the source of F-02.
- Status: PRE_EXISTING (bug.md M-52, not fixed; c55581a was the natural place to fix it)
- Reference: general-audit "M-52"; bug.md:1284

---

## Bug F-07: `ChatBridge` action handlers nil → silent no-op; no debug assertion, no log
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/ChatBridge.swift:48-58, 66-97`
- Description: `send()`, `cancelStreaming()`, `compact()`, `forkFromHere()`, `editAndResend()` and the c55581a-introduced `compactHandler` all use the `handler?()` pattern. A misconfigured bridge (early launch, mid-window-restoration, or simply an unbinding bug) silently swallows user input. c55581a added `compactHandler` following the same broken pattern.
- Status: PRE_EXISTING (bug.md M-69; not fixed; c55581a added another handler on the same pattern)
- Reference: general-audit "M-69"; bug.md:1522

---

## Bug F-08: `Turn.makeTurns` orphan turn `id = UUID()` regenerated on every call — PhaseBlock `@State` flashes during streaming
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Turn.swift:81`
- Description: When the first message in a turn is an assistant message (orphan), `Turn.makeTurns` assigns `id = UUID()` per call. `chatBridge.messages.last?.blocks.count` fires on every streaming block, so `makeVisibleTurns` runs every tick, the orphan turn gets a brand-new UUID, SwiftUI's `ForEach(visible).id(turn.id)` drops the orphan's `TurnBlock` `@State`, and every per-phase `PhaseBlock` `@State` (MessageListView.swift:556) flashes. Worsened by c55581a (more `@State` per turn).
- Status: PRE_EXISTING (bug.md M-70 / L-48; c55581a touched `Turn.makeTurns` for `foldThreshold` removal but did not stabilise the id)
- Reference: general-audit "M-70"; bug.md:1537, 2168

---

## Bug F-09: `StatusLineView.totalResponseDuration` O(n) per body call + `DateComponentsFormatter` allocated per call
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/StatusLineView.swift:13-18, 177-183, 191-198`
- Description: The reduce runs on every body re-eval; two fresh `DateComponentsFormatter` instances are allocated per call (lines 177, 191). With a 10K-message session, that's 10K+ reduce ops per render and SwiftUI re-evaluates on every text delta. `FileManager.default.homeDirectoryForCurrentUser.path` is also called on every render. Unaffected by c55581a; flagged again because the surrounding code changed and the next refactor is the natural place to fix it.
- Status: PRE_EXISTING (bug.md M-74 / L-71; not fixed)
- Reference: general-audit "M-74"; bug.md:1586, 2426

---

## Bug F-10: Back-to-back `taskUpdate` blocks create a spurious empty phase
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:99-135, 105-116`
- Description: `Phase.makePhases` flushes with `owned = closing.map { _ in true } ?? !accumulator.isEmpty`. When two `taskUpdate` blocks arrive consecutively (closing one phase, opening the next with no work in between), the second becomes its own phase with `blocks = [taskUpdate2]`. The header renders but `phaseDetail` filters out the taskUpdate, so the user sees an empty "Phase" row between real phases.
- Status: REGRESSION (c55581a)
- Reference: phase-audit P-01

---

## Bug F-11: `TaskUpdate` with `.running` and no `endTime` shows live spinner after turn ends
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:148-154, 105-115`
- Description: `TaskUpdateMessageFactory.makeRunning` creates a card with `status: .running` and no `endTime`. The card is only finalized when a matching `tool_result` arrives. If the tool never returns (CLI crash, killed subprocess, lost connection), the running taskUpdate stays at `.running` forever. `Phase.makePhases` faithfully reflects that — the closed phase keeps a perpetual spinner with no duration even after the rest of the chat has settled.
- Status: PRE_EXISTING (the underlying "orphaned running taskUpdate" path was present pre-Phase; Phase.swift inherits the behavior, this is a new finding rather than a regression)
- Reference: phase-audit P-04

---

## Bug F-12: Two `taskUpdate` blocks with colliding UUIDs collapse to one in the `ForEach`
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:118-130`
- Description: Phase identity is `closing.id.uuidString`. `TaskUpdateMessageFactory.makeRunning(id: "non-uuid-string")` and `makeWithInput` silently fall back to `UUID()`. If a malformed or repeated `toolUseId` decodes to the same UUID (low but non-zero probability), the resulting phase ids collide and `ForEach(phases)` drops the second row. `TaskProgressStore` tolerated this via upsert; the new `Phase` machinery does not.
- Status: REGRESSION (c55581a — Phase.swift's id-stability requirement is new)
- Reference: phase-audit P-05

---

## Bug F-13: `Phase.makePhases` recomputed on every body re-evaluation (no memoization)
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:448, 490`
- Description: `Phase.makePhases` is called inline in `collapsedSummary` and `expandedContent`. Both are body properties; they re-evaluate on every SwiftUI invalidation. During streaming, `rebuildSettledItems` fires on every `chatBridge.messages.last?.blocks.count` change (line 119-125), so the body can re-evaluate 10-100 times/sec. For a 200-turn view with 30 blocks each, that's 6,000 block iterations per render — and the per-delta cost across all visible settled turns is ~7,500 ops/sec on a 50-turn session with 10 deltas/sec. No `@State` cache, no memoization.
- Status: REGRESSION (c55581a — Phase.swift is new, the derivation cost is new)
- Reference: phase-audit P-10; general-audit M-NEW-01, M-NEW-02, L-NEW-03

---

## Bug F-14: `Turn.Equatable` synthesis includes `isInProgress` — `ForEach(visible)` re-evaluates the diff on every streaming tick
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Turn.swift:9-28`
- Description: `Turn` declares `var isInProgress: Bool` and synthesises `Equatable`. The synthesised equality compares every field including `isInProgress`, so when the flag flips the `Turn.==` returns false and SwiftUI rebuilds the `TurnBlock` subtree (identity stable via `.id(turn.id)`, but the props re-evaluate and `Phase.makePhases` re-runs). Compounds with F-13.
- Status: PRE_EXISTING (bug.md L-48, not fixed in c55581a; the new Phase.swift's per-body recompute amplifies the cost)
- Reference: phase-audit P-12; bug.md:2168

---

## Bug F-15: `Phase.Equatable` synthesis includes `blocks: [MessageBlock]` — O(n) equality on every diff
- Severity: 🟡
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:20`
- Description: `Phase` is `Equatable`-synthesised, comparing `blocks: [MessageBlock]`, `taskUpdate: TaskUpdateMessage?` (which itself carries `[TaskFileChange]` + `[TaskTestResult]`). Every `ForEach(phases)` diff runs `Phase.==` over the entire blocks array. For a 200-turn session with 50 blocks per turn, each `body` re-eval does 200 × 50 = 10,000 `MessageBlock` equality checks.
- Status: REGRESSION (c55581a — Phase is new)
- Reference: general-audit M-NEW-04

---

## Bug F-16: "Working…" copy with green checkmark on settled thinking-only fallback phase
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:58-75, 158-169`
- Description: A turn whose blocks are only thinking (no text, no tool, no taskUpdate) produces one fallback phase titled `"Working…"` because `subtitleForFallback` returns `""` for that input. When the turn is no longer streaming, the phase status flips to `.done` and the collapsed summary shows `✓ Working…` — the green check contradicts the "Working…" copy. Cosmetic.
- Status: REGRESSION (c55581a — Phase.swift is new)
- Reference: phase-audit P-02

---

## Bug F-17: Degenerate `taskUpdate` with empty title falls back to literal "Phase"
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:148-150`
- Description: When `TaskUpdateMessage.title` is empty, `makePhase` substitutes the literal string `"Phase"`. `TaskUpdateParser.parse(jsonObject:)` rejects empty titles from JSON, so the codepath is only reachable when a caller constructs `TaskUpdateMessage(title: "")` directly. Low likelihood (no current factory produces this), but the placeholder gives the user no information.
- Status: REGRESSION (c55581a — Phase.swift is new)
- Reference: phase-audit P-03

---

## Bug F-18: Empty `assistantMessages` on a turn renders the user prompt twice (collapsed row + user bubble)
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:447-479` + `Packages/Sources/ClarcChatKit/Turn.swift:97-101`
- Description: When the active streaming turn has not yet produced any settled assistant blocks, `collapsedSummary` falls through to `Text(turn.collapsedAssistantText.isEmpty ? "…" : turn.collapsedAssistantText)`. `collapsedAssistantText` is `assistantMessages.last?.content ?? userMessage.content` — with empty `assistantMessages` it returns the user prompt, so the user sees their own prompt rendered as the assistant preview while the model is still in its thinking prefix. The `…` literal at line 463 is dead code and is also not localised.
- Status: REGRESSION (c55581a — the new `…` literal is new; the duplicated-prompt issue was pre-existing in the collapsed-summary concept but the dead-code branch is new)
- Reference: phase-audit P-06

---

## Bug F-19: `toggleCollapse` writes an override even when `collapseAllTurns` masks it
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:166-183`
- Description: When `chatBridge.collapseAllTurns` is on, the user can still click the chevron and `toggleCollapse` writes `collapseOverrides[turnId] = !true = false`. The override is stored but invisible. When the user later turns off "Collapse all", the previously-clicked turn is in the toggled state without the user having observed a change. Cosmetic, surprising UX.
- Status: REGRESSION (c55581a — `toggleCollapse` was rewritten in c55581a to fix the last-turn no-op bug; the masking-by-`collapseAllTurns` interaction is a side effect of the rewrite)
- Reference: phase-audit P-07

---

## Bug F-20: `collapseOverrides` retains entries for turns evicted by `visibleTurnCap`
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/MessageListView.swift:22, 81-103, 180-183, 196-198`
- Description: `collapseOverrides: [UUID: Bool]` is keyed by `turn.id` and is only cleared on session switch or via `toggleCollapse`. When a turn is evicted by the 200-turn cap, the override stays in the dict indefinitely. For a long session the dict grows unbounded for the lifetime of the window. Minor memory issue, not a correctness bug.
- Status: REGRESSION (c55581a — interaction between the new `visibleTurnCap` and the pre-existing `collapseOverrides` map)
- Reference: phase-audit P-13

---

## Bug F-21: `Phase.derive` idempotency — same `id`, different `status` for trailing phase across stream transitions
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:99-135, 158`
- Description: The trailing fallback phase's `id` is stable (`"fallback-<first-block-id>"`) but its `status` and `isInProgress` differ depending on the `isStreamingLast` flag. Across the streaming→settled transition, `Phase.==` returns false for the same id with different status, and `ForEach(phases)` may drop `@State`. The deliberate design choice, not a bug, but flagged because the cost is amplified by F-13 (no memoization).
- Status: PRE_EXISTING design choice in c55581a
- Reference: general-audit M-NEW-05

---

## Bug F-22: `Phase.swift` relies on transitive re-export of `TaskUpdateMessage` / `TaskUpdateStatus`
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:1-3`
- Description: `Phase.swift` imports `ClarcCore` and uses `TaskUpdateStatus` / `TaskUpdateMessage` from `ClarcCore/Models/`. Works today via re-export, but if `ClarcCore`'s public API is ever refactored to hide these types, `Phase.swift` breaks with a confusing "cannot find type" error. Style/maintainability.
- Status: REGRESSION (c55581a — Phase.swift is new)
- Reference: general-audit L-NEW-01

---

## Bug F-23: `subtitleForFallback` and `Turn.collapsedAssistantText` compute similar labels with two different algorithms
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:66-75` + `Packages/Sources/ClarcChatKit/Turn.swift:122-125`
- Description: Both produce a short "what did the assistant do" label. `Phase.subtitleForFallback` uses `(tool count) tools · (first text line)`; `Turn.collapsedAssistantText` uses the last assistant message's content. Deliberately different (phase-level vs turn-level), but the cognitive overhead of two algorithms in the same chat view is non-trivial. Consider unifying.
- Status: REGRESSION (c55581a — Phase.swift is new)
- Reference: general-audit L-NEW-02

---

## Bug F-24: `Phase.makePhases` / `makePhase` / nested `flush` — mixed naming convention
- Severity: 🟢
- File:Line: `Packages/Sources/ClarcChatKit/Phase.swift:99-181`
- Description: `makePhases` (plural) returns `[Phase]`; the per-phase helper is `makePhase` (singular); `flush` is a nested function inside `makePhases`. Style only, but unusual for a Swift public API.
- Status: REGRESSION (c55581a — Phase.swift is new)
- Reference: general-audit L-NEW-04

---

## Bug F-25: `SettingsView` mixed deprecation patterns + `@State` for class instances + `bindingPath` helpers
- Severity: 🟢
- File:Line: `Clarc/Views/SettingsView.swift` (multiple)
- Description: c55581a removed the `foldThresholdSection` from `ChatSettingsTab` (a good cleanup), but the rest of the L-67 items — `Text(LocalizedStringKey(...))` vs `Text(verbatim:)` mixing (largely fixed by H-30), `@State` for class instances, `bindingPath` helpers — are untouched. Predates c55581a and is unaffected by it.
- Status: PRE_EXISTING (bug.md L-67; not addressed by c55581a)
- Reference: general-audit "L-67"; bug.md:2374

---

## Notes on items reviewed and dropped

The following audit findings were reviewed and **dropped** from the final list because they were verified intact/working-as-designed in the fix-integrity audit and do not represent bugs:

- **P-08 / P-11 / P-14** (phase-audit): `collapseOverrides` reset on session switch — verified correct. Phase ids stable across rebuilds — verified correct. Non-ASCII titles render correctly — verified correct.
- **compact-audit "ChatBridge.compactionRecord push timing"** (🟢): `withObservationTracking` semantics make `compactionRecord` and `messages` updates atomic; no race with `collapseOverrides` (which is local `@State`).
- **compact-audit "checkAutoCompact race"** (🟢): `CompactService.inFlight` coalescing is documented design intent.
- **compact-audit "Phase.makePhases 误读 summary message"** (✅): the summary message has only `[.text(...)]` blocks (no `taskUpdate`), so `Phase.makePhases` treats it as a fallback phase — verified correct, no spurious phase boundary is created.
- **compact-audit "writeCompactedHistory 不写 isError / duration / attachmentPaths"** (🟢): CLI jsonl format limitation, not v2.6.0-introduced, not actionable in Clarc.
- **fix-integrity-audit H-01..H-32**: all 32 H-tier fixes INTACT at source level in v2.6.0. Zero regressions, zero new H-tier bugs from c55581a. The streamingTail! guard (H-01, line 1877) is preserved; the 77 downstream unwraps are protected by the ownership gate at `processStream:1455`.
- **general-audit security regression check**: c55581a is UI-only. No security regressions.

---

## Summary

| Severity | Count | New | Regression | Pre-existing |
|----------|-------|-----|------------|--------------|
| 🔴       | 2     | 0   | 2 (F-01, F-02) | 0 |
| 🟡       | 13    | 0 (F-03/F-04 are residual of H-02 fix) | 7 (F-10, F-12, F-13, F-15 + residuals) | 6 (F-05, F-06, F-07, F-08, F-09, F-14) |
| 🟢       | 10    | 0   | 8 (F-16, F-17, F-18, F-19, F-20, F-22, F-23, F-24) | 2 (F-21, F-25) |
| **Total** | **25** | 0 | 17 | 8 |

**Highest-priority fixes**:
1. **F-01** (focus mode after compaction, 🔴) — `MessageListView.makeVisibleTurns` needs to apply the focus-mode filter to `compactionRecord?.originalMessages`, not only to `settledItems`.
2. **F-02** (silent `visibleTurnCap` truncation, 🔴) — add a disclosure chip ("N earlier turns hidden — show all") or, better, replace `VStack` with `LazyVStack` and remove the cap.
3. **F-03 + F-04** (compaction persistence residue, 🟡) — write a `__CLARC_COMPACT_BOUNDARY__` sentinel in `message.content` for `isCompactBoundary` messages; convert the fire-and-forget `Task` in `applyCompaction` to a retained task with rollback on failure.

**Next-priority cluster** (F-13 / F-14 / F-15) — the `Phase` recompute hot path. Memoizing `Phase.makePhases` per turn in `makeVisibleTurns` (returning `[(Turn, [Phase])]`), excluding `isInProgress` from `Turn.==` and writing a manual `Phase.==` that compares only discriminator fields would silence most of the per-delta cost.

---

## 修复优先级建议

**第一波**(防用户数据 / 体验, ~1-2 小时):
1. **F-01 + F-02** (focus mode 折叠后失效 / 200 cap 静默截断, 🔴) — 都集中在 `MessageListView.swift:191-198` 的 `makeVisibleTurns`:
   - F-01: `compactionRecord?.originalMessages ?? settledItems` 改为走 `settledOnlyMessages` 过滤逻辑
   - F-02: 把 `visibleTurnCap` 替换回 `foldToggleButton` 显示"+ N earlier turns"占位条

**第二波**(compaction 数据完整性, ~2 小时):
2. **F-03 + F-04** (compaction persistence residue, 🟡) — `writeCompactedHistory` 把 `isCompactBoundary` 标记成 `__CLARC_COMPACT_BOUNDARY__` sentinel 写入 `message.content`;`applyCompaction` 把 fire-and-forget `Task` 改成 retained task + 失败时回滚内存。

**第三波**(性能 / 折叠渲染 hot path, ~3-4 小时):
3. **F-13 / F-14 / F-15** (Phase recompute hot path) — `makeVisibleTurns` 返回 `[(Turn, [Phase])]` memoize,`Turn.==` 排除 `isInProgress`,手写 `Phase.==` 只比较 discriminator 字段(id / status / duration)。一次解决大半 streaming per-delta 成本。

**第四波**(分散的 🟢,可选):F-16 ~ F-21 都是单点 fix,~30 分钟搞定。
