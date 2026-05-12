# jsonl Single Source of Truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the CLI's on-disk jsonl the single authoritative source of truth for session messages so that messages are never missing from the UI regardless of streaming edge cases.

**Architecture:** Split `SessionStreamState.messages` into two tiers — `committedMessages` (loaded from disk, always authoritative) and `streamingTail` (in-flight current turn only). All stream writes go to the tail; all disk reads populate committed. On turn end, the tail is promoted optimistically to committed and then immediately replaced by a fresh jsonl reload. Multiple reload triggers (FS watcher, session switch, app activate) ensure the UI stays in sync even when the stream pipeline fails.

**Tech Stack:** Swift 6, SwiftUI, `@MainActor @Observable AppState`, FSEventStream via `DirectoryWatcher`, `CLISessionStore.loadFullSession` (mmap-based jsonl parser)

---

## File Map

| File | Change |
|---|---|
| `Clarc/App/AppState.swift` | All changes — `StreamingTail` struct, `SessionStreamState` refactor, stream writes, reconcile, watcher, save paths |
| No other files change | `ChatSession`, `ChatMessage`, `PersistenceService`, `DirectoryWatcher`, `ClarcChatKit` are all untouched |

---

### Task 1: Add `StreamingTail` struct to AppState.swift

**Files:**
- Modify: `Clarc/App/AppState.swift` (after `SessionStreamState`, around line 47)

- [ ] **Step 1: Insert StreamingTail struct**

Insert immediately after the closing `}` of `SessionStreamState` (currently line 47), before the blank line at line 48:

```swift
/// Holds the in-flight messages and delta buffers for the currently active streaming turn.
/// Created when streaming starts; discarded after the turn ends and disk is reloaded.
struct StreamingTail {
    var messages: [ChatMessage] = []
    var textDeltaBuffer: String = ""
    var pendingToolResults: [(toolUseId: String, content: String, isError: Bool)] = []
    var needsNewMessage: Bool = false
    var activeToolId: String?
    var activeToolInputBuffer: String = ""
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "feat: add StreamingTail struct for in-flight turn isolation"
```

---

### Task 2: Refactor `SessionStreamState` — add two-tier message storage

**Files:**
- Modify: `Clarc/App/AppState.swift:11-47` (SessionStreamState struct)

- [ ] **Step 1: Replace the messages/delta properties in SessionStreamState**

Current `SessionStreamState` struct (lines 11-47). Replace it entirely with:

```swift
struct SessionStreamState {
    // Two-tier message storage: disk truth + live tail
    var committedMessages: [ChatMessage] = []
    var streamingTail: StreamingTail?

    /// The full message list for rendering and saving.
    var allMessages: [ChatMessage] {
        committedMessages + (streamingTail?.messages ?? [])
    }

    // Streaming lifecycle
    var isStreaming = false
    var isThinking = false
    var activeStreamId: UUID?
    var streamingStartDate: Date?
    var streamTask: Task<Void, Never>?
    var flushTask: Task<Void, Never>?

    // Per-session overrides (persisted in memory across session switches)
    var model: String?
    var effort: String?
    var permissionMode: PermissionMode?

    // Session statistics
    var costUsd: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var durationMs: Double = 0
    var turns: Int = 0
    var lastTurnContextUsedPercentage: Double?
    var activeModelName: String?
}
```

Note: `textDeltaBuffer`, `pendingToolResults`, `needsNewMessage`, `activeToolId`, `activeToolInputBuffer` are removed from here — they now live in `StreamingTail`.

- [ ] **Step 2: Build — expect many errors (all `.messages` callers need updating)**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -40
```

Expected: Multiple "value of type 'SessionStreamState' has no member 'messages'" errors. This is expected — the next tasks fix them all.

- [ ] **Step 3: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "refactor: split SessionStreamState.messages into committedMessages + streamingTail"
```

---

### Task 3: Update `startBridgeObservation` — render `allMessages`

**Files:**
- Modify: `Clarc/App/AppState.swift:585`

- [ ] **Step 1: Update bridge.messages assignment**

