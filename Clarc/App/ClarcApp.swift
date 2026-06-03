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

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(appState: appState, appDelegate: appDelegate)
                .focusable(false)
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
