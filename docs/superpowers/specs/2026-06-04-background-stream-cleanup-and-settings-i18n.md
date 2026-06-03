# 后台流清理 + 设置页中文化

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Settings 提供一个"切项目时取消其他项目后台流"开关,默认关闭(保留现状);同时让关主窗口 / Quit app 主动取消相关后台流,避免后台累积导致 crash 和卡顿;顺便把 SettingsView 的所有英文 label 改成中文常量。

**Architecture:**
- `AppState` 新增两个 `cancel*BackgroundStreams` 方法 + 一个 UserDefaults 持久化的 `cancelBackgroundStreamsOnProjectSwitch: Bool` 开关(默认 false)
- `selectProject` 在开关 on 时主动 cancel 非目标项目后台流
- `ClarcApp` 用 `@NSApplicationDelegateAdaptor` 引入 `AppDelegate`,实现 `applicationWillTerminate(_:)` 调 `cancelAllBackgroundStreams`
- `MainWindowRoot.onDisappear` 根据是否还有项目窗口开放,选择"只清主窗口项目流"或"清所有后台流"
- `SettingsView` 把 `Text("Default Model")` 等字面量直接改成中文,新增一个 Toggle 项

**Tech Stack:** SwiftUI 5+ (`@Observable`, `@NSApplicationDelegateAdaptor`),macOS 15+。

**Spec:** `docs/superpowers/specs/2026-06-04-background-stream-cleanup-and-settings-i18n.md`(待 commit,本文档)。
**Plan:** `docs/superpowers/plans/2026-06-04-background-stream-cleanup-and-settings-i18n.md`(待写)。

---

## Context

**问题描述**:
1. 用户在多项目场景下,切到项目 A → 在项目 A 启动 Claude 流 → 切到项目 B → 项目 A 的流在后台继续跑(由 `detachCurrentStream` 行为决定,见 `AppState.swift:2162-2166`)。这本身是 by design,但**累积多个后台流**导致内存 + CPU 暴涨,在 6/4 crash 报告中表现为 `EXC_BREAKPOINT` at `_postWindowNeedsUpdateConstraints`。
2. 关主窗口时没有清理对应项目的后台流,`onDisappear` 没钩子。
3. SettingsView 大量 `Text("Default Model")` / `Text("User Guide")` 等字面量字符串,**不走 Localizable**,在 zh-Hans locale 下仍显示英文。

**预期结果**:
- 切项目时如果开 toggle,其他项目的后台流被主动 cancel + CLI 子进程 SIGTERM
- 关主窗口时主窗口挂载项目的后台流被清理(不影响其他项目窗口)
- Quit app 时所有后台流被清理
- SettingsView 全部中文常量
- 行为可选:默认不破坏现状(默认 toggle = off),给想要严格控制内存的用户一个开关

**Out of scope:**
- `WindowState` / `MessageListView` / `MessageBubble` 不动
- File tree / Git status / marketplace / inspector 不动
- Project window 的 `.onDisappear` 不需要新加 stream 清理(项目窗口是专门跑该项目的,关它意味着用户离开)
- `Resources/*.lproj/Localizable.strings` 不动(走代码常量)
- `LocalizedStringKey("...")` 用法不动,继续 fallback 到 en.lproj

---

## Approach

按依赖顺序:
1. **先加 `AppState` 新方法 + 开关**(纯内部,无 UI 风险)
2. **接 `selectProject` 触发**(用 switch 控制)
3. **`AppDelegate` 引入 + `applicationWillTerminate`**(新文件)
4. **`MainWindowRoot.onDisappear` 钩子**
5. **SettingsView 改造 + 新增 toggle**(中文 + Toggle)

**关键不变式**:
- `cancelBackgroundStream(for:)` 现有实现(`AppState.swift:2171-2180`)已正确处理 task.cancel + claude.cancel,不重写
- `selectProject` 现有 14 行逻辑(line 2332-2367)不改,只在合适位置插入新 if 块
- `MainWindowRoot.onDisappear` 当前只触发 `unregisterOpenProjectWindow`,增加新清理操作不能影响这个调用
- `AppDelegate` 必须在 `NSApplicationDelegate` 协议下,不破坏 SwiftUI App 协议
- SettingsView 中文改造:只动 `Text("...")` 字面量,不动 `LocalizedStringKey("...")` 用法

---

## File Structure

| 文件 | Action | 责任 |
|---|---|---|
| `Clarc/App/AppState.swift` | Modify | 新增 `cancelAllBackgroundStreams` / `cancelBackgroundStreamsForProject` / `cancelBackgroundStreamsExcludingProject` 三个 async 方法 + `cancelBackgroundStreamsOnProjectSwitch: Bool` 持久化开关;`selectProject` 内部加 if 块 |
| `Clarc/App/ClarcApp.swift` | Modify | 新增 `AppDelegate` 类,实现 `applicationWillTerminate`;用 `@NSApplicationDelegateAdaptor` 引入;`MainWindowRoot` 加 `.onDisappear` 钩子调清理 |
| `Clarc/Views/SettingsView.swift` | Modify | `GeneralSettingsTab` body 加新 section(后台任务 toggle);所有 `Text("...")` 英文字面量改中文 |

