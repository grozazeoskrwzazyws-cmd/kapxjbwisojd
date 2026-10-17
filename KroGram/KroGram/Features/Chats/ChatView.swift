// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import SwiftOGG

// MARK: - Link detection

func linkified(_ text: String, entities: [MessageEntity] = [], revealSpoilers: Bool = false) -> AttributedString {
    var result = AttributedString(text)
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: result) else { continue }
            result[attributedRange].link = url
            result[attributedRange].underlineStyle = .single
        }
    }

    let utf16Count = (text as NSString).length
    for entity in entities where entity.offset <= utf16Count && entity.length <= utf16Count - entity.offset {
        let nsRange = NSRange(location: entity.offset, length: entity.length)
        guard let textRange = Range(nsRange, in: text),
              let range = Range(textRange, in: result) else { continue }
        switch entity.kind {
        case .bold:
            result[range].inlinePresentationIntent = .stronglyEmphasized
        case .italic:
            result[range].inlinePresentationIntent = .emphasized
        case .code, .pre:
            result[range].inlinePresentationIntent = .code
        case .quote:
            result[range].inlinePresentationIntent = .emphasized
        case .spoiler:
            if !revealSpoilers {
                result[range].foregroundColor = .primary
                result[range].backgroundColor = .primary
            }
        case .underline:
            result[range].underlineStyle = .single
        case .strikethrough:
            result[range].strikethroughStyle = .single
        case .textURL(let value):
            result[range].link = URL(string: value)
        case .url:
            if result[range].link == nil { result[range].link = URL(string: String(text[textRange])) }
        case .email:
            result[range].link = URL(string: "mailto:\(text[textRange])")
        case .phoneNumber:
            result[range].link = URL(string: "tel:\(text[textRange])")
        case .mention, .mentionName(_), .hashtag, .cashtag, .botCommand:
            break
        case .customEmoji(_):
            break
        }
    }
    return result
}

