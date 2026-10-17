// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import UIKit

struct ChatRow: View {
    let chat: Chat
    let draft: String
    @EnvironmentObject private var vm: ChatsViewModel
    @EnvironmentObject private var themes: ThemeStore
    @State private var avatarImage: UIImage?

    var body: some View {
        HStack(spacing: KroSpacing.md) {
            AvatarView(
                name: chat.isSavedMessages ? L("chat.savedMessages") : chat.title,
                seed: Int(truncatingIfNeeded: chat.id),
                size: 52,
                showsOnline: chat.kind == .direct && chat.isOnline,
                image: avatarImage
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if chat.kind != .direct {
                        Image(systemName: chat.kind.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if chat.isSavedMessages {
                        Text("chat.savedMessages").kro(.headline, weight: .semibold).lineLimit(1)
                    } else {
                        Text(chat.title).kro(.headline, weight: .semibold).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !chat.isSavedMessages || !chat.messages.isEmpty {
                        Text(chat.lastDate.chatListString)
                            .kro(.caption)
                            .foregroundStyle(chat.unread > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
                HStack(spacing: 6) {
                    preview
                    Spacer(minLength: 4)
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if chat.isPinned && chat.unread == 0 {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if chat.unread > 0 || chat.isMarkedAsUnread {
                        UnreadBadge(count: max(chat.unread, chat.isMarkedAsUnread ? 1 : 0), muted: chat.isMuted)
                    }
                }
            }
        }
        .padding(.vertical, themes.current.density.rowPadding)
        .accessibilityElement(children: .combine)
        .task(id: chat.avatarFileID) {
            guard let fileID = chat.avatarFileID else {
                avatarImage = nil
                return
            }
            if let data = vm.cachedFileData(fileID: fileID) {
                avatarImage = UIImage(data: data)
                return
            }
            do {
                let data = try await vm.downloadFile(fileID: fileID, limit: 2 * 1_024 * 1_024)
                avatarImage = UIImage(data: data)
            } catch {}
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !draft.isEmpty {
            (Text("chats.draft").foregroundColor(.red) + Text(" ") + Text(draft))
                .kro(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(chat.lastMessageText)
                .kro(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Used as the long-press preview. Takes the theme as a value because
/// context-menu previews are rendered outside the normal environment.
struct ChatPreview: View {
    let chat: Chat
    let theme: KroTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chat.isSavedMessages {
                Text("chat.savedMessages").font(.headline)
            } else {
                Text(chat.title).font(.headline)
            }
            Divider()
            ForEach(chat.messages.suffix(5)) { message in
                HStack {
                    if message.isOutgoing { Spacer(minLength: 24) }
                    Text(message.text)
                        .font(.subheadline)
                        .padding(8)
                        .foregroundStyle(message.isOutgoing ? theme.onAccent : Color.primary)
                        .background(
                            message.isOutgoing ? theme.accent : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: min(theme.bubbleRadius, 16), style: .continuous)
                        )
                    if !message.isOutgoing { Spacer(minLength: 24) }
                }
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

struct ChatListView: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @EnvironmentObject private var themes: ThemeStore
    @State private var selection = Set<Int64>()
    @State private var editMode: EditMode = .inactive
    @State private var pendingDelete = Set<Int64>()
    @State private var showDeleteDialog = false
    @State private var notificationSettingsChat: Chat?
    @State private var navigationPath: [Int64] = []
    @State private var showCreateGroup = false
    @State private var showCreateChannel = false
    @State private var showJoinChannel = false

    private var isEditing: Bool { editMode == .active }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(selection: $selection) {
                Section {
                    if !vm.isLive {
                        DemoBanner()
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if vm.connection != .ready {
                        HStack(spacing: KroSpacing.sm) {
                            ProgressView()
                            Text(LocalizedStringKey(connectionKey)).kro(.footnote)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    if let error = vm.mediaError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .listRowSeparator(.hidden)
                    }
                    filterBar
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(vm.visibleChats) { chat in
                    chatLink(for: chat)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.reload() }
            .overlay { stateOverlay }
            .searchable(text: $vm.searchText, prompt: Text("chats.search.prompt"))
            .navigationTitle("chats.title")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "action.done" : "action.select") {
                        withAnimation {
                            editMode = isEditing ? .inactive : .active
                            selection.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("date.title", selection: $vm.dateFilter) {
                            ForEach(DateFilter.allCases) { option in
                                Text(LocalizedStringKey(option.titleKey)).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: vm.dateFilter == .any ? "calendar" : "calendar.badge.clock")
                    }
                }
                if vm.isLive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showCreateGroup = true
                            } label: {
                                Label("group.create", systemImage: "person.2")
                            }
                            Button {
                                showCreateChannel = true
                            } label: {
                                Label("channel.create", systemImage: "megaphone")
                            }
                            Button {
                                showJoinChannel = true
                            } label: {
                                Label("channel.join", systemImage: "person.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(Text("chats.create"))
                    }
                }
            }
            .navigationDestination(for: Int64.self) { chatID in
                ChatView(chatID: chatID)
            }
            .safeAreaInset(edge: .bottom) {
                if isEditing && !selection.isEmpty { bulkBar }
            }
            .confirmationDialog("delete.title", isPresented: $showDeleteDialog, titleVisibility: .visible) {
                Button("action.delete", role: .destructive) {
                    vm.delete(pendingDelete)
                    selection.removeAll()
                }
                Button("action.hide") {
                    vm.update(pendingDelete) { $0.isHidden = true }
                    selection.removeAll()
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text(String(format: L("delete.preview"), pendingDelete.count) + "\n" + L("delete.hint"))
            }
            .sheet(item: $notificationSettingsChat) { chat in
                NavigationStack {
                    ChatNotificationSettingsView(chatID: chat.id)
                }
            }
            .sheet(isPresented: $showCreateGroup) {
                NavigationStack {
                    CreateGroupView { result in
                        showCreateGroup = false
                        Task {
                            await vm.reload()
                            await vm.loadChat(result.chatID)
                            navigationPath.append(result.chatID)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateChannel) {
                NavigationStack {
                    CreateChannelView { result in
                        showCreateChannel = false
                        Task {
                            await vm.reload()
                            await vm.loadChat(result.chatID)
                            navigationPath.append(result.chatID)
                        }
                    }
                }
            }
            .sheet(isPresented: $showJoinChannel) {
                NavigationStack {
                    JoinChannelView { chatID in
                        showJoinChannel = false
                        Task {
                            await vm.reload()
                            await vm.loadChat(chatID)
                            navigationPath.append(chatID)
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func chatLink(for chat: Chat) -> some View {
        NavigationLink(value: chat.id) {
            ChatRow(chat: chat, draft: vm.draft(for: chat.id))
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        .onAppear {
            if chat.id == vm.visibleChats.last?.id {
                Task { await vm.loadMoreChats() }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if vm.canDeleteChats {
                Button(role: .destructive) {
                    askDelete([chat.id])
                } label: { Label("action.delete", systemImage: "trash") }
            }
            Button {
                vm.update([chat.id]) { $0.isArchived = true }
            } label: { Label("action.archive", systemImage: "archivebox") }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            leadingSwipeActions(for: chat)
        }
        .contextMenu {
            contextMenuActions(for: chat)
        } preview: {
            ChatPreview(chat: chat, theme: themes.current)
        }
    }

    @ViewBuilder
    private func leadingSwipeActions(for chat: Chat) -> some View {
        Button {
            vm.update([chat.id]) { $0.isPinned.toggle() }
        } label: {
            Label(chat.isPinned ? "action.unpin" : "action.pin",
                  systemImage: chat.isPinned ? "pin.slash" : "pin")
        }
        .tint(themes.current.accent)
        hideButton(for: [chat.id])
            .tint(.gray)
    }

    private func hideButton(for chatIDs: Set<Int64>, clearsSelection: Bool = false) -> some View {
        Button {
            vm.update(chatIDs) { $0.isHidden = true }
            if clearsSelection {
                selection.removeAll()
            }
        } label: {
            Label("action.hide", systemImage: "eye.slash")
        }
    }

    @ViewBuilder
    private func contextMenuActions(for chat: Chat) -> some View {
        if vm.isLive {
            Button {
                notificationSettingsChat = chat
            } label: {
                Label("notifications.chatSettings", systemImage: "bell.badge")
            }
        }
        Button {
            vm.update([chat.id]) { $0.isPinned.toggle() }
        } label: {
            Label(chat.isPinned ? "action.unpin" : "action.pin",
                  systemImage: chat.isPinned ? "pin.slash" : "pin")
        }
        folderMenu(for: chat)
        Button {
            vm.update([chat.id]) { $0.isArchived = true }
        } label: {
            Label("action.archive", systemImage: "archivebox")
        }
        muteMenu(for: chat)
        Button {
            toggleReadState(for: chat)
        } label: {
            Label(
                chat.isMarkedAsUnread || chat.unread > 0 ? "action.markRead" : "action.markUnread",
                systemImage: chat.isMarkedAsUnread || chat.unread > 0 ? "envelope.open" : "envelope.badge"
            )
        }
        if vm.canDeleteChats {
            Button(role: .destructive) {
                askDelete([chat.id])
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func muteMenu(for chat: Chat) -> some View {
        Menu {
            Button("action.unmute") { vm.setMuted(chat.id, duration: 0) }
            Divider()
            Button("mute.oneHour") { vm.setMuted(chat.id, duration: 3_600) }
            Button("mute.eightHours") { vm.setMuted(chat.id, duration: 28_800) }
            Button("mute.twoDays") { vm.setMuted(chat.id, duration: 172_800) }
            Button("mute.forever") { vm.setMuted(chat.id, duration: Int32.max) }
        } label: {
            Label(chat.isMuted ? "action.muteSettings" : "action.mute", systemImage: "bell.slash")
        }
    }

    private func toggleReadState(for chat: Chat) {
        if chat.unread > 0 {
            Task { await vm.markReadNow(chat.id) }
        } else {
            vm.setMarkedUnread(chat.id, marked: !chat.isMarkedAsUnread)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: KroSpacing.sm) {
                ForEach(ChatFilter.allCases) { option in
                    FilterChip(label: Text(LocalizedStringKey(option.titleKey)), isOn: vm.filter == option) {
                        withAnimation(.snappy) { vm.filter = option }
                    }
                }
                ForEach(vm.folders) { folder in
                    folderChip(folder)
                }
            }
            .padding(.horizontal, KroSpacing.lg)
            .padding(.vertical, KroSpacing.xs)
        }
    }

    private func folderChip(_ folder: ChatFolder) -> some View {
        let isOn = vm.selectedFolderID == folder.id
        let unread = vm.unreadCount(in: folder)
        return Button {
            withAnimation(.snappy) {
                vm.selectedFolderID = isOn ? nil : folder.id
            }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: folder.name)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isOn ? themes.current.accent : .white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isOn ? themes.current.onAccent : themes.current.accent, in: Capsule())
                }
            }
            .kro(.subheadline, weight: .medium)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? themes.current.onAccent : Color.primary)
            .background(
                isOn ? themes.current.accent : Color(.secondarySystemBackground),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var bulkBar: some View {
        HStack {
            Button { vm.update(selection) { $0.isPinned = true }; selection.removeAll() } label: {
                Label("action.pin", systemImage: "pin")
            }
            Spacer()
            Button { vm.update(selection) { $0.isArchived = true }; selection.removeAll() } label: {
                Label("action.archive", systemImage: "archivebox")
            }
            Spacer()
            hideButton(for: selection, clearsSelection: true)
            if vm.canDeleteChats {
                Spacer()
                Button(role: .destructive) { askDelete(selection) } label: {
                    Label("action.delete", systemImage: "trash")
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, KroSpacing.xl)
        .padding(.vertical, KroSpacing.md)
        .background(.bar)
    }

    @ViewBuilder
    private func folderMenu(for chat: Chat) -> some View {
        if !vm.folders.isEmpty {
            Menu {
                ForEach(vm.folders) { folder in
                    let isIn = folder.telegramID.map { chat.telegramFolderIDs.contains($0) }
                        ?? chat.folderIDs.contains(folder.id)
                    Button {
                        vm.setFolder(folder.id, contains: !isIn, for: chat.id)
                    } label: {
                        Label {
                            Text(verbatim: folder.name)
                        } icon: {
                            Image(systemName: isIn ? "checkmark" : folder.symbol)
                        }
                    }
                }
            } label: {
                Label("action.moveToFolder", systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if vm.chats.isEmpty && (vm.loadState == .idle || vm.loadState == .loading) {
            ProgressView()
        } else if vm.chats.isEmpty && vm.loadState == .failed {
            VStack(spacing: KroSpacing.md) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text("chats.loadFailed").kro(.headline)
                Button("chats.retry") { Task { await vm.reload() } }
                    .buttonStyle(KroPrimaryButtonStyle())
            }
        } else if vm.visibleChats.isEmpty {
            ContentUnavailableView("chats.empty", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private var connectionKey: String {
        switch vm.connection {
        case .waitingForNetwork: return "conn.waiting"
        case .updating: return "conn.updating"
        default: return "conn.connecting"
        }
    }

    private func askDelete(_ ids: Set<Int64>) {
        pendingDelete = ids
        showDeleteDialog = true
    }
}
