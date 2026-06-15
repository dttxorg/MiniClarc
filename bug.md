# v2.6.1 Audit — Fresh Scan

> **Generated**: 2026-06-15
> **Target**: HEAD = v2.6.1 (commit `0ef657f`)
> **Method**: 5 parallel agents (1 context reader + 4 track auditors: services / chat-rendering / state / UI)
> **Prior audits**: `bug.md` v2.5.2 (220 findings, 32 H fixes applied in v2.5.3-v2.5.4) and v2.6.0 audit (F-01..F-21, 2 🔴 committed in 1d18d48 but **not actually fixed** — see regressions).

## Summary

- 🔴 High: 7
- 🟡 Medium: 38

- REGRESSION (introduced by v2.6.1 commit 1d18d48 or its sub-features): 5
- NEW (v2.6.1 code paths not in prior audits): 24
- UNFIXED (from prior audits still real at HEAD): 16

> **Two important notes from the audits:**
>
> 1. **The v2.6.1 commit `1d18d48` made false claims.** Its message asserts fixes to F-01, F-02, F-13, F-14, F-15, F-20 from the v2.6.0 audit, but `git show 1d18d48 --` confirms NONE of those lines were touched. F-01 (focus-mode bypass on compactionRecord.originalMessages) and F-02 (200-turn silent cap with no UI disclosure) are still real at HEAD.
>
> 2. **The `summarizeCompletedPhases` pipeline added by 1d18d48 is fire-and-forget with no timeout, no cancellation, no retry cap, and accumulates zombie `claude -p` subprocesses** if the model hangs (one of the four most severe findings).

## Findings

### F-22 [🔴] summarizeCompletedPhases pipeline has no timeout / cancel — single hang blocks all summaries

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:3286`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  AppState.swift:3286-3325 (`summarizeCompletedPhases`) launches a fire-and-forget `Task { [weak self] in for (phaseId, digest) in digestPairs { try await claudeRef.summarizePhase(content: digest, cwd: cwd) } }`. The for-loop is sequential, has no timeout, no retry, no cancel path. `claudeRef.summarizePhase` (ClaudeService.swift:270-296) shells out via `runShellCommand` which itself has no timeout (ClaudeService.swift:773-802 — bug.md M-A3). One stuck `claude -p` blocks the entire pipeline. The phase is marked `pending` in `PhaseSummaryStore` synchronously (line 3304-3306) BEFORE the Task is launched, so a stuck call leaves the phase in `pending` forever. The next `.result` event will SKIP that phase (filter line 3300: `!store.isPending(phase.id)`) — so a permanent hang on one phase only blocks other summaries of the same id, but the pending set in WindowState.phaseSummaryStore retains a stale entry indefinitely.
  ```