private struct MessageInlineText: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var customEmojiImages: [Int64: UIImage] = [:]

    let text: String
    let entities: [MessageEntity]
    let revealSpoilers: Bool

    private var customEmojiEntities: [MessageEntity] {
        entities.filter {
            if case .customEmoji = $0.kind { return true }
            return false
        }.sorted { $0.offset < $1.offset }
    }

    var body: some View {
        content
            .task(id: customEmojiIDs) {
                customEmojiImages = await vm.loadCustomEmojiImages(ids: customEmojiIDs)
            }
    }

    private var customEmojiIDs: [Int64] {
        customEmojiEntities.compactMap {
            guard case .customEmoji(let id) = $0.kind else { return nil }
            return id
        }
    }

    private var content: Text {
        let custom = customEmojiEntities
        guard !custom.isEmpty else {
            return Text(linkified(text, entities: entities, revealSpoilers: revealSpoilers))
        }

        let source = text as NSString
        var position = 0
        var result = Text("")
        for entity in custom where entity.offset >= position && entity.length > 0 && entity.offset + entity.length <= source.length {
            let before = NSRange(location: position, length: entity.offset - position)
            if before.length > 0 {
                result = result + Text(linkified(
                    source.substring(with: before),
                    entities: entities(in: before),
                    revealSpoilers: revealSpoilers
                ))
            }
            let fallback = source.substring(with: NSRange(location: entity.offset, length: entity.length))
            if case .customEmoji(let customEmojiID) = entity.kind,
               let image = customEmojiImages[customEmojiID],
               let cgImage = image.cgImage {
                let scale = max(CGFloat(cgImage.width), CGFloat(cgImage.height)) / 24
                let inlineImage = UIImage(cgImage: cgImage, scale: max(1, scale), orientation: image.imageOrientation)
                result = result + Text(Image(uiImage: inlineImage))
            } else {
                result = result + Text(fallback)
            }
            position = entity.offset + entity.length
        }
        if position < source.length {
            let suffix = NSRange(location: position, length: source.length - position)
            result = result + Text(linkified(
                source.substring(with: suffix),
                entities: entities(in: suffix),
                revealSpoilers: revealSpoilers
            ))
        }
        return result
    }

    private func entities(in range: NSRange) -> [MessageEntity] {
        entities.compactMap { entity in
            if case .customEmoji = entity.kind { return nil }
            let start = max(entity.offset, range.location)
            let end = min(entity.offset + entity.length, range.location + range.length)
            guard start < end else { return nil }
            return MessageEntity(offset: start - range.location, length: end - start, kind: entity.kind)
        }
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: Message
    let replied: Message?
    let onReplyTap: () -> Void
    let onRetry: () -> Void
    let onVotePoll: ([Int]) -> Void
    var showsDiscussionComments = false
    var onCommentsTap: () -> Void = {}
    var albumMessages: [Message] = []
    var onMediaTap: (Message, [Message]) -> Void = { _, _ in }
    @EnvironmentObject private var themes: ThemeStore
    @State private var revealSpoilers = false
    @State private var selectedPollOptions = Set<Int>()

    var body: some View {
        let theme = themes.current
        let foreground: Color = message.isOutgoing ? theme.onAccent : .primary
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if let replied {
                    Button(action: onReplyTap) {
                        HStack(spacing: 6) {
                            Rectangle().fill(foreground.opacity(0.6)).frame(width: 3)
                            Text(replied.text)
                                .kro(.footnote)
                                .lineLimit(2)
                                .opacity(0.8)
                        }
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                } else if message.replyToRemoteID != nil {
                    Button(action: onReplyTap) {
                        Label("chat.replyOriginal", systemImage: "arrowshape.turn.up.left")
                            .font(.footnote)
                            .opacity(0.8)
                    }
                    .buttonStyle(.plain)
                }
                if message.isUnsupportedContent {
                    Label("msg.unsupported", systemImage: "exclamationmark.bubble")
                        .font(.footnote)
                } else if let poll = message.poll {
                    pollContent(poll)
                } else if albumMessages.count > 1 {
                    MediaAlbumGrid(messages: albumMessages) { selected in
                        onMediaTap(selected, albumMessages)
                    }
                    if let caption = albumMessages.compactMap(\.media).first(where: { !$0.caption.isEmpty }) {
                        spoilerRevealButton(for: caption.captionEntities)
                        Text(linkified(caption.caption, entities: caption.captionEntities, revealSpoilers: revealSpoilers))
                            .kro(.body)
                            .tint(foreground)
                    }
                } else if let media = message.media {
                    MediaMessageView(media: media) {
                        onMediaTap(message, [message])
                    }
                    if !media.caption.isEmpty {
                        spoilerRevealButton(for: media.captionEntities)
                        Text(linkified(media.caption, entities: media.captionEntities, revealSpoilers: revealSpoilers))
                            .kro(.body)
                            .tint(foreground)
                    }
                } else {
                    spoilerRevealButton(for: message.entities)
                    MessageInlineText(
                        text: message.text,
                        entities: message.entities,
                        revealSpoilers: revealSpoilers
                    )
                        .kro(.body)
                        .tint(foreground)
                }
                footer(foreground)
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions, id: \.self) { Text($0).font(.footnote) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(foreground.opacity(0.15), in: Capsule())
                }
                if showsDiscussionComments, let replyCount = message.replyCount {
                    Button(action: onCommentsTap) {
                        Label(
                            String(format: L("channel.comments.count"), replyCount),
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(message.isOutgoing ? foreground : Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.isOutgoing ? theme.accent : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous)
            )
            .neonGlow(message.isOutgoing ? theme.accent : .clear, radius: 8)
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .onTapGesture { if message.state == .failed { onRetry() } }
    }

    private func pollContent(_ poll: MessagePoll) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question).font(.body.weight(.semibold))
            ForEach(poll.options.indices, id: \.self) { index in
                let option = poll.options[index]
                let showsResults = poll.totalVoterCount > 0
                Button {
                    guard !poll.isClosed, !poll.options.contains(where: \.isChosen) else { return }
                    if poll.allowsMultipleAnswers {
                        if selectedPollOptions.contains(index) {
                            selectedPollOptions.remove(index)
                        } else {
                            selectedPollOptions.insert(index)
                        }
                    } else {
                        selectedPollOptions = [index]
                    }
                } label: {
                    HStack {
                        Image(systemName: option.isChosen || selectedPollOptions.contains(index)
                              ? "largecircle.fill.circle" : "circle")
                        Text(option.text)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if showsResults {
                            Text("\(option.votePercentage)%")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(poll.isClosed || poll.options.contains(where: \.isChosen))
                if showsResults {
                    ProgressView(value: Double(option.votePercentage), total: 100)
                        .tint(themes.current.accent)
                        .accessibilityLabel(Text("poll.result"))
                        .accessibilityValue("\(option.votePercentage)%")
                }
            }
            if !poll.isClosed, !poll.options.contains(where: \.isChosen) {
                Button("poll.vote") { onVotePoll(selectedPollOptions.sorted()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPollOptions.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !poll.isClosed {
                Button("poll.retractVote") { onVotePoll([]) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(String(format: L("poll.voterCount"), poll.totalVoterCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: poll.options.map(\.isChosen)) { _, chosen in
            selectedPollOptions = Set(chosen.indices.filter { chosen[$0] })
        }
    }

    @ViewBuilder
    private func spoilerRevealButton(for entities: [MessageEntity]) -> some View {
        if entities.contains(where: { $0.kind == .spoiler }), !revealSpoilers {
            Button("msg.revealSpoilers") { revealSpoilers = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
        }
    }

    private func footer(_ foreground: Color) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if message.isEdited {
                Text("chat.edited").kro(.caption)
            }
            Text(message.date.formatted(date: .omitted, time: .shortened)).kro(.caption)
            if let viewCount = message.viewCount {
                Image(systemName: "eye").font(.caption2)
                Text(viewCount.formatted()).kro(.caption)
            }
            if message.isOutgoing { stateIcon }
        }
        .opacity(0.75)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch message.state {
        case .sending:
            Image(systemName: "clock").font(.caption2).accessibilityLabel(Text("chat.state.sending"))
        case .sent:
            Image(systemName: "checkmark").font(.caption2).accessibilityLabel(Text("chat.state.sent"))
        case .read:
            Image(systemName: "checkmark.circle.fill").font(.caption2).accessibilityLabel(Text("chat.state.read"))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .accessibilityLabel(Text("chat.state.failed"))
        }
    }
}

// MARK: - Chat screen

struct ChatView: View {
    let chatID: Int64
    var topicID: Int64? = nil
    var topicTitle: String? = nil
    var topicIsClosed = false
    @EnvironmentObject private var vm: ChatsViewModel
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var privacy: PrivacyMode
    @EnvironmentObject private var commander: CommanderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var query = ""
    @State private var isSearching = false
    @State private var commanderResponse: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedAlbumItems: [PhotosPickerItem] = []
    @State private var selectedVideoNote: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showChatProfile = false
    @State private var showingPollComposer = false
    @State private var showingContactPicker = false
    @State private var showingLocationShare = false
    @State private var showingStickerPicker = false
    @State private var showingEmojiGIFPicker = false
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @State private var composerEntityKind: MessageEntityKind?
    @State private var selectingMessages = false
    @State private var selectedMessageIDs = Set<UUID>()
    @State private var showingForwardPicker = false
    @State private var selectedForwardChatIDs = Set<Int64>()
    @State private var hideForwardSender = false
    @State private var showingDeleteSelectionConfirmation = false
    @State private var discussionPost: Message?
    @State private var mediaGallery: MediaGallerySelection?
    @State private var isSendingAlbum = false

    private static let reactions = ["👍", "❤️", "😂", "🔥"]

    var body: some View {
        if let chat = vm.chat(chatID) {
            if chat.isForum && topicID == nil {
                ForumTopicsView(chat: chat)
            } else {
                content(chat)
            }
        } else {
            ContentUnavailableView("chats.empty", systemImage: "bubble.left")
        }
    }

    private func content(_ chat: Chat) -> some View {
        let theme = themes.current
        let shown: [Message]
        if query.isEmpty {
            shown = chat.messages
        } else {
            shown = vm.searchResults(in: chatID, query: query)
                ?? chat.messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let rendered = albumRows(from: shown)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rendered) { message in
                            if themes.shouldAnimate(reduceMotion: reduceMotion) {
                                bubble(message, in: chat, proxy: proxy)
                                    .id(message.id)
                                    .transition(KroBlurTransition())
                                    .onAppear { loadOlderIfAtTop(message, chat: chat) }
                            } else {
                                bubble(message, in: chat, proxy: proxy)
                                    .id(message.id)
                                    .transition(.identity)
                                    .onAppear { loadOlderIfAtTop(message, chat: chat) }
                            }
                        }
                    }
                    .animation(themes.shouldAnimate(reduceMotion: reduceMotion) ? .snappy : nil, value: rendered.count)
                    .padding(.horizontal, KroSpacing.md)
                    .padding(.vertical, KroSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToEnd(proxy, chat) }
                .onChange(of: chat.messages.last?.id) { _, _ in scrollToEnd(proxy, chat) }
                .overlay {
                    if !query.isEmpty, vm.searchingChats.contains(chatID), shown.isEmpty {
                        ProgressView()
                    }
                }
            }
            if let commanderResponse {
                commanderResult(commanderResponse)
                    .padding(.horizontal, KroSpacing.md)
                    .padding(.bottom, KroSpacing.xs)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let mediaError = vm.mediaError {
                HStack {
                    Text(mediaError).kro(.footnote).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, KroSpacing.md)
            }
            if editing == nil, replyTo == nil, !commanderSuggestions.isEmpty {
                commandSuggestions
            }
            if topicIsClosed {
                HStack(spacing: KroSpacing.sm) {
                    Image(systemName: "lock.fill")
                    Text("topic.closed.readOnly").kro(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, KroSpacing.md)
                .background(.bar)
            } else if chat.kind == .channel && !chat.canPostMessages {
                HStack(spacing: KroSpacing.sm) {
                    Image(systemName: "eye")
                    Text("channel.composer.readOnly").kro(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, KroSpacing.md)
                .background(.bar)
            } else {
                composer
            }
        }
        .background(ChatWallpaper(configuration: theme.background, accent: theme.accent).ignoresSafeArea())
        .navigationTitle(
            topicTitle.map { Text(verbatim: $0) }
                ?? (chat.isSavedMessages ? Text("chat.savedMessages") : Text(chat.title))
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showChatProfile) {
            ChatProfileView(chatID: chatID) {
                dismiss()
            }
        }
        .searchable(text: $query, isPresented: $isSearching, prompt: Text("chat.search"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showChatProfile = true } label: {
                    if chat.isSavedMessages {
                        Text("chat.savedMessages")
                            .font(.headline)
                            .lineLimit(1)
                    } else {
                        Text(chat.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                .accessibilityHint(Text("profile.openChat"))
            }
            if chat.unread > 0 && privacy.hideRead {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        Task { await vm.markReadNow(chatID, topicID: topicID) }
                    } label: {
                        Label("action.markRead", systemImage: "checkmark.message")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectingMessages && !selectedMessageIDs.isEmpty {
                    Menu {
                        if vm.isLive {
                            Button {
                                selectedForwardChatIDs.removeAll()
                                hideForwardSender = false
                                vm.setMediaError(nil)
                                showingForwardPicker = true
                            } label: {
                                Label("action.forward", systemImage: "arrowshape.turn.up.right")
                            }
                        }
                        Button(role: .destructive) {
                            showingDeleteSelectionConfirmation = true
                        } label: {
                            Label("action.deleteSelected", systemImage: "trash")
                        }
                        Button("action.done") {
                            selectingMessages = false
                            selectedMessageIDs.removeAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                } else {
                    Button(selectingMessages ? "action.done" : "action.selectMessages") {
                        selectingMessages.toggle()
                        selectedMessageIDs.removeAll()
                    }
                }
            }
        }
        .sheet(isPresented: $showingForwardPicker) {
            NavigationStack {
                List {
                    if let mediaError = vm.mediaError {
                        Section {
                            Text(mediaError)
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        Toggle("chat.forward.hideSender", isOn: $hideForwardSender)
                    }
                    Section {
                        ForEach(vm.mainChats.filter { $0.id != chatID }) { destination in
                            Button {
                                if selectedForwardChatIDs.contains(destination.id) {
                                    selectedForwardChatIDs.remove(destination.id)
                                } else {
                                    selectedForwardChatIDs.insert(destination.id)
                                }
                            } label: {
                                HStack {
                                    if destination.isSavedMessages {
                                        Text("chat.savedMessages")
                                    } else {
                                        Text(destination.title)
                                    }
                                    Spacer()
                                    if selectedForwardChatIDs.contains(destination.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                .navigationTitle("chat.forward.title")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { showingForwardPicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.forward") {
                            let ids = selectedMessageIDs.sorted { left, right in
                                let messages = vm.chat(chatID)?.messages ?? []
                                return (messages.first { $0.id == left }?.remoteID ?? 0)
                                    < (messages.first { $0.id == right }?.remoteID ?? 0)
                            }
                            let destinations = vm.mainChats.filter {
                                selectedForwardChatIDs.contains($0.id)
                            }.map(\.id).sorted()
                            Task {
                                for destinationID in destinations {
                                    guard await vm.forwardMessages(
                                        ids,
                                        from: chatID,
                                        to: destinationID,
                                        hideSender: hideForwardSender
                                    ) else { return }
                                    selectedForwardChatIDs.remove(destinationID)
                                }
                                showingForwardPicker = false
                                selectingMessages = false
                                selectedMessageIDs.removeAll()
                                selectedForwardChatIDs.removeAll()
                            }
                        }
                        .disabled(selectedForwardChatIDs.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog(
            "action.deleteSelected",
            isPresented: $showingDeleteSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("action.deleteForMe", role: .destructive) {
                deleteSelectedMessages(revoke: false)
            }
            if selectedMessagesCanBeRevoked(in: chat) {
                Button("action.deleteForEveryone", role: .destructive) {
                    deleteSelectedMessages(revoke: true)
                }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text(String(format: L("delete.messages.preview"), selectedMessageIDs.count))
        }
        .sheet(isPresented: $showingPollComposer) {
            PollComposerView { question, options, isAnonymous, allowsMultipleAnswers in
                try await vm.sendPoll(
                    question: question,
                    options: options,
                    isAnonymous: isAnonymous,
                    allowsMultipleAnswers: allowsMultipleAnswers,
                    to: chatID,
                    topicID: topicID
                )
            }
        }
        .sheet(item: $discussionPost) { post in
            NavigationStack {
                DiscussionThreadView(chatID: chatID, post: post)
            }
        }
        .fullScreenCover(item: $mediaGallery) { selection in
            MediaGalleryViewer(
                messages: selection.messages,
                initialMessageID: selection.selectedMessageID
            )
        }
        .sheet(isPresented: $showingContactPicker) {
            SystemContactPicker { selection in
                showingContactPicker = false
                guard let selection else { return }
                Task {
                    do {
                        try await vm.sendContact(
                            firstName: selection.firstName,
                            lastName: selection.lastName,
                            phoneNumber: selection.phoneNumber,
                            to: chatID,
                            topicID: topicID
                        )
                    } catch {
                        vm.setMediaError(TGErrors.message(for: error))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingLocationShare) {
            LocationShareView { latitude, longitude in
                try await vm.sendLocation(
                    latitude: latitude,
                    longitude: longitude,
                    to: chatID,
                    topicID: topicID
                )
            }
        }
        .sheet(isPresented: $showingStickerPicker) {
            StickerPickerView { sticker in
                try await vm.sendSticker(sticker, to: chatID, topicID: topicID)
            }
        }
        .sheet(isPresented: $showingEmojiGIFPicker) {
            AnimationEmojiPickerView(
                chatID: chatID,
                onSelectEmoji: { text.append($0) },
                onSendAnimation: { animation in
                    if animation.queryID != nil {
                        try await vm.sendInlineAnimation(animation, to: chatID, topicID: topicID)
                    } else {
                        try await vm.sendAnimation(animation, to: chatID, topicID: topicID)
                    }
                }
            )
        }
        .onAppear { text = vm.draft(for: chatID) }
        .task { await vm.openChat(chatID, topicID: topicID) }
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await vm.searchMessages(in: chatID, query: query)
        }
        .onDisappear {
            vm.setDraft(text, for: chatID)
            voiceRecorder.cancel()
            if !showChatProfile && discussionPost == nil { vm.closeChat(chatID) }
        }
        .onChange(of: text) { _, newValue in
            if !newValue.isEmpty { vm.userTyped(chatID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                vm.setDraft(text, for: chatID)
                voiceRecorder.cancel()
            } else {
                Task { await vm.openChat(chatID, topicID: topicID) }
            }
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task { await sendPickedPhoto(photo) }
        }
        .onChange(of: selectedAlbumItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPickedAlbum(items) }
        }
        .onChange(of: selectedVideoNote) { _, video in
            guard let video else { return }
            Task { await sendPickedVideoNote(video) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task { await importSelectedFile(result) }
        }
    }

    private func bubble(_ message: Message, in chat: Chat, proxy: ScrollViewProxy) -> some View {
        let replied = chat.messages.first { candidate in
            if let localID = message.replyToID, candidate.id == localID { return true }
            if let remote = message.replyToRemoteID, candidate.remoteID == remote { return true }
            return false
        }
        let albumMessages: [Message]
        if let albumID = message.mediaAlbumID {
            albumMessages = chat.messages.filter {
                $0.mediaAlbumID == albumID && $0.media != nil
            }
        } else {
            albumMessages = []
        }
        return MessageBubble(
            message: message,
            replied: replied,
            albumMessages: albumMessages,
            onMediaTap: { selected, album in
                mediaGallery = MediaGallerySelection(
                    messages: album,
                    selectedMessageID: selected.id
                )
            },
            onReplyTap: {
                Task {
                    guard let target = await vm.replyTarget(for: message, in: chatID) else { return }
                    if !query.isEmpty { query = "" }
                    await Task.yield()
                    withAnimation(.snappy) {
                        proxy.scrollTo(target.id, anchor: .center)
                    }
                }
            },
            onRetry: { vm.retry(message.id, in: chatID, topicID: topicID) },
            onVotePoll: { optionIDs in vm.votePoll(message.id, in: chatID, optionIDs: optionIDs) },
            showsDiscussionComments: chat.kind == .channel && topicID == nil && message.replyCount != nil,
            onCommentsTap: { discussionPost = message }
        )
        .overlay(alignment: .topLeading) {
            if selectingMessages && selectedMessageIDs.contains(message.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(themes.current.accent)
                    .background(.background, in: Circle())
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard selectingMessages else { return }
            if selectedMessageIDs.contains(message.id) {
                selectedMessageIDs.remove(message.id)
            } else if selectedMessageIDs.count < 100 {
                selectedMessageIDs.insert(message.id)
            } else {
                vm.setMediaError(L("chat.forward.limit"))
            }
        })
        .contextMenu {
            if !selectingMessages {
                Button {
                    selectingMessages = true
                    selectedMessageIDs = [message.id]
                } label: {
                    Label("action.selectMessages", systemImage: "checkmark.circle")
                }
            }
            Button { replyTo = message; editing = nil } label: {
                Label("action.reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                let copyText = message.media.map { $0.caption.isEmpty ? message.text : $0.caption }
                    ?? message.poll?.question
                    ?? message.text
                UIPasteboard.general.string = copyText
            } label: {
                Label("action.copy", systemImage: "doc.on.doc")
            }
            Menu {
                ForEach(Self.reactions, id: \.self) { emoji in
                    Button(emoji) { vm.toggleReaction(emoji, on: message.id, in: chatID) }
                }
            } label: {
                Label("chat.react", systemImage: "face.smiling")
            }
            if vm.isLive, message.remoteID != nil {
                if chat.kind != .channel || chat.canPinMessages {
                    Button {
                        vm.setMessagePinned(message.id, in: chatID, pinned: !message.isPinned)
                    } label: {
                        Label(
                            message.isPinned ? "action.unpinMessage" : "action.pinMessage",
                            systemImage: message.isPinned ? "pin.slash" : "pin"
                        )
                    }
                }
                Button {
                    selectingMessages = true
                    selectedMessageIDs = [message.id]
                    selectedForwardChatIDs.removeAll()
                    hideForwardSender = false
                    vm.setMediaError(nil)
                    showingForwardPicker = true
                } label: {
                    Label("action.forward", systemImage: "arrowshape.turn.up.right")
                }
            }
            if message.isOutgoing && (chat.kind != .channel || chat.canPostMessages) {
                Button {
                    editing = message
                    replyTo = nil
                    text = message.text
                    composerEntityKind = nil
                } label: { Label("action.edit", systemImage: "pencil") }
            }
            if vm.isLive, message.remoteID != nil,
               (chat.kind != .channel || chat.canPostMessages) {
                Menu {
                    Button(role: .destructive) {
                        vm.deleteMessage(message.id, in: chatID, revoke: false)
                    } label: {
                        Label("action.deleteForMe", systemImage: "trash")
                    }
                    if message.isOutgoing || chat.kind == .direct
                        || (chat.kind == .channel && chat.canPostMessages) {
                        Button(role: .destructive) {
                            vm.deleteMessage(message.id, in: chatID, revoke: true)
                        } label: {
                            Label("action.deleteForEveryone", systemImage: "trash.slash")
                        }
                    }
                } label: {
                    Label("action.delete", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    vm.deleteMessage(message.id, in: chatID)
                } label: {
                    Label("action.delete", systemImage: "trash")
                }
            }
        }
    }

    private func albumRows(from messages: [Message]) -> [Message] {
        var seenAlbums = Set<Int64>()
        return messages.filter { message in
            guard let albumID = message.mediaAlbumID, message.media != nil else { return true }
            return seenAlbums.insert(albumID).inserted
        }
    }

    private func selectedMessagesCanBeRevoked(in chat: Chat) -> Bool {
        guard vm.isLive, !selectedMessageIDs.isEmpty else { return false }
        if chat.kind == .channel && !chat.canPostMessages { return false }
        return chat.kind == .direct || (chat.kind == .channel && chat.canPostMessages)
            || selectedMessageIDs.allSatisfy { id in
            vm.chat(chatID)?.messages.first { $0.id == id }?.isOutgoing == true
        }
    }

    private func deleteSelectedMessages(revoke: Bool) {
        let ids = Array(selectedMessageIDs)
        Task {
            guard await vm.deleteMessages(ids, in: chatID, revoke: revoke) else { return }
            selectedMessageIDs.removeAll()
            selectingMessages = false
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let target = replyTo ?? editing {
                HStack(spacing: KroSpacing.sm) {
                    Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(editing != nil ? "chat.editing" : "chat.replying")
                            .kro(.caption, weight: .semibold)
                            .foregroundStyle(.tint)
                        Text(target.text).kro(.footnote).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if editing != nil { text = "" }
                        replyTo = nil
                        editing = nil
                        composerEntityKind = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("action.cancel"))
                }
                .padding(.horizontal, KroSpacing.lg)
                .padding(.vertical, KroSpacing.sm)
            }
            HStack(alignment: .bottom, spacing: KroSpacing.sm) {
                Menu {
                    Button("format.bold") { composerEntityKind = .bold }
                    Button("format.italic") { composerEntityKind = .italic }
                    Button("format.code") { composerEntityKind = .code }
                    Button("format.quote") { composerEntityKind = .quote }
                    Button("format.spoiler") { composerEntityKind = .spoiler }
                    Button("format.none") { composerEntityKind = nil }
                } label: {
                    Image(systemName: "textformat")
                        .font(.title3)
                        .foregroundStyle(composerEntityKind == nil ? Color.secondary : themes.current.accent)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editing != nil)
                .accessibilityLabel(Text("format.title"))
                Button {
                    showingEmojiGIFPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("emojiGIF.title"))
                Menu {
                    if vm.isLive {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("chat.attach.photo", systemImage: "photo")
                        }
                        PhotosPicker(
                            selection: $selectedAlbumItems,
                            maxSelectionCount: 100,
                            matching: .any(of: [.images, .videos])
                        ) {
                            Label("media.album.select", systemImage: "square.stack")
                        }
                        PhotosPicker(selection: $selectedVideoNote, matching: .videos) {
                            Label("chat.attach.videoNote", systemImage: "video.circle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("chat.attach.file", systemImage: "doc")
                        }
                        Button {
                            showingPollComposer = true
                        } label: {
                            Label("poll.create", systemImage: "chart.bar")
                        }
                        Button {
                            showingContactPicker = true
                        } label: {
                            Label("chat.attach.contact", systemImage: "person.crop.circle")
                        }
                        Button {
                            showingLocationShare = true
                        } label: {
                            Label("chat.attach.location", systemImage: "location")
                        }
                        Button {
                            showingStickerPicker = true
                        } label: {
                            Label("sticker.title", systemImage: "face.smiling")
                        }
                        Button {
                            Task {
                                do {
                                    try await voiceRecorder.start()
                                } catch {
                                    vm.setMediaError(TGErrors.message(for: error))
                                }
                            }
                        } label: {
                            Label("chat.attach.voice", systemImage: "mic")
                        }
                    } else {
                        Text("media.realOnly")
                    }
                } label: {
                    if isSendingAlbum {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
                .disabled(isSendingAlbum)
                .accessibilityLabel(Text("chat.attach.photo"))
                if voiceRecorder.isRecording {
                    Text("chat.voiceRecording")
                        .kro(.body)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                } else {
                    TextField("chat.message.placeholder", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .kro(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glass(cornerRadius: KroRadius.field)
                }
                Button(action: voiceRecorder.isRecording ? finishVoiceRecording : submit) {
                    Image(systemName: voiceRecorder.isRecording
                          ? "stop.circle.fill"
                          : (editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill"))
                        .font(.title)
                }
                .disabled(!voiceRecorder.isRecording && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, KroSpacing.md)
            .padding(.vertical, KroSpacing.sm)
        }
        .background(.bar)
    }

    private var commanderSuggestions: [String] {
        CommanderCommandEngine.suggestions(for: text, preferences: commander.preferences)
    }

    private var commandSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: KroSpacing.sm) {
                ForEach(commanderSuggestions, id: \.self) { command in
                    Button {
                        text = command
                        commanderResponse = nil
                    } label: {
                        Text(command)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .glass(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, KroSpacing.md)
            .padding(.vertical, KroSpacing.xs)
        }
        .accessibilityLabel(Text("commander.suggestions"))
    }

    private func commanderResult(_ result: String) -> some View {
        HStack(alignment: .top, spacing: KroSpacing.sm) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(themes.current.accent)
                .neonGlow(themes.current.accent, radius: 8)
            Text(result)
                .kro(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                commanderResponse = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("action.dismiss"))
        }
        .padding(KroSpacing.md)
        .glass(cornerRadius: KroRadius.card)
    }

    private func submit() {
        if let editing {
            vm.edit(editing.id, in: chatID, text: text)
            self.editing = nil
        } else {
            if replyTo == nil,
               let chat = vm.chat(chatID),
               let result = CommanderCommandEngine.execute(
                   text,
                   chat: chat,
                   preferences: commander.preferences
               ) {
                switch result {
                case .local(let message):
                    commanderResponse = message
                case .pin(let pinned):
                    guard chat.isPinned != pinned else {
                        commanderResponse = L(pinned ? "commander.result.alreadyPinned" : "commander.result.alreadyUnpinned")
                        text = ""
                        vm.setDraft("", for: chatID)
                        return
                    }
                    vm.update([chatID]) { $0.isPinned = pinned }
                    commanderResponse = L(pinned ? "commander.result.pinned" : "commander.result.unpinned")
                case .archive(let archived):
                    guard chat.isArchived != archived else {
                        commanderResponse = L(archived ? "commander.result.alreadyArchived" : "commander.result.alreadyUnarchived")
                        text = ""
                        vm.setDraft("", for: chatID)
                        return
                    }
                    vm.update([chatID]) { $0.isArchived = archived }
                    commanderResponse = L(archived ? "commander.result.archived" : "commander.result.unarchived")
                }
                text = ""
                composerEntityKind = nil
                vm.setDraft("", for: chatID)
                Haptics.success()
                return
            }
            vm.send(
                text,
                in: chatID,
                replyTo: replyTo?.id,
                entityKind: composerEntityKind,
                topicID: topicID
            )
            replyTo = nil
        }
        text = ""
        composerEntityKind = nil
        vm.setDraft("", for: chatID)
    }

    @MainActor
    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                vm.setMediaError(L("err.generic"))
                return
            }
            guard data.count <= 10 * 1_024 * 1_024 else {
                vm.setMediaError(L("media.tooLarge"))
                return
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let url = try storeOutgoingFile(data, fileExtension: ext)
            defer { removeOutgoingFileIfSafe(url) }
            try await vm.sendPhoto(path: url.path, caption: text, to: chatID, topicID: topicID)
            text = ""
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    @MainActor
    private func sendPickedAlbum(_ items: [PhotosPickerItem]) async {
        guard !isSendingAlbum else { return }
        isSendingAlbum = true
        var outgoingURLs: [URL] = []
        defer {
            outgoingURLs.forEach { removeOutgoingFileIfSafe($0) }
            selectedAlbumItems = []
            isSendingAlbum = false
        }

        do {
            var captionPending = text
            for start in stride(from: 0, to: items.count, by: 10) {
                let end = min(start + 10, items.count)
                var batch: [ChatRepository.OutgoingAlbumMedia] = []
                for item in items[start..<end] {
                    guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                        throw TDError(code: -3, message: "MEDIA_READ_FAILED")
                    }
                    let movieType = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                    if let movieType {
                        guard data.count <= 25 * 1_024 * 1_024 else {
                            throw TDError(code: -3, message: "FILE_TOO_LARGE")
                        }
                        let ext = movieType.preferredFilenameExtension?.lowercased() ?? "mp4"
                        guard ["mov", "mp4", "m4v"].contains(ext) else {
                            throw TDError(code: -3, message: "UNSUPPORTED_MEDIA_TYPE")
                        }
                        let url = try storeOutgoingFile(data, fileExtension: ext)
                        outgoingURLs.append(url)
                        batch.append(.video(path: url.path))
                    } else {
                        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) else {
                            throw TDError(code: -3, message: "UNSUPPORTED_MEDIA_TYPE")
                        }
                        guard data.count <= 10 * 1_024 * 1_024 else {
                            throw TDError(code: -3, message: "FILE_TOO_LARGE")
                        }
                        let ext = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?
                            .preferredFilenameExtension ?? "jpg"
                        let url = try storeOutgoingFile(data, fileExtension: ext)
                        outgoingURLs.append(url)
                        batch.append(.photo(path: url.path))
                    }
                }
                if batch.count > 1 {
                    try await vm.sendMediaAlbum(batch, caption: captionPending, to: chatID, topicID: topicID)
                } else if let item = batch.first {
                    try await sendAlbumItem(item, caption: captionPending)
                }
                captionPending = ""
                outgoingURLs.forEach { removeOutgoingFileIfSafe($0) }
                outgoingURLs.removeAll()
            }
            text = ""
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    @MainActor
    private func sendAlbumItem(
        _ item: ChatRepository.OutgoingAlbumMedia,
        caption: String
    ) async throws {
        switch item {
        case .photo(let path):
            try await vm.sendPhoto(path: path, caption: caption, to: chatID, topicID: topicID)
        case .video(let path):
            try await vm.sendVideo(path: path, caption: caption, to: chatID, topicID: topicID)
        }
    }

    @MainActor
    private func sendPickedVideoNote(_ item: PhotosPickerItem) async {
        defer { selectedVideoNote = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw TDError(code: -3, message: "MEDIA_READ_FAILED")
            }
            guard data.count > 0, data.count <= 25 * 1_024 * 1_024 else {
                throw TDError(code: -3, message: "FILE_TOO_LARGE")
            }
            let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) }
            let preferredExtension = videoType?.preferredFilenameExtension?.lowercased()
            let supportedExtensions = ["mov", "mp4", "m4v"]
            let ext = preferredExtension.flatMap { supportedExtensions.contains($0) ? $0 : nil } ?? "mov"
            let url = try storeOutgoingFile(data, fileExtension: ext)
            defer { removeOutgoingFileIfSafe(url) }
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard duration.isFinite, duration > 0, duration <= 60 else {
                throw TDError(code: -3, message: "INVALID_MEDIA_DURATION")
            }
            let tracks = try await asset.load(.tracks)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                throw TDError(code: -3, message: "MEDIA_READ_FAILED")
            }
            let naturalSize = try await videoTrack.load(.naturalSize)
            let side = max(1, min(640, Int(min(abs(naturalSize.width), abs(naturalSize.height)))))
            try await vm.sendVideoNote(
                path: url.path,
                duration: Int(duration.rounded(.up)),
                length: side,
                to: chatID,
                topicID: topicID
            )
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    private func finishVoiceRecording() {
        do {
            let recording = try voiceRecorder.finish()
            let oggURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).ogg")
            Task {
                var outgoingURL: URL?
                defer {
                    if let outgoingURL { removeOutgoingFileIfSafe(outgoingURL) }
                    try? FileManager.default.removeItem(at: recording.url)
                    try? FileManager.default.removeItem(at: oggURL)
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try OGGConverter.convertM4aFileToOpusOGG(src: recording.url, dest: oggURL)
                    }.value
                    let data = try Data(contentsOf: oggURL, options: .mappedIfSafe)
                    let url = try storeOutgoingFile(data, fileExtension: "ogg")
                    outgoingURL = url
                    try await vm.sendVoiceNote(
                        path: url.path,
                        duration: recording.duration,
                        to: chatID,
                        topicID: topicID
                    )
                } catch {
                    vm.setMediaError(TGErrors.message(for: error))
                }
            }
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    @MainActor
    private func importSelectedFile(_ result: Result<[URL], Error>) async {
        do {
            guard let source = try result.get().first else { return }
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= 1_073_741_824 else {
                vm.setMediaError(L("media.tooLarge"))
                return
            }
            let url = try storeOutgoingFile(from: source)
            do {
                if UTType(filenameExtension: source.pathExtension)?.conforms(to: .movie) == true {
                    try await vm.sendVideo(path: url.path, caption: text, to: chatID, topicID: topicID)
                } else {
                    try await vm.sendDocument(path: url.path, caption: text, to: chatID, topicID: topicID)
                }
            } catch {
                removeOutgoingFileIfSafe(url)
                throw error
            }
            text = ""
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    private func removeOutgoingFileIfSafe(_ url: URL) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/outgoing", isDirectory: true)
        let path = directory.path
        guard url.path.hasPrefix(path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanExpiredOutgoingFiles() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/outgoing", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func storeOutgoingFile(_ data: Data, fileExtension ext: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/outgoing", isDirectory: true)
        cleanExpiredOutgoingFiles()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let currentSize = try existing.reduce(Int64.zero) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values.fileSize ?? 0)
        }
        guard currentSize + Int64(data.count) <= 2_147_483_648 else {
            throw TDError(code: -6, message: "OUTGOING_STORAGE_FULL")
        }
        let safeExtension = ext.range(of: "^[a-zA-Z0-9]{1,8}$", options: .regularExpression) == nil ? "bin" : ext
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(safeExtension)")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func storeOutgoingFile(from source: URL) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/outgoing", isDirectory: true)
        cleanExpiredOutgoingFiles()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceSize = (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard sourceSize > 0, sourceSize <= 1_073_741_824 else {
            throw TDError(code: -3, message: "FILE_TOO_LARGE")
        }
        let existing = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let currentSize = try existing.reduce(Int64.zero) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values.fileSize ?? 0)
        }
        guard currentSize + sourceSize <= 2_147_483_648 else {
            throw TDError(code: -6, message: "OUTGOING_STORAGE_FULL")
        }
        let ext = source.pathExtension
        let safeExtension = ext.range(of: "^[a-zA-Z0-9]{1,8}$", options: .regularExpression) == nil ? "bin" : ext
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(safeExtension)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ chat: Chat) {
        guard let last = chat.messages.last else { return }
        if themes.shouldAnimate(reduceMotion: reduceMotion) {
            withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }

    }

    private func loadOlderIfAtTop(_ message: Message, chat: Chat) {
        if query.isEmpty {
            guard message.id == chat.messages.first(where: { $0.remoteID != nil })?.id else { return }
            Task { await vm.loadOlderHistory(chatID: chatID, topicID: topicID) }
        } else {
            guard vm.searchResults(in: chatID, query: query)?.last?.id == message.id else { return }
            Task { await vm.searchMessages(in: chatID, query: query, loadMore: true) }
        }
    }
}
