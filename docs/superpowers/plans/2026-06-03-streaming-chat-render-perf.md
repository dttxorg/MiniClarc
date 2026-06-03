# Streaming Chat Render Perf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce UI jank during Claude streaming so the chat area scrolls smoothly and other UI (sidebar, input) stays responsive, by isolating streaming text-delta work from the settled list rebuild and switching the layout container to a lazy variant.

**Architecture:** In `MessageListView.swift` only. Three independent changes to the same file: (1) drop the 50ms polling `task` and rewire `rebuildSettledItems` to fire on discrete events (`messages.count`, `isStreaming` end, `messages.last?.blocks.count`), (2) wrap the settled and streaming `VStack` containers in `LazyVStack`, (3) leave `settledOnlyMessages` semantics unchanged (its two branches naturally collapse once the 50ms polling is gone — verified at task 3).

**Tech Stack:** SwiftUI 5+ (`@Observable`, `LazyVStack`, `ScrollPosition`), macOS 15+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-03-streaming-chat-render-perf-design.md` (commit `889dadb`).

**Out of scope:** AppState, ChatBridge interface, WindowState, MarkdownView, MessageBubble internals, sidebar / file tree / history list. Single-file change; `git revert` of the implementation commit is the rollback path.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Packages/Sources/ClarcChatKit/MessageListView.swift` | Modify | Drop 50ms polling, add discrete-event triggers, switch two `VStack` → `LazyVStack`. All three changes in this one file. |

No new files, no new tests (project has no test target — verified by `Package.swift` and the project root). Verification is the existing `xcodebuild CODE_SIGNING_ALLOWED=NO build` plus the manual smoke test in the verification section below.

---

## Task 1: Drop the 50ms polling task and rewire the rebuild trigger

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/MessageListView.swift:113-116, 169-181, 182-196`

- [ ] **Step 1: Remove the `onStructureChanged` callback from `StreamingMessageView`**

In `MessageListView.swift`, find the call site (around lines 113–116):

```swift
StreamingMessageView {
    rebuildSettledItems()
    if isNearBottom { scrollToBottomDebounced() }
}
```

Replace it with an empty call site — `StreamingMessageView` no longer takes a callback from `MessageListView` for this purpose:

```swift
StreamingMessageView()
```

(`StreamingMessageView`'s own `onChange(of: messages.count)` in its own file stays — that's a separate internal trigger.)

- [ ] **Step 2: Delete the 50ms polling `task` block**

In `MessageListView.swift`, delete the entire `.task(id: chatBridge.isStreaming) { ... }` block (around lines 174–181). Specifically, remove this region **and** its leading comment block (lines 169–181):

```swift
        // Tier 1 (part 2): text deltas don't change messages.count, so the
        // existing onChange-of-count trigger never fires while only text is
        // streaming. This timer drives a periodic settled-list refresh at the
        // same 50ms cadence as AppState.flushTask upstream, so settledItems
        // stays in sync with the live streaming tail.
        .task(id: chatBridge.isStreaming) {
            guard chatBridge.isStreaming else { return }
            while !Task.isCancelled && chatBridge.isStreaming {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                rebuildSettledItems()
            }
        }
```

**Why this is safe:** streaming text deltas update the *same* `ChatMessage`'s `blocks`; they don't change `chatBridge.messages.count`. The only settled-list shape changes are (a) new message append (count changes), (b) `isStreaming` end (finalized message flips from streaming → settled), and (c) during streaming, the active streaming message's `blocks` growing when a `tool_result` block lands on it. We re-introduce (a) and (b) via the existing `isStreaming` end handler plus a new `messages.count` `onChange`, and handle (c) via a `last?.blocks.count` `onChange` (added in step 3).

- [ ] **Step 3: Add discrete-event rebuild triggers**

In `MessageListView.swift`, locate the existing `onChange(of: chatBridge.isStreaming)` (around lines 182–196). **Leave it intact** (it already handles the end-of-stream `rebuildSettledItems()` + `scrollToBottomDebounced()` and the `isOlderCollapsed` reset).

**Add** the following two new modifiers **immediately after** the existing `onChange(of: chatBridge.isStreaming)` (so the order is: existing `isStreaming` change → new `messages.count` change → new `last.blocks.count` change). Insert after line 196 (the closing `}` of the existing onChange):

```swift
        .onChange(of: chatBridge.messages.count) { _, _ in
            // A new message was appended (user prompt, tool result that
            // produced a new assistant turn, etc.). Rebuild the settled
            // list so the new entry appears in the correct slot.
            rebuildSettledItems()
            if isNearBottom { scrollToBottomDebounced() }
        }
        .onChange(of: chatBridge.messages.last?.blocks.count) { _, _ in
            // During streaming, a tool_result that lands on the *current*
            // streaming message grows its blocks without changing
            // messages.count. Rebuild so the settled list (and the fold
            // threshold) reflects the new shape.
            if chatBridge.isStreaming { rebuildSettledItems() }
        }
