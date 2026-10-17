// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

struct DiscussionThreadView: View {
    let chatID: Int64
    let post: Message

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var thread: DiscussionThreadPage?
    @State private var comments: [Message] = []
    @State private var text = ""
    @State private var isLoading = true
    @State private var isLoadingOlder = false
    @State private var isSending = false
    @State private var hasMore = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading, thread == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: KroSpacing.sm) {
                            if hasMore, thread != nil {
                                Button {
                                    Task { await loadOlder(using: proxy) }
                                } label: {
                                    if isLoadingOlder {
                                        ProgressView()
                                    } else {
                                        Text("channel.comments.loadOlder")
                                            .font(.footnote.weight(.medium))
                                    }
                                }
                                .disabled(isLoadingOlder)
                                .padding(.vertical, KroSpacing.xs)
                            }

                            MessageBubble(
                                message: post,
                                replied: nil,
                                onReplyTap: {},
                                onRetry: {},
                                onVotePoll: { _ in }
                            )
                            .padding(.horizontal, KroSpacing.md)

                            ForEach(comments) { comment in
                                let replied = comment.replyToRemoteID == thread?.threadMessageID
                                    ? post
                                    : comments.first(where: { $0.remoteID == comment.replyToRemoteID })
                                MessageBubble(
                                    message: comment,
                                    replied: replied,
                                    onReplyTap: {},
                                    onRetry: {},
                                    onVotePoll: { _ in }
                                )
                                .id(comment.id)
                                .padding(.horizontal, KroSpacing.md)
                            }
                        }
                        .padding(.vertical, KroSpacing.md)
                    }
                    .onChange(of: comments.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .refreshable { await reload() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KroSpacing.md)
                    .padding(.vertical, KroSpacing.xs)
            }

            composer
        }
        .navigationTitle("channel.comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.done") { dismiss() }
            }
        }
        .task { await reload() }
        .onChange(of: vm.latestDiscussionMessage?.id) { _, _ in
            guard let message = vm.latestDiscussionMessage,
                  let thread,
                  !comments.contains(where: { $0.remoteID == message.remoteID }) else { return }
            comments.append(message)
            Task {
                do {
                    try await vm.markDiscussionCommentsRead([message], in: thread.chatID)
                } catch {
                    errorMessage = TGErrors.message(for: error)
                }
            }
        }
        .onDisappear { vm.closeDiscussionThread() }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: KroSpacing.sm) {
            TextField("channel.comments.placeholder", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onSubmit { Task { await send() } }
                .padding(.horizontal, KroSpacing.md)
                .padding(.vertical, KroSpacing.sm)
                .background(Color(.secondarySystemBackground), in: Capsule())

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }
            .accessibilityLabel(Text("channel.comments.send"))
            .disabled(thread == nil || isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, KroSpacing.md)
        .padding(.vertical, KroSpacing.sm)
        .background(.bar)
    }

    private func reload() async {
        guard let postID = post.remoteID else {
            isLoading = false
            errorMessage = TGErrors.message(for: MockRepositoryError.unsupported)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await vm.loadDiscussionThread(chatID: chatID, messageID: postID)
            thread = loaded
            comments = loaded.messages
            hasMore = post.replyCount.map { $0 > loaded.messages.count } ?? (loaded.messages.count >= 50)
            errorMessage = nil
            await vm.openDiscussionThread(loaded, channelID: chatID, postID: postID)
            try await vm.markDiscussionCommentsRead(loaded.messages, in: loaded.chatID)
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }

    private func loadOlder(using proxy: ScrollViewProxy) async {
        guard !isLoadingOlder,
              let thread,
              let postID = post.remoteID,
              let firstID = comments.first?.id,
              let firstRemoteID = comments.first?.remoteID else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older = try await vm.loadOlderDiscussionComments(
                chatID: chatID,
                messageID: postID,
                discussionChatID: thread.chatID,
                threadMessageID: thread.threadMessageID,
                before: firstRemoteID
            )
            guard !older.isEmpty else {
                hasMore = false
                return
            }
            let existingIDs = Set(comments.compactMap(\.remoteID))
            let unique = older.filter { message in
                guard let remoteID = message.remoteID else { return true }
                return !existingIDs.contains(remoteID)
            }
            guard !unique.isEmpty else {
                hasMore = false
                return
            }
            comments.insert(contentsOf: unique, at: 0)
            vm.registerDiscussionMessages(unique)
            hasMore = post.replyCount.map { $0 > comments.count } ?? (older.count >= 50)
            await Task.yield()
            proxy.scrollTo(firstID, anchor: .top)
            try await vm.markDiscussionCommentsRead(older, in: thread.chatID)
            errorMessage = nil
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }

    private func send() async {
        guard !isSending,
              let thread,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let outgoingText = text
        isSending = true
        defer { isSending = false }
        do {
            let sent = try await vm.sendDiscussionComment(
                chatID: thread.chatID,
                threadMessageID: thread.threadMessageID,
                text: outgoingText
            )
            if let remoteID = sent.remoteID,
               !comments.contains(where: { $0.remoteID == remoteID }) {
                comments.append(sent)
                vm.registerDiscussionMessages([sent])
            }
            if let postID = post.remoteID {
                vm.recordDiscussionReply(sent, channelID: chatID, postID: postID)
            }
            text = ""
            errorMessage = nil
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }
}
