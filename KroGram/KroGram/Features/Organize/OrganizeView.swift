// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

struct OrganizeView: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var showNewFolder = false
    @State private var editingFolder: ChatFolder?

    private let smartLists: [(scope: ChatScope, key: String, symbol: String)] = [
        (.unread, "organize.list.unread", "envelope.badge"),
        (.pinned, "organize.list.pinned", "star"),
        (.archived, "organize.list.archived", "archivebox"),
        (.hidden, "organize.list.hidden", "eye.slash")
    ]

    var body: some View {
        NavigationStack {
            List {
                if let mediaError = vm.mediaError {
                    Text(mediaError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                smartListsSection
                foldersSection
                noteSection
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("organize.title")
            .navigationDestination(for: ChatScope.self) { ChatCollectionView(scope: $0) }
            .toolbar { EditButton() }
            .sheet(isPresented: $showNewFolder) { ChatFolderEditorSheet() }
            .sheet(item: $editingFolder) { folder in ChatFolderEditorSheet(folder: folder) }
        }
    }

    private var smartListsSection: some View {
        Section("organize.smart") {
            ForEach(smartLists, id: \.key) { item in
                NavigationLink(value: item.scope) {
                    HStack {
                        Label(LocalizedStringKey(item.key), systemImage: item.symbol)
                        Spacer()
                        Text("\(vm.chats(in: item.scope).count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
        }
    }

    private var foldersSection: some View {
        Section("organize.folders") {
            ForEach(vm.folders) { folder in
                NavigationLink(value: ChatScope.folder(folder.id)) {
                    HStack {
                        Label {
                            Text(verbatim: folder.name)
                        } icon: {
                            Image(systemName: folder.symbol)
                        }
                        Spacer()
                        Text("\(vm.chats(in: .folder(folder.id)).count)")
                            .foregroundStyle(.secondary)
                        if vm.unreadCount(in: folder) > 0 {
                            UnreadBadge(count: vm.unreadCount(in: folder))
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .contextMenu {
                    Button("action.edit") { editingFolder = folder }
                    Button("action.delete", role: .destructive) { vm.deleteFolder(folder.id) }
                }
            }
            .onDelete { offsets in offsets.map { vm.folders[$0].id }.forEach(vm.deleteFolder) }
            .onMove(perform: vm.moveFolders)
            Button { showNewFolder = true } label: {
                Label("organize.newFolder", systemImage: "plus.circle")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
    }

    private var noteSection: some View {
        Section {
            Text("organize.note")
                .kro(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
    }
}

struct ChatCollectionView: View {
    let scope: ChatScope
    @EnvironmentObject private var vm: ChatsViewModel

    var body: some View {
        let items = vm.chats(in: scope)
        List {
            if let mediaError = vm.mediaError {
                Text(mediaError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(items) { chat in
                NavigationLink {
                    ChatView(chatID: chat.id)
                } label: {
                    ChatRow(chat: chat, draft: vm.draft(for: chat.id))
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .swipeActions(edge: .trailing) {
                    switch scope {
                    case .archived:
                        Button { vm.update([chat.id]) { $0.isArchived = false } } label: {
                            Label("action.unarchive", systemImage: "tray.and.arrow.up")
                        }.tint(.orange)
                        Button { vm.update([chat.id]) { $0.isPinned.toggle() } } label: {
                            Label(chat.isPinned ? "action.unpin" : "action.pin", systemImage: "pin")
                        }.tint(.blue)
                        muteMenu(for: chat)
                        Button { toggleReadState(for: chat) } label: {
                            Label(
                                chat.unread > 0 || chat.isMarkedAsUnread ? "action.markRead" : "action.markUnread",
                                systemImage: "envelope"
                            )
                        }.tint(.green)
                    case .hidden:
                        Button { vm.update([chat.id]) { $0.isHidden = false } } label: {
                            Label("action.unhide", systemImage: "eye")
                        }.tint(.gray)
                    case .folder(let id):
                        Button { vm.setFolder(id, contains: false, for: chat.id) } label: {
                            Label("action.removeFromFolder", systemImage: "folder.badge.minus")
                        }.tint(.orange)
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if items.isEmpty { ContentUnavailableView("organize.empty", systemImage: "tray") }
        }
        .navigationTitle(vm.title(for: scope))
        .navigationBarTitleDisplayMode(.inline)
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
            Label("action.mute", systemImage: "bell.slash")
        }
        .tint(.gray)
    }

    private func toggleReadState(for chat: Chat) {
        if chat.unread > 0 {
            Task { await vm.markReadNow(chat.id) }
        } else {
            vm.setMarkedUnread(chat.id, marked: !chat.isMarkedAsUnread)
        }
    }
}

struct ChatFolderEditorSheet: View {
    let folder: ChatFolder?
    @EnvironmentObject private var vm: ChatsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String

    init(folder: ChatFolder? = nil) {
        self.folder = folder
        _name = State(initialValue: folder?.name ?? "")
        _symbol = State(initialValue: folder?.symbol ?? "folder")
    }

    private let symbols = ["folder", "star", "briefcase", "house", "heart", "book", "gamecontroller", "cart"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("organize.folderName", text: $name)
                if let mediaError = vm.mediaError {
                    Text(mediaError).foregroundStyle(.red)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: KroSpacing.md) {
                    ForEach(symbols, id: \.self) { s in
                        Button { symbol = s } label: {
                            Image(systemName: s)
                                .font(.title2)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(symbol == s ? Color.accentColor.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(folder == nil ? "organize.newFolder" : "action.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(folder == nil ? "action.add" : "action.save") {
                        Task {
                            if await vm.saveFolder(name: name, symbol: symbol, editing: folder) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
