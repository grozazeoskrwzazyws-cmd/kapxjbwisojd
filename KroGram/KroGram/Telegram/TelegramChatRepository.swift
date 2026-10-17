// Copyright © 2026 Kro. KroGram original materials.

import Foundation

/// `ChatRepository` backed by a real Telegram session (TDLib).
struct TelegramChatRepository: ChatRepository {
    let service: TelegramService

    var isReal: Bool { true }
    var events: AsyncStream<ChatEvent>? { service.events }

    func loadChats() async throws -> [Chat] { try await service.loadChats() }
    func loadMoreChats() async throws -> [Chat] { try await service.loadMoreChats() }
    func loadFolders() async throws -> [ChatFolder] { try await service.loadFolders() }
    func saveFolder(_ folder: ChatFolder) async throws -> ChatFolder {
        try await service.saveFolder(folder)
    }
    func deleteFolder(_ folder: ChatFolder) async throws { try await service.deleteFolder(folder) }
    func reorderFolders(_ folders: [ChatFolder]) async throws {
        try await service.reorderFolders(folders)
    }
    func setFolderMembership(
        _ folder: ChatFolder,
        chatID: Int64,
        contains: Bool
    ) async throws -> ChatFolder {
        try await service.setFolderMembership(folder, chatID: chatID, contains: contains)
    }
    func loadContacts() async throws -> [Contact] { try await service.loadContacts() }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }

    func refreshChat(_ id: Int64) async throws -> Chat? { try await service.chat(id) }
    func loadHistory(chatID: Int64) async throws -> [Message]? { try await service.loadHistory(chatID: chatID) }
    func loadOlderHistory(chatID: Int64, before messageID: Int64) async throws -> [Message]? {
        try await service.loadOlderHistory(chatID: chatID, before: messageID)
    }
    func loadMessage(chatID: Int64, messageID: Int64) async throws -> Message? {
        try await service.loadMessage(chatID: chatID, messageID: messageID)
    }
    func loadDiscussionThread(chatID: Int64, messageID: Int64, limit: Int) async throws -> DiscussionThreadPage {
        try await service.loadDiscussionThread(chatID: chatID, messageID: messageID, limit: limit)
    }
    func loadOlderDiscussionComments(
        chatID: Int64,
        messageID: Int64,
        discussionChatID: Int64,
        threadMessageID: Int64,
        before replyMessageID: Int64
    ) async throws -> [Message] {
        try await service.loadOlderDiscussionComments(
            chatID: chatID,
            messageID: messageID,
            discussionChatID: discussionChatID,
            threadMessageID: threadMessageID,
            before: replyMessageID
        )
    }
    func sendDiscussionComment(chatID: Int64, threadMessageID: Int64, text: String) async throws -> Message {
        try await service.sendDiscussionComment(chatID: chatID, threadMessageID: threadMessageID, text: text)
    }
    func loadMyProfile() async throws -> TelegramProfile? { try await service.myProfile() }
    func loadChatProfile(chatID: Int64) async throws -> ChatProfile? {
        try await service.chatProfile(chatID: chatID)
    }
    func createGroup(title: String, memberIDs: [Int64], photoPath: String?) async throws -> GroupCreationResult {
        try await service.createGroup(title: title, memberIDs: memberIDs, photoPath: photoPath)
    }
    func loadGroupManagementInfo(chatID: Int64) async throws -> GroupManagementInfo {
        try await service.groupManagementInfo(chatID: chatID)
    }
    func loadMoreGroupMembers(chatID: Int64, offset: Int) async throws -> GroupMembersPage {
        try await service.loadMoreGroupMembers(chatID: chatID, offset: offset)
    }
    func addGroupMembers(chatID: Int64, userIDs: [Int64]) async throws {
        try await service.addGroupMembers(chatID: chatID, userIDs: userIDs)
    }
    func updateGroupMember(
        chatID: Int64,
        userID: Int64,
        status: GroupMemberStatus,
        adminRights: GroupAdminRights?
    ) async throws {
        try await service.updateGroupMember(
            chatID: chatID,
            userID: userID,
            status: status,
            adminRights: adminRights
        )
    }
    func createGroupInviteLink(chatID: Int64) async throws -> String {
        try await service.createGroupInviteLink(chatID: chatID)
    }
    func upgradeBasicGroup(chatID: Int64) async throws -> Int64 {
        try await service.upgradeBasicGroup(chatID: chatID)
    }
    func leaveGroup(chatID: Int64) async throws { try await service.leaveGroup(chatID: chatID) }
    func createChannel(title: String, description: String, photoPath: String?) async throws -> ChannelCreationResult {
        try await service.createChannel(title: title, description: description, photoPath: photoPath)
    }
    func loadChannelManagementInfo(chatID: Int64) async throws -> ChannelManagementInfo {
        try await service.channelManagementInfo(chatID: chatID)
    }
    func joinChannel(identifier: String) async throws -> Int64 {
        try await service.joinChannel(identifier: identifier)
    }
    func leaveChannel(chatID: Int64) async throws { try await service.leaveChannel(chatID: chatID) }
    func loadForumTopics(chatID: Int64) async throws -> [ForumTopic] {
        try await service.loadForumTopics(chatID: chatID)
    }
    func createForumTopic(chatID: Int64, name: String) async throws {
        try await service.createForumTopic(chatID: chatID, name: name)
    }
    func editForumTopic(chatID: Int64, topicID: Int64, name: String) async throws {
        try await service.editForumTopic(chatID: chatID, topicID: topicID, name: name)
    }
    func setForumTopicClosed(chatID: Int64, topicID: Int64, closed: Bool) async throws {
        try await service.setForumTopicClosed(chatID: chatID, topicID: topicID, closed: closed)
    }
    func loadForumTopicHistory(chatID: Int64, topicID: Int64, limit: Int) async throws -> [Message] {
        try await service.loadForumTopicHistory(chatID: chatID, topicID: topicID, limit: limit)
    }
    func loadOlderForumTopicHistory(chatID: Int64, topicID: Int64, before messageID: Int64) async throws -> [Message] {
        try await service.loadOlderForumTopicHistory(chatID: chatID, topicID: topicID, before: messageID)
    }
    func sendTopicMessage(
        text: String,
        chatID: Int64,
        topicID: Int64,
        replyToRemoteID: Int64?,
        entities: [MessageEntity]
    ) async throws -> Message? {
        try await service.sendTopicMessage(
            text: text,
            chatID: chatID,
            topicID: topicID,
            replyToRemoteID: replyToRemoteID,
            entities: entities
        )
    }
    func updateMyProfile(firstName: String, lastName: String, bio: String) async throws {
        try await service.updateMyProfile(firstName: firstName, lastName: lastName, bio: bio)
    }
    func downloadFileData(fileID: Int64, limit: Int64) async throws -> Data {
        try await service.downloadFileData(fileID: fileID, limit: limit)
    }
    func downloadFileURL(fileID: Int64, limit: Int64) async throws -> URL {
        try await service.downloadFileURL(fileID: fileID, limit: limit)
    }
    func cancelFileDownload(fileID: Int64) async throws {
        try await service.cancelFileDownload(fileID: fileID)
    }
    func sendPhoto(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws {
        try await service.sendPhoto(chatID: chatID, path: path, caption: caption, topicID: topicID)
    }
    func sendVideo(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws {
        try await service.sendVideo(chatID: chatID, path: path, caption: caption, topicID: topicID)
    }
    func sendMediaAlbum(
        chatID: Int64,
        items: [OutgoingAlbumMedia],
        caption: String,
        topicID: Int64?
    ) async throws {
        try await service.sendMediaAlbum(chatID: chatID, items: items, caption: caption, topicID: topicID)
    }
    func sendVideoNote(chatID: Int64, path: String, duration: Int, length: Int, topicID: Int64?) async throws {
        try await service.sendVideoNote(chatID: chatID, path: path, duration: duration, length: length, topicID: topicID)
    }
    func sendVoiceNote(chatID: Int64, path: String, duration: Int, topicID: Int64?) async throws {
        try await service.sendVoiceNote(chatID: chatID, path: path, duration: duration, topicID: topicID)
    }
    func sendPoll(chatID: Int64, question: String, options: [String], isAnonymous: Bool, allowsMultipleAnswers: Bool, topicID: Int64?) async throws {
        try await service.sendPoll(
            chatID: chatID,
            question: question,
            options: options,
            isAnonymous: isAnonymous,
            allowsMultipleAnswers: allowsMultipleAnswers,
            topicID: topicID
        )
    }
    func sendContact(chatID: Int64, firstName: String, lastName: String, phoneNumber: String, topicID: Int64?) async throws {
        try await service.sendContact(
            chatID: chatID,
            firstName: firstName,
            lastName: lastName,
            phoneNumber: phoneNumber,
            topicID: topicID
        )
    }
    func sendLocation(chatID: Int64, latitude: Double, longitude: Double, topicID: Int64?) async throws {
        try await service.sendLocation(chatID: chatID, latitude: latitude, longitude: longitude, topicID: topicID)
    }
    func votePoll(chatID: Int64, messageID: Int64, optionIDs: [Int]) async throws -> Message? {
        try await service.votePoll(chatID: chatID, messageID: messageID, optionIDs: optionIDs)
    }
    func loadStickers() async throws -> [TelegramSticker] {
        try await service.loadStickers()
    }
    func loadStickerSets() async throws -> [TelegramStickerSet] {
        try await service.loadStickerSets()
    }
    func searchStickerSets(query: String) async throws -> [TelegramStickerSet] {
        try await service.searchStickerSets(query: query)
    }
    func loadStickers(setID: Int64) async throws -> [TelegramSticker] {
        try await service.loadStickers(setID: setID)
    }
    func loadRecentStickers() async throws -> [TelegramSticker] {
        try await service.loadRecentStickers()
    }
    func setStickerSetInstalled(setID: Int64, installed: Bool) async throws {
        try await service.setStickerSetInstalled(setID: setID, installed: installed)
    }
    func sendSticker(chatID: Int64, sticker: TelegramSticker, topicID: Int64?) async throws {
        try await service.sendSticker(chatID: chatID, sticker: sticker, topicID: topicID)
    }
    func loadSavedAnimations() async throws -> [TelegramAnimation] {
        try await service.loadSavedAnimations()
    }
    func searchAnimations(chatID: Int64, query: String) async throws -> [TelegramAnimation] {
        try await service.searchAnimations(chatID: chatID, query: query)
    }
    func setAnimationSaved(_ animation: TelegramAnimation, saved: Bool) async throws {
        try await service.setAnimationSaved(animation, saved: saved)
    }
    func sendAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64?) async throws {
        try await service.sendAnimation(chatID: chatID, animation: animation, topicID: topicID)
    }
    func sendInlineAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64?) async throws {
        try await service.sendInlineAnimation(chatID: chatID, animation: animation, topicID: topicID)
    }
    func searchEmojis(query: String, languageCodes: [String]) async throws -> [String] {
        try await service.searchEmojis(query: query, languageCodes: languageCodes)
    }
    func loadCustomEmojiImages(ids: [Int64]) async throws -> [Int64: Data] {
        try await service.loadCustomEmojiImages(ids: ids)
    }
    func sendDocument(chatID: Int64, path: String, caption: String, topicID: Int64?) async throws {
        try await service.sendDocument(chatID: chatID, path: path, caption: caption, topicID: topicID)
    }
    func cancelUpload(fileID: Int64, chatID: Int64, messageID: Int64) async throws {
        try await service.cancelUpload(fileID: fileID, chatID: chatID, messageID: messageID)
    }
    func clearMediaCache() async throws { try await service.clearMediaCache() }
    func clearMediaCache(kind: MessageMediaKind?) async throws {
        try await service.clearMediaCache(kind: kind)
    }

    func sendRemote(text: String, chatID: Int64, replyToRemoteID: Int64?, entities: [MessageEntity]) async throws -> Message? {
        try await service.sendText(
            chatID: chatID,
            text: text,
            replyToRemoteID: replyToRemoteID,
            entities: entities
        )
    }

    func editRemote(chatID: Int64, messageID: Int64, text: String) async throws {
        try await service.editText(chatID: chatID, messageID: messageID, text: text)
    }

    func deleteRemote(chatID: Int64, messageID: Int64, revoke: Bool) async throws {
        try await service.deleteMessage(chatID: chatID, messageID: messageID, revoke: revoke)
    }

    func deleteRemote(chatID: Int64, messageIDs: [Int64], revoke: Bool) async throws {
        try await service.deleteMessages(chatID: chatID, messageIDs: messageIDs, revoke: revoke)
    }

    func markRead(chatID: Int64, remoteIDs: [Int64]) async throws {
        try await service.markRead(chatID: chatID, messageIDs: remoteIDs)
    }

    func setChatOpen(_ chatID: Int64, _ open: Bool) async { await service.setChatOpen(chatID, open) }
    func sendTyping(chatID: Int64) async { await service.sendTyping(chatID: chatID) }
    func setPinned(chatID: Int64, pinned: Bool, archived: Bool = false) async throws {
        try await service.setPinned(chatID: chatID, pinned: pinned, archived: archived)
    }
    func setArchived(chatID: Int64, archived: Bool) async throws { try await service.setArchived(chatID: chatID, archived: archived) }
    func setMuted(chatID: Int64, duration: Int32) async throws {
        try await service.setMuted(chatID: chatID, duration: duration)
    }
    func setMarkedUnread(chatID: Int64, marked: Bool) async throws {
        try await service.setMarkedUnread(chatID: chatID, marked: marked)
    }
    func loadNotificationSettings(chatID: Int64) async throws -> ChatNotificationSettings {
        try await service.loadNotificationSettings(chatID: chatID)
    }
    func saveNotificationSettings(chatID: Int64, settings: ChatNotificationSettings) async throws {
        try await service.saveNotificationSettings(chatID: chatID, settings: settings)
    }
    func setMessageReaction(chatID: Int64, messageID: Int64, emoji: String?) async throws -> [String]? {
        try await service.setMessageReaction(chatID: chatID, messageID: messageID, emoji: emoji)
    }
    func setMessagePinned(chatID: Int64, messageID: Int64, pinned: Bool) async throws {
        try await service.setMessagePinned(chatID: chatID, messageID: messageID, pinned: pinned)
    }
    func forwardMessages(
        fromChatID: Int64,
        toChatID: Int64,
        messageIDs: [Int64],
        hideSender: Bool
    ) async throws {
        try await service.forwardMessages(
            fromChatID: fromChatID,
            toChatID: toChatID,
            messageIDs: messageIDs,
            hideSender: hideSender
        )
    }
    func searchMessages(chatID: Int64, query: String, fromMessageID: Int64, limit: Int) async throws -> [Message]? {
        try await service.searchMessages(chatID: chatID, query: query, fromMessageID: fromMessageID, limit: limit)
    }
    func loadActiveSessions() async throws -> [TelegramSession] { try await service.activeSessions() }
    func terminateSession(_ id: Int64) async throws { try await service.terminateSession(id) }
    func terminateOtherSessions() async throws { try await service.terminateOtherSessions() }
    func loadTelegramPrivacySettings() async throws -> [TelegramPrivacyPreference] {
        try await service.telegramPrivacySettings()
    }
    func setTelegramPrivacy(_ setting: TelegramPrivacySetting, policy: TelegramPrivacyPolicy) async throws {
        try await service.setTelegramPrivacy(setting, policy: policy)
    }
    func loadBlockedTelegramUsers() async throws -> [BlockedTelegramUser] {
        try await service.blockedTelegramUsers()
    }
    func unblockTelegramUser(_ id: Int64) async throws { try await service.unblockTelegramUser(id) }
    func loadTelegramPasswordState() async throws -> TelegramPasswordState {
        try await service.telegramPasswordState()
    }
    func updateTelegramPassword(current: String, new: String, hint: String) async throws -> TelegramPasswordState {
        try await service.updateTelegramPassword(current: current, new: new, hint: hint)
    }
    func apply(privacy: PrivacySnapshot) async { await service.apply(privacy: privacy) }
    func setForeground(_ foreground: Bool) async { await service.setForeground(foreground) }
}