Find line 585 (`bridge.messages = state.messages`) in `startBridgeObservation` and change to:

```swift
bridge.messages = state.allMessages
```

- [ ] **Step 2: Update `messages(in:)` accessor** (line 370)

Find:
```swift
func messages(in window: WindowState) -> [ChatMessage] {
    streamState(in: window).messages
}
```

Change to:
```swift
func messages(in window: WindowState) -> [ChatMessage] {
    streamState(in: window).allMessages
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: render allMessages (committed + tail) in bridge and accessor"
```

---

### Task 4: Update `flushPendingUpdates` — read/write from `streamingTail`

**Files:**
- Modify: `Clarc/App/AppState.swift:1314-1361`

`flushPendingUpdates` currently reads `state.textDeltaBuffer`, `state.pendingToolResults`, `state.needsNewMessage` and writes to `state.messages`. All of these must use `state.streamingTail` instead.

- [ ] **Step 1: Rewrite flushPendingUpdates**

Find the `flushPendingUpdates` function (around line 1314). Replace its body with:

```swift
private func flushPendingUpdates(for key: String) {
    guard var state = sessionStates[key] else { return }
    guard var tail = state.streamingTail else { return }

    let hasText = !tail.textDeltaBuffer.isEmpty
    let hasToolResults = !tail.pendingToolResults.isEmpty
    guard hasText || hasToolResults else { return }

    // Phase 1: Apply pending tool results to the last assistant message in tail
    if hasToolResults {
        let results = tail.pendingToolResults
        tail.pendingToolResults = []
        if let idx = tail.messages.indices.last(where: { tail.messages[$0].role == .assistant }) {
            for (toolUseId, content, isError) in results {
                tail.messages[idx].setToolResult(id: toolUseId, result: content, isError: isError)
            }
        }
    }

    // Phase 2: Flush text delta buffer
    if hasText {
        let buffered = tail.textDeltaBuffer
        tail.textDeltaBuffer = ""

        if tail.needsNewMessage {
            // Finalize previous streaming message
            if let idx = tail.messages.indices.last(where: { tail.messages[$0].isStreaming }) {
                tail.messages[idx].isStreaming = false
                tail.messages[idx].finalizeToolCalls()
                tail.messages[idx].stripNoResponseRequested()
            }
            tail.needsNewMessage = false
            tail.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
        } else if let idx = tail.messages.indices.last(where: { tail.messages[$0].isStreaming && tail.messages[$0].role == .assistant }) {
            tail.messages[idx].appendText(buffered)
        } else {
            tail.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
        }
    }

    state.streamingTail = tail
    sessionStates[key] = state
}
```

> **Note:** The methods `setToolResult`, `finalizeToolCalls`, `stripNoResponseRequested`, `appendText` are existing methods on `ChatMessage`/`MessageBlock`. Verify exact method names in `ChatMessage.swift` if build fails.

- [ ] **Step 2: Build and check errors**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

Fix any "no member" errors by checking `ChatMessage.swift` for the correct method names.

