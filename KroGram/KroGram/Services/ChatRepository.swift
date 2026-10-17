// Copyright © 2026 Kro. KroGram original materials.

import Foundation

/// Boundary between UI and data. `MockChatRepository` powers the demo;
/// `TelegramChatRepository` talks to Telegram through TDLib.
protocol ChatRepository: Sendable {
    var isReal: Bool { get }
    var events: AsyncStream<ChatEvent>? { get }

    func loadChats() async throws -> [Chat]
    func loadMoreChats() async throws -> [Chat]
    func loadFolders() async throws -> [ChatFolder]
    func saveFolder(_ folder: ChatFolder) async throws -> ChatFolder
    func deleteFolder(_ folder: ChatFolder) async throws
    func reorderFolders(_ folders: [ChatFolder]) async throws
    func setFolderMembership(_ folder: ChatFolder, chatID: Int64, contains: Bool) async throws -> ChatFolder
    func loadContacts() async throws -> [Contact]
    func send(text: String, chatID: Int64) async throws -> DeliveryState

    func refreshChat(_ id: Int64) async throws -> Chat?
    func loadHistory(chatID: Int64) async throws -> [Message]?
    func loadOlderHistory(chatID: Int64, before messageID: Int64) async throws -> [Message]?
    func loadMessage(chatID: Int64, messageID: Int64) async throws -> Message?
    func loadDiscussionThread(chatID: Int64, messageID: Int64, limit: Int) async throws -> DiscussionThreadPage
    func loadOlderDiscussionComments(
        chatID: Int64,
        messageID: Int64,
        discussionChatID: Int64,
        threadMessageID: Int64,
        before replyMessageID: Int64
    ) async throws -> [Message]
    func sendDiscussionComment(
        chatID: Int64,
        threadMessageID: Int64,
        text: String
    ) async throws -> Message
    func loadMyProfile() async throws -> TelegramProfile?
    func loadActiveSessions() async throws -> [TelegramSession]
    func terminateSession(_ id: Int64) async throws
    func terminateOtherSessions() async throws
    func loadTelegramPrivacySettings() async throws -> [TelegramPrivacyPreference]
    func setTelegramPrivacy(_ setting: TelegramPrivacySetting, policy: TelegramPrivacyPolicy) async throws
    func loadBlockedTelegramUsers() async throws -> [BlockedTelegramUser]
    func unblockTelegramUser(_ id: Int64) async throws
    func loadTelegramPasswordState() async throws -> TelegramPasswordState
    func updateTelegramPassword(current: String, new: String, hint: String) async throws -> TelegramPasswordState
    func loadChatProfile(chatID: Int64) async throws -> ChatProfile?
    func createGroup(title: String, memberIDs: [Int64], photoPath: String?) async throws -> GroupCreationResult
    func loadGroupManagementInfo(chatID: Int64) async throws -> GroupManagementInfo
    func loadMoreGroupMembers(chatID: Int64, offset: Int) async throws -> GroupMembersPage
    func addGroupMembers(chatID: Int64, userIDs: [Int64]) async throws
    func updateGroupMember(
        chatID: Int64,
        userID: Int64,
        status: GroupMemberStatus,
        adminRights: GroupAdminRights?
    ) async throws
    func createGroupInviteLink(chatID: Int64) async throws -> String
    func upgradeBasicGroup(chatID: Int64) async throws -> Int64
    func leaveGroup(chatID: Int64) async throws
    func createChannel(title: String, description: String, photoPath: String?) async throws -> ChannelCreationResult
    func loadChannelManagementInfo(chatID: Int64) async throws -> ChannelManagementInfo
    func joinChannel(identifier: String) async throws -> Int64
    func leaveChannel(chatID: Int64) async throws
    func loadForumTopics(chatID: Int64) async throws -> [ForumTopic]
    func createForumTopic(chatID: Int64, name: String) async throws
    func editForumTopic(chatID: Int64, topicID: Int64, name: String) async throws
    func setForumTopicClosed(chatID: Int64, topicID: Int64, closed: Bool) async throws
    func loadForumTopicHistory(chatID: Int64, topicID: Int64, limit: Int) async throws -> [Message]
    func loadOlderForumTopicHistory(chatID: Int64, topicID: Int64, before messageID: Int64) async throws -> [Message]
    func sendTopicMessage(text: String, chatID: Int64, topicID: Int64, replyToRemoteID: Int64?, entities: [MessageEntity]) async throws -> Message?
    func updateMyProfile(firstName: String, lastName: String, bio: String) async throws
    func downloadFileData(fileID: Int64, limit: Int64) async throws -> Data
    func downloadFileURL(fileID: Int64, limit: Int64) async throws -> URL
    func cancelFileDownload(fileID: Int64) async throws
    func sendPhoto(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws
    func sendVideo(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws
    func sendMediaAlbum(chatID: Int64, items: [OutgoingAlbumMedia], caption: String, topicID: Int64?) async throws
    func sendVideoNote(chatID: Int64, path: String, duration: Int, length: Int, topicID: Int64?) async throws
    func sendVoiceNote(chatID: Int64, path: String, duration: Int, topicID: Int64?) async throws
    func sendPoll(chatID: Int64, question: String, options: [String], isAnonymous: Bool, allowsMultipleAnswers: Bool, topicID: Int64?) async throws
    func sendContact(chatID: Int64, firstName: String, lastName: String, phoneNumber: String, topicID: Int64?) async throws
    func sendLocation(chatID: Int64, latitude: Double, longitude: Double, topicID: Int64?) async throws
    func votePoll(chatID: Int64, messageID: Int64, optionIDs: [Int]) async throws -> Message?
    func loadStickers() async throws -> [TelegramSticker]
    func loadStickerSets() async throws -> [TelegramStickerSet]
    func searchStickerSets(query: String) async throws -> [TelegramStickerSet]
    func loadStickers(setID: Int64) async throws -> [TelegramSticker]
    func loadRecentStickers() async throws -> [TelegramSticker]
    func setStickerSetInstalled(setID: Int64, installed: Bool) async throws
    func sendSticker(chatID: Int64, sticker: TelegramSticker, topicID: Int64?) async throws
    func loadSavedAnimations() async throws -> [TelegramAnimation]
    func searchAnimations(chatID: Int64, query: String) async throws -> [TelegramAnimation]
    func setAnimationSaved(_ animation: TelegramAnimation, saved: Bool) async throws
    func sendAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64?) async throws
    func sendInlineAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64?) async throws
    func searchEmojis(query: String, languageCodes: [String]) async throws -> [String]
    func loadCustomEmojiImages(ids: [Int64]) async throws -> [Int64: Data]
    func sendDocument(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws
    func cancelUpload(fileID: Int64, chatID: Int64, messageID: Int64) async throws
    func clearMediaCache() async throws
    func clearMediaCache(kind: MessageMediaKind?) async throws
    /// Returns nil when the repository has no remote backend (demo): caller falls back to `send(text:chatID:)`.
    func sendRemote(text: String, chatID: Int64, replyToRemoteID: Int64?, entities: [MessageEntity]) async throws -> Message?
    func editRemote(chatID: Int64, messageID: Int64, text: String) async throws
    func deleteRemote(chatID: Int64, messageID: Int64, revoke: Bool) async throws
    func deleteRemote(chatID: Int64, messageIDs: [Int64], revoke: Bool) async throws
    func markRead(chatID: Int64, remoteIDs: [Int64]) async throws
    func setChatOpen(_ chatID: Int64, _ open: Bool) async
    func sendTyping(chatID: Int64) async
    func setPinned(chatID: Int64, pinned: Bool, archived: Bool) async throws
    func setArchived(chatID: Int64, archived: Bool) async throws
    func setMuted(chatID: Int64, duration: Int32) async throws
    func setMarkedUnread(chatID: Int64, marked: Bool) async throws
    func loadNotificationSettings(chatID: Int64) async throws -> ChatNotificationSettings
    func saveNotificationSettings(chatID: Int64, settings: ChatNotificationSettings) async throws
    func setMessageReaction(chatID: Int64, messageID: Int64, emoji: String?) async throws -> [String]?
    func setMessagePinned(chatID: Int64, messageID: Int64, pinned: Bool) async throws
    func forwardMessages(
        fromChatID: Int64,
        toChatID: Int64,
        messageIDs: [Int64],
        hideSender: Bool
    ) async throws
    func searchMessages(chatID: Int64, query: String, fromMessageID: Int64, limit: Int) async throws -> [Message]?
    func apply(privacy: PrivacySnapshot) async
    func setForeground(_ foreground: Bool) async
}

extension ChatRepository {
    var isReal: Bool { false }
    var events: AsyncStream<ChatEvent>? { nil }
    func refreshChat(_ id: Int64) async throws -> Chat? { nil }
    func loadHistory(chatID: Int64) async throws -> [Message]? { nil }
    func loadMoreChats() async throws -> [Chat] { [] }
    func saveFolder(_ folder: ChatFolder) async throws -> ChatFolder { throw MockRepositoryError.unsupported }
    func deleteFolder(_ folder: ChatFolder) async throws { throw MockRepositoryError.unsupported }
    func reorderFolders(_ folders: [ChatFolder]) async throws { throw MockRepositoryError.unsupported }
    func setFolderMembership(_ folder: ChatFolder, chatID: Int64, contains: Bool) async throws -> ChatFolder {
        throw MockRepositoryError.unsupported
    }
    func loadOlderHistory(chatID: Int64, before messageID: Int64) async throws -> [Message]? { nil }
    func loadMessage(chatID: Int64, messageID: Int64) async throws -> Message? { nil }
    func loadDiscussionThread(chatID: Int64, messageID: Int64, limit: Int) async throws -> DiscussionThreadPage {
        throw MockRepositoryError.unsupported
    }
    func loadOlderDiscussionComments(
        chatID: Int64,
        messageID: Int64,
        discussionChatID: Int64,
        threadMessageID: Int64,
        before replyMessageID: Int64
    ) async throws -> [Message] {
        throw MockRepositoryError.unsupported
    }
    func sendDiscussionComment(
        chatID: Int64,
        threadMessageID: Int64,
        text: String
    ) async throws -> Message {
        throw MockRepositoryError.unsupported
    }
    func loadMyProfile() async throws -> TelegramProfile? { nil }
    func loadActiveSessions() async throws -> [TelegramSession] { throw MockRepositoryError.unsupported }
    func terminateSession(_ id: Int64) async throws { throw MockRepositoryError.unsupported }
    func terminateOtherSessions() async throws { throw MockRepositoryError.unsupported }
    func loadTelegramPrivacySettings() async throws -> [TelegramPrivacyPreference] {
        throw MockRepositoryError.unsupported
    }
    func setTelegramPrivacy(_ setting: TelegramPrivacySetting, policy: TelegramPrivacyPolicy) async throws {
        throw MockRepositoryError.unsupported
    }
    func loadBlockedTelegramUsers() async throws -> [BlockedTelegramUser] {
        throw MockRepositoryError.unsupported
    }
    func unblockTelegramUser(_ id: Int64) async throws { throw MockRepositoryError.unsupported }
    func loadTelegramPasswordState() async throws -> TelegramPasswordState {
        throw MockRepositoryError.unsupported
    }
    func updateTelegramPassword(current: String, new: String, hint: String) async throws -> TelegramPasswordState {
        throw MockRepositoryError.unsupported
    }
    func loadChatProfile(chatID: Int64) async throws -> ChatProfile? { nil }
    func createGroup(title: String, memberIDs: [Int64], photoPath: String?) async throws -> GroupCreationResult {
        throw MockRepositoryError.unsupported
    }
    func loadGroupManagementInfo(chatID: Int64) async throws -> GroupManagementInfo {
        throw MockRepositoryError.unsupported
    }
    func loadMoreGroupMembers(chatID: Int64, offset: Int) async throws -> GroupMembersPage {
        throw MockRepositoryError.unsupported
    }
    func addGroupMembers(chatID: Int64, userIDs: [Int64]) async throws {
        throw MockRepositoryError.unsupported
    }
    func updateGroupMember(
        chatID: Int64,
        userID: Int64,
        status: GroupMemberStatus,
        adminRights: GroupAdminRights? = nil
    ) async throws {
        throw MockRepositoryError.unsupported
    }
    func createGroupInviteLink(chatID: Int64) async throws -> String {
        throw MockRepositoryError.unsupported
    }
    func upgradeBasicGroup(chatID: Int64) async throws -> Int64 {
        throw MockRepositoryError.unsupported
    }
    func leaveGroup(chatID: Int64) async throws { throw MockRepositoryError.unsupported }
    func createChannel(title: String, description: String, photoPath: String?) async throws -> ChannelCreationResult {
        throw MockRepositoryError.unsupported
    }
    func loadChannelManagementInfo(chatID: Int64) async throws -> ChannelManagementInfo {
        throw MockRepositoryError.unsupported
    }
    func joinChannel(identifier: String) async throws -> Int64 { throw MockRepositoryError.unsupported }
    func leaveChannel(chatID: Int64) async throws { throw MockRepositoryError.unsupported }
    func loadForumTopics(chatID: Int64) async throws -> [ForumTopic] { throw MockRepositoryError.unsupported }
    func createForumTopic(chatID: Int64, name: String) async throws { throw MockRepositoryError.unsupported }
    func editForumTopic(chatID: Int64, topicID: Int64, name: String) async throws { throw MockRepositoryError.unsupported }
    func setForumTopicClosed(chatID: Int64, topicID: Int64, closed: Bool) async throws {
        throw MockRepositoryError.unsupported
    }
    func loadForumTopicHistory(chatID: Int64, topicID: Int64, limit: Int) async throws -> [Message] {
        throw MockRepositoryError.unsupported
    }
    func loadOlderForumTopicHistory(chatID: Int64, topicID: Int64, before messageID: Int64) async throws -> [Message] {
        throw MockRepositoryError.unsupported
    }
    func sendTopicMessage(
        text: String,
        chatID: Int64,
        topicID: Int64,
        replyToRemoteID: Int64?,
        entities: [MessageEntity]
    ) async throws -> Message? { throw MockRepositoryError.unsupported }
    func updateMyProfile(firstName: String, lastName: String, bio: String) async throws {
        throw MockRepositoryError.unsupported
    }
    func downloadFileData(fileID: Int64, limit: Int64) async throws -> Data {
        throw MockRepositoryError.unsupported
    }
    func downloadFileURL(fileID: Int64, limit: Int64) async throws -> URL {
        throw MockRepositoryError.unsupported
    }
    func cancelFileDownload(fileID: Int64) async throws {}
    func sendPhoto(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendVideo(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendMediaAlbum(
        chatID: Int64,
        items: [OutgoingAlbumMedia],
        caption: String,
        topicID: Int64?
    ) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendVideoNote(chatID: Int64, path: String, duration: Int, length: Int, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }

    func sendVoiceNote(chatID: Int64, path: String, duration: Int, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendPoll(chatID: Int64, question: String, options: [String], isAnonymous: Bool, allowsMultipleAnswers: Bool, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendContact(chatID: Int64, firstName: String, lastName: String, phoneNumber: String, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendLocation(chatID: Int64, latitude: Double, longitude: Double, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func votePoll(chatID: Int64, messageID: Int64, optionIDs: [Int]) async throws -> Message? {
        throw MockRepositoryError.unsupported
    }
    func loadStickers() async throws -> [TelegramSticker] { throw MockRepositoryError.unsupported }
    func loadStickerSets() async throws -> [TelegramStickerSet] { throw MockRepositoryError.unsupported }
    func searchStickerSets(query: String) async throws -> [TelegramStickerSet] {
        throw MockRepositoryError.unsupported
    }
    func loadStickers(setID: Int64) async throws -> [TelegramSticker] {
        throw MockRepositoryError.unsupported
    }
    func loadRecentStickers() async throws -> [TelegramSticker] { throw MockRepositoryError.unsupported }
    func setStickerSetInstalled(setID: Int64, installed: Bool) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendSticker(chatID: Int64, sticker: TelegramSticker, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func loadSavedAnimations() async throws -> [TelegramAnimation] { [] }
    func searchAnimations(chatID: Int64, query: String) async throws -> [TelegramAnimation] { [] }
    func setAnimationSaved(_ animation: TelegramAnimation, saved: Bool) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func sendInlineAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func searchEmojis(query: String, languageCodes: [String]) async throws -> [String] { [] }
    func loadCustomEmojiImages(ids: [Int64]) async throws -> [Int64: Data] { [:] }
    func sendDocument(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        throw MockRepositoryError.unsupported
    }
    func cancelUpload(fileID: Int64, chatID: Int64, messageID: Int64) async throws {
        throw MockRepositoryError.unsupported
    }
    func clearMediaCache() async throws {}
    func clearMediaCache(kind: MessageMediaKind?) async throws {
        if kind == nil { try await clearMediaCache() }
        else { throw MockRepositoryError.unsupported }
    }
    func sendRemote(text: String, chatID: Int64, replyToRemoteID: Int64?, entities: [MessageEntity]) async throws -> Message? { nil }
    func editRemote(chatID: Int64, messageID: Int64, text: String) async throws {}
    func deleteRemote(chatID: Int64, messageID: Int64, revoke: Bool) async throws {}
    func deleteRemote(chatID: Int64, messageIDs: [Int64], revoke: Bool) async throws {
        for messageID in messageIDs {
            try await deleteRemote(chatID: chatID, messageID: messageID, revoke: revoke)
        }
    }
    func markRead(chatID: Int64, remoteIDs: [Int64]) async throws {}
    func setChatOpen(_ chatID: Int64, _ open: Bool) async {}
    func sendTyping(chatID: Int64) async {}
    func setPinned(chatID: Int64, pinned: Bool, archived: Bool = false) async throws {}
    func setArchived(chatID: Int64, archived: Bool) async throws {}
    func setMuted(chatID: Int64, duration: Int32) async throws { throw MockRepositoryError.unsupported }
    func setMarkedUnread(chatID: Int64, marked: Bool) async throws { throw MockRepositoryError.unsupported }
    func loadNotificationSettings(chatID: Int64) async throws -> ChatNotificationSettings {
        throw MockRepositoryError.unsupported
    }
    func saveNotificationSettings(chatID: Int64, settings: ChatNotificationSettings) async throws {
        throw MockRepositoryError.unsupported
    }
    func setMessageReaction(chatID: Int64, messageID: Int64, emoji: String?) async throws -> [String]? {
        throw MockRepositoryError.unsupported
    }
    func setMessagePinned(chatID: Int64, messageID: Int64, pinned: Bool) async throws {
        throw MockRepositoryError.unsupported
    }
    func forwardMessages(
        fromChatID: Int64,
        toChatID: Int64,
        messageIDs: [Int64],
        hideSender: Bool = false
    ) async throws {
        throw MockRepositoryError.unsupported
    }
    func searchMessages(chatID: Int64, query: String, fromMessageID: Int64, limit: Int) async throws -> [Message]? {
        nil
    }
    func apply(privacy: PrivacySnapshot) async {}
    func setForeground(_ foreground: Bool) async {}
}

enum MockRepositoryError: Error {
    case simulatedSendFailure
    case unsupported
}

/// Demo repository. Sending text that starts with "/fail" simulates a send error.
struct MockChatRepository: ChatRepository {
    var delay: Duration = .milliseconds(400)

    func loadChats() async throws -> [Chat] {
        try await Task.sleep(for: delay)
        return MockData.chats()
    }

    func loadFolders() async throws -> [ChatFolder] {
        MockData.folders
    }

    func loadContacts() async throws -> [Contact] {
        MockData.contacts
    }

    func send(text: String, chatID: Int64) async throws -> DeliveryState {
        try await Task.sleep(for: delay)
        if text.hasPrefix("/fail") { throw MockRepositoryError.simulatedSendFailure }
        return .sent
    }
}