```

**Why both are needed:** `messages.count` catches "new message appended". `last?.blocks.count` catches "current streaming message grew a tool_result block" (no count change). Both are Int keys, so `onChange` is reliable.

- [ ] **Step 4: Verify the diff shape**

Confirm by reading the file that the three regions now look like this (approximate line numbers after edit):

- ~line 113: `StreamingMessageView()` with no trailing closure
- The entire `.task(id: chatBridge.isStreaming) { ... }` block is gone (about 13 lines removed)
- After the existing `onChange(of: chatBridge.isStreaming) { ... }` block, two new `.onChange` modifiers are present

- [ ] **Step 5: Build**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Packages/Sources/ClarcChatKit/MessageListView.swift
git commit -m "perf(chat): drop 50ms polling during streaming; rebuild settledItems on discrete events

Streaming text deltas update the same message's blocks; they don't
change messages.count. The 50ms polling task burned Main Thread cycles
every tick and was the primary cause of UI jank during streaming
(scroll lag, input delay). Replaced with three discrete triggers:

  - messages.count change         (new message appended)
  - isStreaming end (existing)    (finalized message flips to settled)
  - last.blocks.count change     (tool_result on the current streaming message)

StreamingMessageView no longer takes a structure-change callback from
MessageListView; its own onChange(of: messages.count) is untouched.

No behavior change in the settled list: every event that previously
fired the 50ms rebuild still does, just at the right moment instead of
poll rate."
```

---

## Task 2: Wrap settled and streaming containers in `LazyVStack`

**Files:**
- Modify: `Packages/Sources/ClarcChatKit/MessageListView.swift:27, 106`

- [ ] **Step 1: Wrap the settled messages `VStack` in `LazyVStack`**

In `MessageListView.swift`, change the first `VStack(spacing: 16)` (line 27, the one that contains the `if chatBridge.phaseSummaries.isEmpty` block):

```swift
            VStack(spacing: 16) {
```

to:

```swift
            LazyVStack(spacing: 16) {
```

**Why this is safe:** every direct child already has a stable `.id(...)` — `MessageGroup.id = accumulator[0].id` (line 325), `MessageBubble.id(message.id)` (line 216), `PhaseSummaryCard.id(summary.id)` (line 235), `TransientGroupSummaryView.id(group.id)` (line 213). Keyed diff works inside `LazyVStack`; SwiftUI only materializes rows that intersect the visible viewport.

- [ ] **Step 2: Wrap the streaming-tail `VStack` in `LazyVStack`**

In `MessageListView.swift`, change the second `VStack(spacing: 16)` (line 106, the one that contains `StreamingMessageView` and `StreamingIndicatorView`):

```swift
            VStack(spacing: 16) {
```

to:

```swift
            LazyVStack(spacing: 16) {
```

**Why this is safe:** the streaming container holds at most a few rows (`StreamingMessageView` + optional `StreamingIndicatorView` + optional `WebPreviewButton`). Even though it's small, keeping both containers consistent avoids SwiftUI re-laying out the whole stack when content type changes.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If you see `LazyVStack` related compile errors, double-check that no surrounding modifier broke. Common pitfall: the `.padding(.horizontal, 20)` / `.padding(.top, 16)` modifiers on lines 102–103 still apply to the new `LazyVStack` correctly.

- [ ] **Step 4: Commit**

```bash
git add Packages/Sources/ClarcChatKit/MessageListView.swift
git commit -m "perf(chat): switch settled and streaming containers to LazyVStack

Bubbles outside the visible viewport no longer participate in layout
or diff. Combined with the discrete-event rebuild from the previous
commit, this keeps SwiftUI's per-frame work proportional to the
number of on-screen bubbles, not the total bubble count in the
session.

Both children already use stable .id(...) (MessageGroup.id, message.id,
summary.id), so keyed diff inside LazyVStack works correctly."
```

