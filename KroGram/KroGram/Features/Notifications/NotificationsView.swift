// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager

    var body: some View {
        NavigationStack {
            let unread = vm.chats(in: .unread)
            List {
                demoSection
                permissionSection
                unreadSection(unread)
                noteSection
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("notifications.title")
            .task { await notificationManager.refreshAuthorizationStatus() }
        }
    }

    private var permissionSection: some View {
        Section("notifications.system") {
            HStack {
                Text("notifications.permission")
                Spacer()
                Text(LocalizedStringKey(authorizationStatusKey)).foregroundStyle(.secondary)
            }
            if notificationManager.authorizationStatus == .denied {
                Button {
                    notificationManager.openAppSettings()
                } label: {
                    Label("notifications.openSettings", systemImage: "gearshape")
                }
            } else if notificationManager.authorizationStatus != .authorized
                && notificationManager.authorizationStatus != .provisional
                && notificationManager.authorizationStatus != .ephemeral {
                Button {
                    Task { await notificationManager.requestAuthorization() }
                } label: {
                    Label("notifications.enable", systemImage: "bell.badge")
                }
            }
            if let errorText = notificationManager.errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var authorizationStatusKey: String {
        switch notificationManager.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "notifications.permissionEnabled"
        case .denied: "notifications.permissionDenied"
        case .notDetermined: "notifications.permissionNotDetermined"
        @unknown default: "notifications.permissionUnknown"
        }
    }

    @ViewBuilder
    private var demoSection: some View {
        if !vm.isLive {
            Section {
                DemoBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func unreadSection(_ unread: [Chat]) -> some View {
        Section("notifications.unread") {
            if unread.isEmpty {
                ContentUnavailableView("notifications.empty", systemImage: "bell")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(unread) { chat in
                    HStack(spacing: KroSpacing.md) {
                        NavigationLink {
                            ChatView(chatID: chat.id)
                        } label: {
                            HStack(spacing: KroSpacing.md) {
                                AvatarView(name: chat.title, seed: Int(truncatingIfNeeded: chat.id), size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.title).kro(.body, weight: .medium)
                                    Text(chat.lastMessageText)
                                        .kro(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                UnreadBadge(count: chat.unread, muted: chat.isMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        if vm.isLive {
                            NavigationLink {
                                ChatNotificationSettingsView(chatID: chat.id)
                            } label: {
                                Image(systemName: "gearshape")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("notifications.chatSettings")
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }
            }
        }
    }

    private var noteSection: some View {
        Section {
            Text("notifications.note")
                .kro(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
    }
}

struct ChatNotificationSettingsView: View {
    let chatID: Int64
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var settings = ChatNotificationSettings.defaults
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadFailed = false

    private struct MuteChoice: Identifiable {
        let key: String
        let duration: Int32
        var id: Int32 { duration }
    }

    private let muteChoices: [MuteChoice] = [
        MuteChoice(key: "mute.never", duration: 0),
        MuteChoice(key: "mute.oneHour", duration: 3_600),
        MuteChoice(key: "mute.eightHours", duration: 28_800),
        MuteChoice(key: "mute.twoDays", duration: 172_800),
        MuteChoice(key: "mute.forever", duration: Int32.max)
    ]

    var body: some View {
        Form {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Section("notifications.chatSettings") {
                    Picker("notifications.muteDuration", selection: $settings.muteFor) {
                        ForEach(muteChoices) { choice in
                            Text(LocalizedStringKey(choice.key)).tag(choice.duration)
                        }
                    }
                    Toggle("notifications.sound", isOn: $settings.soundEnabled)
                    Toggle("notifications.preview", isOn: $settings.showPreview)
                }
            }
            if let mediaError = vm.mediaError {
                Text(mediaError).foregroundStyle(.red)
            }
        }
        .navigationTitle(vm.chat(chatID)?.title ?? L("notifications.chatSettings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") {
                    Task {
                        isSaving = true
                        _ = await vm.saveChatNotificationSettings(chatID, settings: settings)
                        isSaving = false
                    }
                }
                .disabled(isLoading || isSaving || loadFailed)
            }
        }
        .task {
            if let loaded = await vm.loadChatNotificationSettings(chatID) {
                settings = loaded
            } else {
                loadFailed = true
            }
            isLoading = false
        }
    }
