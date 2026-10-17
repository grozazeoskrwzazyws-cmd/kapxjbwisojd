// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

@main
@MainActor
struct KroGramApp: App {
    @StateObject private var themes: ThemeStore
    @StateObject private var privacy: PrivacyMode
    @StateObject private var chats: ChatsViewModel
    @StateObject private var session: SessionStore
    @StateObject private var commander: CommanderStore
    @StateObject private var notifications: PushNotificationManager
    @StateObject private var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let privacyMode = PrivacyMode.shared
        let notificationManager = PushNotificationManager.shared
        let chatsModel = ChatsViewModel(repository: MockChatRepository(), privacy: privacyMode)
        let lockManager = AppLockManager()
        _themes = StateObject(wrappedValue: ThemeStore())
        _privacy = StateObject(wrappedValue: privacyMode)
        _chats = StateObject(wrappedValue: chatsModel)
        _session = StateObject(wrappedValue: SessionStore(
            chats: chatsModel,
            privacy: privacyMode,
            notifications: notificationManager
        ))
        _commander = StateObject(wrappedValue: CommanderStore())
        _notifications = StateObject(wrappedValue: notificationManager)
        _appLock = StateObject(wrappedValue: lockManager)
    }

    @UIApplicationDelegateAdaptor(KroGramAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(themes)
                .environmentObject(privacy)
                .environmentObject(chats)
                .environmentObject(session)
                .environmentObject(commander)
                .environmentObject(notifications)
                .environmentObject(appLock)
                .tint(themes.current.accent)
                .preferredColorScheme(themes.appearance.scheme)
                .task { await session.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    chats.setForeground(phase == .active)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                switch session.phase {
                case .live, .demo:
                    if themes.shouldAnimate(reduceMotion: reduceMotion) {
                        RootTabView()
                            .transition(KroBlurTransition())
                    } else {
                        RootTabView()
                            .transition(.identity)
                    }
                default:
                    if themes.shouldAnimate(reduceMotion: reduceMotion) {
                        LoginView()
                            .transition(KroBlurTransition())
                    } else {
                        LoginView()
                            .transition(.identity)
                    }
                }
            }
            .blur(radius: scenePhase == .active ? 0 : 28)
            if scenePhase != .active {
                AppPrivacyShield().zIndex(2)
            } else if appLock.isLocked {
                AppLockView().zIndex(1)
            }
        }
        .animation(themes.shouldAnimate(reduceMotion: reduceMotion) ? .smooth : nil, value: isInApp)
        .onChange(of: scenePhase) { _, phase in appLock.sceneDidChange(phase) }
    }

    private var isInApp: Bool {
        session.phase == .live || session.phase == .demo
    }
}