- [ ] **Step 3: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: flushPendingUpdates reads/writes StreamingTail instead of messages"
```

---

### Task 5: Update `handlePartialEvent` — write to `streamingTail`

**Files:**
- Modify: `Clarc/App/AppState.swift` (~lines 1395-1465, the `handlePartialEvent` function)

`handlePartialEvent` currently writes to `state.messages[...]`. All those writes must become `state.streamingTail!.messages[...]`. The tail is guaranteed to exist during streaming (initialized in Task 6).

- [ ] **Step 1: Find all `state.messages` writes in handlePartialEvent**

```bash
grep -n "state\.messages" /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift | grep -v "//.*state\.messages"
```

- [ ] **Step 2: Replace each write — change `state.messages` to `state.streamingTail!.messages`**

The affected lines are approximately:
- Line 1399: `state.messages.append(ChatMessage(role: .assistant, isStreaming: true))` → `state.streamingTail!.messages.append(ChatMessage(role: .assistant, isStreaming: true))`
- Line 1402: `state.messages.append(ChatMessage(role: .assistant, isStreaming: true))` → `state.streamingTail!.messages.append(ChatMessage(role: .assistant, isStreaming: true))`
- Line 1406: `state.messages[lastIndex].appendToolCall(...)` → `state.streamingTail!.messages[lastIndex].appendToolCall(...)`
- Line 1460: `state.messages[msgIdx].blocks[blockIdx].toolCall?.input = parsed` → `state.streamingTail!.messages[msgIdx].blocks[blockIdx].toolCall?.input = parsed`

Also update any index calculations that use `state.messages.indices.last(where:)` → `state.streamingTail!.messages.indices.last(where:)`.

Also move the buffer property accesses: `state.textDeltaBuffer` → `state.streamingTail!.textDeltaBuffer`, `state.activeToolId` → `state.streamingTail!.activeToolId`, `state.activeToolInputBuffer` → `state.streamingTail!.activeToolInputBuffer`, `state.needsNewMessage` → `state.streamingTail!.needsNewMessage`, `state.isThinking` stays on `state`.

- [ ] **Step 3: Build and fix errors**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 4: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: handlePartialEvent writes to streamingTail.messages"
```

---

### Task 6: Update stream lifecycle — initialize tail on start, promote on end

**Files:**
- Modify: `Clarc/App/AppState.swift` (~lines 977-1230, `processStream`)

- [ ] **Step 1: Initialize streamingTail when streaming starts**

In `processStream`, find where `isStreaming = true` is set (before the `for await event in stream` loop). After that line, add:

```swift
updateState(sessionKey) {
    $0.isStreaming = true
    $0.streamingTail = StreamingTail()
}
```

If there's no `updateState` helper, use the direct pattern:
```swift
if var s = sessionStates[sessionKey] {
    s.isStreaming = true
    s.streamingTail = StreamingTail()
    sessionStates[sessionKey] = s
}
```

- [ ] **Step 2: Promote tail to committed on `.result`**

Find the `.result` handler (around line 1150-1185). After `stopFlushTimer`, before `saveSession`, add tail promotion:

```swift
// Promote in-flight tail into committed (fast path before disk reload)
if var s = sessionStates[resultEvent.sessionId] {
    let tailMessages = s.streamingTail?.messages ?? []
    s.committedMessages += tailMessages.map { msg in
        var m = msg; m.isStreaming = false; return m
    }
    s.streamingTail = nil
    s.isStreaming = false
    sessionStates[resultEvent.sessionId] = s
}
```

Change the `saveSession` call to use `allMessages` (which equals `committedMessages` now that tail is nil):
```swift
await saveSession(
    sessionId: resultEvent.sessionId,
    projectId: projectId,
    messages: stateForSession(resultEvent.sessionId).allMessages
)
```

Then replace the `reconcileFromDisk(...)` call at line 1185 with `reloadCommittedFromDisk(...)` (defined in Task 7).

- [ ] **Step 3: Clear tail on stream cancel/error**

Find where `isStreaming = false` is set on cancellation and error paths. In each location, also set `streamingTail = nil` AND promote any partial tail content:

```swift
if var s = sessionStates[sessionKey] {
    let tailMessages = s.streamingTail?.messages ?? []
    s.committedMessages += tailMessages.map { msg in
        var m = msg; m.isStreaming = false; return m
    }
    s.streamingTail = nil
    s.isStreaming = false
    sessionStates[sessionKey] = s
}
```

Search for all `isStreaming = false` assignments in AppState.swift to find every cancellation/error path:
```bash
grep -n "isStreaming = false" /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift
```

Apply the tail promotion pattern to each path.