不新增文件,不动 `Resources/`,不动 `MainView.swift` / `ProjectWindowView.swift` / 其他 view。

---

## 详细设计

### AppState.swift

#### 1. 新增持久化开关(放在 `foldThreshold` 附近)

```swift
/// When true, switching to a project cancels any background Claude streams
/// belonging to other projects. Default false (preserves existing behavior
/// where multiple projects' streams run concurrently in the background).
var cancelBackgroundStreamsOnProjectSwitch: Bool = (UserDefaults.standard
    .object(forKey: "cancelBackgroundStreamsOnProjectSwitch") as? Bool) ?? false {
    didSet { UserDefaults.standard.set(cancelBackgroundStreamsOnProjectSwitch, forKey: "cancelBackgroundStreamsOnProjectSwitch") }
}
```

#### 2. 新增三个 cancel 方法(放在 `cancelBackgroundStream` 之后)

```swift
/// Cancel every streaming session across all projects.
func cancelAllBackgroundStreams() async {
    let ids = sessionStates.compactMap { $0.value.isStreaming ? $0.key : nil }
    for sid in ids { await cancelBackgroundStream(for: sid) }
}

/// Cancel streaming sessions belonging to one specific project.
func cancelBackgroundStreamsForProject(_ projectId: UUID) async {
    let ids = sessionStates.compactMap { (key, state) -> String? in
        guard state.isStreaming else { return nil }
        // sessionStates keys are sessionIds; resolve projectId via allSessionSummaries
        guard let summary = allSessionSummaries.first(where: { $0.id == key }) else { return nil }
        return summary.projectId == projectId ? key : nil
    }
    for sid in ids { await cancelBackgroundStream(for: sid) }
}

/// Cancel streaming sessions NOT belonging to a specific project.
func cancelBackgroundStreamsExcludingProject(_ projectId: UUID) async {
    let ids = sessionStates.compactMap { (key, state) -> String? in
        guard state.isStreaming else { return nil }
        guard let summary = allSessionSummaries.first(where: { $0.id == key }) else { return nil }
        return summary.projectId == projectId ? nil : key
    }
    for sid in ids { await cancelBackgroundStream(for: sid) }
}
```

#### 3. `selectProject` 接入(line 2332 附近, `withAnimation(nil)` 之前)

```swift
// Before mutating selectedProject, optionally cancel background streams
// belonging to other projects.
if cancelBackgroundStreamsOnProjectSwitch {
    await cancelBackgroundStreamsExcludingProject(project.id)
}
```

### ClarcApp.swift

#### 1. AppDelegate(新)

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        guard let appState else { return }
        // Fire-and-forget: at this point the runloop is shutting down, so we
        // can only synchronously cancel tasks. The OS will reap child
        // processes when the app dies; cancelling the Task handle ensures
        // any pending await on the MainActor doesn't keep us alive past
        // the willTerminate window.
        let ids = appState.sessionStates.compactMap { $0.value.isStreaming ? $0.key : nil }
        for sid in ids {
            appState.sessionStates[sid]?.streamTask?.cancel()
            appState.sessionStates[sid]?.isStreaming = false
            appState.sessionStates[sid]?.activeStreamId = nil
        }
    }
}
```

#### 2. App 协议 + 适配器(line 28 附近)

```swift
@main
struct ClarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    // ...

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(appState: appState)
                .focusable(false)
                // ...
        }
        // ...
    }
}
```

并在 `MainWindowRoot` 初始化后,`body` 末尾加 `.task { appDelegate.appState = appState }`。

#### 3. MainWindowRoot.onDisappear

```swift
MainWindowRoot(appState: appState)
    .focusable(false)
    .environment(...)
    .task { ... }                  // 现有初始化
    .onDisappear {
        // Capture selected project (if any) and clean up its background
        // streams. If a project window is still open, leave the global
        // sessionStates alone; if no other project window is open, clear
        // all background streams.
        Task { @MainActor in
            guard let pid = appState.windowState?.selectedProject?.id else { return }
            if appState.hasOpenProjectWindow(for: pid) {
                // a project window for this project is still open — only
                // cancel this project's streams (the project window
                // owns them now).
                await appState.cancelBackgroundStreamsForProject(pid)
            } else {
                // main window is the only window — cancel all.
                await appState.cancelAllBackgroundStreams()
            }
        }
    }