---

## Task 3: Smoke test the full flow (no code change, verification only)

**Files:** none modified in this task.

- [ ] **Step 1: Build the release variant as a final check**

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Manual interaction smoke test**

Open the built `.app` in `~/Library/Developer/Xcode/DerivedData/Clarc-*/Build/Products/Debug/Clarc.app` (or Release variant). Run the following four scenarios and confirm each behaves as expected. Use `git stash` to temporarily roll back both implementation commits for an A/B comparison if needed.

Scenario A — empty session rendering:
- Launch the app, do not pick a project
- Expected: `EmptySessionView` is centered, no scroll jank, no layout flashes

Scenario B — load a session with > 50 messages:
- Pick a project, pick a session that has many messages
- Expected: scrolling is smooth; the older-messages fold button appears at the threshold; expanding then collapsing works; switching tabs to another session and back preserves scroll position

Scenario C — streaming text delta:
- In a session, send a prompt that elicits a long code-block-heavy response
- While the response is streaming:
  - Scroll the chat area — text appears smoothly, no visible jank
  - Click the sidebar — switching projects/sessions responds within ~100ms
  - Click into the input box and type — no input lag
- After the response completes, the message moves into the settled list with full content (no truncation)

Scenario D — streaming with tool calls:
- Send a prompt that causes Claude to use a tool (e.g. Read, Bash)
- Expected: tool result renders inside the streaming message; the streaming indicator stays visible; once the assistant turn completes, the message settles correctly

- [ ] **Step 3: Verify no regression in non-streaming paths**

Confirm the following still work (each is a small targeted check):
- Renaming a session (sidebar right-click → Rename) updates the title in the list
- Pinning a session moves it to the top of the list
- Deleting a session (any of: right-click Delete, or the chat-toolbar Delete) removes it from the list and from the disk
- The "Delete All" header button removes all sessions
- Switching focus mode (if exposed) still filters the list per `settledOnlyMessages`'s focus-mode branch

- [ ] **Step 4: Final commit (only if a doc tweak was needed)**

If during smoke testing you found a small doc-comment fix worth shipping, commit it; otherwise skip this step:

```bash
git add <files>
git commit -m "docs(chat): <describe the comment tweak>"
```

---

## Self-Review

**1. Spec coverage:**
- Spec Fix 1 (drop 50ms polling, add discrete triggers) → Task 1, steps 1–3 ✓
- Spec Fix 2 (VStack → LazyVStack, both containers) → Task 2, steps 1–2 ✓
- Spec Fix 3 (settledOnlyMessages simplification) → Spec said "behavior unchanged, only call frequency drops". Verified by reading the function — it has two branches, both still reachable from the new discrete triggers. **No code change needed.** Captured as a comment in the verification section. ✓
- Spec risk: "tool_result on streaming message doesn't change count" → handled in Task 1 step 3 with the `last?.blocks.count` `onChange`. ✓
- Spec out-of-scope items (AppState, ChatBridge, MarkdownView, sidebar, etc.) → not touched in any task. ✓

**2. Placeholder scan:** No TBD / TODO / "implement later" / "add validation" / "similar to Task N" in the plan. Every code step shows the actual replacement code.

**3. Type consistency:** `StreamingMessageView()` is called with no closure in Task 1 step 1. **Verify the call site tolerates no closure** by checking `Packages/Sources/ClarcChatKit/MessageListView.swift` for `StreamingMessageView`'s definition. Looking at lines 363–413 of the same file: `struct StreamingMessageView: View` has `var onStructureChanged: () -> Void` as a stored property. In Swift, a stored closure property can be called as `StreamingMessageView()` only if the closure has a default value, **or** if it's optional. **This is a real issue — Task 1 step 1 must use a no-op closure or change the property to default-initialized.**

**Action: fix Task 1 step 1 to pass a no-op closure instead of removing it:**

Replace step 1's `StreamingMessageView()` with:

```swift
StreamingMessageView {
    // No-op: structure rebuilds now fire from .onChange modifiers above.
}
```

This keeps the API contract and removes the polling dependency. The closure still gets called from inside `StreamingMessageView`'s `onChange(of: messages.count)` (line 402) but the no-op means the redundant rebuild path is dead.

---

## Execution

Plan complete. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for catching drift between intent and implementation.

**2. Inline Execution** — I execute the tasks in this session, batch with checkpoints for review.

Which approach?