- [ ] **Step 4: Build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: initialize StreamingTail on stream start, promote to committed on end"
```

---

### Task 7: Replace `reconcileFromDisk` with `reloadCommittedFromDisk`

**Files:**
- Modify: `Clarc/App/AppState.swift:2263-2289`

- [ ] **Step 1: Delete `reconcileFromDisk` and `lastReconciledJsonlSize`**

Remove:
- `private var lastReconciledJsonlSize: [String: UInt64] = [:]` (line 2239)
- The entire `reconcileFromDisk` function (lines 2263-2289)

- [ ] **Step 2: Add `reloadCommittedFromDisk`**

Insert in their place:

```swift
/// Reloads committed messages from the CLI's jsonl, unconditionally replacing
/// `committedMessages`. Skipped only when the session is actively streaming
/// (tail holds the in-progress turn). Safe to call from any trigger.
private func reloadCommittedFromDisk(sessionId: String, projectId: UUID, cwd: String) {
    let summary = summaryFor(sessionId: sessionId, projectId: projectId)
    Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        guard let full = await self.persistence.loadFullSession(summary: summary, cwd: cwd) else { return }
        let cleaned = await self.cleanLoadedMessages(full.messages)
        await MainActor.run {
            guard var state = self.sessionStates[sessionId],
                  !state.isStreaming else { return }
            state.committedMessages = cleaned
            self.sessionStates[sessionId] = state
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 4: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "refactor: replace reconcileFromDisk with reloadCommittedFromDisk (no guards)"
```

---

### Task 8: Update non-stream message writes to `committedMessages`

**Files:**
- Modify: `Clarc/App/AppState.swift` (multiple locations)

These are message writes that happen OUTSIDE the streaming tail — they should write to `committedMessages` directly.

- [ ] **Step 1: User message append (~line 2412)**

Find the user message append in `addMessage` (or equivalent). Change:
```swift
state.messages.append(ChatMessage(role: .user, content: displayText, attachments: resolvedAttachments))
```
To:
```swift
state.committedMessages.append(ChatMessage(role: .user, content: displayText, attachments: resolvedAttachments))
```

- [ ] **Step 2: Compact boundary append (~line 1114)**

Find the compact boundary message append in `processStream`. Change:
```swift
state.messages.append(ChatMessage(role: .assistant, content: "Previous conversation has been compacted", isCompactBoundary: true))
```
To:
```swift
state.committedMessages.append(ChatMessage(role: .assistant, content: "Previous conversation has been compacted", isCompactBoundary: true))
```

- [ ] **Step 3: Error message append (~line 1270)**

Find the error message append in `processStream`. Change:
```swift
state.messages.append(ChatMessage(role: .assistant, content: errorMsg, isError: true))
```
To:
```swift
state.committedMessages.append(ChatMessage(role: .assistant, content: errorMsg, isError: true))
```

- [ ] **Step 4: Find remaining `.messages` writes**

```bash
grep -n "\.messages\." /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift | grep -v "streamingTail\|committedMessages\|allMessages\|bridge\.\|//\|ChatMessage\|saveSession\|ChatSession\|stateForSession"
```

For each remaining result, determine if it is:
- A bulk load/assignment → change target to `committedMessages`
- A streaming in-turn write → should already be using `streamingTail` from Task 5

- [ ] **Step 5: Update `editAndResend` (~line 619)**

Find:
```swift
var snapshot = sessionStates[key]?.messages ?? []
```
Change to:
```swift
var snapshot = sessionStates[key]?.allMessages ?? []
```

Also update the save call at line 635 if it uses `.messages`.

- [ ] **Step 6: Update ownership-transfer saves (~lines 1034-1036)**

Find:
```swift
let msgs = stateForSession(sessionKey).messages
if !msgs.isEmpty {
    await saveSession(sessionId: resultEvent.sessionId, projectId: projectId, messages: msgs)
}
```
Change to:
```swift
let msgs = stateForSession(sessionKey).allMessages
if !msgs.isEmpty {
    await saveSession(sessionId: resultEvent.sessionId, projectId: projectId, messages: msgs)
}
```

- [ ] **Step 7: Build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 8: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: non-stream writes (user, error, compact boundary) go to committedMessages"
```

---

### Task 9: Update session-switch loading to use `committedMessages`

**Files:**
- Modify: `Clarc/App/AppState.swift:1842-1860` (`switchToSession`) and `loadMessagesInBackground` (~line 2294)

- [ ] **Step 1: Update `switchToSession` — always call `reloadCommittedFromDisk`**

In `switchToSession`, find the block that checks `sessionStates[session.id] == nil` and calls `loadMessagesInBackground`. Replace the entire conditional loading block with a single unconditional reload:

```swift
if sessionStates[session.id] == nil {
    var state = SessionStreamState()
    state.model = session.model
    state.effort = session.effort
    state.permissionMode = session.permissionMode
    sessionStates[session.id] = state
}

// Always reload from disk — disk is the source of truth
if let project = window.selectedProject {
    reloadCommittedFromDisk(sessionId: session.id, projectId: project.id, cwd: project.path)
}
```

The `reloadCommittedFromDisk` has an `!isStreaming` guard so it will safely no-op if this session is being streamed by another window.

- [ ] **Step 2: Update `loadMessagesInBackground` — write to `committedMessages`**

Find `loadMessagesInBackground` (~line 2294). It ends with:
```swift
state.messages = cleaned
```
Change to:
```swift
state.committedMessages = cleaned
```

Also remove the guards:
```swift
guard !state.isStreaming, state.messages.isEmpty else { return }
```
Change to:
```swift
guard !state.isStreaming else { return }
```

(This function is now only called from legacy paths; the main path uses `reloadCommittedFromDisk`.)

- [ ] **Step 3: Build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 4: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: switchToSession always reloads committedMessages from disk"
```

---

### Task 10: Wire up additional reload triggers

**Files:**
- Modify: `Clarc/App/AppState.swift` (watchProjectDirectory ~line 1805, didSwitchToSession ~line 1906, app init)

- [ ] **Step 1: Update `watchProjectDirectory` onChange — reload active sessions**

Find `watchProjectDirectory` (~line 1805). Update the onChange closure to also reload committed messages for any window currently showing this project:

```swift
private func watchProjectDirectory(_ project: Project) {
    let projectId = project.id
    let cwd = project.path
    Task { [weak self] in
        guard let self else { return }
        let dir = await self.cliStore.directory(forCwd: cwd)
        await self.directoryWatcher.watch(url: dir) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let p = self.projects.first(where: { $0.id == projectId }) else { return }
                await self.reloadSessionSummaries(for: p)
                // Reload committed messages for any window actively showing this project
                self.reloadActiveSessionsForProject(projectId: projectId, cwd: cwd)
            }
        }
    }
}