```

⚠️ **风险**:`appState.windowState` 字段不存在。需要从 `MainWindowRoot` 内部的 `windowState` 引用,或者加一个全局 `currentMainWindow: WindowState?` 字段在 `AppState` 上。

**简化方案**:在 `MainWindowRoot` 内部持有一个 `@State windowState`,`onDisappear` 直接用这个 `windowState` + 调 `appState.cancelBackgroundStreams*`:

```swift
struct MainWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        MainView()
            .environment(appState)
            .environment(windowState)
            // ... existing modifiers ...
            .task { ... }   // existing setup
            .onDisappear {
                Task { @MainActor in
                    let pid = windowState.selectedProject?.id
                    if let pid {
                        if appState.hasOpenProjectWindow(for: pid) {
                            await appState.cancelBackgroundStreamsForProject(pid)
                        } else {
                            await appState.cancelAllBackgroundStreams()
                        }
                    }
                }
            }
    }
}
```

### SettingsView.swift

#### 1. `GeneralSettingsTab` body 新增 section

在 `focusModeSection` 和 `foldThresholdSection` 之间插入新的"后台任务"section:

```swift
private var backgroundTaskSection: some View {
    @Bindable var appState = appState
    return VStack(alignment: .leading, spacing: 12) {
        Text("后台任务")
            .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

        Toggle(isOn: $appState.cancelBackgroundStreamsOnProjectSwitch) {
            VStack(alignment: .leading, spacing: 2) {
                Text("切换项目时取消其他项目后台的 Claude 流")
                    .font(.system(size: ClaudeTheme.size(12)))
                Text("开启后,切到项目 B 会终止项目 A 后台仍在运行的 Claude 命令行进程,释放内存。关闭则保留现状(多任务并行)。")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
```

body 中:
```swift
VStack(alignment: .leading, spacing: 24) {
    modelSection(...)
    Divider()
    permissionModeSection
    Divider()
    effortSection
    Divider()
    focusModeSection
    Divider()
    backgroundTaskSection        // ← 新增
    Divider()
    foldThresholdSection
    Divider()
    autoPreviewSection
}
```

#### 2. 所有 `Text("...")` 英文字面量 → 中文

需要改的字符串(grep 出来):
- `Text("General")`, `Text("Message")`, `Text("Slash Commands")`, `Text("Shortcuts")` (tab 标签) → `Text("通用")`, `Text("聊天")`, `Text("斜杠命令")`, `Text("快捷按钮")`
- `Text("Default Model")` → `Text("默认模型")`
- `Text("Used for new sessions. ...")` → `Text("用于新会话。可在工具栏按会话单独覆盖。")`
- `Text("Default Permission Mode")` → `Text("默认权限模式")`
- `Text("Default Effort Level")` → `Text("默认努力程度")`
- `Text("Auto")` → `Text("自动")`
- `Text("Focus Mode")` → `Text("专注模式")`
- `Text("Fold older messages")` → `Text("折叠较早消息")`
- `Text("Attachment auto-preview")` → `Text("附件自动预览")`
- `Text("User Guide")` → `Text("使用手册")`
- 等等

**注意**:`Text(LocalizedStringKey("..."))` **不动**(它们是 en/zh 走资源切换的)。

---

## Risk

| 风险 | 等级 | 缓解 |
|---|---|---|
| `cancelBackgroundStreams*` 内部 `sessionStates.compactMap` 与 streaming task 冲突 | 中 | 现有 `cancelBackgroundStream` 已用 `task.cancel` + `claude.cancel` 安全清理,新方法只是包装,行为不变 |
| `applicationWillTerminate` 不 await,后台 CLI 进程可能来不及 SIGTERM | 中 | macOS 在 app 死亡时自动 reap 子进程(除非 `Process.terminate` 没调);`task.cancel` + `claude.cancel` 是同步,确保内存 state 清理 |
| `MainWindowRoot.onDisappear` 在 macOS app 关闭顺序里可能不触发 | 低 | `onDisappear` 在 NSWindow 关闭时一定触发;多窗口场景下最后关主窗口时一定会触发 |
| `@NSApplicationDelegateAdaptor` 跟 SwiftUI App 协议混用 | 低 | Apple 官方文档推荐用法,跟现有 ClarcApp 结构兼容 |
| SettingsView 中文化后,其他 view 引用 label 文字作为 identifier | 低 | grep 一下确认;现有 identifier 都是用 `systemImage` 不是 label text |

---

## Verification

1. `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`
2. 启动 app → Cmd+, 打开设置 → 所有 label 显示中文
3. 新 toggle 默认 off;切项目 → 后台流不取消(打开 Activity Monitor 看 `claude` 进程数)
4. 开 toggle;切项目 → 后台流应取消(`claude` 进程数下降)
5. 关主窗口(其他项目窗口开着)→ 主窗口项目所在流应取消
6. 关所有窗口 + Cmd+Q → 所有 `claude` 子进程消失
7. 重打 dmg + 端到端启动测试 + 上传 GitHub release,版本号 2.4.2

---

## Self-Review

1. **Spec coverage**: 三件事(可选 toggle / 关主窗口清理 / 设置页中文化)都在 spec 内
2. **Placeholder scan**: 无 TBD/TODO
3. **Internal consistency**: 三个 cancel 方法命名一致;`AppDelegate.applicationWillTerminate` 跟 `MainWindowRoot.onDisappear` 行为不冲突(后者处理窗口层,前者处理 app 层)
4. **Scope check**: 单文件改动 3 个 + AppState 一处新增;控制在 200-300 行 diff
5. **Ambiguity check**: "切项目时取消"明确"非目标项目";关主窗口时明确"先查 hasOpenProjectWindow"
