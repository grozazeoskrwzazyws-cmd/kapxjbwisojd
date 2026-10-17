// Copyright © 2026 Kro. KroGram original materials.

import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class ChatsViewModel: ObservableObject {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    struct UndoBanner: Identifiable {
        let id = UUID()
        let text: String
        /// Previous state of only the affected chats.
        let restore: [Chat]
    }

    @Published private(set) var chats: [Chat] = []
    @Published private(set) var folders: [ChatFolder] = []
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var contactsLoading = false
    @Published private(set) var isLoadingMoreChats = false
    @Published private(set) var mediaProgress: [Int64: (downloaded: Int64, total: Int64)] = [:]
    @Published private(set) var downloadQueue: [DownloadRecord] = []
    @Published private(set) var uploadQueue: [UploadRecord] = []
    @Published private(set) var networkConnection: NetworkConnectionKind = .other
    @Published private(set) var mediaError: String?
    @Published private(set) var profile: TelegramProfile?
    @Published private(set) var profileLoading = false
    @Published private(set) var drafts: [Int64: String] = [:]
    @Published private(set) var messageSearchResults: [Int64: [Message]] = [:]
    @Published private(set) var messageSearchQueries: [Int64: String] = [:]
    @Published private(set) var searchingChats: Set<Int64> = []
    @Published private(set) var stickers: [TelegramSticker] = []
    @Published private(set) var stickersLoading = false
    @Published private(set) var stickerSets: [TelegramStickerSet] = []
    @Published private(set) var stickerSearchResults: [TelegramStickerSet] = []
    @Published private(set) var recentStickers: [TelegramSticker] = []
    @Published private(set) var selectedStickerSetStickers: [TelegramSticker] = []
    @Published private(set) var savedAnimations: [TelegramAnimation] = []
    @Published private(set) var animationSearchResults: [TelegramAnimation] = []
    @Published private(set) var emojiSearchResults: [String] = []
    @Published private(set) var recentEmojis: [String] = []
    @Published private(set) var connection: ConnectionState = .ready
    @Published private(set) var latestDiscussionMessage: Message?
    @Published var searchText = ""
    @Published var filter: ChatFilter = .all
    @Published var dateFilter: DateFilter = .any
    @Published var selectedFolderID: UUID?
    @Published var undoBanner: UndoBanner?

    private var repository: ChatRepository
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "krogram.network-monitor")
    private let privacy: PrivacyMode
    private let defaults: UserDefaults
    private var undoTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var hiddenIDs: Set<Int64>
    private var lastTyping: [Int64: Date] = [:]
    private var historyLoading: Set<Int64> = []
    private var initialHistoryLoading: Set<Int64> = []
    private var chatOpenRequests: [Int64: UUID] = [:]
    private var historyExhausted: Set<Int64> = []
    private var searchCursors: [Int64: Int64] = [:]
    private var searchExhausted: Set<Int64> = []
    private var searchTokens: [Int64: UUID] = [:]
    private var activeChatID: Int64?
    private var activeTopicID: Int64?
    private var activeDiscussionChatID: Int64?
    private var activeDiscussionMessageIDs: Set<Int64> = []
    private var discussionReplyCountedIDs: Set<Int64> = []
    private var activeDiscussionChannelID: Int64?
    private var activeDiscussionPostID: Int64?
    private var isForeground = true
    private var moreChatsExhausted = false
    private var contactsLoaded = false
    private var stickersLoaded = false
    private var stickerSearchRequestID = UUID()
    private var stickerRepositoryGenerationID = UUID()
    private var animationRepositoryGenerationID = UUID()
    private var animationSearchRequestID = UUID()
    private var emojiSearchRequestID = UUID()
    private var mediaTasks: [Int64: Task<Data, Error>] = [:]
    private var mediaURLTasks: [Int64: Task<URL, Error>] = [:]
    private var dataCache: [Int64: Data] = [:]
    private var customEmojiImageCache: [Int64: UIImage] = [:]
    private var customEmojiImageCacheOrder: [Int64] = []
    private var dataCacheOrder: [Int64] = []
    private var dataCacheBytes = 0
    private let maxDataCacheBytes = 50 * 1_024 * 1_024

    private static let draftsKey = "krochat.drafts.v1"
    private static let hiddenKey = "krochat.hidden.v1"
    private static let foldersKey = "krochat.folders.v1"
    private static let recentEmojisKey = "krogram.recentEmojis.v1"
    private static let downloadQueueKey = "krogram.downloadQueue.v1"
    private static let uploadQueueKey = "krogram.uploadQueue.v1"
    private static let maxRecentEmojis = 32
    private static let maxDrafts = 100

    init(repository: ChatRepository, privacy: PrivacyMode? = nil, defaults: UserDefaults = .standard) {
        self.repository = repository
        let privacy = privacy ?? .shared
        self.privacy = privacy
        self.defaults = defaults
        let storedDrafts = (defaults.dictionary(forKey: Self.draftsKey) as? [String: String]) ?? [:]
        var restored: [Int64: String] = [:]
        for (key, value) in storedDrafts {
            if let id = Int64(key) { restored[id] = value }
        }
        drafts = restored
        recentEmojis = Array((defaults.stringArray(forKey: Self.recentEmojisKey) ?? []).prefix(Self.maxRecentEmojis))
        downloadQueue = (try? JSONDecoder().decode(
            [DownloadRecord].self,
            from: defaults.data(forKey: Self.downloadQueueKey) ?? Data()
        )) ?? []
        for index in downloadQueue.indices where downloadQueue[index].status == .downloading {
            downloadQueue[index].status = .paused
        }
        uploadQueue = (try? JSONDecoder().decode(
            [UploadRecord].self,
            from: defaults.data(forKey: Self.uploadQueueKey) ?? Data()
        )) ?? []
        hiddenIDs = Set((defaults.array(forKey: Self.hiddenKey) as? [NSNumber] ?? []).map(\.int64Value))
        if let data = defaults.data(forKey: Self.foldersKey),
           let decoded = try? JSONDecoder().decode([ChatFolder].self, from: data) {
            folders = decoded
        }
        privacy.onChange = { [weak self] in self?.pushPrivacy() }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let connection: NetworkConnectionKind
            if path.status != .satisfied {
                connection = .offline
            } else if path.usesInterfaceType(.wifi) {
                connection = .wifi
            } else if path.usesInterfaceType(.cellular) {
                connection = .cellular
            } else {
                connection = .other
            }
            Task { @MainActor [weak self] in self?.networkConnection = connection }
        }
        networkMonitor.start(queue: networkQueue)
        startEvents()
    }

    var isLive: Bool { repository.isReal }
    var canDeleteChats: Bool { !repository.isReal }

    func shouldAutoDownload(_ media: MessageMedia) -> Bool {
        guard isLive, media.fileSize <= 10 * 1_024 * 1_024,
              [.photo, .animation, .sticker].contains(media.kind) else { return false }
        switch networkConnection {
        case .wifi:
            return UserDefaults.standard.bool(forKey: "krogram.autoDownload.wifi")
        case .cellular:
            return UserDefaults.standard.bool(forKey: "krogram.autoDownload.cellular")
        case .other, .offline:
            return false
        }
    }

    // MARK: Repository switching

    /// Replaces the data source (demo <-> live) and clears state.
    func attach(_ newRepository: ChatRepository) {
        eventTask?.cancel()
        eventTask = nil
        repository = newRepository
        chats = []
        folders = []
        contacts = []
        stickers = []
        stickerSets = []
        stickerSearchResults = []
        recentStickers = []
        selectedStickerSetStickers = []
        savedAnimations = []
        animationSearchResults = []
        emojiSearchResults = []
        stickerSearchRequestID = UUID()
        stickerRepositoryGenerationID = UUID()
        animationSearchRequestID = UUID()
        animationRepositoryGenerationID = UUID()
        customEmojiImageCache.removeAll()
        customEmojiImageCacheOrder.removeAll()
        loadState = .idle
        contactsLoading = false
        contactsLoaded = false
        stickersLoaded = false
        stickersLoading = false
        isLoadingMoreChats = false
        historyLoading.removeAll()
        initialHistoryLoading.removeAll()
        chatOpenRequests.removeAll()
        historyExhausted.removeAll()
        activeDiscussionChatID = nil
        activeDiscussionMessageIDs.removeAll()
        discussionReplyCountedIDs.removeAll()
        activeDiscussionChannelID = nil
        activeDiscussionPostID = nil
        latestDiscussionMessage = nil
        activeChatID = nil
        activeTopicID = nil
        moreChatsExhausted = false
        mediaProgress.removeAll()
        for task in mediaURLTasks.values { task.cancel() }
        mediaURLTasks.removeAll()
        downloadQueue.removeAll { $0.status == .downloading || $0.status == .queued }
        persistDownloadQueue()
        dataCache.removeAll()
        dataCacheOrder.removeAll()
        dataCacheBytes = 0
        profile = nil
        connection = .ready
        selectedFolderID = nil
        startEvents()
        pushPrivacy()
    }

    func pushPrivacy() {
        let snapshot = privacy.snapshot
        let repo = repository
        Task { await repo.apply(privacy: snapshot) }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        let repo = repository
        Task { await repo.setForeground(foreground) }
    }

    private func startEvents() {
        guard let stream = repository.events else { return }
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    // MARK: Loading

    func load() async {
        guard loadState == .idle || loadState == .failed else { return }
        loadState = .loading
        do {
            let repo = repository
            async let loadedChats = repo.loadChats()
            async let loadedFolders = repo.loadFolders()
            let (c, f) = try await (loadedChats, loadedFolders)
            var merged = c
            if repo.isReal {
                for i in merged.indices where hiddenIDs.contains(merged[i].id) { merged[i].isHidden = true }
            }
            chats = merged
            folders = f
            if !repo.isReal { persistFolders() }
            loadState = .loaded
        } catch {
            mediaError = TGErrors.message(for: error)
            loadState = .failed
        }
    }

    func loadMoreChats() async {
        guard repository.isReal, !isLoadingMoreChats, !moreChatsExhausted else { return }
        isLoadingMoreChats = true
        defer { isLoadingMoreChats = false }
        do {
            let additional = try await repository.loadMoreChats()
            if additional.isEmpty {
                moreChatsExhausted = true
                return
            }
            for var chat in additional where !chats.contains(where: { $0.id == chat.id }) {
                chat.isHidden = hiddenIDs.contains(chat.id)
                chats.append(chat)
            }
        } catch {
            loadState = .failed
        }
    }

    func loadContacts() async {
        guard !contactsLoaded, !contactsLoading else { return }
        contactsLoading = true
        defer { contactsLoading = false }
        do {
            contacts = try await repository.loadContacts()
            contactsLoaded = true
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func reload() async {
        guard loadState != .loading else { return }
        loadState = .idle
        await load()
    }

    // MARK: Queries

    private func sorted(_ list: [Chat]) -> [Chat] {
        list.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.lastDate > b.lastDate
        }
    }

    var mainChats: [Chat] {
        let visible = chats.filter { !$0.isArchived && !$0.isHidden }
        if repository.isReal {
            return orderedLiveChats(visible, archived: false, savedMessagesFirst: true)
        }
        return sorted(visible)
    }
    var totalUnread: Int { mainChats.filter { !$0.isMuted }.reduce(0) { $0 + $1.unread } }

    var visibleChats: [Chat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceChats: [Chat]
        if repository.isReal, selectedFolderID != nil {
            sourceChats = chats.filter { !$0.isHidden }
        } else {
            sourceChats = mainChats
        }
        return sourceChats.filter { chat in
            guard filter.matches(chat), dateFilter.matches(chat.lastDate) else { return false }
            if let folderID = selectedFolderID,
               let folder = folders.first(where: { $0.id == folderID }),
               !belongs(chat, to: folder) { return false }
            if query.isEmpty { return true }
            return chat.title.localizedCaseInsensitiveContains(query)
                || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    func chat(_ id: Int64) -> Chat? { chats.first { $0.id == id } }

    func chats(in scope: ChatScope) -> [Chat] {
        switch scope {
        case .unread: return mainChats.filter { $0.unread > 0 || $0.isMarkedAsUnread }
        case .pinned: return mainChats.filter { $0.isPinned }
        case .archived:
            let archived = chats.filter(\.isArchived)
            return repository.isReal
                ? orderedLiveChats(archived, archived: true)
                : sorted(archived)
        case .hidden:
            let hidden = chats.filter(\.isHidden)
            return repository.isReal ? hidden : sorted(hidden)
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return [] }
            let candidates = repository.isReal ? chats.filter { !$0.isHidden } : mainChats
            return candidates.filter { belongs($0, to: folder) }
        }
    }

    private func orderedLiveChats(
        _ list: [Chat],
        archived: Bool,
        savedMessagesFirst: Bool = false
    ) -> [Chat] {
        list.enumerated().sorted { left, right in
            if savedMessagesFirst, left.element.isSavedMessages != right.element.isSavedMessages {
                return left.element.isSavedMessages
            }
            let leftOrder = archived ? left.element.archiveListOrder : left.element.mainListOrder
            let rightOrder = archived ? right.element.archiveListOrder : right.element.mainListOrder
            if let leftOrder, let rightOrder, leftOrder != rightOrder { return leftOrder > rightOrder }
            if leftOrder != nil, rightOrder == nil { return true }
            if leftOrder == nil, rightOrder != nil { return false }
            return left.offset < right.offset
        }.map(\.element)
    }

    func unreadCount(in folder: ChatFolder) -> Int {
        chats(in: .folder(folder.id)).reduce(0) { $0 + max($1.unread, $1.isMarkedAsUnread ? 1 : 0) }
    }

    private func belongs(_ chat: Chat, to folder: ChatFolder) -> Bool {
        if let telegramID = folder.telegramID {
            return chat.telegramFolderIDs.contains(telegramID)
                || folder.includedChatIDs?.contains(chat.id) == true
                || folder.pinnedChatIDs?.contains(chat.id) == true
        }
        return chat.folderIDs.contains(folder.id)
    }

    func title(for scope: ChatScope) -> String {
        switch scope {
        case .unread: return L("organize.list.unread")
        case .pinned: return L("organize.list.pinned")
        case .archived: return L("organize.list.archived")
        case .hidden: return L("organize.list.hidden")
        case .folder(let id): return folders.first { $0.id == id }?.name ?? ""
        }
    }

    // MARK: Chat actions (all with undo)

    func update(_ ids: Set<Int64>, undoKey: String = "undo.changed", _ change: (inout Chat) -> Void) {
        let before = chats.filter { ids.contains($0.id) }
        guard !before.isEmpty else { return }
        for i in chats.indices where ids.contains(chats[i].id) {
            change(&chats[i])
        }
        persistHidden(for: ids)
        pushRemoteFlags(before: before)
        presentUndo(String(format: L(undoKey), before.count), restore: before)
    }

    /// Demo only. Deleting real chats is intentionally disabled to protect the account.
    func delete(_ ids: Set<Int64>) {
        guard canDeleteChats else { return }
        let before = chats.filter { ids.contains($0.id) }
        guard !before.isEmpty else { return }
        chats.removeAll { ids.contains($0.id) }
        presentUndo(String(format: L("undo.deleted"), before.count), restore: before)
    }

    func undo() {
        guard let banner = undoBanner else { return }
        let ids = Set(banner.restore.map(\.id))
        let current = chats.filter { ids.contains($0.id) }
        for old in banner.restore {
            if let i = chats.firstIndex(where: { $0.id == old.id }) {
                chats[i] = old
            } else {
                chats.append(old)
            }
        }
        persistHidden(for: ids)
        pushRemoteFlags(before: current)
        dismissUndo()
    }

    func dismissUndo() {
        undoTask?.cancel()
        undoBanner = nil
    }

    private func presentUndo(_ text: String, restore: [Chat]) {
        undoTask?.cancel()
        undoBanner = UndoBanner(text: text, restore: restore)
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.undoBanner = nil
        }
    }

    private func persistHidden(for ids: Set<Int64>) {
        guard repository.isReal else { return }
        for chat in chats where ids.contains(chat.id) {
            if chat.isHidden { hiddenIDs.insert(chat.id) } else { hiddenIDs.remove(chat.id) }
        }
        defaults.set(hiddenIDs.map { NSNumber(value: $0) }, forKey: Self.hiddenKey)
    }

    private func persistFolders() {
        guard let encoded = try? JSONEncoder().encode(folders) else { return }
        defaults.set(encoded, forKey: Self.foldersKey)
    }

    /// Pin and archive are real Telegram actions when connected.
    private func pushRemoteFlags(before: [Chat]) {
        guard repository.isReal else { return }
        let repo = repository
        for old in before {
            guard let now = chats.first(where: { $0.id == old.id }) else { continue }
            guard old.isPinned != now.isPinned || old.isArchived != now.isArchived else { continue }
            Task {
                do {
                    if old.isArchived != now.isArchived {
                        try await repo.setArchived(chatID: old.id, archived: now.isArchived)
                    }
                    if old.isPinned != now.isPinned {
                        try await repo.setPinned(
                            chatID: old.id,
                            pinned: now.isPinned,
                            archived: now.isArchived
                        )
                    }
                    mediaError = nil
                } catch {
                    mediaError = TGErrors.message(for: error)
                    await refresh(old.id)
                }
            }
        }
    }

    // MARK: Folders

    func addFolder(name: String, symbol: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !repository.isReal else { return }
        folders.append(ChatFolder(name: String(trimmed.prefix(30)), symbol: symbol))
        persistFolders()
    }

    func saveFolder(name: String, symbol: String, editing folder: ChatFolder? = nil) async -> Bool {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty else { return false }
        var candidate = folder ?? ChatFolder(name: trimmed, symbol: symbol)
        candidate.name = trimmed
        candidate.symbol = symbol

        if repository.isReal {
            do {
                let saved = try await repository.saveFolder(candidate)
                if let index = folders.firstIndex(where: {
                    $0.id == saved.id || (saved.telegramID != nil && $0.telegramID == saved.telegramID)
                }) {
                    folders[index] = saved
                } else {
                    folders.append(saved)
                }
                mediaError = nil
                return true
            } catch {
                mediaError = TGErrors.message(for: error)
                return false
            }
        }

        if let index = folders.firstIndex(where: { $0.id == candidate.id }) {
            folders[index] = candidate
        } else {
            folders.append(candidate)
        }
        persistFolders()
        return true
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        if repository.isReal {
            Task {
                do {
                    try await repository.deleteFolder(folder)
                    removeFolderLocally(id)
                    mediaError = nil
                } catch {
                    mediaError = TGErrors.message(for: error)
                }
            }
            return
        }
        removeFolderLocally(id)
    }

    private func removeFolderLocally(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in chats.indices { chats[i].folderIDs.remove(id) }
        if selectedFolderID == id { selectedFolderID = nil }
        if !repository.isReal { persistFolders() }
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        let old = folders
        let moving = source.sorted().map { folders[$0] }
        for index in source.sorted(by: >) { folders.remove(at: index) }
        let adjustedDestination = max(0, min(folders.count, destination - source.filter { $0 < destination }.count))
        folders.insert(contentsOf: moving, at: adjustedDestination)
        guard repository.isReal else {
            persistFolders()
            return
        }
        let reordered = folders
        Task {
            do {
                try await repository.reorderFolders(reordered)
                mediaError = nil
            } catch {
                folders = old
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    func setFolder(_ folderID: UUID, contains: Bool, for chatID: Int64) {
        if repository.isReal, let folder = folders.first(where: { $0.id == folderID }) {
            Task {
                do {
                    let updated = try await repository.setFolderMembership(folder, chatID: chatID, contains: contains)
                    if let index = folders.firstIndex(where: { $0.id == folderID }) { folders[index] = updated }
                    if !contains { mutateChat(chatID) { $0.telegramFolderIDs.remove(updated.telegramID ?? 0) } }
                    mediaError = nil
                } catch {
                    mediaError = TGErrors.message(for: error)
                }
            }
            return
        }
        mutateChat(chatID) { chat in
            if contains { chat.folderIDs.insert(folderID) } else { chat.folderIDs.remove(folderID) }
        }
    }

    func setMuted(_ chatID: Int64, duration: Int32) {
        guard repository.isReal else {
            mutateChat(chatID) { $0.isMuted = duration > 0 }
            return
        }
        Task {
            do {
                try await repository.setMuted(chatID: chatID, duration: duration)
                mutateChat(chatID) { $0.isMuted = duration > 0 }
                mediaError = nil
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    func loadChatNotificationSettings(_ chatID: Int64) async -> ChatNotificationSettings? {
        do {
            let settings = try await repository.loadNotificationSettings(chatID: chatID)
            mediaError = nil
            return settings
        } catch {
            mediaError = TGErrors.message(for: error)
            return nil
        }
    }

    func saveChatNotificationSettings(_ chatID: Int64, settings: ChatNotificationSettings) async -> Bool {
        do {
            try await repository.saveNotificationSettings(chatID: chatID, settings: settings)
            mutateChat(chatID) { chat in
                chat.notificationSettings = settings
                chat.isMuted = settings.muteFor > 0
            }
            mediaError = nil
            return true
        } catch {
            mediaError = TGErrors.message(for: error)
            return false
        }
    }

    func setMarkedUnread(_ chatID: Int64, marked: Bool) {
        guard repository.isReal else {
            mutateChat(chatID) { $0.isMarkedAsUnread = marked }
            return
        }
        Task {
            do {
                try await repository.setMarkedUnread(chatID: chatID, marked: marked)
                mutateChat(chatID) { $0.isMarkedAsUnread = marked }
                mediaError = nil
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    // MARK: Opening chats / read state

    private func mutateChat(_ id: Int64, _ change: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[i])
    }

    private func message(_ id: UUID, in chatID: Int64) -> Message? {
        chat(chatID)?.messages.first { $0.id == id }
            ?? messageSearchResults[chatID]?.first { $0.id == id }
    }

    func replyTarget(for message: Message, in chatID: Int64) async -> Message? {
        if let localID = message.replyToID, let target = self.message(localID, in: chatID) {
            return target
        }
        guard let remoteID = message.replyToRemoteID else { return nil }
        if let target = chat(chatID)?.messages.first(where: { $0.remoteID == remoteID }) {
            return target
        }
        do {
            guard let target = try await repository.loadMessage(chatID: chatID, messageID: remoteID) else {
                return nil
            }
            mutateChat(chatID) { chat in
                guard !chat.messages.contains(where: { $0.remoteID == remoteID }) else { return }
                chat.messages.append(target)
                chat.messages.sort { $0.date < $1.date }
            }
            return target
        } catch {
            mediaError = TGErrors.message(for: error)
            return nil
        }
    }

    private func mutateMessage(_ id: UUID, in chatID: Int64, _ change: (inout Message) -> Void) {
        if let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == id }) {
            change(&chats[chatIndex].messages[messageIndex])
            return
        }
        guard var results = messageSearchResults[chatID],
              let index = results.firstIndex(where: { $0.id == id }) else { return }
        change(&results[index])
        messageSearchResults[chatID] = results
    }

    func openChat(_ id: Int64, topicID: Int64? = nil) async {
        let requestID = UUID()
        activeChatID = id
        activeTopicID = topicID
        chatOpenRequests[id] = requestID
        initialHistoryLoading.insert(id)
        defer {
            if chatOpenRequests[id] == requestID {
                chatOpenRequests[id] = nil
                initialHistoryLoading.remove(id)
            }
        }
        let repo = repository
        await repo.setChatOpen(id, true)
        guard isCurrentOpenRequest(requestID, chatID: id, topicID: topicID) else { return }
        if topicID == nil, chat(id)?.isForum == true { return }
        if topicID != nil {
            historyExhausted.remove(id)
        }
        if topicID == nil, repo.isReal, (chat(id)?.kind == .channel || chat(id)?.kind == .group) {
            do {
                if let fresh = try await repo.refreshChat(id) {
                    guard isCurrentOpenRequest(requestID, chatID: id, topicID: topicID) else { return }
                    mergeRefreshedChat(fresh, id: id)
                }
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
        guard isCurrentOpenRequest(requestID, chatID: id, topicID: topicID) else { return }
        if topicID == nil, chat(id)?.isForum == true { return }
        if topicID != nil {
            mutateChat(id) { chat in
                chat.messages = chat.messages.filter {
                    $0.remoteID == nil && $0.isOutgoing && $0.state != .sent
                }
            }
        }
        let history: [Message]?
        do {
            if let topicID {
                history = try await repo.loadForumTopicHistory(chatID: id, topicID: topicID, limit: 50)
            } else {
                history = try await repo.loadHistory(chatID: id)
            }
        } catch {
            mediaError = TGErrors.message(for: error)
            history = nil
        }
        guard isCurrentOpenRequest(requestID, chatID: id, topicID: topicID) else { return }
        if let history, !history.isEmpty || topicID != nil {
            mutateChat(id) { chat in
                let pending = chat.messages.filter { $0.remoteID == nil && $0.isOutgoing && $0.state != .sent }
                chat.messages = Array((history + pending).suffix(200))
            }
            if history.count < 50 { historyExhausted.insert(id) }
        }
        if !privacy.hideRead { await markReadNow(id, topicID: topicID) }
    }

    func loadChat(_ id: Int64) async {
        do {
            guard let fresh = try await repository.refreshChat(id) else { return }
            mergeRefreshedChat(fresh, id: id)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func closeChat(_ id: Int64) {
        if activeChatID == id {
            activeChatID = nil
            activeTopicID = nil
            chatOpenRequests[id] = nil
            initialHistoryLoading.remove(id)
        }
        let repo = repository
        Task { await repo.setChatOpen(id, false) }
        mutateChat(id) { chat in
            let latest = chat.messages.last
            let pending = chat.messages.filter { $0.remoteID == nil && $0.isOutgoing && $0.state != .sent }.suffix(50)
            chat.messages = (latest.map { [$0] } ?? []) + pending.filter { $0.id != latest?.id }
        }
    }

    func loadOlderHistory(chatID: Int64, topicID: Int64? = nil) async {
        guard isForeground, activeChatID == chatID, activeTopicID == topicID,
              !initialHistoryLoading.contains(chatID),
              repository.isReal, !historyExhausted.contains(chatID),
              !historyLoading.contains(chatID),
              let first = chat(chatID)?.messages.first(where: { $0.remoteID != nil }),
              let remoteID = first.remoteID else { return }
        historyLoading.insert(chatID)
        defer { historyLoading.remove(chatID) }
        do {
            let older: [Message]?
            if let topicID {
                older = try await repository.loadOlderForumTopicHistory(
                    chatID: chatID,
                    topicID: topicID,
                    before: remoteID
                )
            } else {
                older = try await repository.loadOlderHistory(chatID: chatID, before: remoteID)
            }
            guard let older else { return }
            guard isForeground, activeChatID == chatID, activeTopicID == topicID else { return }
            if older.count < 50 { historyExhausted.insert(chatID) }
            guard !older.isEmpty else { return }
            mutateChat(chatID) { chat in
                let existingIDs = Set(chat.messages.compactMap(\.remoteID))
                let unique = older.filter { message in
                    guard let id = message.remoteID else { return true }
                    return !existingIDs.contains(id)
                }
                chat.messages = Array((unique + chat.messages).suffix(200))
            }
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func loadMyProfile() async {
        guard !profileLoading else { return }
        profileLoading = true
        defer { profileLoading = false }
        do {
            profile = try await repository.loadMyProfile()
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func updateMyProfile(firstName: String, lastName: String, bio: String) async throws {
        do {
            try await repository.updateMyProfile(firstName: firstName, lastName: lastName, bio: bio)
            profile = try await repository.loadMyProfile()
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func loadChatProfile(chatID: Int64) async throws -> ChatProfile? {
        try await repository.loadChatProfile(chatID: chatID)
    }

    func createGroup(title: String, memberIDs: [Int64], photoPath: String?) async throws -> GroupCreationResult {
        try await repository.createGroup(title: title, memberIDs: memberIDs, photoPath: photoPath)
    }

    func loadGroupManagementInfo(chatID: Int64) async throws -> GroupManagementInfo {
        try await repository.loadGroupManagementInfo(chatID: chatID)
    }

    func loadMoreGroupMembers(chatID: Int64, offset: Int) async throws -> GroupMembersPage {
        try await repository.loadMoreGroupMembers(chatID: chatID, offset: offset)
    }

    func addGroupMembers(chatID: Int64, userIDs: [Int64]) async throws {
        try await repository.addGroupMembers(chatID: chatID, userIDs: userIDs)
    }

    func updateGroupMember(
        chatID: Int64,
        userID: Int64,
        status: GroupMemberStatus,
        adminRights: GroupAdminRights? = nil
    ) async throws {
        try await repository.updateGroupMember(
            chatID: chatID,
            userID: userID,
            status: status,
            adminRights: adminRights
        )
    }

    func createGroupInviteLink(chatID: Int64) async throws -> String {
        try await repository.createGroupInviteLink(chatID: chatID)
    }

    func upgradeBasicGroup(chatID: Int64) async throws -> Int64 {
        try await repository.upgradeBasicGroup(chatID: chatID)
    }

    func leaveGroup(chatID: Int64) async throws {
        try await repository.leaveGroup(chatID: chatID)
    }

    func createChannel(title: String, description: String, photoPath: String?) async throws -> ChannelCreationResult {
        try await repository.createChannel(title: title, description: description, photoPath: photoPath)
    }

    func loadChannelManagementInfo(chatID: Int64) async throws -> ChannelManagementInfo {
        try await repository.loadChannelManagementInfo(chatID: chatID)
    }

    func joinChannel(identifier: String) async throws -> Int64 {
        try await repository.joinChannel(identifier: identifier)
    }

    func leaveChannel(chatID: Int64) async throws {
        try await repository.leaveChannel(chatID: chatID)
    }

    func loadForumTopics(chatID: Int64) async throws -> [ForumTopic] {
        try await repository.loadForumTopics(chatID: chatID)
    }

    func createForumTopic(chatID: Int64, name: String) async throws {
        try await repository.createForumTopic(chatID: chatID, name: name)
    }

    func editForumTopic(chatID: Int64, topicID: Int64, name: String) async throws {
        try await repository.editForumTopic(chatID: chatID, topicID: topicID, name: name)
    }

    func setForumTopicClosed(chatID: Int64, topicID: Int64, closed: Bool) async throws {
        try await repository.setForumTopicClosed(chatID: chatID, topicID: topicID, closed: closed)
    }

    func loadDiscussionThread(chatID: Int64, messageID: Int64) async throws -> DiscussionThreadPage {
        try await repository.loadDiscussionThread(chatID: chatID, messageID: messageID, limit: 50)
    }

    func loadOlderDiscussionComments(
        chatID: Int64,
        messageID: Int64,
        discussionChatID: Int64,
        threadMessageID: Int64,
        before replyMessageID: Int64
    ) async throws -> [Message] {
        try await repository.loadOlderDiscussionComments(
            chatID: chatID,
            messageID: messageID,
            discussionChatID: discussionChatID,
            threadMessageID: threadMessageID,
            before: replyMessageID
        )
    }

    func markDiscussionCommentsRead(_ messages: [Message], in discussionChatID: Int64) async throws {
        guard !privacy.hideRead else { return }
        let ids = messages.compactMap(\.remoteID)
        guard !ids.isEmpty else { return }
        try await repository.markRead(chatID: discussionChatID, remoteIDs: Array(ids.suffix(100)))
    }

    func openDiscussionThread(_ thread: DiscussionThreadPage, channelID: Int64, postID: Int64) async {
        let alreadyOpen = activeDiscussionChatID == thread.chatID
            && activeDiscussionMessageIDs.contains(thread.threadMessageID)
        let knownMessages = alreadyOpen ? activeDiscussionMessageIDs : []
        if !alreadyOpen { discussionReplyCountedIDs.removeAll() }
        activeDiscussionChatID = thread.chatID
        activeDiscussionMessageIDs = knownMessages.union(
            [thread.threadMessageID] + thread.messages.compactMap(\.remoteID)
        )
        activeDiscussionChannelID = channelID
        activeDiscussionPostID = postID
        if !alreadyOpen {
            latestDiscussionMessage = nil
            await repository.setChatOpen(thread.chatID, true)
        }
    }

    func registerDiscussionMessages(_ messages: [Message]) {
        guard activeDiscussionChatID != nil else { return }
        activeDiscussionMessageIDs.formUnion(messages.compactMap(\.remoteID))
    }

    func closeDiscussionThread() {
        guard let discussionChatID = activeDiscussionChatID else { return }
        activeDiscussionChatID = nil
        activeDiscussionMessageIDs.removeAll()
        discussionReplyCountedIDs.removeAll()
        activeDiscussionChannelID = nil
        activeDiscussionPostID = nil
        latestDiscussionMessage = nil
        let repo = repository
        Task { await repo.setChatOpen(discussionChatID, false) }
    }

    func sendDiscussionComment(chatID: Int64, threadMessageID: Int64, text: String) async throws -> Message {
        try await repository.sendDiscussionComment(chatID: chatID, threadMessageID: threadMessageID, text: text)
    }

    func recordDiscussionReply(_ message: Message, channelID: Int64, postID: Int64) {
        guard let replyID = message.remoteID,
              discussionReplyCountedIDs.insert(replyID).inserted else { return }
        incrementDiscussionReplyCount(chatID: channelID, messageID: postID)
    }

    private func incrementDiscussionReplyCount(chatID: Int64, messageID: Int64) {
        mutateChat(chatID) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.remoteID == messageID }),
                  let count = chat.messages[index].replyCount else { return }
            chat.messages[index].replyCount = count + 1
        }
    }

    func setMediaError(_ message: String?) {
        mediaError = message
    }

    func cachedFileData(fileID: Int64) -> Data? {
        guard let data = dataCache[fileID] else { return nil }
        dataCacheOrder.removeAll { $0 == fileID }
        dataCacheOrder.append(fileID)
        return data
    }

    func cacheFileURL(fileID: Int64, data: Data, fileName: String?, mimeType: String?) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionName = Self.safeExtension(fileName: fileName, mimeType: mimeType)
        let destination = directory.appendingPathComponent("\(fileID).\(extensionName)")
        try data.write(to: destination, options: .atomic)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        var entries: [(url: URL, size: Int, modified: Date)] = []
        for url in files where url != destination {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = data.count + entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) where total > maxDataCacheBytes {
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
        return destination
    }

    private static func safeExtension(fileName: String?, mimeType: String?) -> String {
        if let ext = fileName.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() }),
           !ext.isEmpty, ext.count <= 8,
           ext.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil {
            return ext
        }
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "video/mp4": return "mp4"
        case "audio/mpeg": return "mp3"
        case "audio/ogg": return "ogg"
        default: return "bin"
        }
    }

    func downloadFileURL(
        fileID: Int64,
        title: String,
        fileSize: Int64,
        mediaKind: MessageMediaKind? = nil,
        limit: Int64 = 1_073_741_824
    ) async throws -> URL {
        if let existing = mediaURLTasks[fileID] { return try await existing.value }
        let repo = repository
        updateDownload(fileID: fileID) { record in
            record.title = title.isEmpty ? record.title : title
            record.totalBytes = max(record.totalBytes, fileSize)
            record.mediaKind = mediaKind ?? record.mediaKind
            record.status = .downloading
            record.errorMessage = nil
        } create: {
            DownloadRecord(
                fileID: fileID,
                title: title,
                totalBytes: fileSize,
                downloadedBytes: 0,
                status: .downloading,
                mediaKind: mediaKind,
                localPath: nil,
                errorMessage: nil
            )
        }
        let task = Task<URL, Error> {
            try await withTaskCancellationHandler {
                try await repo.downloadFileURL(fileID: fileID, limit: limit)
            } onCancel: {
                Task { try? await repo.cancelFileDownload(fileID: fileID) }
            }
        }
        mediaURLTasks[fileID] = task
        do {
            let url = try await task.value
            mediaURLTasks[fileID] = nil
            updateDownload(fileID: fileID) { record in
                record.status = .completed
                record.localPath = url.path
                record.errorMessage = nil
                if record.totalBytes == 0 {
                    record.totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                }
                record.downloadedBytes = record.totalBytes
            }
            mediaProgress[fileID] = nil
            return url
        } catch {
            mediaURLTasks[fileID] = nil
            updateDownload(fileID: fileID) { record in
                if record.status != .paused && record.status != .cancelled {
                    record.status = error is CancellationError ? .paused : .failed
                }
                if !(error is CancellationError) { record.errorMessage = TGErrors.message(for: error) }
            }
            throw error
        }
    }

    func pauseDownload(fileID: Int64) {
        updateDownload(fileID: fileID) { $0.status = .paused }
        mediaURLTasks[fileID]?.cancel()
    }

    func resumeDownload(fileID: Int64) {
        guard let record = downloadQueue.first(where: { $0.fileID == fileID }) else { return }
        updateDownload(fileID: fileID) { $0.status = .queued }
        Task {
            _ = try? await downloadFileURL(
                fileID: record.fileID,
                title: record.title,
                fileSize: record.totalBytes,
                mediaKind: record.mediaKind
            )
        }
    }

    func cancelDownload(fileID: Int64) {
        updateDownload(fileID: fileID) { $0.status = .cancelled }
        if let task = mediaURLTasks[fileID] {
            task.cancel()
        } else {
            let repo = repository
            Task { try? await repo.cancelFileDownload(fileID: fileID) }
        }
    }

    func removeDownload(fileID: Int64) {
        mediaURLTasks[fileID]?.cancel()
        downloadQueue.removeAll { $0.fileID == fileID }
        persistDownloadQueue()
    }

    private func updateDownload(
        fileID: Int64,
        change: (inout DownloadRecord) -> Void,
        create: (() -> DownloadRecord)? = nil
    ) {
        if let index = downloadQueue.firstIndex(where: { $0.fileID == fileID }) {
            change(&downloadQueue[index])
        } else if let create {
            downloadQueue.insert(create(), at: 0)
            if downloadQueue.count > 100 { downloadQueue.removeLast() }
        }
        persistDownloadQueue()
    }

    private func persistDownloadQueue() {
        guard let data = try? JSONEncoder().encode(downloadQueue) else { return }
        defaults.set(data, forKey: Self.downloadQueueKey)
    }

    private func persistUploadQueue() {
        guard let data = try? JSONEncoder().encode(uploadQueue) else { return }
        defaults.set(data, forKey: Self.uploadQueueKey)
    }

    func cancelUpload(fileID: Int64) async {
        guard let record = uploadQueue.first(where: { $0.fileID == fileID }),
              record.status == .uploading else { return }
        do {
            try await repository.cancelUpload(
                fileID: record.fileID,
                chatID: record.chatID,
                messageID: record.messageID
            )
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func removeUploadRecord(fileID: Int64) {
        guard let record = uploadQueue.first(where: { $0.fileID == fileID }),
              record.status != .uploading else { return }
        removeOutgoingUploadFile(at: record.sourcePath)
        uploadQueue.removeAll { $0.fileID == fileID }
        persistUploadQueue()
    }

    func downloadFile(fileID: Int64, limit: Int64) async throws -> Data {
        if let cached = cachedFileData(fileID: fileID) { return cached }
        if let existing = mediaTasks[fileID] { return try await existing.value }
        mediaError = nil
        let repo = repository
        let task = Task<Data, Error> {
            try await withTaskCancellationHandler {
                try await repo.downloadFileData(fileID: fileID, limit: limit)
            } onCancel: {
                Task {
                    do {
                        try await repo.cancelFileDownload(fileID: fileID)
                    } catch {
                        await MainActor.run { self.mediaError = TGErrors.message(for: error) }
                    }
                }
            }
        }
        mediaTasks[fileID] = task
        do {
            let data = try await task.value
            mediaTasks[fileID] = nil
            cache(data, for: fileID)
            mediaProgress[fileID] = nil
            mediaError = nil
            return data
        } catch {
            mediaTasks[fileID] = nil
            if !(error is CancellationError) { mediaError = TGErrors.message(for: error) }
            throw error
        }
    }

    func cancelFileDownload(fileID: Int64) {
        if mediaURLTasks[fileID] != nil {
            cancelDownload(fileID: fileID)
            return
        }
        mediaTasks[fileID]?.cancel()
        mediaProgress[fileID] = nil
    }

    private func cache(_ data: Data, for fileID: Int64) {
        guard data.count <= maxDataCacheBytes else { return }
        if let old = dataCache[fileID] { dataCacheBytes -= old.count }
        dataCache[fileID] = data
        dataCacheBytes += data.count
        dataCacheOrder.removeAll { $0 == fileID }
        dataCacheOrder.append(fileID)
        while dataCacheBytes > maxDataCacheBytes, let oldest = dataCacheOrder.first {
            dataCacheOrder.removeFirst()
            dataCacheBytes -= dataCache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    func sendPhoto(path: String, caption: String, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendPhoto(chatID: chatID, path: path, caption: caption, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendVideo(path: String, caption: String, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendVideo(chatID: chatID, path: path, caption: caption, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendMediaAlbum(
        _ items: [OutgoingAlbumMedia],
        caption: String,
        to chatID: Int64,
        topicID: Int64? = nil
    ) async throws {
        do {
            try await repository.sendMediaAlbum(chatID: chatID, items: items, caption: caption, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendVideoNote(path: String, duration: Int, length: Int, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendVideoNote(
                chatID: chatID, path: path, duration: duration, length: length, topicID: topicID
            )
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendVoiceNote(path: String, duration: Int, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendVoiceNote(chatID: chatID, path: path, duration: duration, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendPoll(
        question: String,
        options: [String],
        isAnonymous: Bool,
        allowsMultipleAnswers: Bool,
        to chatID: Int64,
        topicID: Int64? = nil
    ) async throws {
        do {
            try await repository.sendPoll(
                chatID: chatID,
                question: question,
                options: options,
                isAnonymous: isAnonymous,
                allowsMultipleAnswers: allowsMultipleAnswers,
                topicID: topicID
            )
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendContact(
        firstName: String,
        lastName: String,
        phoneNumber: String,
        to chatID: Int64,
        topicID: Int64? = nil
    ) async throws {
        do {
            try await repository.sendContact(
                chatID: chatID,
                firstName: firstName,
                lastName: lastName,
                phoneNumber: phoneNumber,
                topicID: topicID
            )
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendLocation(latitude: Double, longitude: Double, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendLocation(
                chatID: chatID, latitude: latitude, longitude: longitude, topicID: topicID
            )
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func loadStickers() async {
        guard isLive, !stickersLoaded, !stickersLoading else { return }
        stickersLoading = true
        defer { stickersLoading = false }
        do {
            stickers = try await repository.loadStickers()
            stickersLoaded = !stickers.isEmpty
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func loadStickerSets() async {
        guard isLive, stickerSets.isEmpty else { return }
        let generationID = stickerRepositoryGenerationID
        do {
            let result = try await repository.loadStickerSets()
            guard generationID == stickerRepositoryGenerationID else { return }
            stickerSets = result.filter { $0.isInstalled && !$0.isArchived }
            mediaError = nil
        } catch {
            guard generationID == stickerRepositoryGenerationID else { return }
            mediaError = TGErrors.message(for: error)
        }
    }

    func searchStickerSets(query: String) async {
        guard isLive else { return }
        let requestID = UUID()
        stickerSearchRequestID = requestID
        do {
            let results = try await repository.searchStickerSets(query: query)
            guard requestID == stickerSearchRequestID else { return }
            stickerSearchResults = results
            mediaError = nil
        } catch {
            guard requestID == stickerSearchRequestID else { return }
            mediaError = TGErrors.message(for: error)
        }
    }

    func clearStickerSearch() {
        stickerSearchRequestID = UUID()
        stickerSearchResults = []
    }

    func loadStickers(setID: Int64) async {
        selectedStickerSetStickers = []
        do {
            selectedStickerSetStickers = try await repository.loadStickers(setID: setID)
            mediaError = nil
        } catch {
            selectedStickerSetStickers = []
            mediaError = TGErrors.message(for: error)
        }
    }

    func loadRecentStickers() async {
        do {
            recentStickers = try await repository.loadRecentStickers()
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func loadSavedAnimations() async {
        guard isLive, savedAnimations.isEmpty else { return }
        let generationID = animationRepositoryGenerationID
        do {
            let animations = try await repository.loadSavedAnimations()
            guard generationID == animationRepositoryGenerationID else { return }
            savedAnimations = animations
            mediaError = nil
        } catch {
            guard generationID == animationRepositoryGenerationID else { return }
            mediaError = TGErrors.message(for: error)
        }
    }

    func searchAnimations(query: String, in chatID: Int64) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        animationSearchRequestID = requestID
        guard isLive, !normalized.isEmpty else {
            animationSearchResults = []
            return
        }
        let generationID = animationRepositoryGenerationID
        do {
            let results = try await repository.searchAnimations(chatID: chatID, query: normalized)
            guard requestID == animationSearchRequestID, generationID == animationRepositoryGenerationID else { return }
            animationSearchResults = results
            mediaError = nil
        } catch {
            guard requestID == animationSearchRequestID, generationID == animationRepositoryGenerationID else { return }
            animationSearchResults = []
            mediaError = TGErrors.message(for: error)
        }
    }

    func saveAnimation(_ animation: TelegramAnimation, saved: Bool) async {
        do {
            try await repository.setAnimationSaved(animation, saved: saved)
            savedAnimations.removeAll { $0.fileID == animation.fileID }
            if saved { savedAnimations.insert(animation, at: 0) }
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func sendAnimation(_ animation: TelegramAnimation, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendAnimation(chatID: chatID, animation: animation, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendInlineAnimation(_ animation: TelegramAnimation, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendInlineAnimation(chatID: chatID, animation: animation, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func searchEmojis(query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        emojiSearchRequestID = requestID
        guard isLive, !normalized.isEmpty else {
            emojiSearchResults = []
            return
        }
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        do {
            let results = try await repository.searchEmojis(query: normalized, languageCodes: [languageCode])
            guard requestID == emojiSearchRequestID else { return }
            emojiSearchResults = results
            mediaError = nil
        } catch {
            guard requestID == emojiSearchRequestID else { return }
            emojiSearchResults = []
            mediaError = TGErrors.message(for: error)
        }
    }

    func recordRecentEmoji(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        recentEmojis.removeAll { $0 == emoji }
        recentEmojis.insert(emoji, at: 0)
        if recentEmojis.count > Self.maxRecentEmojis {
            recentEmojis = Array(recentEmojis.prefix(Self.maxRecentEmojis))
        }
        defaults.set(recentEmojis, forKey: Self.recentEmojisKey)
    }

    func loadCustomEmojiImages(ids: [Int64]) async -> [Int64: UIImage] {
        let missingIDs = Array(Set(ids)).filter { customEmojiImageCache[$0] == nil }
        guard !missingIDs.isEmpty else {
            return customEmojiImageCache.filter { ids.contains($0.key) }
        }
        do {
            let dataByID = try await repository.loadCustomEmojiImages(ids: missingIDs)
            for (customEmojiID, data) in dataByID {
                guard let image = UIImage(data: data) else { continue }
                customEmojiImageCache[customEmojiID] = image
                customEmojiImageCacheOrder.removeAll { $0 == customEmojiID }
                customEmojiImageCacheOrder.append(customEmojiID)
                if customEmojiImageCacheOrder.count > 96 {
                    customEmojiImageCache.removeValue(forKey: customEmojiImageCacheOrder.removeFirst())
                }
            }
        } catch {
            return customEmojiImageCache.filter { ids.contains($0.key) }
        }
        return customEmojiImageCache.filter { ids.contains($0.key) }
    }

    func setStickerSetInstalled(_ set: TelegramStickerSet, installed: Bool) async {
        do {
            try await repository.setStickerSetInstalled(setID: set.id, installed: installed)
            let refreshedSets = try await repository.loadStickerSets()
            stickerSets = refreshedSets.filter { $0.isInstalled && !$0.isArchived }
            stickerSearchResults = stickerSearchResults.map { item in
                guard item.id == set.id else { return item }
                return TelegramStickerSet(
                    id: item.id,
                    title: item.title,
                    name: item.name,
                    stickerCount: item.stickerCount,
                    isInstalled: installed,
                    isArchived: false
                )
            }
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func sendSticker(_ sticker: TelegramSticker, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendSticker(chatID: chatID, sticker: sticker, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func sendDocument(path: String, caption: String, to chatID: Int64, topicID: Int64? = nil) async throws {
        do {
            try await repository.sendDocument(chatID: chatID, path: path, caption: caption, topicID: topicID)
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
            throw error
        }
    }

    func clearMediaCache(kind: MessageMediaKind? = nil) async {
        let affectedIDs = Set(downloadQueue.filter { kind == nil || $0.mediaKind == kind }.map(\.fileID))
        for (fileID, task) in mediaURLTasks where kind == nil || affectedIDs.contains(fileID) {
            task.cancel()
            updateDownload(fileID: fileID) { $0.status = .paused }
        }
        do {
            try await repository.clearMediaCache(kind: kind)
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KroGram/Media", isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                if kind == nil {
                    try FileManager.default.removeItem(at: directory)
                } else {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    for url in files {
                        if let fileID = Int64(url.deletingPathExtension().lastPathComponent), affectedIDs.contains(fileID) {
                            try FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
            let removedIDs = kind == nil ? Set(dataCache.keys) : affectedIDs
            for fileID in removedIDs {
                dataCacheBytes -= dataCache.removeValue(forKey: fileID)?.count ?? 0
                dataCacheOrder.removeAll { $0 == fileID }
            }
            mediaProgress = mediaProgress.filter { !removedIDs.contains($0.key) }
            downloadQueue.removeAll { kind == nil || $0.mediaKind == kind }
            persistDownloadQueue()
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    /// Sends a read receipt for incoming messages (explicit user action or ghost mode off).
    func markReadNow(_ id: Int64, topicID: Int64? = nil) async {
        guard topicID == nil || (activeChatID == id && activeTopicID == topicID) else { return }
        guard let chat = chat(id) else { return }
        let ids = chat.messages.compactMap(\.remoteID).suffix(50)
        guard !ids.isEmpty else { return }
        do {
            try await repository.markRead(chatID: id, remoteIDs: Array(ids))
            if topicID == nil {
                mutateChat(id) { $0.unread = 0 }
                if chat.isMarkedAsUnread { setMarkedUnread(id, marked: false) }
            }
            mediaError = nil
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    func userTyped(_ chatID: Int64) {
        guard repository.isReal, !privacy.hideTyping else { return }
        let now = Date()
        if let last = lastTyping[chatID], now.timeIntervalSince(last) < 4 { return }
        lastTyping[chatID] = now
        let repo = repository
        Task { await repo.sendTyping(chatID: chatID) }
    }

    // MARK: Live events

    func apply(_ event: ChatEvent) {
        switch event {
        case .chatChanged(let id):
            Task { await refresh(id) }

        case .newMessage(let chatID, let message):
            if activeDiscussionChatID == chatID,
               let replyID = message.replyToRemoteID,
               activeDiscussionMessageIDs.contains(replyID),
               message.remoteID.map({ !activeDiscussionMessageIDs.contains($0) }) ?? true {
                latestDiscussionMessage = message
                if let remoteID = message.remoteID { activeDiscussionMessageIDs.insert(remoteID) }
                if let channelID = activeDiscussionChannelID,
                   let postID = activeDiscussionPostID {
                    recordDiscussionReply(message, channelID: channelID, postID: postID)
                }
                return
            }
            guard let ci = chats.firstIndex(where: { $0.id == chatID }) else {
                Task {
                    await refresh(chatID)
                    if let chat = self.chat(chatID) { self.notifyIncoming(message, for: chat) }
                }
                return
            }
            if let remote = message.remoteID, chats[ci].messages.contains(where: { $0.remoteID == remote }) { return }
            if activeChatID == chatID, chats[ci].isForum {
                guard let activeTopicID, message.topicID == activeTopicID else { return }
            }
            if message.isOutgoing,
               let pi = chats[ci].messages.firstIndex(where: { $0.remoteID == nil && $0.state == .sending && $0.text == message.text }) {
                chats[ci].messages[pi].remoteID = message.remoteID
                return
            }
            if activeChatID == chatID {
                chats[ci].messages.append(message)
                chats[ci].messages = Array(chats[ci].messages.suffix(200))
            } else {
                let pending = chats[ci].messages.filter {
                    $0.remoteID == nil && $0.isOutgoing && $0.state != .sent
                }.suffix(50)
                chats[ci].messages = [message] + pending
            }
            notifyIncoming(message, for: chats[ci])

        case .messageContent(let chatID, let remoteID, let text):
            mutateChat(chatID) { chat in
                if let i = chat.messages.firstIndex(where: { $0.remoteID == remoteID }) {
                    chat.messages[i].text = text
                    chat.messages[i].isEdited = true
                }
            }

        case .messageEdited(let chatID, let remoteID):
            mutateChat(chatID) { chat in
                if let index = chat.messages.firstIndex(where: { $0.remoteID == remoteID }) {
                    chat.messages[index].isEdited = true
                }
            }

        case .messagePinned(let chatID, let remoteID, let isPinned):
            mutateChat(chatID) { chat in
                guard let index = chat.messages.firstIndex(where: { $0.remoteID == remoteID }) else { return }
                chat.messages[index].isPinned = isPinned
            }

        case .messageReactions(let chatID, let remoteID, let all, let chosen, let viewCount, let replyCount):
            mutateChat(chatID) { chat in
                guard let index = chat.messages.firstIndex(where: { $0.remoteID == remoteID }) else { return }
                chat.messages[index].reactions = all
                chat.messages[index].chosenReactions = chosen
                if let viewCount {
                    chat.messages[index].viewCount = viewCount
                }
                if let replyCount {
                    chat.messages[index].replyCount = replyCount
                }
            }

        case .pollUpdated(let poll):
            guard let pollID = poll.remoteID else { return }
            for chatIndex in chats.indices {
                for messageIndex in chats[chatIndex].messages.indices
                    where chats[chatIndex].messages[messageIndex].poll?.remoteID == pollID {
                    chats[chatIndex].messages[messageIndex].poll = poll
                }
            }

        case .sendSucceeded(let chatID, let oldID, let message):
            mutateChat(chatID) { chat in
                if let i = chat.messages.firstIndex(where: { $0.remoteID == oldID }) {
                    chat.messages[i].remoteID = message.remoteID
                    chat.messages[i].state = .sent
                    chat.messages[i].date = message.date
                }
            }
            if let index = uploadQueue.firstIndex(where: { $0.chatID == chatID && $0.messageID == oldID }) {
                uploadQueue[index].messageID = message.remoteID ?? oldID
                uploadQueue[index].status = .completed
                uploadQueue[index].uploadedBytes = uploadQueue[index].totalBytes
                removeOutgoingUploadFile(at: uploadQueue[index].sourcePath)
                uploadQueue[index].sourcePath = ""
                persistUploadQueue()
            }

        case .sendFailed(let chatID, let oldID):
            mutateChat(chatID) { chat in
                if let i = chat.messages.firstIndex(where: { $0.remoteID == oldID }) {
                    chat.messages[i].state = .failed
                }
            }
            if let index = uploadQueue.firstIndex(where: { $0.chatID == chatID && $0.messageID == oldID }) {
                uploadQueue[index].status = .failed
                persistUploadQueue()
            }

        case .deleted(let chatID, let ids):
            mutateChat(chatID) { chat in
                chat.messages.removeAll { message in
                    guard let remote = message.remoteID else { return false }
                    return ids.contains(remote)
                }
            }

        case .foldersChanged(let updatedFolders):
            folders = updatedFolders
            if let selectedFolderID, !updatedFolders.contains(where: { $0.id == selectedFolderID }) {
                self.selectedFolderID = nil
            }

        case .actionFailed(let message):
            mediaError = message

        case .userStatus(let userID, let online):
            mutateChat(userID) { $0.isOnline = online }

        case .fileProgress(let fileID, let downloaded, let total, let completed):
            if completed {
                mediaProgress[fileID] = nil
            } else {
                mediaProgress[fileID] = (downloaded, total)
            }
            if let index = downloadQueue.firstIndex(where: { $0.fileID == fileID }) {
                downloadQueue[index].downloadedBytes = downloaded
                if total > 0 { downloadQueue[index].totalBytes = total }
                if completed {
                    downloadQueue[index].status = .completed
                    persistDownloadQueue()
                } else if downloadQueue[index].status == .queued {
                    downloadQueue[index].status = .downloading
                }
            }

        case .uploadStarted(let fileID, let chatID, let messageID, let title, let total, let sourcePath):
            if let index = uploadQueue.firstIndex(where: { $0.fileID == fileID }) {
                let wasCompleted = uploadQueue[index].status == .completed
                uploadQueue[index].chatID = chatID
                uploadQueue[index].messageID = messageID
                uploadQueue[index].title = title
                uploadQueue[index].totalBytes = max(uploadQueue[index].totalBytes, total)
                if wasCompleted {
                    removeOutgoingUploadFile(at: sourcePath)
                    uploadQueue[index].sourcePath = ""
                } else {
                    uploadQueue[index].sourcePath = sourcePath
                    uploadQueue[index].status = .uploading
                }
            } else {
                uploadQueue.insert(UploadRecord(
                    fileID: fileID,
                    chatID: chatID,
                    messageID: messageID,
                    title: title,
                    totalBytes: total,
                    uploadedBytes: 0,
                    status: .uploading,
                    sourcePath: sourcePath
                ), at: 0)
            }
            persistUploadQueue()

        case .uploadProgress(let fileID, let uploaded, let total, let completed):
            if let index = uploadQueue.firstIndex(where: { $0.fileID == fileID }) {
                uploadQueue[index].uploadedBytes = uploaded
                if total > 0 { uploadQueue[index].totalBytes = total }
                if completed {
                    uploadQueue[index].status = .completed
                    removeOutgoingUploadFile(at: uploadQueue[index].sourcePath)
                    uploadQueue[index].sourcePath = ""
                    persistUploadQueue()
                } else if uploadQueue[index].status != .completed {
                    uploadQueue[index].status = .uploading
                }
            } else {
                uploadQueue.insert(UploadRecord(
                    fileID: fileID,
                    chatID: 0,
                    messageID: 0,
                    title: L("downloads.upload.unknown"),
                    totalBytes: total,
                    uploadedBytes: uploaded,
                    status: completed ? .completed : .uploading,
                    sourcePath: ""
                ), at: 0)
                if completed { persistUploadQueue() }
            }

        case .uploadCancelled(let fileID):
            if let index = uploadQueue.firstIndex(where: { $0.fileID == fileID }) {
                uploadQueue[index].status = .cancelled
                removeOutgoingUploadFile(at: uploadQueue[index].sourcePath)
                uploadQueue[index].sourcePath = ""
                persistUploadQueue()
            }

        case .fileCancelled(let fileID):
            mediaProgress[fileID] = nil
            if let index = downloadQueue.firstIndex(where: { $0.fileID == fileID }),
               downloadQueue[index].status == .downloading {
                downloadQueue[index].status = .paused
                persistDownloadQueue()
            }

        case .connection(let state):
            connection = state
        }
    }

    private func removeOutgoingUploadFile(at path: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/outgoing", isDirectory: true)
        guard !path.isEmpty, path.hasPrefix(directory.path + "/") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func notifyIncoming(_ message: Message, for chat: Chat) {
        guard !message.isOutgoing, isForeground, activeChatID != chat.id, !chat.isMuted else { return }
        let body = chat.notificationSettings.showPreview ? message.text : L("notifications.newMessage")
        PushNotificationManager.shared.notifyIncomingMessage(
            chatID: chat.id,
            messageID: message.remoteID,
            title: chat.title,
            body: body,
            soundEnabled: chat.notificationSettings.soundEnabled
        )
    }

    private func refresh(_ id: Int64) async {
        do {
            guard let fresh = try await repository.refreshChat(id) else { return }
            mergeRefreshedChat(fresh, id: id)
        } catch {
            mediaError = TGErrors.message(for: error)
        }
    }

    private func mergeRefreshedChat(_ fresh: Chat, id: Int64) {
        var merged = fresh
        if let i = chats.firstIndex(where: { $0.id == id }) {
            merged.folderIDs = chats[i].folderIDs
            merged.isHidden = chats[i].isHidden || hiddenIDs.contains(id)
            if chats[i].messages.count > 1 { merged.messages = chats[i].messages }
            chats[i] = merged
        } else {
            merged.isHidden = hiddenIDs.contains(id)
            chats.append(merged)
        }
    }

    private func isCurrentOpenRequest(_ requestID: UUID, chatID: Int64, topicID: Int64?) -> Bool {
        isForeground
            && activeChatID == chatID
            && activeTopicID == topicID
            && chatOpenRequests[chatID] == requestID
    }

    // MARK: Sending

    func send(
        _ text: String,
        in chatID: Int64,
        replyTo: UUID?,
        entityKind: MessageEntityKind? = nil,
        topicID: Int64? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let replyRemote = replyTo.flatMap { id in
            message(id, in: chatID)?.remoteID
        }
        let entities = entityKind.map {
            [MessageEntity(offset: 0, length: (trimmed as NSString).length, kind: $0)]
        } ?? []
        let outgoingMessage = Message(
            text: trimmed,
            isOutgoing: true,
            state: .sending,
            replyToID: replyTo,
            replyToRemoteID: replyRemote,
            entities: entities
        )
        mutateChat(chatID) { chat in
            chat.messages.append(outgoingMessage)
            chat.messages = Array(chat.messages.suffix(200))
        }
        Task {
            await deliver(
                localID: outgoingMessage.id,
                text: trimmed,
                chatID: chatID,
                replyRemote: replyRemote,
                entities: entities,
                topicID: topicID
            )
        }
    }

    func retry(_ messageID: UUID, in chatID: Int64, topicID: Int64? = nil) {
        guard let message = chat(chatID)?.messages.first(where: { $0.id == messageID }) else { return }
        setState(.sending, messageID: messageID, chatID: chatID)
        let text = message.text
        let reply = message.replyToRemoteID
        let entities = message.entities
        Task {
            await deliver(
                localID: messageID,
                text: text,
                chatID: chatID,
                replyRemote: reply,
                entities: entities,
                topicID: topicID
            )
        }
    }

    private func deliver(
        localID: UUID,
        text: String,
        chatID: Int64,
        replyRemote: Int64?,
        entities: [MessageEntity],
        topicID: Int64?
    ) async {
        do {
            let remote: Message?
            if let topicID {
                remote = try await repository.sendTopicMessage(
                    text: text,
                    chatID: chatID,
                    topicID: topicID,
                    replyToRemoteID: replyRemote,
                    entities: entities
                )
            } else {
                remote = try await repository.sendRemote(
                    text: text,
                    chatID: chatID,
                    replyToRemoteID: replyRemote,
                    entities: entities
                )
            }
            if let remote {
                adopt(remote, for: localID, chatID: chatID)
            } else {
                let state = try await repository.send(text: text, chatID: chatID)
                setState(state, messageID: localID, chatID: chatID)
            }
        } catch {
            setState(.failed, messageID: localID, chatID: chatID)
        }
    }

    /// Links the local placeholder to the Telegram message (or drops it if the update already added it).
    private func adopt(_ remote: Message, for localID: UUID, chatID: Int64) {
        mutateChat(chatID) { chat in
            guard let li = chat.messages.firstIndex(where: { $0.id == localID }) else { return }
            if let remoteID = remote.remoteID,
               let existing = chat.messages.firstIndex(where: { $0.remoteID == remoteID }), existing != li {
                chat.messages.remove(at: li)
            } else {
                chat.messages[li].remoteID = remote.remoteID
                chat.messages[li].date = remote.date
                if chat.messages[li].state == .sending { chat.messages[li].state = remote.state }
            }
        }
    }

    private func setState(_ state: DeliveryState, messageID: UUID, chatID: Int64) {
        mutateChat(chatID) { chat in
            if let i = chat.messages.firstIndex(where: { $0.id == messageID }) {
                chat.messages[i].state = state
            }
        }
    }

    func edit(_ messageID: UUID, in chatID: Int64, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let target = message(messageID, in: chatID), target.isOutgoing else { return }
        if let remoteID = target.remoteID {
            let repo = repository
            Task {
                do {
                    try await repo.editRemote(chatID: chatID, messageID: remoteID, text: trimmed)
                    mutateMessage(messageID, in: chatID) { message in
                        message.text = trimmed
                        message.isEdited = true
                        message.entities = []
                    }
                    mediaError = nil
                } catch {
                    mediaError = TGErrors.message(for: error)
                }
            }
        } else {
            mutateMessage(messageID, in: chatID) { message in
                message.text = trimmed
                message.isEdited = true
                message.entities = []
            }
        }
    }

    func deleteMessage(_ messageID: UUID, in chatID: Int64, revoke: Bool = true) {
        guard let target = message(messageID, in: chatID) else { return }
        let removeLocally = {
            if let chatIndex = self.chats.firstIndex(where: { $0.id == chatID }) {
                self.chats[chatIndex].messages.removeAll { $0.id == messageID }
            }
            if var results = self.messageSearchResults[chatID] {
                results.removeAll { $0.id == messageID }
                self.messageSearchResults[chatID] = results
            }
        }
        guard repository.isReal, let remoteID = target.remoteID else {
            removeLocally()
            return
        }
        let repo = repository
        Task {
            do {
                try await repo.deleteRemote(chatID: chatID, messageID: remoteID, revoke: revoke)
                removeLocally()
                mediaError = nil
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    func deleteMessages(_ messageIDs: [UUID], in chatID: Int64, revoke: Bool = false) async -> Bool {
        let targets = messageIDs.compactMap { id -> (UUID, Message)? in
            guard let target = message(id, in: chatID) else { return nil }
            return (id, target)
        }
        guard !targets.isEmpty else { return false }
        if repository.isReal {
            let remoteIDs = targets.compactMap { $0.1.remoteID }
            do {
                if !remoteIDs.isEmpty {
                    try await repository.deleteRemote(chatID: chatID, messageIDs: remoteIDs, revoke: revoke)
                }
            } catch {
                mediaError = TGErrors.message(for: error)
                return false
            }
        }
        let idsToRemove = Set(targets.map(\.0))
        if let chatIndex = chats.firstIndex(where: { $0.id == chatID }) {
            chats[chatIndex].messages.removeAll { idsToRemove.contains($0.id) }
        }
        if var results = messageSearchResults[chatID] {
            results.removeAll { idsToRemove.contains($0.id) }
            messageSearchResults[chatID] = results
        }
        mediaError = nil
        return true
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: Int64) {
        guard let message = message(messageID, in: chatID) else { return }
        if repository.isReal {
            guard let remoteID = message.remoteID else { return }
            let reaction = message.chosenReactions.contains(emoji) ? nil : emoji
            let repo = repository
            Task {
                do {
                    let reactions = try await repo.setMessageReaction(
                        chatID: chatID,
                        messageID: remoteID,
                        emoji: reaction
                    )
                    guard let reactions else { return }
                    mutateMessage(messageID, in: chatID) { message in
                        message.reactions = reactions
                        message.chosenReactions = reaction.map { [$0] } ?? []
                    }
                    mediaError = nil
                } catch {
                    mediaError = TGErrors.message(for: error)
                }
            }
            return
        }
        mutateMessage(messageID, in: chatID) { message in
            if let r = message.reactions.firstIndex(of: emoji) {
                message.reactions.remove(at: r)
            } else {
                message.reactions.append(emoji)
            }
        }
    }

    func setMessagePinned(_ messageID: UUID, in chatID: Int64, pinned: Bool) {
        guard let message = message(messageID, in: chatID) else { return }
        guard repository.isReal, let remoteID = message.remoteID else {
            mutateMessage(messageID, in: chatID) { message in
                message.isPinned = pinned
            }
            return
        }
        let repo = repository
        Task {
            do {
                try await repo.setMessagePinned(chatID: chatID, messageID: remoteID, pinned: pinned)
                mutateMessage(messageID, in: chatID) { message in
                    message.isPinned = pinned
                }
                mediaError = nil
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    func votePoll(_ messageID: UUID, in chatID: Int64, optionIDs: [Int]) {
        guard let message = message(messageID, in: chatID),
              let remoteID = message.remoteID,
              let poll = message.poll,
              !poll.isClosed,
              optionIDs.allSatisfy({ poll.options.indices.contains($0) }),
              poll.allowsMultipleAnswers || optionIDs.count <= 1 else { return }
        let repo = repository
        Task {
            do {
                if let fresh = try await repo.votePoll(chatID: chatID, messageID: remoteID, optionIDs: optionIDs) {
                    mutateMessage(messageID, in: chatID) { $0.poll = fresh.poll }
                }
                mediaError = nil
            } catch {
                mediaError = TGErrors.message(for: error)
            }
        }
    }

    func forwardMessages(
        _ messageIDs: [UUID],
        from sourceChatID: Int64,
        to destinationChatID: Int64,
        hideSender: Bool = false
    ) async -> Bool {
        let remoteIDs = messageIDs.compactMap { id in message(id, in: sourceChatID)?.remoteID }
        guard !remoteIDs.isEmpty, remoteIDs.count == messageIDs.count else {
            mediaError = L("chat.forward.unavailable")
            return false
        }
        do {
            try await repository.forwardMessages(
                fromChatID: sourceChatID,
                toChatID: destinationChatID,
                messageIDs: remoteIDs,
                hideSender: hideSender
            )
            mediaError = nil
            return true
        } catch {
            mediaError = TGErrors.message(for: error)
            return false
        }
    }

    func searchMessages(in chatID: Int64, query: String, loadMore: Bool = false) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            messageSearchResults[chatID] = nil
            messageSearchQueries[chatID] = nil
            searchCursors[chatID] = nil
            searchTokens[chatID] = nil
            searchingChats.remove(chatID)
            searchExhausted.remove(chatID)
            return
        }
        if loadMore {
            guard !searchingChats.contains(chatID), !searchExhausted.contains(chatID),
                  messageSearchQueries[chatID] == trimmed else { return }
        } else {
            messageSearchQueries[chatID] = trimmed
            messageSearchResults[chatID] = []
            searchCursors[chatID] = nil
            searchTokens[chatID] = nil
            searchExhausted.remove(chatID)
        }
        let requestToken = UUID()
        searchTokens[chatID] = requestToken
        searchingChats.insert(chatID)
        defer {
            if searchTokens[chatID] == requestToken {
                searchingChats.remove(chatID)
                searchTokens[chatID] = nil
            }
        }

        if !repository.isReal {
            guard searchTokens[chatID] == requestToken else { return }
            messageSearchResults[chatID] = (chat(chatID)?.messages ?? [])
                .filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
            searchExhausted.insert(chatID)
            return
        }

        let fromID = loadMore ? (searchCursors[chatID] ?? 0) : 0
        do {
            guard let page = try await repository.searchMessages(
                chatID: chatID,
                query: trimmed,
                fromMessageID: fromID,
                limit: 50
            ), messageSearchQueries[chatID] == trimmed,
                 searchTokens[chatID] == requestToken else { return }
            let existingIDs = Set((messageSearchResults[chatID] ?? []).compactMap(\.remoteID))
            let unique = page.filter { message in
                guard let remoteID = message.remoteID else { return true }
                return !existingIDs.contains(remoteID)
            }
            messageSearchResults[chatID, default: []].append(contentsOf: unique)
            if let oldest = unique.compactMap(\.remoteID).min() { searchCursors[chatID] = oldest }
            if page.count < 50 || unique.isEmpty { searchExhausted.insert(chatID) }
            mediaError = nil
        } catch {
            guard searchTokens[chatID] == requestToken else { return }
            mediaError = TGErrors.message(for: error)
        }
    }

    func searchResults(in chatID: Int64, query: String) -> [Message]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, messageSearchQueries[chatID] == trimmed else { return nil }
        return messageSearchResults[chatID]
    }

    // MARK: Drafts (local only, capped)

    func draft(for chatID: Int64) -> String { drafts[chatID] ?? "" }

    func setDraft(_ text: String, for chatID: Int64) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: chatID)
        } else {
            drafts[chatID] = String(text.prefix(4000))
            if drafts.count > Self.maxDrafts, let victim = drafts.keys.first(where: { $0 != chatID }) {
                drafts.removeValue(forKey: victim)
            }
        }
        persistDrafts()
    }

    private func persistDrafts() {
        var stored: [String: String] = [:]
        for (id, text) in drafts { stored[String(id)] = text }
        defaults.set(stored, forKey: Self.draftsKey)
    }
}