private func reloadActiveSessionsForProject(projectId: UUID, cwd: String) {
    // Find all window states that have this project selected and a current session
    // WindowState is accessed per-window; iterate all known session IDs for this project
    for summary in allSessionSummaries where summary.projectId == projectId {
        guard let state = sessionStates[summary.id], !state.isStreaming else { continue }
        // Only reload sessions that are actually in memory (i.e., a window has them loaded)
        reloadCommittedFromDisk(sessionId: summary.id, projectId: projectId, cwd: cwd)
    }
}
```

> **Note:** If `WindowState` instances are accessible from `AppState` (check for a `var windows: [WindowState]` property or similar), prefer to iterate windows and reload only the `currentSessionId` of each window that matches `projectId`. Check the actual AppState properties to find the right accessor. If no windows collection exists, the `allSessionSummaries` approach above is the safe fallback.

- [ ] **Step 2: Add app-activate reload**

Find `initializeWindow` or the app startup section in AppState. Add a notification observer:

```swift
// Add this in init() or wherever the app sets up notifications
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self else { return }
        // Reload committed for all in-memory non-streaming sessions
        for (sid, state) in self.sessionStates where !state.isStreaming {
            if let summary = self.allSessionSummaries.first(where: { $0.id == sid }) {
                let project = self.projects.first(where: { $0.id == summary.projectId })
                let cwd = project?.path ?? ""
                self.reloadCommittedFromDisk(sessionId: sid, projectId: summary.projectId, cwd: cwd)
            }
        }
    }
}
```

Place this in the `AppState` initializer (find `init()` in AppState.swift).

- [ ] **Step 3: Reload on session focus (`didSwitchToSession`)**

`reloadCommittedFromDisk` is already called from `switchToSession` (Task 9). No additional change needed in `didSwitchToSession`.

- [ ] **Step 4: Build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "feat: reload committedMessages on FS change, session switch, and app activate"
```

