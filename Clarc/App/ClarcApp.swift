import SwiftUI
import ClarcCore
import ClarcChatKit

// MARK: - FocusedValues

private struct StartNewChatKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var startNewChat: (() -> Void)? {
        get { self[StartNewChatKey.self] }
        set { self[StartNewChatKey.self] = newValue }
    }
}

// MARK: - AppDelegate

/// Synchronous cleanup hook for app termination. AppKit calls
/// `applicationWillTerminate(_:)` near the end of the shutdown sequence;
/// the runloop is already winding down, so we use synchronous
/// `Task.cancel()` and direct state mutation rather than awaiting
/// anything. Child CLI processes spawned via `Process` are reaped
/// automatically when the app dies.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        guard let appState else { return }
        // Snapshot the keys first, then mutate. Mutating sessionStates
        // while iterating it would crash.
        let ids = appState.sessionStates.compactMap { $0.value.isStreaming ? $0.key : nil }
        for sid in ids {
            appState.sessionStates[sid]?.streamTask?.cancel()
            appState.sessionStates[sid]?.isStreaming = false
            appState.sessionStates[sid]?.activeStreamId = nil
        }
        // Tear down subprocesses and the hook HTTP server. ClaudeService
        // and PermissionServer are actors, so we hop onto each in a Task
        // and wait on a semaphore — the runloop is winding down but
        // synchronous work (Process.interrupt, listener.cancel, file
        // removal) still runs before the process exits.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await appState.claude.cleanup()
            await appState.permission.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(250))
    }

    /// Called when the app loses active foreground focus (e.g. the user
    /// hides Clarc, switches spaces, or it goes to the dock). We tear
    /// down the hook HTTP server and child CLI processes here too —
    /// background runs in a desktop CLI client are not expected, and
    /// the server holds open hook files on disk that should not linger.
    func sceneDidEnterBackground(_ notification: Notification) {
        guard let appState else { return }
        Task.detached {
            await appState.permission.stop()
            await appState.claude.cleanup()
        }
    }
}

// MARK: - ProjectWindowValue

struct ProjectWindowValue: Codable, Hashable {
    let projectId: UUID
    let instanceId: UUID
}

// MARK: - App

@main
struct ClarcApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.startNewChat) private var startNewChat
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(appState: appState, appDelegate: appDelegate)
                .focusable(false)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        // App moved out of the foreground (user hid it,
                        // switched spaces, etc.). Tear down the hook HTTP
                        // server and child CLI processes — a desktop CLI
                        // client should not keep them running invisibly.
                        Task.detached {
                            await appState.permission.stop()
                            await appState.claude.cleanup()
                        }
                    }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    startNewChat?()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                // No "Check for Updates..." entry — this hard fork
                // does not run Sparkle. Users update by downloading
                // a new build from
                // https://github.com/dttxorg/MiniClarc/releases.
            }
            CommandMenu("Theme") {
                ForEach(AppTheme.allCases) { theme in
                    Button(theme.displayName) {
                        appState.selectedTheme = theme
                    }
                    .disabled(appState.selectedTheme == theme)
                }
            }
        }

        // Dedicated project window — opened on double-click
        WindowGroup(id: "project-window", for: ProjectWindowValue.self) { $value in
            if let id = value?.projectId {
                ProjectWindowRoot(appState: appState, projectId: id)
                    .focusable(false)
            }
        }
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsWindowRoot(appState: appState)
        }
    }
}

// MARK: - Main Window Root

struct MainWindowRoot: View {
    let appState: AppState
    let appDelegate: AppDelegate
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        MainView()
            .environment(appState)
            .environment(windowState)
            .environment(chatBridge)
            .environment(\.openURL, OpenURLAction { url in
                var finalURL = url
                if url.scheme == nil || url.scheme!.isEmpty {
                    finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                }
                NSWorkspace.shared.open(finalURL)
                return .handled
            })
            .task {
                await appState.initialize()
                appState.setupChatBridge(chatBridge, for: windowState)
                await appState.initializeWindow(windowState)
                await NotificationService.shared.requestAuthorizationIfNeeded()
                NotificationService.shared.onNotificationTapped = { projectId, sessionId in
                    appState.handleNotificationTap(projectId: projectId, sessionId: sessionId, mainWindow: windowState)
                }
            }
            .onAppear { appDelegate.appState = appState }
            .onDisappear {
                // Main window is closing. If another project window is
                // open for the currently selected project, that window
                // owns the streaming sessions and we should leave them
                // alone; we only cancel this project's streams. If no
                // other window is open, cancel all background streams
                // — the user is effectively quitting the project.
                Task { @MainActor in
                    guard let pid = windowState.selectedProject?.id else { return }
                    if appState.hasOpenProjectWindow(for: pid) {
                        await appState.cancelBackgroundStreamsForProject(pid)
                    } else {
                        await appState.cancelAllBackgroundStreams()
                    }
                }
            }
    }
}

// MARK: - Settings Window Root

struct SettingsWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()

    var body: some View {
        SettingsView()
            .environment(appState)
            .environment(windowState)
    }
}

// MARK: - Project Window Root

struct ProjectWindowRoot: View {
    let appState: AppState
    let projectId: UUID
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        ProjectWindowView()
            .environment(appState)
            .environment(windowState)
            .environment(chatBridge)
            .environment(\.openURL, OpenURLAction { url in
                var finalURL = url
                if url.scheme == nil || url.scheme!.isEmpty {
                    finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                }
                NSWorkspace.shared.open(finalURL)
                return .handled
            })
            .task {
                // AppState is already initialized at this point
                appState.setupChatBridge(chatBridge, for: windowState)
                await appState.initializeWindow(windowState, selectingProjectId: projectId)
                // Apply pending notification navigation (new window case)
                if let sessionId = appState.pendingNotificationSession.removeValue(forKey: projectId) {
                    windowState.currentSessionId = sessionId
                }
            }
            .onAppear { appState.registerOpenProjectWindow(projectId) }
            .onDisappear { appState.unregisterOpenProjectWindow(projectId) }
            // Apply pending notification navigation (already-open window case)
            .onChange(of: appState.pendingNotificationSession[projectId]) { _, sessionId in
                guard let sessionId else { return }
                windowState.currentSessionId = sessionId
                appState.pendingNotificationSession.removeValue(forKey: projectId)
            }
    }
}