- **Repro**: 1. Have a session that completes a phase. 2. The phase's summarization call to `claude -p` hangs (network blip, child process defunct, etc.). 3. The next phases in `digestPairs` are blocked behind the hung call. 4. The user never sees a summary for any of them. 5. On window close, `phaseSummaryStore.clear()` is never called because there's no `onDisappear` hook to do so (the store is owned by WindowState which has no cleanup path; it just gets GC'd when the window dies).

### F-23 [🔴] summarizeCompletedPhases fire-and-forget Task has no cancel, no timeout, no retry; accumulates zombie claude subprocesses

- **File**: `Clarc/App/AppState.swift:3309`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackC
- **Evidence**:
  ```
  Clarc/App/AppState.swift:3309: `Task { [weak self] in guard let self else { return } }` — the `guard let self` is dead code (the closure body never references `self`), but the Task is FIRE-AND-FORGET with no handle stored anywhere. The Task captures `store` (window.phaseSummaryStore) and `digestPairs` strongly. The `for (phaseId, digest) in digestPairs` loop is sequential with NO `Task.isCancelled` check, NO `Task.sleep` polling for cancellation, NO timeout. `runShellCommand` (line 287-291 of ClaudeService.swift) also has no timeout. A single `claude -p` hang blocks the entire summary pipeline forever. Every `.result` event handler in `processStream` (line 1684) re-arms this pipeline, so a user with N sessions closing each turn gets N×T concurrent `claude` subprocesses (the previous one is still running, never cancelled). On a long phase with multiple sub-phases, the user accumulates one zombie CLI per phase summary request.
  ```
- **Repro**: Run any turn that produces one or more phases with `taskUpdate` boundaries. Open the terminal and observe multiple `claude -p` processes running in the background even after the foreground response completes. To reproduce the hang, set `--max-thinking-tokens` to a very high value (e.g. via .claude/settings.json) and watch the summarization pipeline stall indefinitely.

### F-24 [🔴] runShellCommand in summarizePhase has no timeout / SIGTERM-SIGKILL fallback; one hang blocks the entire summary pipeline

- **File**: `Clarc/Services/ClaudeService.swift:287`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackC
- **Evidence**:
  ```
  Clarc/Services/ClaudeService.swift:287-291: `summarizePhase` calls `runShellCommand` which has no timeout. `runShellCommand` (line 845-874) spawns a `Process` and `await withCheckedContinuation { proc.terminationHandler = { _ in continuation.resume() } }` — there is NO `proc.terminate()` fallback if the child hangs. `summarizePhase` is now invoked by `summarizeCompletedPhases` for every closed phase on every `.result` event (line 1684). If `claude -p` is waiting on a network call, a permission prompt (unlikely on -p but possible for the wrapper), or any model hang, the call never returns. The Task that owns the call is detached and has no cancel path (M-C2). A single prompt-injection-flavored tool result that makes the summarization model hang stalls the entire pipeline.
  ```
- **Repro**: Send a turn that completes with at least one phase. While the user is typing their next turn, the summary background task starts. Simulate the model hanging by killing the network and the next summarization call blocks forever, leaving a `claude -p` process pinned indefinitely.

### F-25 [🔴] F-02: visibleTurnCap=200 silently truncates long sessions with no disclosure

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:29`
- **Category**: ux  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:29 (`private static let visibleTurnCap = 200`) and MessageListView.swift:195-198 (`Array(all.suffix(cap))`) silently truncate the turn list with no disclosure to the user. `grep -rn 'earlier turns' /Packages/Sources/ClarcChatKit/Resources/` returns no matches. `grep foldToggleButton` returns no matches. The user has no way to see the older turns. The 1d18d48 commit message claims a `foldToggleButton`-style '+ N earlier turns' placeholder was added, but the actual code only contains a comment (lines 24-28) — no view, no localizable key.
  ```
- **Repro**: Load a session with >200 turns. The first 200-N turns are silently dropped from the view tree. There is no 'show N earlier turns' button to expand the visible range, no count of dropped turns, and no way for the user to navigate to them.

### F-26 [🔴] v2.6.1 commit message falsely claims F-01/F-02/F-13/F-14/F-15/F-20 fixes — none of the six landed in code at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:189`
- **Category**: ux  ·  **Status**: UNFIXED
- **Source track**: TrackB
- **Evidence**:
  ```
  Commit message for 1d18d48 ("fix(chat): v2.6.0 audit round 1 — focus mode + 200-cap + hot-path") explicitly claims:
  - "F-01: focus mode filter now applies to compactionRecord.originalMessages"
  - "F-02: the silent 200-turn visibleTurnCap is replaced with a foldToggleButton-style placeholder showing '+ N earlier turns'"
  - "F-13: makeVisibleTurns returns the (Turn, [Phase]) pair cached for the duration of one body re-evaluation"
  - "F-14: Turn drops isInProgress from synthesized Equatable"
  - "F-15: Phase.== compares discriminator fields only"
  - "F-20: collapseOverrides is also pruned when turns are evicted by the cap"
  
  But `git show 1d18d48 -- Packages/Sources/ClarcChatKit/MessageListView.swift` does not touch any of the relevant lines. At HEAD:
  - MessageListView.swift:29 — `private static let visibleTurnCap = 200` still present (line untouched in 1d18d48 diff).
  - MessageListView.swift:189 — `private func makeVisibleTurns() -> [Turn]` still returns `[Turn]`, NOT `[(Turn, [Phase])]`.
  - MessageListView.swift:190 — `let source: [ChatMessage] = chatBridge.compactionRecord?.originalMessages ?? settledItems` — focus mode filter from settledOnlyMessages (line 224) is NOT applied to this branch.
  - Turn.swift:9-28 — no `static func ==` override; isInProgress is still a stored `var` and synthesized Equatable still includes it.
  - Phase.swift:20 — no `static func ==` override; synthesis still compares `blocks: [MessageBlock]`, `taskUpdate: TaskUpdateMessage?`.
  - collapseOverrides only cleared in `.task(id: windowState.currentSessionId)` on session switch (line 86), never when turns are evicted by the cap.
  
  The Localizable.strings diff for 1d18d48 adds 6 new keys per locale (Waiting/Running/…/%lld tools run/%lld chars/%.1fs thinking) — but the "Show N earlier messages" / "Collapse earlier messages" keys (which exist in all 3 locales) are still not wired to any view. The "foldToggleButton" view does not exist anywhere in the codebase (`grep foldToggleButton` returns nothing). Net: six F-tier fixes advertised in the commit message did NOT land in code. Users with sessions >200 turns still see the silent cap with no disclosure; focus mode is still bypassed after compaction; per-delta cost of every streaming tick on a long session is unchanged from pre-1d18d48.
  ```
- **Repro**: 1. Open a session that has been compacted (use /compact), or open a session with >200 turns.
2. Expected per release notes / commit message: a "+ N earlier turns" disclosure placeholder appears; focus-mode filter applies to compactionRecord.originalMessages.
3. Actual: silent 200-turn cap with no disclosure; focus mode shows raw pre-compaction messages with assistant/streaming entries not filtered.

### F-27 [🔴] F-01: focus-mode filter still bypassed when rendering compactionRecord.originalMessages

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:190`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:190 — `let source: [ChatMessage] = chatBridge.compactionRecord?.originalMessages ?? settledItems` reads the pre-compaction snapshot directly without applying the `windowState.focusMode` filter that `settledOnlyMessages` (line 224-226) applies. When focus mode is on, the live `settledItems` are filtered to `user` / `isResponseComplete` / `isCompactBoundary`, but the compaction-record path bypasses this filter. After a compaction with focus mode enabled, the user sees the full unfiltered original history. Commit message for 1d18d48 claims the fix landed, but the diff never modified line 190.
  ```
- **Repro**: 1. Open a session with >5 turns. 2. Enable focus mode. 3. Trigger a context compaction. 4. The compact banner appears but the turns above the compact boundary are now unfiltered (the pre-compaction history shows ALL roles, not just user / completed-assistant / compact-boundary).

### F-28 [🔴] F-02 visibleTurnCap=200 silent cap STILL not replaced with foldToggleButton placeholder (commit-claim false)

- **File**: `Packages/Sources/ClarcChatKit/MessageListView.swift:29`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Packages/Sources/ClarcChatKit/MessageListView.swift:29, 189-198: Line 29 still has `private static let visibleTurnCap = 200`. Line 195-197 still has `let cap = Self.visibleTurnCap; if all.count <= cap { return all } return Array(all.suffix(cap))`. There is NO `foldToggleButton`-style placeholder, NO "+ N earlier turns" disclosure, NO `Localizable.strings` key. A 300-turn session silently shows only the last 200 turns — earlier turns are invisible with no user-facing indicator. The commit message for 1d18d48 explicitly claims this was fixed: "the silent 200-turn visibleTurnCap is replaced with a foldToggleButton-style placeholder showing '+ N earlier turns'". The code contradicts the commit message.
  ```
- **Repro**: Create or load a session with 250 turns. Open the chat view. The first 50 turns are missing from the view tree with no disclosure to the user. The user cannot scroll up to find them, cannot click a placeholder, and there is no way to load them. Confirmed by `grep` across `Packages/Sources/ClarcChatKit/Resources/*/Localizable.strings` for "earlier turns" / "fold" / "+ N" — no matches.

### F-29 [🟡] F-01 false-claim fix: focus-mode filter is NOT applied to compactionRecord.originalMessages at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:189-198`
- **Category**: correctness  ·  **Status**: REGRESSION
- **Source track**: TrackD
- **Evidence**:
  ```
  Commit 1d18d48 message claims "F-01 fix: focus mode filter now applies to compactionRecord.originalMessages as well as settledItems." `git show 1d18d48 -- MessageListView.swift` adds zero lines to the makeVisibleTurns body. The code at MessageListView.swift:189-198 still reads `let source: [ChatMessage] = chatBridge.compactionRecord?.originalMessages ?? settledItems` then `let all = Turn.makeTurns(from: source, isStreamingLast: chatBridge.isStreaming)`. The focus-mode filter (line 224-226 in `settledOnlyMessages`) is applied only to `chatBridge.messages` via `rebuildSettledItems()` → `settledItems`, NEVER to `compactionRecord?.originalMessages`. So after a compaction, focus mode shows ALL messages (including thinking/tool-call blocks from `originalMessages`), bypassing the user-selected filter. The bug.md F-01 finding is INTACT at HEAD.
  ```
- **Repro**: 1. Build a long session with many tool calls. 2. Enable focus mode (only user prompts and completed assistant responses). 3. Trigger /compact. 4. Observe that the focus-mode filter is dropped: thinking blocks, partial tool calls, and noisy intermediate assistant messages reappear.

### F-30 [🟡] F-02 false-claim fix: visibleTurnCap=200 silent truncation NOT replaced at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:24-29, 189-198`
- **Category**: correctness  ·  **Status**: REGRESSION
- **Source track**: TrackD
- **Evidence**:
  ```
  Commit 1d18d48 message claims "F-02 fix: visibleTurnCap replaced with foldToggleButton-style placeholder showing '+ N earlier turns'." At MessageListView.swift:24-29 the constant `private static let visibleTurnCap = 200` is still present. At line 195-198 the body still has `let cap = Self.visibleTurnCap; if all.count <= cap { return all }; return Array(all.suffix(cap))`. No `foldToggleButton` view exists. `grep -rn 'earlier turns' Packages/Sources/ClarcChatKit/Resources` returns no matches. The 6 new Localizable.strings keys added by 1d18d48 (Streaming/Thinking/Running etc.) include NO key for the disclosure. F-02 is INTACT at HEAD — long sessions silently truncate the oldest 200-turns-with-no-disclosure, the same regression introduced by c55581a.
  ```
- **Repro**: 1. Build a session with >200 turns. 2. Observe that the oldest turns are silently dropped (no "+ N earlier turns" disclosure, no way to scroll back). The `collapseOverrides` map also retains entries for evicted turns (F-20 same commit's third false-claim).

### F-31 [🟡] F-02 false-claim fix: visibleTurnCap=200 silent truncation NOT replaced at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:24`
- **Category**: correctness  ·  **Status**: REGRESSION
- **Source track**: TrackD
- **Evidence**:
  ```
  Commit 1d18d48 message claims "F-02 fix: visibleTurnCap replaced with foldToggleButton-style placeholder showing '+ N earlier turns'." At MessageListView.swift:24-29 the constant `private static let visibleTurnCap = 200` is still present. At line 195-198 the body still has `let cap = Self.visibleTurnCap; if all.count <= cap { return all }; return Array(all.suffix(cap))`. No `foldToggleButton` view exists. `grep -rn 'earlier turns' Packages/Sources/ClarcChatKit/Resources` returns no matches. The 6 new Localizable.strings keys added by 1d18d48 (Streaming/Thinking/Running etc.) include NO key for the disclosure. F-02 is INTACT at HEAD — long sessions silently truncate the oldest 200-turns-with-no-disclosure, the same regression introduced by c55581a.
  ```
- **Repro**: 1. Build a session with >200 turns. 2. Observe that the oldest turns are silently dropped (no "+ N earlier turns" disclosure, no way to scroll back). The `collapseOverrides` map also retains entries for evicted turns (F-20 same commit's third false-claim).

### F-32 [🟡] F-01 false-claim fix: focus-mode filter is NOT applied to compactionRecord.originalMessages at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:189`
- **Category**: correctness  ·  **Status**: REGRESSION
- **Source track**: TrackD
- **Evidence**:
  ```
  Commit 1d18d48 message claims "F-01 fix: focus mode filter now applies to compactionRecord.originalMessages as well as settledItems." `git show 1d18d48 -- MessageListView.swift` adds zero lines to the makeVisibleTurns body. The code at MessageListView.swift:189-198 still reads `let source: [ChatMessage] = chatBridge.compactionRecord?.originalMessages ?? settledItems` then `let all = Turn.makeTurns(from: source, isStreamingLast: chatBridge.isStreaming)`. The focus-mode filter (line 224-226 in `settledOnlyMessages`) is applied only to `chatBridge.messages` via `rebuildSettledItems()` → `settledItems`, NEVER to `compactionRecord?.originalMessages`. So after a compaction, focus mode shows ALL messages (including thinking/tool-call blocks from `originalMessages`), bypassing the user-selected filter. The bug.md F-01 finding is INTACT at HEAD.
  ```
- **Repro**: 1. Build a long session with many tool calls. 2. Enable focus mode (only user prompts and completed assistant responses). 3. Trigger /compact. 4. Observe that the focus-mode filter is dropped: thinking blocks, partial tool calls, and noisy intermediate assistant messages reappear.

### F-33 [🟡] F-13/F-14/F-15 false-claim fixes: hot-path memoization and Equatable refinements NOT in code at HEAD

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Phase.swift:20`
- **Category**: perf  ·  **Status**: REGRESSION
- **Source track**: TrackD
- **Evidence**:
  ```
  Commit 1d18d48 message claims "F-13 fix: makeVisibleTurns returns the (Turn, [Phase]) pair cached for the duration of one body re-evaluation; F-14: Turn drops isInProgress from synthesized Equatable; F-15: Phase.== compares discriminator fields only." None of these are in HEAD. (a) MessageListView.swift:189 signature is `private func makeVisibleTurns() -> [Turn]`, not `[(Turn, [Phase])]`. (b) Phase.makePhases is still called inline at MessageListView.swift:447 (in `collapsedSummary`) and 489 (in `expandedContent`) — the bug.md F-13 hot-path regression "6,000 block iterations per render" is INTACT. (c) `grep -n 'static func ==' Turn.swift` returns no matches — F-14 INTACT, isInProgress still in synthesized Equatable so the body re-evaluates the turn's collapse icon on every streaming tick. (d) `grep -n 'static func ==' Phase.swift` returns no matches — F-15 INTACT, Phase equality compares `blocks: [MessageBlock]` arrays on every view body invocation.
  ```
- **Repro**: Open a 200-turn session. Watch Instruments: every streaming delta fires view body re-evaluation; for each Turn in the visible window, `Phase.makePhases` walks the full block list twice (collapsedSummary + expandedContent). No memoization, no Equatable short-circuit.

### F-34 [🟡] startBridgeObservation re-registration Task leak — amplified by 1d18d48's 6 new streamingTick-driven fields

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:884-950`
- **Category**: perf  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:884-941 implements `startBridgeObservation` via two `withObservationTracking` loops (`observeStream`, `observeSettings`). Each `onChange` callback spawns `Task { @MainActor in observeStream() }` to re-register. (a) The re-registering Task is never stored, so it cannot be cancelled when the window closes or the bridge is replaced. (b) `observeStream` body writes 7 properties on `bridge` (`activeToolName`, `streamingOutputChars`, `streamingToolsExecuted`, `streamingThinkingSeconds`, `streamingTick`, plus the 7 reads in the first half). Critically, `streamingTick &+= 1` (line 927) is the forcing function the comment calls out. The observation body reads `streamState(in: window)` which reads `sessionStates` (an @Observable). Every 50ms flushPendingUpdates writes a new `state.streamingTail` value, and many other event handlers also mutate `sessionStates[key]` directly. So `onChange` fires at 20-100Hz during a streaming turn, spawning a new re-registering Task each time. With 1d18d48 ADDING 6 new bridge fields and the new 1d18d48 `ChatBridge.collapseAllTurns` and `compactionRecord` reads, the body became significantly heavier per fire. Net: observation Task leak, amplified by 1d18d48's additions.
  ```
- **Repro**: 1. Open a chat window. 2. Send a prompt that produces a 30s streaming turn with many tool calls. 3. Close the window mid-stream. 4. Inspect via `instruments` or a Task.sleep print: the re-registration Task continues running until the next `sessionStates` mutation (which may be the next user prompt in a DIFFERENT window), and even then briefly, the Task graph holds a strong ref to the closed window's bridge via the closure capture. The new chat window retains a stale `streamingTick` cadence.

### F-35 [🟡] summarizeCompletedPhases races reloadCommittedFromDisk and window switch — summary may target wrong store or stale state

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1662-1684`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:1662-1684: in the `.result` branch, the sequence is `await saveSession(...)` (line 1656-1660), then `reloadCommittedFromDisk(sessionId:resultEvent.sessionId, ...)` (line 1662, which is `Task.detached(priority:.userInitiated)`), then `summarizeCompletedPhases(sessionKey:key, in:window, cwd:cwdCapture)` (line 1684, synchronous in this Task — it just spawns a detached `Task { [weak self] in for ... }`). The race: the `summarizeCompletedPhases` Task captures `state` (a value-type copy of `SessionStreamState` at line 3288) and uses `state.allMessages` to build `digestPairs` (line 3293-3295). But the `reloadCommittedFromDisk` `Task.detached` runs on `userInitiated` priority and can finish BEFORE the summarize task starts scheduling. When it finishes, it assigns `state.committedMessages = cleaned` (line 3106) which differs from what the summarize task saw (the in-memory pre-disk version with `localAddendum` etc.). Worst case: the summarize task reads pre-reload `allMessages`, the disk reloader overwrites in-memory state, and the next saveSession (if user sends another prompt) writes the disk-state over the summary-state. The summary, if it lands, was generated from a stale snapshot. Additionally, if the user switches window mid-summary, the `window.phaseSummaryStore` is cleared (on a new WindowState) and the writes from the still-running Task go to a store the user can no longer see.
  ```
- **Repro**: 1. Send a turn whose .result event triggers both reloadCommittedFromDisk (detached) and summarizeCompletedPhases (detached). 2. Mid-summary, switch the window to a different session (creates a new WindowState, which has a new PhaseSummaryStore). 3. The original Task continues to write to the original window's store; the user sees no summary in the new window.

### F-36 [🟡] summarizeCompletedPhases writes to the CURRENT window.phaseSummaryStore, not the session's owning window

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1667, 3286-3325`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:3313: `try await claudeRef.summarizePhase(content: digest, cwd: cwd)`. The `cwd` is captured at line 1667 (`let cwdCapture = cwd`) from the streaming turn's `cwd` parameter (the project's directory). But by the time `summarizeCompletedPhases` runs, the user may have switched the window to a different project — the project associated with `window.selectedProject` at line 3286 is the window's CURRENT project, not the project of the session being summarized. `window.phaseSummaryStore` is a fresh per-window store; if the user opens a window for project B, runs a turn there, and during the summary the user switches the window to project A, the summary writes to a store the user has navigated away from. The `claude -p` call is launched with the OLD project's `cwd` (which is correct for that session's transcripts) but the summary is written to the NEW window's `phaseSummaryStore`, where no view in the original project can see it. (Compounds with F-29.)
  ```
- **Repro**: 1. Open window 1, select project A. Send a turn that produces 3 phases. 2. While the LLM summary calls are in flight, switch the window to project B (which creates a new phaseSummaryStore). 3. The summary tasks finish, write summaries to window.phaseSummaryStore. But window.phaseSummaryStore is now project B's store; the user in project A sees no summaries. The LLM spent the API tokens for nothing visible.

### F-37 [🟡] startBridgeObservation re-registration Task leak — amplified by 1d18d48's 6 new streamingTick-driven fields

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:884`
- **Category**: perf  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:884-941 implements `startBridgeObservation` via two `withObservationTracking` loops (`observeStream`, `observeSettings`). Each `onChange` callback spawns `Task { @MainActor in observeStream() }` to re-register. (a) The re-registering Task is never stored, so it cannot be cancelled when the window closes or the bridge is replaced. (b) `observeStream` body writes 7 properties on `bridge` (`activeToolName`, `streamingOutputChars`, `streamingToolsExecuted`, `streamingThinkingSeconds`, `streamingTick`, plus the 7 reads in the first half). Critically, `streamingTick &+= 1` (line 927) is the forcing function the comment calls out. The observation body reads `streamState(in: window)` which reads `sessionStates` (an @Observable). Every 50ms flushPendingUpdates writes a new `state.streamingTail` value, and many other event handlers also mutate `sessionStates[key]` directly. So `onChange` fires at 20-100Hz during a streaming turn, spawning a new re-registering Task each time. With 1d18d48 ADDING 6 new bridge fields and the new 1d18d48 `ChatBridge.collapseAllTurns` and `compactionRecord` reads, the body became significantly heavier per fire. Net: observation Task leak, amplified by 1d18d48's additions.
  ```
- **Repro**: 1. Open a chat window. 2. Send a prompt that produces a 30s streaming turn with many tool calls. 3. Close the window mid-stream. 4. Inspect via `instruments` or a Task.sleep print: the re-registration Task continues running until the next `sessionStates` mutation (which may be the next user prompt in a DIFFERENT window), and even then briefly, the Task graph holds a strong ref to the closed window's bridge via the closure capture.

### F-38 [🟡] summarizeCompletedPhases races reloadCommittedFromDisk and window switch — summary may target wrong store or stale state

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1662`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:1662-1684: in the `.result` branch, the sequence is `await saveSession(...)` (line 1656-1660), then `reloadCommittedFromDisk(sessionId:resultEvent.sessionId, ...)` (line 1662, which is `Task.detached(priority:.userInitiated)`), then `summarizeCompletedPhases(sessionKey:key, in:window, cwd:cwdCapture)` (line 1684, synchronous in this Task — it just spawns a detached `Task { [weak self] in for ... }`). The race: the `summarizeCompletedPhases` Task captures `state` (a value-type copy of `SessionStreamState` at line 3288) and uses `state.allMessages` to build `digestPairs` (line 3293-3295). But the `reloadCommittedFromDisk` `Task.detached` runs on `userInitiated` priority and can finish BEFORE the summarize task starts scheduling. When it finishes, it assigns `state.committedMessages = cleaned` (line 3106) which differs from what the summarize task saw (the in-memory pre-disk version with `localAddendum` etc.). Worst case: the summarize task reads pre-reload `allMessages`, the disk reloader overwrites in-memory state, and the next saveSession (if user sends another prompt) writes the disk-state over the summary-state. The summary, if it lands, was generated from a stale snapshot. Additionally, if the user switches window mid-summary, the `window.phaseSummaryStore` is cleared (on a new WindowState) and the writes from the still-running Task go to a store the user can no longer see.
  ```
- **Repro**: 1. Send a turn whose .result event triggers both reloadCommittedFromDisk (detached) and summarizeCompletedPhases (detached). 2. Mid-summary, switch the window to a different session (creates a new WindowState, which has a new PhaseSummaryStore). 3. The original Task continues to write to the original window's store; the user sees no summary in the new window.

### F-39 [🟡] summarizeCompletedPhases writes to the CURRENT window.phaseSummaryStore, not the session's owning window

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1667`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:3313: `try await claudeRef.summarizePhase(content: digest, cwd: cwd)`. The `cwd` is captured at line 1667 (`let cwdCapture = cwd`) from the streaming turn's `cwd` parameter (the project's directory). But by the time `summarizeCompletedPhases` runs, the user may have switched the window to a different project — the project associated with `window.selectedProject` at line 3286 is the window's CURRENT project, not the project of the session being summarized. `window.phaseSummaryStore` is a fresh per-window store; if the user opens a window for project B, runs a turn there, and during the summary the user switches the window to project A, the summary writes to a store the user has navigated away from. The `claude -p` call is launched with the OLD project's `cwd` (which is correct for that session's transcripts) but the summary is written to the NEW window's `phaseSummaryStore`, where no view in the original project can see it. (Compounds with F-29.)
  ```
- **Repro**: 1. Open window 1, select project A. Send a turn that produces 3 phases. 2. While the LLM summary calls are in flight, switch the window to project B (which creates a new phaseSummaryStore). 3. The summary tasks finish, write summaries to window.phaseSummaryStore. But window.phaseSummaryStore is now project B's store; the user in project A sees no summaries. The LLM spent the API tokens for nothing visible.

### F-40 [🟡] summarizeCompletedPhases races with reloadCommittedFromDisk in .result handler

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1684`
- **Category**: data-loss  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  AppState.swift:1684 — `summarizeCompletedPhases(sessionKey: key, in: window, cwd: cwdCapture)` is called from the `.result` branch of `processStream`, INSIDE the same branch that calls `reloadCommittedFromDisk` at line 1662. The summary pipeline reads `state.allMessages` (line 3288) which may be a snapshot of the pre-reload or post-reload state depending on async ordering. If the reload overwrites the messages between line 1662 and line 1684, the digests sent to `summarizePhase` reflect stale data; the generated summary is then stored in `PhaseSummaryStore` keyed by a phase.id that may not exist in the post-reload blocks. The summary shows up in the UI attached to a phase that no longer exists, or attached to a different phase with a colliding id.
  ```
- **Repro**: 1. Complete a turn that emits taskUpdate phases. 2. The .result event triggers both `reloadCommittedFromDisk` and `summarizeCompletedPhases` synchronously adjacent. 3. If `reloadCommittedFromDisk` swaps in a different message set (e.g. a concurrent manual save finished), the digest is computed against the pre-reload state but the phase.id may now collide with a phase derived from the new state. 4. `PhaseSummaryStore.setSummary` writes the wrong summary to the wrong phase.

### F-41 [🟡] summarizeCompletedPhases filter races with chatBridge.isStreaming flip

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:1684`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  AppState.swift:1684 — `summarizeCompletedPhases` filter at line 3297-3302 requires `phase.status == .done`. With F-11 (a running taskUpdate with no endTime never gets a `taskUpdate` block to close the phase), the trailing fallback phase has `status = isStreamingLast ? .running : .done` — if `isStreamingLast` is true at the moment of filtering (e.g. the .result event is processed before `chatBridge.isStreaming` flips to false in the observation block), the filter excludes the phase. Then the next time `.result` fires, the phase may or may not be included depending on the observation block's race.
  ```
- **Repro**: 1. A streaming turn ends without a final closing taskUpdate. 2. `.result` event fires. 3. `summarizeCompletedPhases` is called with `isStreamingLast` reflecting the observation-block state at that moment. 4. The trailing fallback phase is included or excluded based on a race between `chatBridge.isStreaming` and `state.allMessages` snapshot. 5. Non-deterministic: some completions get a summary, some don't.

### F-42 [🟡] summarizeCompletedPhases background pipeline has no timeout, no cancel path; a single claude -p hang blocks all subsequent phase summaries forever

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:3309`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackB
- **Evidence**:
  ```
  AppState.swift:3286-3325 (summarizeCompletedPhases) fires a fire-and-forget `Task { [weak self] in for (phaseId, digest) in digestPairs { try await claudeRef.summarizePhase(...); await MainActor.run { store.setSummary(...) } } }`. `summarizePhase` (ClaudeService.swift:275-296) calls `runShellCommand` (line 845-873) which has NO timeout — `proc.terminationHandler = { _ in continuation.resume() }` waits forever if the child CLI hangs. Combined with the for-loop's lack of a `Task.cancel()` path and the per-phase `markPending → setSummary | markFailed` contract on `PhaseSummaryStore` (Packages/Sources/ClarcCore/TaskUpdate/PhaseSummaryStore.swift), a single `claude -p` hang in the child process:
  1. blocks the for-loop indefinitely;
  2. leaves all subsequent `pending` phase ids in `store.pending` forever (markFailed is only called inside the catch block, which never fires because the await never returns);
  3. prevents subsequent session switches from showing the LLM summary for those phases (PhaseBlock and PhaseTitleRow fall back to `phase.title` when `summary(for:) == nil`).
  4. holds a detached `Task { [weak self] }` reference — on a window switch, the `[weak self]` is fine, but the `store` (captured strongly in line 3287 `let store = window.phaseSummaryStore`) and `claudeRef` (line 3307) keep the window's phaseSummaryStore alive across window close. This is the v2.6.1 hot path: every closed phase triggers a summarize call (M-C2 / M-A3). The release notes claim "失败静默降级" (silent degrade on failure) — the bug is that this is NOT a failure, it's a hang; markFailed never fires, the user sees perpetual "N pending" with no error.
  ```
- **Repro**: 1. Trigger a multi-phase task (e.g. /refactor across 3 files).
2. After the turn completes (.result fires), AppState.summarizeCompletedPhases runs.
3. If `claude -p` hangs (e.g. due to a rate-limit error that doesn't terminate the child, or a CLI deadlock), the for-loop never advances.
4. The user sees the original phase titles in PhaseBlock / PhaseTitleRow forever; no error toast; no retry button.
5. Closing the window does not cancel the detached task (Task is owned by AppState, not by the window).

### F-43 [🟡] summarizeCompletedPhases has no timeout, no retry, no cancel — a single claude -p hang blocks the entire pipeline

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/Services/ClaudeService.swift:275-298`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:3286-3325 `summarizeCompletedPhases` builds a `digestPairs: [(String, String)]` array synchronously, marks all phases pending (line 3304-3306), then spawns a single detached `Task { [weak self] in for (phaseId, digest) in digestPairs { try await claudeRef.summarizePhase(content: digest, cwd: cwd); ... } }`. `claudeRef.summarizePhase` (ClaudeService.swift:275-298) calls `runShellCommand` (line 845-874) which `await`s process termination via `withCheckedContinuation` with NO timeout. If any `claude -p` call hangs (network stalled, CLI child wedged on stdin), the `for` loop blocks forever. The `pending` set grows (those phases already marked pending; new arrivals can't enter because of the markPending dedup, AppState.swift:3304-3306). The Task is `[weak self]` and has no `Task.cancel()` path. The `markFailed` call (line 3321) is only reached after a `throw`, but a hanging process never throws — it just sits. Compounded by M-A3 (runShellCommand no timeout, M-A5 no SIGKILL fallback).
  ```
- **Repro**: 1. Configure a network condition (firewall) that makes `claude -p` hang on outbound API. 2. Send a multi-phase turn. 3. Observe that after the first .result the summarizeCompletedPhases Task is dispatched and never completes; the `pending` set in `window.phaseSummaryStore` stays populated; on the next .result those phases are filtered out by `!store.isPending(...)` and never retried.

### F-44 [🟡] summarizeCompletedPhases has no timeout, no retry, no cancel — a single claude -p hang blocks the entire pipeline

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/Services/ClaudeService.swift:275`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:3286-3325 `summarizeCompletedPhases` builds a `digestPairs: [(String, String)]` array synchronously, marks all phases pending (line 3304-3306), then spawns a single detached `Task { [weak self] in for (phaseId, digest) in digestPairs { try await claudeRef.summarizePhase(content: digest, cwd: cwd); ... } }`. `claudeRef.summarizePhase` (ClaudeService.swift:275-298) calls `runShellCommand` (line 845-874) which `await`s process termination via `withCheckedContinuation` with NO timeout. If any `claude -p` call hangs (network stalled, CLI child wedged on stdin), the `for` loop blocks forever. The `pending` set grows (those phases already marked pending; new arrivals can't enter because of the markPending dedup, AppState.swift:3304-3306). The Task is `[weak self]` and has no `Task.cancel()` path. The `markFailed` call (line 3321) is only reached after a `throw`, but a hanging process never throws — it just sits. Compounded by M-A3 (runShellCommand no timeout, M-A5 no SIGKILL fallback).
  ```
- **Repro**: 1. Configure a network condition (firewall) that makes `claude -p` hang on outbound API. 2. Send a multi-phase turn. 3. Observe that after the first .result the summarizeCompletedPhases Task is dispatched and never completes; the `pending` set in `window.phaseSummaryStore` stays populated; on the next .result those phases are filtered out by `!store.isPending(...)` and never retried.

### F-45 [🟡] StreamingIndicatorView heartbeat: liveness cue fragile under parent re-render

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:49`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:49-56 — `StreamingIndicatorView` is wrapped in a parent `HStack` that is conditional on `chatBridge.isStreaming`. The view's `.onAppear` (line 862-871) starts a `heartbeatTask` that ticks every 250ms. `.onDisappear` cancels it. However, the indicator is the ONLY visible liveness cue during long silent gaps (e.g. while waiting on a long-running tool). If the parent `if chatBridge.isStreaming` re-evaluates (e.g. due to a parent state change that doesn't unmount the indicator), the indicator's `@State heartbeatTask` is preserved by SwiftUI, so `.onAppear` does NOT fire again — but the OLD `heartbeatTask` continues. Conversely, if the view is re-mounted (e.g. parent re-render destroys the conditional subtree), the new `heartbeatTask` is created in `.onAppear` and the old one is cancelled — but the new `heartbeat` `@State` initializes to 0, so the counter resets and the user sees a visual jump.
  ```
- **Repro**: 1. Start streaming. 2. The indicator mounts and the heartbeat ticks. 3. Force a re-render of the parent (e.g. by toggling focus mode). 4. If the `if chatBridge.isStreaming` subtree is preserved, the heartbeat continues from the old generation. 5. If the subtree is destroyed and recreated, the heartbeat `@State` resets to 0 — the user sees a '0' or '0.0s' jump.

### F-46 [🟡] makeVisibleTurns is called on every body re-eval with no memoization

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:191`
- **Category**: perf  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:191-198 — `makeVisibleTurns` runs `Turn.makeTurns(from: source, isStreamingLast: chatBridge.isStreaming)` on every body re-eval. With `streamingTick` bumping 10-100 Hz and a 200-turn session, the full `makeTurns` runs 10-100 times per second. Each call iterates all `source.count` messages, allocates a new `[Turn]` array, and (combined with F-13's inline `Phase.makePhases`) re-derives phases for every visible turn. The `@State collapseOverrides: [UUID: Bool]` is keyed on stable `turn.id` so the collapse state survives, but the work to build the `[Turn]` is repeated every tick.
  ```
- **Repro**: Profile a 100-turn session mid-stream. Each tick of `streamingTick` re-evaluates `body` -> `settledContent` -> `makeVisibleTurns` -> `Turn.makeTurns` -> inline `Phase.makePhases` for each TurnBlock. No memoization.

### F-47 [🟡] New StreamingIndicatorView has no accessibility label / hint / hidden treatment — VoiceOver cannot detect liveness from the 4Hz heartbeat counter

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:811`
- **Category**: ux  ·  **Status**: NEW
- **Source track**: TrackB
- **Evidence**:
  ```
  StreamingIndicatorView (MessageListView.swift:811-927) renders a live status indicator with 4 states (thinking / running tool / generating / waiting) and a 4Hz heartbeat. `grep -n "accessibilityLabel\|accessibilityHidden" MessageListView.swift` returns NOTHING for the new code. The view has:
  - `PulseRingView` (purely decorative animation) — no `.accessibilityHidden(true)` so VoiceOver reads "image" with no label.
  - `activityLabel` — Text with localized string, VoiceOver reads the literal "Thinking..." / "Running Edit…" / "Generating response..." / "Waiting..." (in whatever language is current). No accessibility hint about what these mean semantically.
  - `counterText` — Text with format strings. The thinking counter is "1.5s thinking" / "12 chars" / "3 tools run" — VoiceOver reads "1.5s thinking" as "one point five s thinking" which is meaningless; should be "1.5 seconds elapsed".
  - `ElapsedTimeView` (line 931-958) has the same issue; no accessibility label.
  
  The new streaming indicator is the primary "is the agent alive" cue promised in the v2.6.1 release notes ("用户看到"Working…"frozen" is the failure mode the heartbeat was designed to address). VoiceOver users currently cannot distinguish between "frozen" and "actively thinking" because the counter string is the only non-text indicator. The 4Hz heartbeat is a 100% visual cue (the integer changes every 250ms) — VoiceOver would not notice a frozen heartbeat. Release notes do not address this.
  ```
- **Repro**: 1. Enable VoiceOver (⌘F5).
2. Trigger a streaming response.
3. VoiceOver focus on the streaming indicator: reads the literal "Thinking..." text plus the counter text. No semantic hint about liveness, no .accessibilityElement(children: .combine), no .accessibilityLabel override.
4. When the heartbeat ticks (every 250ms), VoiceOver hears no change.
5. When streaming silently hangs (run a long tool), VoiceOver user has no way to detect the freeze.

### F-48 [🟡] StreamingIndicatorView counter looks live while data is stale if heartbeat Task is silently cancelled

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:815`
- **Category**: ux  ·  **Status**: NEW
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:811-815 — `StreamingIndicatorView`'s body reads `chatBridge.streamingTick` (transitively, via `bridge.activeToolName` / `streamingOutputChars` / `streamingToolsExecuted` / `streamingThinkingSeconds`) and re-evaluates on each observation fire. `chatBridge.streamingTick` is bumped on every `withObservationTracking` re-fire in AppState.swift:927. The indicator's body re-evaluates 10-100 Hz during streaming. The local `heartbeat` Task is REDUNDANT for re-render triggering — but the comment on line 815-817 claims it is needed for liveness during silent gaps. In practice, if the underlying state is stable (no deltas for >250ms during a long tool call), `streamingTick` does NOT increment, so the heartbeat is the only re-eval trigger. If the heartbeat Task is cancelled by a parent re-render (without the indicator unmounting), the user sees the indicator 'frozen' on stale values — the very thing the heartbeat was designed to prevent.
  ```
- **Repro**: 1. Streaming turn calls a long-running tool. 2. No deltas arrive for 5 seconds. 3. `streamingTick` does not increment. 4. The local heartbeat Task ticks 4Hz and forces the body to re-evaluate. 5. If a parent re-render cancels the heartbeat Task (line 873) but the view is preserved (State survives), the user sees a frozen indicator with stale counts.

### F-49 [🟡] Fallback phase id is freshly-generated UUID per Phase.makePhases call — summary key never matches UI's phase id

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Phase.swift:186`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  AppState.swift:3286-3303: `summarizeCompletedPhases` calls `Phase.makePhases(from: assistantBlocks, isStreamingLast: false)` (line 3296). `isStreamingLast: false` is hardcoded. After a .result, `promoteTailToCommitted` (line 1645) clears `state.streamingTail` and `finalizeStreamSession` (line 1632) clears `state.isStreaming`. So `isStreamingLast: false` is the right value here. But `makePhases` looks at `state.streamingTail`? No — it takes `assistantBlocks` directly. So the hardcoded `false` is correct. However, `Phase.makePhases` derives `id = "fallback-" + (blocks.first?.id ?? UUID().uuidString)` for phases without a taskUpdate (Phase.swift:186). The `UUID().uuidString` is regenerated every call. If the user has a phase that happens to be the LAST one and is a fallback (no taskUpdate, isStreamingLast=false), the fallback UUID is `UUID()` and changes between view re-evaluations. SwiftUI ForEach keyed on `Phase.id` will detect a new id and DESTROY + RECREATE the PhaseBlock, losing any `@State` inside (e.g. its `isExpanded` bool from line 565). This is the F-08 finding re-surfaced in the new summarize path. The summary Task calls `Phase.makePhases` (line 3296) which generates a new UUID; meanwhile the view re-derives the same phases via `Phase.makePhases` from the same `allMessages` (line 447/489) and gets a DIFFERENT UUID for the trailing fallback phase. Net: the summary key (line 3308 `toSummarize.map { ($0.id, ...) }`) and the UI's phase id disagree for any fallback phase, and the summary never matches the UI's phase id, so the summary is stored under an id nothing displays.
  ```
- **Repro**: 1. Run a turn that does not emit a closing taskUpdate. 2. Observe that on .result, `summarizeCompletedPhases` calls Phase.makePhases, gets a fallback phase with id `fallback-<UUID>` (newly generated), stores the summary under that id, and the UI's PhaseBlock — which calls Phase.makePhases on the same blocks — gets a DIFFERENT id (different UUID), so `chatBridge.phaseSummaryStore?.summary(for: phase.id)` returns nil forever. No summary is ever displayed for fallback phases.

### F-50 [🟡] PhaseSummaryStore @Published changes do not propagate to ChatBridge consumers — view never re-renders when LLM summary arrives

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcCore/TaskUpdate/PhaseSummaryStore.swift:18-44`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  PhaseTitleRow/PhaseBlock read `chatBridge.phaseSummaryStore?.summary(for: phase.id)` (MessageListView.swift:514, 611). PhaseSummaryStore declares `@Published public private(set) var summaries: [String: String]` (PhaseSummaryStore.swift:20) on an `ObservableObject` (line 18), but the view does not `import Combine`, does not `@ObservedObject` / `@StateObject` / `store.objectWillChange.sink` — it only reads via the `chatBridge.phaseSummaryStore` weak getter. The `chatBridge` is an `@Observable` and views that read it observe only its tracked properties, not the `ObservableObject`'s @Published storage. When `AppState.summarizeCompletedPhases` calls `store.setSummary(...)` after the LLM call returns, the @Published change fires on the store but the view is NOT subscribed, so the body does not re-evaluate. The new LLM summary only appears when some OTHER view-state change re-renders the row (next streaming tick, scroll geometry change, session switch). Net: a phase that the LLM summarized minutes ago may continue to show the derived fallback title in the UI until the user does something else. The whole `PhaseSummaryStore` class is observable in name only.
  ```
- **Repro**: Send a turn that produces a completed phase (closing taskUpdate). Wait for `summarizeCompletedPhases` background LLM call to finish. The phase title in the collapsed TurnBlock continues to show the derived fallback (e.g. "3 tools · first text…") instead of the LLM summary. Title only updates after the next streaming tick, scroll change, or window switch.

### F-51 [🟡] LLM-generated phase summaries are not persisted — wiped on quit, window close, or session switch

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcCore/TaskUpdate/PhaseSummaryStore.swift:8-11`
- **Category**: data-loss  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  PhaseSummaryStore is in-memory only (PhaseSummaryStore.swift:8-11 comment: "This is not persisted — it lives only for the current app session"). Neither `ChatSession` (ChatSession.swift:8-16) nor `SessionMetaStore.Meta` (SessionMetaStore.swift:9-16) has a `phaseSummaries: [String: String]` field. The LLM summary is generated by `summarizeCompletedPhases` (AppState.swift:3286-3325) and written only to `store.setSummary(...)`. On app quit, on window close, or on session switch (which calls `clear()` indirectly via the next-PhaseSummaryStore being owned by a new WindowState), all generated summaries are lost. Reopening the session, switching back, or reloading from disk shows only the derived fallback title. Every LLM call (default model, no --model haiku) was wasted on relaunch.
  ```
- **Repro**: 1. Run a multi-phase turn. Wait for all LLM-generated summaries to land. 2. Quit and relaunch the app. 3. Reopen the session. Every phase shows the derived fallback title; the LLM-generated one-sentence summary is gone.

### F-52 [🟡] LLM-generated phase summaries are not persisted — wiped on quit, window close, or session switch

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcCore/TaskUpdate/PhaseSummaryStore.swift:8`
- **Category**: data-loss  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  PhaseSummaryStore is in-memory only (PhaseSummaryStore.swift:8-11 comment: "This is not persisted — it lives only for the current app session"). Neither `ChatSession` (ChatSession.swift:8-16) nor `SessionMetaStore.Meta` (SessionMetaStore.swift:9-16) has a `phaseSummaries: [String: String]` field. The LLM summary is generated by `summarizeCompletedPhases` (AppState.swift:3286-3325) and written only to `store.setSummary(...)`. On app quit, on window close, or on session switch (which calls `clear()` indirectly via the next-PhaseSummaryStore being owned by a new WindowState), all generated summaries are lost. Reopening the session, switching back, or reloading from disk shows only the derived fallback title. Every LLM call (default model, no --model haiku) was wasted on relaunch.
  ```
- **Repro**: 1. Run a multi-phase turn. Wait for all LLM-generated summaries to land. 2. Quit and relaunch the app. 3. Reopen the session. Every phase shows the derived fallback title; the LLM-generated one-sentence summary is gone.

### F-53 [🟡] PhaseSummaryStore @Published changes do not propagate to ChatBridge consumers — view never re-renders when LLM summary arrives

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcCore/TaskUpdate/PhaseSummaryStore.swift:18`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackD
- **Evidence**:
  ```
  PhaseTitleRow/PhaseBlock read `chatBridge.phaseSummaryStore?.summary(for: phase.id)` (MessageListView.swift:514, 611). PhaseSummaryStore declares `@Published public private(set) var summaries: [String: String]` (PhaseSummaryStore.swift:20) on an `ObservableObject` (line 18), but the view does not `@ObservedObject` / `@StateObject` / `store.objectWillChange.sink` — it only reads via the `chatBridge.phaseSummaryStore` weak getter. The `chatBridge` is an `@Observable` and views that read it observe only its tracked properties, not the `ObservableObject`'s @Published storage. When `AppState.summarizeCompletedPhases` calls `store.setSummary(...)` after the LLM call returns, the @Published change fires on the store but the view is NOT subscribed, so the body does not re-evaluate. The new LLM summary only appears when some OTHER view-state change re-renders the row (next streaming tick, scroll geometry change, session switch). Net: a phase that the LLM summarized minutes ago may continue to show the derived fallback title in the UI until the user does something else. The whole `PhaseSummaryStore` class is observable in name only.
  ```
- **Repro**: Send a turn that produces a completed phase (closing taskUpdate). Wait for `summarizeCompletedPhases` background LLM call to finish. The phase title in the collapsed TurnBlock continues to show the derived fallback (e.g. "3 tools · first text…") instead of the LLM summary. Title only updates after the next streaming tick, scroll change, or window switch.

### F-54 [🟡] summarizeCompletedPhases Task strongly captures WindowState.phaseSummaryStore; window close leaks until completion

- **File**: `Clarc/App/AppState.swift:3309`
- **Category**: correctness  ·  **Status**: NEW
- **Source track**: TrackC
- **Evidence**:
  ```
  Clarc/App/AppState.swift:3309-3324: `summarizeCompletedPhases` is called from `processStream` at line 1684 inside the `.result` event handler. The Task captures `window.phaseSummaryStore` (line 3287) and `store.setSummary(_, for:)` is called inside `await MainActor.run { ... }` (line 3316). The Task has no weak reference to `window` — `store` is captured strongly. When the user switches to a different session in the same window, `WindowState.phaseSummaryStore` is NOT cleared (verified: there's no `clear()` call on session switch in AppState's session-switch path; `phaseSummaryStore.clear()` is only in the type definition and never invoked). The store persists across session switches, so summaries for the previous session's phases are still shown in the new session if any phase id coincidentally matches. More importantly, the Task is NEVER cancelled. If the user closes the window while summaries are in flight, the Task keeps running and holds a strong reference to the store, leaking the WindowState until completion. With `summarizePhase` having no timeout (F-22), this is a real window-scoped memory leak that survives window close.
  ```
- **Repro**: Open a project, send a turn that produces phases, then close the window while the summarization Task is still in flight. The detached Task holds `store` (a `let` of WindowState) and the WindowState itself, preventing ARC release. Open the same project again — the previous in-flight Task may still complete and write to the now-defunct WindowState, which is also a UAF risk because the new WindowState has a new UUID but PhaseSummaryStore is class-scoped (not UUID-scoped).

### F-55 [🟡] Manual Compact button has no failure feedback — compactHandler swallows errors with `try?` and StatusLineView has no error UI

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:857`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackB
- **Evidence**:
  ```
  /Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/App/AppState.swift:855-858 wires `bridge.compactHandler` as:
  ```
  bridge.compactHandler = { [weak self, weak window] in
      guard let self, let window else { return }
      _ = try? await self.compactService.run(in: window)
  }
  ```
  The `try?` swallows every `CompactError` (`noSession`, `tooShort`, `cancelled`) without ever surfacing a UI error. StatusLineView.swift:77-87 has the only manual trigger:
  ```
  Button {
      Task { await chatBridge.compact() }
  } label: { Image(systemName: "arrow.triangle.2.circlepath") }
  .buttonStyle(.plain)
  .help(String(localized: "Compact context", bundle: .module))
  .disabled(chatBridge.messages.count < 2)
  ```
  There is no spinner, no "compacting..." state, no error toast. The button is always enabled (only disabled when messages.count < 2). When `compactService.run` throws (e.g. `noSession` after window close, `cancelled` when the app is shutting down), the user sees a click that does nothing — no `.alert`, no `.errorMessage` set on `windowState`. Compare with the new `summarizeCompletedPhases` pipeline which at least logs to `markFailed`. The compact button is a primary navigation action (the user explicitly invoked "Compact context"); silent failure on this code path is a UX regression that the v2.6.1 work (which added the compact button as a v2.5.x feature) left in place.
  ```
- **Repro**: 1. Open a window with no selected session (e.g. project picker visible).
2. Click the compact button (↻ icon, top-right of the chat area).
3. Expected: error toast or disabled state.
4. Actual: button click silently no-ops; no feedback. Same on a window mid-shutdown where `window` weak-ref is nil.

### F-56 [🟡] ProjectWindowView sets isProjectWindow = true in onAppear with no onDisappear reset (residual M-D8 / L-18, no v2.6.1 fix)

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Clarc/Views/ProjectWindowView.swift:58`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackB
- **Evidence**:
  ```
  ProjectWindowView.swift:57-59 sets `windowState.isProjectWindow = true` in `.onAppear`. There is NO `.onDisappear` to reset it. `isProjectWindow` is read by `HistoryListView` in 5 places (lines 38, 47, 80, 135, 233) to decide whether to filter sessions to the current project only and whether to show the projectName column. Sequence that breaks:
  1. Open a dedicated project window (Cmd+4 or via ProjectWindowValue) — sets `isProjectWindow = true`. HistoryListView filters to current project, hides projectName column.
  2. Close the project window. SwiftUI fires onDisappear on the window's contents, but `isProjectWindow` is not reset.
  3. The main window still shows the same `WindowState` instance? No — `isProjectWindow` is on `WindowState`, and each window has its own. So if a main window was previously a normal (non-project) window, and the user opens a project window, the main window's `WindowState.isProjectWindow` was false (it was created as a regular window). Closing the project window does not affect the main window. But: if the user opens the project window for the SAME project that the main window is showing, then closes it, the main window's state is fine. The bug manifests when WindowState is reused across window lifetimes: each new project window gets a fresh WindowState (per `setupChatBridge` flow), so the leak is per-window-instance, not cross-window. The residual risk: WindowState instances are stored in `appState.windows` (or similar); if a stale WindowState with `isProjectWindow = true` is reused later, HistoryListView's filter is wrong. Audited as M-D8 / L-18. v2.6.1 did not address this; new StreamingIndicatorView makes the bug slightly worse because more UI state is read from `chatBridge` which is bound to a specific WindowState — closing the window leaves the bridge's `phaseSummaryStore` weak ref dangling (AppState.swift:877 sets `bridge.phaseSummaryStore = window.phaseSummaryStore` on setup but no cleanup on window close).
  ```
- **Repro**: 1. Open main window — isProjectWindow = false, HistoryListView shows all projects.
2. Open a dedicated project window (double-click a project tab) — isProjectWindow = true on the new windowState.
3. Close the project window.
4. No .onDisappear runs to reset isProjectWindow to false.
5. If the windowState is later reused (rare but possible when WindowState is recycled), HistoryListView's "current project only" filter persists incorrectly.

### F-57 [🟡] F-13: makeVisibleTurns still returns [Turn]; Phase.makePhases called inline per body re-eval

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/MessageListView.swift:189`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  MessageListView.swift:189 — `private func makeVisibleTurns() -> [Turn]` (returns `[Turn]`, not `[(Turn, [Phase])]`). MessageListView.swift:447 and 489 — `Phase.makePhases(from: assistantBlocks, isStreamingLast: turn.isInProgress)` is called inline inside `collapsedSummary` and `expandedContent` body properties. With a 200-turn session and `streamingTick` bumping 10-100 Hz, every view re-evaluation re-derives the full phase list for every visible turn — bug.md F-13 documented "6,000 block iterations per render" cost, unchanged at HEAD.
  ```
- **Repro**: Profile a streaming session with 50+ visible turns. Each streaming tick re-runs Phase.makePhases for all 50+ TurnBlocks. The phase list does not change between ticks, but it is recomputed every time.

### F-58 [🟡] F-15: Phase.== is still synthesized comparing blocks & taskUpdate, not just discriminator fields

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Phase.swift:20`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  Phase.swift:20-53 — `public struct Phase: Identifiable, Equatable` has no `static func ==` override. The synthesized `==` compares `blocks: [MessageBlock]`, `taskUpdate: TaskUpdateMessage?`, `id: String`, and `isInProgress: Bool`. The commit message for 1d18d48 claims 'Phase.== compares discriminator fields only'. `grep 'static func ==' Phase.swift` returns nothing. If `Phase` is ever placed in a `Set` or used as a diff key (e.g. for animation transitions, or by future caching code that the commit message hints at), two phases with the same id but different streaming text would compare unequal — defeating the point of the stable `id`. Conversely, the synthesized `==` compares `[MessageBlock]` arrays element-wise, so it is much stricter than the id-based 'same phase' comparison the comment promises.
  ```
- **Repro**: During a streaming turn, Phase.makePhases derives a Phase whose blocks change as new text deltas arrive. Synthesized Phase.== compares the full blocks array, so the same logical phase is structurally unequal to itself across ticks. This is the opposite of the discriminator-only behaviour the commit message claims.

### F-59 [🟡] F-10: back-to-back taskUpdates create spurious empty phases

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Phase.swift:99`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  Phase.swift:99-135 (`makePhases`) — when the LLM emits two taskUpdate blocks back to back (e.g. one for 'analyze' that closes with an empty accumulator, then one for 'implement' that closes with another empty accumulator), `flush(with: update, isInProgress: false)` is called for EACH. The `owned` check (line 137) returns true for a non-nil `closing` regardless of `accumulator.isEmpty`, so two back-to-back taskUpdates create TWO phases: one with empty blocks but a taskUpdate, and another with the same empty accumulator. The first phase renders as a 0-block collapsed row with the first taskUpdate's title — visually a duplicated or empty phase. F-10 still UNFIXED.
  ```
- **Repro**: LLM emits `taskUpdate(title: "Analyze")` immediately followed by `taskUpdate(title: "Implement")` with no intervening text/tool blocks. `makePhases` produces two phases: a 0-block phase with title 'Analyze' and a 0-block phase with title 'Implement'. The UI shows two empty phase rows.

### F-60 [🟡] F-14: Turn.== is still synthesized with isInProgress as a discriminator

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Turn.swift:9`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  Turn.swift:9-28 — `struct Turn: Identifiable, Equatable` has no `static func ==` override. The synthesized `==` compares all stored properties, including `var isInProgress: Bool` (line 27). 1d18d48 added `bridge.streamingTick &+= 1` (AppState.swift:927) which fires 10-100 Hz during streaming. Every time `isInProgress` flips between derivations, SwiftUI sees a different `Turn` value and the `ForEach(turn.id)` (MessageListView.swift:148) re-evaluates — losing per-turn collapse state and re-running `isTurnCollapsed` for every turn on every tick.
  ```
- **Repro**: Open a 100-turn session. Start streaming on a turn. With `streamingTick` firing per observation, the trailing `Turn.isInProgress` toggles between true/false across derivations; if the ForEach is keyed on `turn.id` (stable UUID) the view tree is preserved, but any code path that compares Turn values (animations, scroll-to-bottom triggers, settle/diff) sees a non-equal Turn every tick.

### F-61 [🟡] F-08: orphan-turn id regenerates per makeTurns call, breaking ForEach identity

- **File**: `/Volumes/外置硬盘/claude code/claude code 套壳/Clarc/Packages/Sources/ClarcChatKit/Turn.swift:81`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackA
- **Evidence**:
  ```
  Turn.swift:81 — `id: UUID()` is generated inside `Turn.makeTurns` for orphan turns (assistant block with no preceding user). Every call to `makeTurns` (which happens on every streaming-tick observation fire) re-runs this code path and produces a NEW UUID for the same logical orphan turn. The `ForEach(turn.id)` in `MessageListView.swift:148` keys on this UUID; on every re-derivation the orphan turn gets a new identity, so SwiftUI treats it as a brand-new view — its collapse state, scroll anchor, and any per-turn @State resets. This is F-08, still UNFIXED at HEAD.
  ```
- **Repro**: 1. Open a reloaded session whose first block is an assistant message (orphan). 2. Send a new prompt to start streaming. 3. Every streaming tick re-runs `Turn.makeTurns`, regenerating the orphan's UUID. 4. SwiftUI sees a different `id` and re-instantiates the orphan's `TurnBlock`, losing its collapse state.

### F-62 [🟡] BashSafety whitelist auto-approves cat/head on arbitrary paths; secrets exfiltrated into tool result + phase digest

- **File**: `Clarc/Services/BashSafety.swift:17`
- **Category**: security  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Clarc/Services/BashSafety.swift:17-46: The `safeCommands` set includes `"echo"`, `"printf"`, and `"cat"`. The `echo` and `printf` entries are read-only in their own right but the set does NOT include any token-level guard against shell parameter expansion. More critically, `"tee"` is NOT in the list (verified), but the comment line 39 says "code / archive inspection (read-only)" which is the only comment. The "write redirections" check at line 259-266 only catches `>` literal, not `>>` or `>&` chains. The `segmentHasWriteRedirect` only removes `>/dev/null`, `2>/dev/null`, `2>&1` and then checks for any remaining `>`. A command like `echo content > file` would NOT be caught because the first `>` is found, stripped… wait, no — `allowedRedirectTokens` is `[">/dev/null", "2>/dev/null", "2>&1"]`. `echo content > /tmp/x` becomes `echo content ` after stripping `>/dev/null`/`2>&1`/`>/dev/null` — actually `>/dev/null` doesn't appear, so the `>` is still there. But the `>>` operator? `>>` contains `>`, so the contains-check triggers. Actually re-reading: `return stripped.contains(">")` — `>>` contains `>`, so it returns true, blocking `>>`. The issue is the OPPOSITE direction: a `>` inside an argument like `echo "abc > def"` is treated as a write redirect, which is a false positive but safe. The more dangerous pattern is the lack of a `tee` check: the comment says these are read-only tools, but `echo content | tee /tmp/x` is NOT detected because `tee` is not even in the list, so it would be rejected at the `safeCommands.contains(base)` step. The bug is the OPPOSITE: the whitelist seems incomplete. More material issue: line 17-46, the entry for `cat` allows arbitrary file paths. The Bash hook checks whitelist for read-only commands; a malicious agent (or prompt-injected content) running `cat ~/.aws/credentials` would be auto-approved because `cat` is in `safeCommands` and the tool returns no result the user sees. The hook just returns a "safe" reason; the data is exfiltrated through the tool result into the conversation transcript. Combined with the new `summarizePhase` content path (which sends tool results as a digest to a model that may log), this is a real exfiltration vector.
  ```
- **Repro**: Configure the Bash hook to auto-approve whitelisted commands. Run a turn whose prompt is injected to "check this file": `cat ~/.aws/credentials`. The hook returns autoApprove; the transcript records the credentials. The new `summarizePhase` digests tool results into a one-sentence summary fed to `claude -p` — the credentials are in the digest.

### F-63 [🟡] F-13 Phase.makePhases still called inline in collapsedSummary/expandedContent body properties (commit-claim false)

- **File**: `Packages/Sources/ClarcChatKit/MessageListView.swift:447`
- **Category**: perf  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Packages/Sources/ClarcChatKit/MessageListView.swift:447, 489: `Phase.makePhases(from: assistantBlocks, isStreamingLast: turn.isInProgress)` is called inside `collapsedSummary` (line 447) and `expandedContent` (line 489) — both are computed view properties that re-evaluate on every body re-render. The function walks all blocks and allocates `[Phase]` (with sub-allocations for `id`, `title`, `fallbackSubtitle`). For a session with 200 visible turns, each turn is a `TurnBlock`; each `TurnBlock` calls `Phase.makePhases` 2x per body re-eval (once for collapsed, once for expanded — but only the visible branch runs, so it depends on state). On a streaming tick (10-100 Hz), each tick re-evaluates the body of every visible `TurnBlock` because `chatBridge.messages` mutates. Net: 200 turns × 1 Phase.makePhases call × 1 body re-eval × 50 ticks/sec = 10,000 Phase.makePhases calls per second, each allocating ~N Phase structs. The commit message for 1d18d48 explicitly claims: "makeVisibleTurns returns the (Turn, [Phase]) pair cached for the duration of one body re-evaluation". The function signature at line 189 is still `private func makeVisibleTurns() -> [Turn]` (returns `[Turn]`, not `[(Turn, [Phase])]`), and `Phase.makePhases` is still called inline.
  ```
- **Repro**: Stream a long response on a session with 200 visible turns. In Instruments, observe the SwiftUI render loop and the `Phase.makePhases` allocations. Compare to the same session with 50 turns — the 200-turn session is 4-8x slower on the streaming tick hot path.

### F-64 [🟡] F-15 Phase synthesized Equatable compares isInProgress + blocks; state resets on every render (commit-claim false)

- **File**: `Packages/Sources/ClarcChatKit/Phase.swift:20`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Packages/Sources/ClarcChatKit/Phase.swift:20: `public struct Phase: Identifiable, Equatable` with NO `static func == (lhs: Phase, rhs: Phase) -> Bool` override. The synthesized Equatable compares ALL stored properties: `id`, `title`, `summary`, `status`, `durationSeconds`, `taskUpdate`, `blocks`, `isInProgress`. For streaming phases, `isInProgress` flips `true → false` at `.result`; `taskUpdate` may swap from nil to a TaskUpdateMessage when a closing taskUpdate arrives; `blocks` mutates as the CLI appends new blocks. SwiftUI's `@State private var isExpanded: Bool` inside `PhaseBlock` (line 565) reads `phase.isInProgress || phase.status != .done` in `init` (line 573). Once the phase becomes `.done`, re-evaluation of `PhaseBlock` with a now-different `Phase` value still has the old `@State` if the parent re-uses the same struct via `ForEach` keyed by `phase.id`. But the Phase's `==` is the gate; if Equatable returns false (because `isInProgress` differs from the previous render), SwiftUI treats it as a new view and RESETS the @State. This means every time a phase's `isInProgress` flips (e.g. on every observation fire during streaming), the expand/collapse state of `PhaseBlock` is RESET. The commit message for 1d18d48 explicitly claims: "Phase.== compares discriminator fields only". No such override exists.
  ```
- **Repro**: Stream a turn that produces phases. During streaming, the trailing phase has `isInProgress = true`; user clicks the phase header to expand. At `.result`, the phase becomes `.done` and `isInProgress = false`. The synthesized Equatable returns false, SwiftUI recreates `PhaseBlock` with a fresh `@State var isExpanded = phase.isInProgress || phase.status != .done` (now `false || false = false`). The user-expanded phase collapses itself on completion. Reproducible on every phase in every turn.

### F-65 [🟡] appendUser drops tool_result-only user messages (no text → no ChatMessage appended)

- **File**: `Packages/Sources/ClarcCore/CLISession/CLILineToBlocksMapper.swift:73`
- **Category**: data-loss  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Packages/Sources/ClarcCore/CLISession/CLILineToBlocksMapper.swift:58-82: In `appendUser` `.parts(let parts)` branch, the code walks every part and either appends to `textsForNewMessage` or calls `foldToolResult`. After the loop, line 73-81: `if !textsForNewMessage.isEmpty { messages.append(ChatMessage(... blocks: [.text(combined)])) }`. The `foldToolResult` calls (line 67-68) modify `messages` in place; if the loop did NOT encounter any text part (only tool_result parts), `textsForNewMessage` is empty and the message is dropped — no `ChatMessage` is created. Concretely, a user-line that consists of `[{type:"tool_result", tool_use_id:"X", content:"..."}]` is silently discarded. The matching tool_use in the preceding assistant turn then has its result set via `foldToolResult` — but only if the assistant turn is the most recent message and the id is findable. In interleaved streams (e.g. two parallel tool uses A and B, with A's result then B's result), this still works via the backward walk. But a user-line with only tool_results and no text is invisible — and worse, the `messages.append(ChatMessage(...role: .user, blocks: [.text(combined)], isResponseComplete: true))` is what would set up the turn boundary in `Turn.makeTurns`. Dropping it means a tool_result-only user message contributes zero user-message signals to the turn list.
  ```
- **Repro**: Replay a jsonl where a user line contains only `[{type:"tool_result", tool_use_id:"abc", content:"..."}]` with no text. After CLILineToBlocksMapper.map, the resulting ChatMessage list has no user message for that line. The UI sees the assistant tool_use with its result folded in but the turn-end marker is missing, so the preceding user message is grouped with the NEXT user turn (creating a turn with two user prompts). Reproducible with any session that ends with a tool_result-only user line.

### F-66 [🟡] lastTimestamp 16KB tail scan returns nil for sessions whose terminal block is large text

- **File**: `Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:318`
- **Category**: correctness  ·  **Status**: UNFIXED
- **Source track**: TrackC
- **Evidence**:
  ```
  Packages/Sources/ClarcCore/CLISession/CLISessionStore.swift:318-348: `lastTimestamp(in:)` reads at most the last 16 KB of the jsonl (line 15, 328). If the file is larger than 16 KB and the last 16 KB does not contain a `"timestamp":"..."` line, the function returns nil. This happens whenever a session ends with a long assistant message whose line itself exceeds 16 KB, or when the last few lines are text blocks with no timestamped envelope nearby. The caller (line 199) falls back to mtime in that case, which is `now()` if the file was just rewritten by the CLI — so a session that just finished shows `updatedAt = now()` instead of the actual last activity timestamp. UI surface: `ChatSession.Summary.updatedAt` is shown in the sidebar; a session that has been idle for 30 min shows "now" instead of the correct timestamp, making the sidebar's time-since grouping useless.
  ```
- **Repro**: Create a session that ends with a 20 KB assistant message. Run `lastTimestamp(in: url)` — it returns nil because the timestamp is more than 16 KB back. Caller falls back to mtime; sidebar shows "now" instead of "5 min ago".

## Fix Priority

**First wave (data loss / process leak / false-commit-claims)** — ~1-2 hours:
- F-22 (summarizeCompletedPhases pipeline) + F-25 (runShellCommand timeout) — paired: add cancellation + 30s timeout to both
- F-29 + F-30 (the 2 v2.6.0 findings the v2.6.1 commit falsely claimed to fix) — actually do the work 1d18d48 promised

**Second wave (real correctness bugs)** — ~2-4 hours:
- All remaining 🔴
- Top 10 🟡 by file:cluster (especially `MessageListView.swift` / `AppState.swift` / `ClaudeService.swift`)

**Third wave (M/L tier cosmetic / i18n / a11y)** — ~4-8 hours:
- Remaining 🟡