---

### Task 11: Sweep — fix all remaining `state.messages` references

**Files:**
- Modify: `Clarc/App/AppState.swift`

- [ ] **Step 1: Find all remaining raw `.messages` accesses**

```bash
grep -n "\.messages" /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift | grep -v "committedMessages\|allMessages\|streamingTail\|bridge\.\|//\|ChatMessage\|saveSession\|ChatSession\|Summary\|sessionSummaries"
```

- [ ] **Step 2: Classify and fix each hit**

For each result:
- If reading (e.g., `state.messages.isEmpty`, `state.messages.count`): change to `state.allMessages`
- If writing (assigning): change to `state.committedMessages`
- If part of a save call: change to `state.allMessages`

Common patterns to look for:
```swift
// releaseOutgoingSession (~line 1891)
let outgoingMessages = sessionStates[outgoingId]?.messages ?? []
// → change to:
let outgoingMessages = sessionStates[outgoingId]?.allMessages ?? []

// saveCurrentSession (~line 2322)
messages: stateForSession(sessionId).messages
// → change to:
messages: stateForSession(sessionId).allMessages
```

- [ ] **Step 3: Build — must succeed**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep -E "error:|warning:.*'messages'|Build succeeded"
```

Expected: `Build succeeded` with no remaining "has no member 'messages'" errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "fix: replace all raw .messages accesses with .allMessages or .committedMessages"
```

---

### Task 12: Remove dead code

**Files:**
- Modify: `Clarc/App/AppState.swift`

- [ ] **Step 1: Search for any remaining references to removed properties**

```bash
grep -n "textDeltaBuffer\|pendingToolResults\|needsNewMessage\|activeToolId\|activeToolInputBuffer\|lastReconciledJsonlSize" \
  /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift
```

Any hit that is NOT inside `StreamingTail` or accessing `streamingTail.xxx` is dead code from before the refactor. Remove it.

- [ ] **Step 2: Search for old reconcileFromDisk**

```bash
grep -n "reconcileFromDisk" /Users/miniling/workspace/Clarc/Clarc/App/AppState.swift
```

Should return zero results (removed in Task 7). If found, remove.

- [ ] **Step 3: Final build**

```bash
xcodebuild -project /Users/miniling/workspace/Clarc/Clarc.xcodeproj \
  -scheme Clarc -configuration Debug \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Final commit**

```bash
cd /Users/miniling/workspace/Clarc
git add Clarc/App/AppState.swift
git commit -m "chore: remove dead stream-state properties superseded by StreamingTail"
```

---

## Self-Review Checklist

### Spec coverage

| Requirement | Task |
|---|---|
| jsonl is single source of truth | Task 7 (reloadCommittedFromDisk, no guards) |
| Stream writes don't contaminate committed | Tasks 4, 5 (all → streamingTail) |
| Messages appear after stream end | Task 6 (promote tail + reload) |
| Messages appear after session switch | Task 9 (unconditional reload in switchToSession) |
| Messages appear after FS change (external CLI) | Task 10 (watcher onChange) |
| Messages appear on app activate | Task 10 (didBecomeActive) |
| Disk format unchanged (backward compat) | Not a code task — ChatSession struct untouched, saveSession still writes `allMessages` |
| No UI flicker during stream | Task 6 (tail promoted optimistically before disk reload) |
| No regression in streaming UX | Tasks 4, 5 (streamingTail renders same as old messages during stream) |

### Placeholder scan

No TBD, TODO, or placeholder steps. All code is concrete.

### Type consistency

- `StreamingTail.messages: [ChatMessage]` — used as `streamingTail!.messages` in Tasks 4, 5
- `SessionStreamState.allMessages: [ChatMessage]` — computed from `committedMessages + streamingTail?.messages ?? []`
- `reloadCommittedFromDisk(sessionId:projectId:cwd:)` — called identically from Tasks 6, 7, 9, 10
- `summaryFor(sessionId:projectId:)` — existing helper, unchanged, called in Task 7

All consistent.
