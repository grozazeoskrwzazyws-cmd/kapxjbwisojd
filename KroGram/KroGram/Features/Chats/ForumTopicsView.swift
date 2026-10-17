// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

struct ForumTopicsView: View {
    let chat: Chat
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var topics: [ForumTopic] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingCreate = false
    @State private var editingTopic: ForumTopic?
    @State private var didLoadTopics = false

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if topics.isEmpty {
                ContentUnavailableView("topic.empty", systemImage: "bubble.left.and.bubble.right")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(topics) { topic in
                    HStack(spacing: KroSpacing.sm) {
                        NavigationLink(destination: ChatView(
                            chatID: chat.id,
                            topicID: topic.id,
                            topicTitle: topic.name,
                            topicIsClosed: topic.isClosed
                        )) {
                            topicRow(topic)
                        }
                        if chat.canManageTopics || topic.isCreatedByMe {
                            Menu {
                                Button("topic.rename", systemImage: "pencil") {
                                    editingTopic = topic
                                }
                                if !topic.isGeneral {
                                    Button(
                                        topic.isClosed ? "topic.reopen" : "topic.close",
                                        systemImage: topic.isClosed ? "lock.open" : "lock"
                                    ) {
                                        Task { await setClosed(topic, closed: !topic.isClosed) }
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(isSaving)
                        }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .overlay {
            if isSaving {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KroRadius.card))
            }
        }
        .navigationTitle(chat.title)
        .toolbar {
            if chat.canCreateTopics {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("topic.create"))
                    .disabled(isSaving)
                }
            }
        }
        .task {
            await vm.openChat(chat.id)
            await reload()
            didLoadTopics = true
        }
        .onAppear {
            if didLoadTopics {
                Task {
                    await vm.openChat(chat.id)
                    await reload()
                }
            }
        }
        .refreshable { await reload() }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                ForumTopicNameView(titleKey: "topic.create", initialName: "") { name in
                    try await vm.createForumTopic(chatID: chat.id, name: name)
                    await reload()
                }
            }
        }
        .sheet(item: $editingTopic) { topic in
            NavigationStack {
                ForumTopicNameView(titleKey: "topic.rename", initialName: topic.name) { name in
                    try await vm.editForumTopic(chatID: chat.id, topicID: topic.id, name: name)
                    await reload()
                }
            }
        }
    }

    private func topicRow(_ topic: ForumTopic) -> some View {
        HStack(spacing: KroSpacing.md) {
            Image(systemName: topic.isGeneral ? "bubble.left.and.bubble.right.fill" : "bubble.left.fill")
                .font(.title3)
                .foregroundStyle(topicColor(topic.iconColor))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(topic.name)
                        .font(.headline)
                        .lineLimit(1)
                    if topic.isClosed {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(topic.lastMessage?.text ?? L("topic.noMessages"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: KroSpacing.xs)
            if topic.unreadCount > 0 {
                UnreadBadge(count: topic.unreadCount, muted: chat.isMuted)
            }
        }
        .padding(.vertical, KroSpacing.xs)
        .contentShape(Rectangle())
    }

    private func topicColor(_ rgb: Int) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    private func reload() async {
        isLoading = topics.isEmpty
        do {
            topics = try await vm.loadForumTopics(chatID: chat.id)
            errorMessage = nil
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
        isLoading = false
    }

    private func setClosed(_ topic: ForumTopic, closed: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await vm.setForumTopicClosed(chatID: chat.id, topicID: topic.id, closed: closed)
            await reload()
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }
}

private struct ForumTopicNameView: View {
    @Environment(\.dismiss) private var dismiss
    let titleKey: String
    let save: (String) async throws -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(titleKey: String, initialName: String, save: @escaping (String) async throws -> Void) {
        self.titleKey = titleKey
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            Section("topic.name") {
                TextField("topic.name", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(LocalizedStringKey(titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") { Task { await saveName() } }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || name.count > 128)
            }
        }
    }

    private func saveName() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }
}
