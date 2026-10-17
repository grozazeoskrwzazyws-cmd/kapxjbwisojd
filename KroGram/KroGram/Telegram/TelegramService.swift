// Copyright © 2026 Kro. KroGram original materials.

import Foundation

enum AuthStep: Sendable, Equatable {
    case starting
    case databaseReady
    case waitPhone
    case waitCode
    case waitPassword(hint: String)
    case unsupported(String)
    case failed(String)
    case ready
    case closed
}

/// Owns the TDLib session: authorization, chats, messages, privacy options.
/// All Telegram traffic goes through TDLib (official library); nothing is sent to other servers.
actor TelegramService {
    nonisolated let authSteps: AsyncStream<AuthStep>
    nonisolated let events: AsyncStream<ChatEvent>

    private let authOut: AsyncStream<AuthStep>.Continuation
    private let eventOut: AsyncStream<ChatEvent>.Continuation
    private let client = TDJSONClient.shared
    private let credentials: TelegramCredentials
    private let dbKey: Data

    private var consumer: Task<Void, Never>?
    private var authReady = false
    private var isForeground = true
    private var privacy = PrivacySnapshot()
    private var userCache: [Int64: TGUser] = [:]
    private var myUserID: Int64?
    private var savedMessagesChatID: Int64?
    private var animationSearchBotUserID: Int64?
    private var chatFolderInfos: [JSON] = []
    private var mainChatListPosition = 0
    private var lastReadOutbox: [Int64: Int64] = [:]
    private var loadedChatIDs: [String: [Int64]] = [:]
    private var knownFileIDs: Set<Int64> = []
    private var knownFileKinds: [Int64: MessageMediaKind] = [:]
    private var cachedDownloadedSizes: [Int64: Int64] = [:]
    private var downloadedFileOrder: [Int64] = []
    private var activeDownloadIDs: Set<Int64> = []
    private let chatPageSize = 25
    private let historyPageSize = 50
    private var mediaCacheLimit: Int64 {
        let configuredMB = UserDefaults.standard.integer(forKey: "krogram.mediaCacheLimitMB")
        return Int64(configuredMB == 0 ? 1_024 : configuredMB) * 1_024 * 1_024
    }

    init(credentials: TelegramCredentials, dbKey: Data) {
        self.credentials = credentials
        self.dbKey = dbKey
        var authContinuation: AsyncStream<AuthStep>.Continuation!
        authSteps = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { authContinuation = $0 }
        authOut = authContinuation
        var eventContinuation: AsyncStream<ChatEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(500)) { eventContinuation = $0 }
        eventOut = eventContinuation
    }

    // MARK: Lifecycle

    func start() {
        guard consumer == nil else { return }
        var continuation: AsyncStream<TDObject>.Continuation!
        let stream = AsyncStream<TDObject>(bufferingPolicy: .unbounded) { continuation = $0 }
        client.startSession(sink: continuation)
        authOut.yield(.starting)
        consumer = Task { [weak self] in
            for await object in stream {
                await self?.handle(object)
            }
        }
    }

    func logOut() async throws {
        _ = try await call(["@type": "logOut"])
    }

    // MARK: Authorization

    func submitPhone(_ phone: String) async throws {
        _ = try await call(["@type": "setAuthenticationPhoneNumber", "phone_number": phone])
    }

    func submitCode(_ code: String) async throws {
        _ = try await call(["@type": "checkAuthenticationCode", "code": code])
    }

    func submitPassword(_ password: String) async throws {
        _ = try await call(["@type": "checkAuthenticationPassword", "password": password])
    }

    private func sendParameters() async {
        let directory: String
        do {
            directory = try Self.databaseDirectory()
        } catch {
            authOut.yield(.failed(TGErrors.message(for: error)))
            return
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let query: JSON = [
            "@type": "setTdlibParameters",
            "use_test_dc": false,
            "database_directory": directory,
            "files_directory": directory + "/files",
            "database_encryption_key": dbKey.base64EncodedString(),
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": credentials.apiID,
            "api_hash": credentials.apiHash,
            "system_language_code": Locale.current.language.languageCode?.identifier ?? "en",
            "device_model": "iPhone",
            "system_version": "",
            "application_version": version
        ]
        do {
            _ = try await call(query)
            authOut.yield(.databaseReady)
        } catch {
            authOut.yield(.failed(TGErrors.message(for: error)))
        }
    }

    private func handleAuthorization(_ state: JSON) async {
        let type = TGParse.string(state["@type"])
        switch type {
        case "authorizationStateWaitTdlibParameters":
            await sendParameters()
        case "authorizationStateWaitPhoneNumber":
            authReady = false
            authOut.yield(.waitPhone)
        case "authorizationStateWaitCode":
            authOut.yield(.waitCode)
        case "authorizationStateWaitPassword":
            authOut.yield(.waitPassword(hint: TGParse.string(state["password_hint"])))
        case "authorizationStateReady":
            authReady = true
            authOut.yield(.ready)
            await applyOnlineStatus()
            if !chatFolderInfos.isEmpty {
                do {
                    eventOut.yield(.foldersChanged(try await loadFolders()))
                } catch {
                    eventOut.yield(.actionFailed(TGErrors.message(for: error)))
                }
            }
        case "authorizationStateLoggingOut":
            authReady = false
        case "authorizationStateClosing":
            authReady = false
        case "authorizationStateClosed":
            authReady = false
            authOut.yield(.closed)
        default:
            authOut.yield(.unsupported(type))
        }
    }

    // MARK: Updates

    private func handle(_ object: TDObject) async {
        let update = object.json
        let type = TGParse.string(update["@type"])
        switch type {
        case "updateAuthorizationState":
            if let state = update["authorization_state"] as? JSON { await handleAuthorization(state) }

        case "updateConnectionState":
            let state = TGParse.string((update["state"] as? JSON)?["@type"])
            switch state {
            case "connectionStateReady": eventOut.yield(.connection(.ready))
            case "connectionStateWaitingForNetwork": eventOut.yield(.connection(.waitingForNetwork))
            case "connectionStateUpdating": eventOut.yield(.connection(.updating))
            default: eventOut.yield(.connection(.connecting))
            }

        case "updateNewChat":
            if let chat = update["chat"] as? JSON { eventOut.yield(.chatChanged(TGParse.int64(chat["id"]))) }

        case "updateChatFolders":
            chatFolderInfos = update["chat_folders"] as? [JSON] ?? []
            mainChatListPosition = Int(TGParse.int64(update["main_chat_list_position"]))
            do {
                eventOut.yield(.foldersChanged(try await loadFolders()))
            } catch {
                eventOut.yield(.actionFailed(TGErrors.message(for: error)))
            }

        case "updateChatLastMessage", "updateChatReadInbox", "updateChatPosition",
             "updateChatTitle", "updateChatNotificationSettings":
            eventOut.yield(.chatChanged(TGParse.int64(update["chat_id"])))

        case "updateChatReadOutbox":
            let id = TGParse.int64(update["chat_id"])
            lastReadOutbox[id] = TGParse.int64(update["last_read_outbox_message_id"])
            eventOut.yield(.chatChanged(id))

        case "updateNewMessage":
            if let message = update["message"] as? JSON {
                let chatID = TGParse.int64(message["chat_id"])
                let parsed = TGParse.message(message, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
                registerFiles(in: [parsed])
                eventOut.yield(.newMessage(chatID: chatID, message: parsed))
            }

        case "updateMessageContent":
            if let content = update["new_content"] as? JSON {
                eventOut.yield(.messageContent(
                    chatID: TGParse.int64(update["chat_id"]),
                    remoteID: TGParse.int64(update["message_id"]),
                    text: TGParse.contentText(content)
                ))
            }

        case "updateMessageEdited":
            eventOut.yield(.messageEdited(
                chatID: TGParse.int64(update["chat_id"]),
                remoteID: TGParse.int64(update["message_id"])
            ))

        case "updateMessageIsPinned":
            eventOut.yield(.messagePinned(
                chatID: TGParse.int64(update["chat_id"]),
                remoteID: TGParse.int64(update["message_id"]),
                isPinned: (update["is_pinned"] as? Bool) == true
            ))

        case "updateMessageInteractionInfo":
            let details = TGParse.reactionDetails(
                interactionInfo: update["interaction_info"] as? JSON ?? [:]
            )
            eventOut.yield(.messageReactions(
                chatID: TGParse.int64(update["chat_id"]),
                remoteID: TGParse.int64(update["message_id"]),
                all: details.all,
                chosen: details.chosen,
                viewCount: {
                    let count = Int(TGParse.int64((update["interaction_info"] as? JSON)?["view_count"]))
                    return count > 0 ? count : nil
                }(),
                replyCount: {
                    let replyInfo = (update["interaction_info"] as? JSON)?["reply_info"] as? JSON
                    return replyInfo.map { Int(TGParse.int64($0["reply_count"])) }
                }()
            ))

        case "updateMessageReactions":
            let details = TGParse.reactionDetails(
                reactions: update["reactions"] as? [JSON] ?? []
            )
            eventOut.yield(.messageReactions(
                chatID: TGParse.int64(update["chat_id"]),
                remoteID: TGParse.int64(update["message_id"]),
                all: details.all,
                chosen: details.chosen,
                viewCount: nil,
                replyCount: nil
            ))

        case "updatePoll":
            if let poll = TGParse.pollObject(update["poll"] as? JSON ?? [:]) {
                eventOut.yield(.pollUpdated(poll))
            }

        case "updateMessageSendSucceeded":
            if let message = update["message"] as? JSON {
                let chatID = TGParse.int64(message["chat_id"])
                eventOut.yield(.sendSucceeded(
                    chatID: chatID,
                    oldRemoteID: TGParse.int64(update["old_message_id"]),
                    message: TGParse.message(message, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
                ))
            }

        case "updateMessageSendFailed":
            if let message = update["message"] as? JSON {
                eventOut.yield(.sendFailed(
                    chatID: TGParse.int64(message["chat_id"]),
                    oldRemoteID: TGParse.int64(update["old_message_id"])
                ))
            }

        case "updateDeleteMessages":
            let permanent = (update["is_permanent"] as? Bool) ?? false
            let fromCache = (update["from_cache"] as? Bool) ?? false
            if permanent && !fromCache {
                let ids = ((update["message_ids"] as? [NSNumber]) ?? []).map(\.int64Value)
                eventOut.yield(.deleted(chatID: TGParse.int64(update["chat_id"]), remoteIDs: ids))
            }

        case "updateUserStatus":
            let userID = TGParse.int64(update["user_id"])
            let online = TGParse.string((update["status"] as? JSON)?["@type"]) == "userStatusOnline"
            if var cached = userCache[userID] {
                cached.isOnline = online
                userCache[userID] = cached
            }
            eventOut.yield(.userStatus(userID: userID, isOnline: online))

        case "updateFile":
            guard let file = update["file"] as? JSON else { break }
            let id = TGParse.int64(file["id"])
            knownFileIDs.insert(id)
            let local = file["local"] as? JSON ?? [:]
            let remote = file["remote"] as? JSON ?? [:]
            if (local["is_downloading_completed"] as? Bool) == true {
                recordCachedFile(id, size: TGParse.int64(local["downloaded_size"]))
            }
            let uploadCompleted = (remote["is_uploading_completed"] as? Bool) == true
            if (remote["is_uploading_active"] as? Bool) == true || uploadCompleted
                || TGParse.int64(remote["uploaded_size"]) > 0 {
                eventOut.yield(.uploadProgress(
                    fileID: id,
                    uploaded: TGParse.int64(remote["uploaded_size"]),
                    total: TGParse.int64(file["size"]),
                    completed: uploadCompleted
                ))
            } else {
                eventOut.yield(.fileProgress(
                    fileID: id,
                    downloaded: TGParse.int64(local["downloaded_size"]),
                    total: TGParse.int64(file["size"]),
                    completed: (local["is_downloading_completed"] as? Bool) == true
                ))
            }

        default:
            break
        }
    }

    // MARK: Chats

    func loadChats(limit: Int = 25) async throws -> [Chat] {
        try await loadChatPage(limit: min(max(limit, 1), chatPageSize), loadMore: false)
    }

    func loadMoreChats() async throws -> [Chat] {
        try await loadChatPage(limit: chatPageSize, loadMore: true)
    }

    func loadFolders() async throws -> [ChatFolder] {
        var folders: [ChatFolder] = []
        for info in chatFolderInfos {
            let folderID = Int32(TGParse.int64(info["id"]))
            guard folderID > 0 else { continue }
            let folder = try await call(["@type": "getChatFolder", "chat_folder_id": folderID])
            guard TGParse.string(folder["@type"]) == "chatFolder" else {
                throw TDError(code: -3, message: "CHAT_FOLDER_UNAVAILABLE")
            }
            folders.append(Self.parseChatFolder(folder, info: info))
        }
        return folders
    }

    func saveFolder(_ folder: ChatFolder) async throws -> ChatFolder {
        let payload = Self.chatFolderPayload(folder)
        let result: JSON
        if let telegramID = folder.telegramID {
            result = try await call([
                "@type": "editChatFolder",
                "chat_folder_id": telegramID,
                "folder": payload
            ])
        } else {
            result = try await call(["@type": "createChatFolder", "folder": payload])
        }
        let savedID = Int32(TGParse.int64(result["id"]))
        guard savedID > 0 else {
            throw TDError(code: -3, message: "CHAT_FOLDER_SAVE_FAILED")
        }
        var saved = folder
        saved.telegramID = savedID
        if let index = chatFolderInfos.firstIndex(where: { Int32(TGParse.int64($0["id"])) == savedID }) {
            chatFolderInfos[index] = result
        } else {
            chatFolderInfos.append(result)
        }
        eventOut.yield(.foldersChanged(try await loadFolders()))
        return saved
    }

    func deleteFolder(_ folder: ChatFolder) async throws {
        guard let telegramID = folder.telegramID else {
            throw TDError(code: -3, message: "CHAT_FOLDER_ID_UNAVAILABLE")
        }
        _ = try await call([
            "@type": "deleteChatFolder",
            "chat_folder_id": telegramID,
            "leave_chat_ids": [Int64]()
        ])
        chatFolderInfos.removeAll { Int32(TGParse.int64($0["id"])) == telegramID }
        eventOut.yield(.foldersChanged(try await loadFolders()))
    }

    func reorderFolders(_ folders: [ChatFolder]) async throws {
        let folderIDs = folders.compactMap(\.telegramID)
        guard folderIDs.count == folders.count else {
            throw TDError(code: -3, message: "CHAT_FOLDER_ID_UNAVAILABLE")
        }
        _ = try await call([
            "@type": "reorderChatFolders",
            "chat_folder_ids": folderIDs,
            "main_chat_list_position": mainChatListPosition
        ])
        let byID = Dictionary(uniqueKeysWithValues: chatFolderInfos.map {
            (Int32(TGParse.int64($0["id"])), $0)
        })
        chatFolderInfos = folderIDs.compactMap { byID[$0] }
        eventOut.yield(.foldersChanged(try await loadFolders()))
    }

    func setFolderMembership(_ folder: ChatFolder, chatID: Int64, contains: Bool) async throws -> ChatFolder {
        guard let telegramID = folder.telegramID else {
            throw TDError(code: -3, message: "CHAT_FOLDER_ID_UNAVAILABLE")
        }
        let folderObject = try await call(["@type": "getChatFolder", "chat_folder_id": telegramID])
        var updated = Self.parseChatFolder(folderObject, info: ["id": telegramID])
        var included = updated.includedChatIDs ?? []
        var excluded = updated.excludedChatIDs ?? []
        if contains {
            included.insert(chatID)
            excluded.remove(chatID)
        } else {
            included.remove(chatID)
            excluded.insert(chatID)
        }
        updated.includedChatIDs = included
        updated.excludedChatIDs = excluded
        let result = try await call([
            "@type": "editChatFolder",
            "chat_folder_id": telegramID,
            "folder": Self.chatFolderPayload(updated)
        ])
        updated.telegramID = Int32(TGParse.int64(result["id"]))
        eventOut.yield(.foldersChanged(try await loadFolders()))
        eventOut.yield(.chatChanged(chatID))
        return updated
    }

    private func loadChatPage(limit: Int, loadMore: Bool) async throws -> [Chat] {
        var pageIDs: [Int64] = []
        let perListLimit = (limit + 1) / 2
        for list in ["chatListMain", "chatListArchive"] {
            let listObject: JSON = ["@type": list]
            let previouslyLoaded = loadedChatIDs[list] ?? []
            let desiredCount = loadMore
                ? previouslyLoaded.count + perListLimit
                : max(previouslyLoaded.count, perListLimit)
            var result = try await call([
                "@type": "getChats",
                "chat_list": listObject,
                "limit": desiredCount
            ])
            var found = ((result["chat_ids"] as? [NSNumber]) ?? []).map(\.int64Value)
            if found.count < desiredCount, authReady {
                do {
                    _ = try await call([
                        "@type": "loadChats",
                        "chat_list": listObject,
                        "limit": perListLimit
                    ])
                    result = try await call([
                        "@type": "getChats",
                        "chat_list": listObject,
                        "limit": desiredCount
                    ])
                    found = ((result["chat_ids"] as? [NSNumber]) ?? []).map(\.int64Value)
                } catch {
                    if found.isEmpty { throw error }
                }
            }
            loadedChatIDs[list] = found
            let eligible = loadMore ? found.filter { !previouslyLoaded.contains($0) } : Array(found.prefix(limit))
            pageIDs.append(contentsOf: eligible)
        }

        if !loadMore, authReady {
            let savedID = try await ensureSavedMessagesChat()
            pageIDs.insert(savedID, at: 0)
        }

        var chats: [Chat] = []
        for id in pageIDs where !chats.contains(where: { $0.id == id }) {
            do {
                chats.append(try await self.chat(id))
            } catch {
                if chats.isEmpty { throw error }
            }
        }
        return chats
    }

    private func ensureSavedMessagesChat() async throws -> Int64 {
        if let savedMessagesChatID { return savedMessagesChatID }
        let me = try await call(["@type": "getMe"])
        let userID = TGParse.int64(me["id"])
        guard userID != 0 else {
            throw TDError(code: -3, message: "CURRENT_USER_UNAVAILABLE")
        }
        myUserID = userID
        let savedChat = try await call([
            "@type": "createPrivateChat",
            "user_id": userID,
            "force": false
        ])
        let chatID = TGParse.int64(savedChat["id"])
        guard chatID != 0 else {
            throw TDError(code: -3, message: "SAVED_MESSAGES_UNAVAILABLE")
        }
        savedMessagesChatID = chatID
        return chatID
    }

    private static func parseChatFolder(_ folder: JSON, info: JSON) -> ChatFolder {
        let nameObject = (folder["name"] as? JSON) ?? (info["name"] as? JSON) ?? [:]
        let formattedName = nameObject["text"] as? JSON ?? [:]
        let rawName = TGParse.string(formattedName["text"])
        let iconObject = (folder["icon"] as? JSON) ?? (info["icon"] as? JSON) ?? [:]
        let iconName = TGParse.string(iconObject["name"])
        let telegramID = Int32(TGParse.int64(info["id"] ?? folder["id"]))
        return ChatFolder(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", UInt32(bitPattern: telegramID)))
                ?? UUID(),
            name: rawName.isEmpty ? "Folder" : rawName,
            symbol: appFolderSymbol(for: iconName),
            telegramID: telegramID,
            colorID: Int32(TGParse.int64(folder["color_id"])),
            isShareable: folder["is_shareable"] as? Bool ?? false,
            pinnedChatIDs: Set(((folder["pinned_chat_ids"] as? [NSNumber]) ?? []).map(\.int64Value)),
            includedChatIDs: Set(((folder["included_chat_ids"] as? [NSNumber]) ?? []).map(\.int64Value)),
            excludedChatIDs: Set(((folder["excluded_chat_ids"] as? [NSNumber]) ?? []).map(\.int64Value)),
            excludesMuted: folder["exclude_muted"] as? Bool ?? false,
            excludesRead: folder["exclude_read"] as? Bool ?? false,
            excludesArchived: folder["exclude_archived"] as? Bool ?? false,
            includesContacts: folder["include_contacts"] as? Bool ?? false,
            includesNonContacts: folder["include_non_contacts"] as? Bool ?? false,
            includesBots: folder["include_bots"] as? Bool ?? false,
            includesGroups: folder["include_groups"] as? Bool ?? false,
            includesChannels: folder["include_channels"] as? Bool ?? false
        )
    }

    private static func chatFolderPayload(_ folder: ChatFolder) -> JSON {
        [
            "@type": "chatFolder",
            "name": [
                "@type": "chatFolderName",
                "text": ["@type": "formattedText", "text": folder.name, "entities": []] as JSON,
                "animate_custom_emoji": false
            ] as JSON,
            "icon": ["@type": "chatFolderIcon", "name": telegramFolderIcon(for: folder.symbol)] as JSON,
            "color_id": folder.colorID ?? 0,
            "is_shareable": folder.isShareable ?? false,
            "pinned_chat_ids": Array(folder.pinnedChatIDs ?? []),
            "included_chat_ids": Array(folder.includedChatIDs ?? []),
            "excluded_chat_ids": Array(folder.excludedChatIDs ?? []),
            "exclude_muted": folder.excludesMuted ?? false,
            "exclude_read": folder.excludesRead ?? false,
            "exclude_archived": folder.excludesArchived ?? false,
            "include_contacts": folder.includesContacts ?? false,
            "include_non_contacts": folder.includesNonContacts ?? false,
            "include_bots": folder.includesBots ?? false,
            "include_groups": folder.includesGroups ?? false,
            "include_channels": folder.includesChannels ?? false
        ]
    }

    private static func telegramFolderIcon(for symbol: String) -> String {
        switch symbol {
        case "star": "CustomFolder0"
        case "briefcase": "CustomFolder1"
        case "house": "CustomFolder2"
        case "heart": "CustomFolder3"
        case "book": "CustomFolder4"
        case "gamecontroller": "CustomFolder5"
        case "cart": "CustomFolder6"
        default: "CustomFolder"
        }
    }

    private static func appFolderSymbol(for icon: String) -> String {
        switch icon {
        case "CustomFolder0": "star"
        case "CustomFolder1": "briefcase"
        case "CustomFolder2": "house"
        case "CustomFolder3": "heart"
        case "CustomFolder4": "book"
        case "CustomFolder5": "gamecontroller"
        case "CustomFolder6": "cart"
        default: "folder"
        }
    }

    func chat(_ id: Int64) async throws -> Chat {
        let object = try await call(["@type": "getChat", "chat_id": id])
        let readOutbox = TGParse.int64(object["last_read_outbox_message_id"])
        lastReadOutbox[id] = readOutbox
        var result = TGParse.chat(object, lastReadOutbox: readOutbox)
        if let type = object["type"] as? JSON, TGParse.string(type["@type"]) == "chatTypePrivate" {
            let userID = TGParse.int64(type["user_id"])
            result.isSavedMessages = userID == myUserID
            if result.isSavedMessages { result.title = "Saved Messages" }
            if let info = await self.user(userID) {
                result.isOnline = info.isOnline
                if info.isBot { result.kind = .bot }
                result.avatarFileID = info.avatarFileID
            }
        } else if let type = object["type"] as? JSON,
                  TGParse.string(type["@type"]) == "chatTypeSupergroup" {
            let supergroup = try await call([
                "@type": "getSupergroup",
                "supergroup_id": TGParse.int64(type["supergroup_id"])
            ])
            let status = supergroup["status"] as? JSON ?? [:]
            let rights = status["rights"] as? JSON ?? [:]
            let statusType = TGParse.string(status["@type"])
            let permissions = object["permissions"] as? JSON ?? [:]
            if (type["is_channel"] as? Bool) == true {
                result.canPostMessages = statusType == "chatMemberStatusCreator"
                    || (statusType == "chatMemberStatusAdministrator"
                        && (rights["can_post_messages"] as? Bool) == true)
                result.canPinMessages = statusType == "chatMemberStatusCreator"
                    || (statusType == "chatMemberStatusAdministrator"
                        && (rights["can_pin_messages"] as? Bool) == true)
            }
            result.isForum = (supergroup["is_forum"] as? Bool) == true
            result.canManageTopics = statusType == "chatMemberStatusCreator"
                || (statusType == "chatMemberStatusAdministrator"
                    && (rights["can_manage_topics"] as? Bool) == true)
            result.canCreateTopics = result.canManageTopics
                || (permissions["can_create_topics"] as? Bool) == true
        }
        if let fileID = result.avatarFileID { knownFileIDs.insert(fileID) }
        registerFiles(in: result.messages)
        return result
    }

    private func user(_ id: Int64) async -> TGUser? {
        if let cached = userCache[id] { return cached }
        guard let object = try? await call(["@type": "getUser", "user_id": id]) else { return nil }
        let user = TGParse.user(object)
        userCache[id] = user
        if let fileID = user.avatarFileID { knownFileIDs.insert(fileID) }
        return user
    }

    func myProfile() async throws -> TelegramProfile {
        let user = try await call(["@type": "getMe"])
        let userID = TGParse.int64(user["id"])
        let fullInfo = try await call(["@type": "getUserFullInfo", "user_id": userID])
        let profile = TGParse.profile(user: user, fullInfo: fullInfo)
        if let fileID = profile.avatarFileID { knownFileIDs.insert(fileID) }
        return profile
    }

    func createChannel(title: String, description: String, photoPath: String?) async throws -> ChannelCreationResult {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 128 else {
            throw TDError(code: -3, message: "INVALID_CHANNEL_TITLE")
        }
        let created = try await call([
            "@type": "createNewSupergroupChat",
            "title": normalizedTitle,
            "is_forum": false,
            "is_channel": true,
            "description": normalizedDescription,
            "location": NSNull(),
            "message_auto_delete_time": 0,
            "for_import": false
        ])
        let chatID = TGParse.int64(created["id"])
        guard chatID != 0 else {
            throw TDError(code: -3, message: "CHANNEL_CREATION_FAILED")
        }
        eventOut.yield(.chatChanged(chatID))
        var warnings: [String] = []
        if let photoPath {
            do {
                guard FileManager.default.fileExists(atPath: photoPath) else {
                    throw TDError(code: -3, message: "CHANNEL_PHOTO_UNAVAILABLE")
                }
                _ = try await call([
                    "@type": "setChatPhoto",
                    "chat_id": chatID,
                    "photo": [
                        "@type": "inputChatPhotoStatic",
                        "photo": ["@type": "inputFileLocal", "path": photoPath] as JSON
                    ] as JSON
                ])
            } catch {
                warnings.append(TGErrors.message(for: error))
            }
        }
        eventOut.yield(.chatChanged(chatID))
        return ChannelCreationResult(chatID: chatID, warnings: warnings)
    }

    func channelManagementInfo(chatID: Int64) async throws -> ChannelManagementInfo {
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        let type = chat["type"] as? JSON ?? [:]
        guard TGParse.string(type["@type"]) == "chatTypeSupergroup",
              (type["is_channel"] as? Bool) == true else {
            throw TDError(code: -3, message: "NOT_A_CHANNEL")
        }
        let groupID = TGParse.int64(type["supergroup_id"])
        let supergroup = try await call(["@type": "getSupergroup", "supergroup_id": groupID])
        let full = try await call(["@type": "getSupergroupFullInfo", "supergroup_id": groupID])
        let status = supergroup["status"] as? JSON ?? [:]
        let statusType = TGParse.string(status["@type"])
        let rights = status["rights"] as? JSON ?? [:]
        let isCreator = statusType == "chatMemberStatusCreator"
        let isMember = !["chatMemberStatusLeft", "chatMemberStatusBanned", ""].contains(statusType)
        let invite = TGParse.string((full["invite_link"] as? JSON)?["invite_link"])
        return ChannelManagementInfo(
            isMember: isMember,
            canPostMessages: isCreator
                || (statusType == "chatMemberStatusAdministrator"
                    && (rights["can_post_messages"] as? Bool) == true),
            canPinMessages: isCreator
                || (statusType == "chatMemberStatusAdministrator"
                    && (rights["can_pin_messages"] as? Bool) == true),
            canInviteUsers: isCreator
                || (statusType == "chatMemberStatusAdministrator"
                    && (rights["can_invite_users"] as? Bool) == true),
            subscriberCount: Int(TGParse.int64(full["member_count"])),
            inviteLink: invite.isEmpty ? nil : invite
        )
    }

    func joinChannel(identifier: String) async throws -> Int64 {
        let input = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw TDError(code: -3, message: "CHANNEL_IDENTIFIER_EMPTY") }
        let normalized = input.contains("://") ? input : "https://\(input)"
        let url = URL(string: normalized)
        let path = url?.pathComponents.filter { $0 != "/" } ?? []
        let host = url?.host?.lowercased() ?? ""
        let isTelegramLink = host == "t.me" || host == "telegram.me"
        let isInviteLink = isTelegramLink
            && (path.first?.hasPrefix("+") == true || path.first == "joinchat")
        let chat: JSON
        if isInviteLink {
            let inviteInfo = try await call([
                "@type": "checkChatInviteLink",
                "invite_link": normalized
            ])
            guard TGParse.string((inviteInfo["type"] as? JSON)?["@type"]) == "inviteLinkChatTypeChannel" else {
                throw TDError(code: -3, message: "NOT_A_CHANNEL")
            }
            chat = try await call(["@type": "joinChatByInviteLink", "invite_link": normalized])
        } else {
            let username: String
            if isTelegramLink {
                guard let first = path.first else {
                    throw TDError(code: -3, message: "CHANNEL_IDENTIFIER_INVALID")
                }
                username = first
            } else {
                username = input.hasPrefix("@") ? String(input.dropFirst()) : input
            }
            let publicChat = try await call(["@type": "searchPublicChat", "username": username])
            let foundID = TGParse.int64(publicChat["id"])
            guard foundID != 0 else { throw TDError(code: -3, message: "CHANNEL_NOT_FOUND") }
            let publicType = publicChat["type"] as? JSON ?? [:]
            guard TGParse.string(publicType["@type"]) == "chatTypeSupergroup",
                  (publicType["is_channel"] as? Bool) == true else {
                throw TDError(code: -3, message: "NOT_A_CHANNEL")
            }
            let joinedChat = try await call(["@type": "joinChat", "chat_id": foundID])
            if TGParse.int64(joinedChat["id"]) != 0 {
                chat = joinedChat
            } else {
                chat = publicChat
            }
        }
        let chatID = TGParse.int64(chat["id"])
        guard chatID != 0 else { throw TDError(code: -3, message: "CHANNEL_JOIN_FAILED") }
        let type = chat["type"] as? JSON ?? [:]
        guard TGParse.string(type["@type"]) == "chatTypeSupergroup",
              (type["is_channel"] as? Bool) == true else {
            throw TDError(code: -3, message: "NOT_A_CHANNEL")
        }
        eventOut.yield(.chatChanged(chatID))
        return chatID
    }

    func leaveChannel(chatID: Int64) async throws {
        _ = try await call(["@type": "leaveChat", "chat_id": chatID])
        eventOut.yield(.chatChanged(chatID))
    }

    func loadForumTopics(chatID: Int64) async throws -> [ForumTopic] {
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        let type = chat["type"] as? JSON ?? [:]
        guard TGParse.string(type["@type"]) == "chatTypeSupergroup" else {
            throw TDError(code: -3, message: "NOT_A_FORUM")
        }
        let group = try await call([
            "@type": "getSupergroup",
            "supergroup_id": TGParse.int64(type["supergroup_id"])
        ])
        guard (group["is_forum"] as? Bool) == true else {
            throw TDError(code: -3, message: "NOT_A_FORUM")
        }
        var topics: [ForumTopic] = []
        var offsetDate = 0
        var offsetMessageID: Int64 = 0
        var offsetTopicID: Int64 = 0
        var totalCount = Int.max
        while topics.count < totalCount {
            let result = try await call([
                "@type": "getForumTopics",
                "chat_id": chatID,
                "query": "",
                "offset_date": offsetDate,
                "offset_message_id": offsetMessageID,
                "offset_forum_topic_id": offsetTopicID,
                "limit": 100
            ])
            let page = (result["topics"] as? [JSON]) ?? []
            totalCount = Int(TGParse.int64(result["total_count"]))
            guard !page.isEmpty else { break }
            topics.append(contentsOf: page.compactMap {
                TGParse.forumTopic($0, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
            })
            guard let lastTopic = page.last,
                  let info = lastTopic["info"] as? JSON else { break }
            let nextTopicID = TGParse.int64(info["forum_topic_id"])
            let lastMessage = lastTopic["last_message"] as? JSON ?? [:]
            let nextMessageID = TGParse.int64(lastMessage["id"])
            let nextDate = Int(TGParse.int64(lastMessage["date"]))
            guard nextTopicID != offsetTopicID
                    || nextMessageID != offsetMessageID
                    || nextDate != offsetDate else { break }
            offsetTopicID = nextTopicID
            offsetMessageID = nextMessageID
            offsetDate = nextDate
        }
        return topics.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.order != $1.order { return $0.order > $1.order }
            return $0.id > $1.id
            }
    }

    func createForumTopic(chatID: Int64, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 128 else {
            throw TDError(code: -3, message: "INVALID_TOPIC_NAME")
        }
        _ = try await call([
            "@type": "createForumTopic",
            "chat_id": chatID,
            "name": normalizedName,
            "is_name_implicit": false,
            "icon": [
                "@type": "forumTopicIcon",
                "color": 0x6FB9F0,
                "custom_emoji_id": 0
            ] as JSON
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func editForumTopic(chatID: Int64, topicID: Int64, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topicID > 0, normalizedName.count <= 128 else {
            throw TDError(code: -3, message: "INVALID_TOPIC_NAME")
        }
        _ = try await call([
            "@type": "editForumTopic",
            "chat_id": chatID,
            "forum_topic_id": topicID,
            "name": normalizedName,
            "edit_icon_custom_emoji": false,
            "icon_custom_emoji_id": 0
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func setForumTopicClosed(chatID: Int64, topicID: Int64, closed: Bool) async throws {
        guard topicID > 0 else { throw TDError(code: -3, message: "INVALID_TOPIC_ID") }
        _ = try await call([
            "@type": "toggleForumTopicIsClosed",
            "chat_id": chatID,
            "forum_topic_id": topicID,
            "is_closed": closed
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func loadForumTopicHistory(chatID: Int64, topicID: Int64, limit: Int = 50) async throws -> [Message] {
        guard topicID > 0 else { throw TDError(code: -3, message: "INVALID_TOPIC_ID") }
        let result = try await call([
            "@type": "getForumTopicHistory",
            "chat_id": chatID,
            "forum_topic_id": topicID,
            "from_message_id": 0,
            "offset": 0,
            "limit": limit.clamped(to: 1...100)
        ])
        let messages = ((result["messages"] as? [JSON]) ?? [])
            .reversed()
            .map { TGParse.message($0, lastReadOutbox: lastReadOutbox[chatID] ?? 0) }
        registerFiles(in: messages)
        return messages
    }

    func loadOlderForumTopicHistory(chatID: Int64, topicID: Int64, before messageID: Int64) async throws -> [Message] {
        guard topicID > 0, messageID > 0 else { throw TDError(code: -3, message: "INVALID_TOPIC_ID") }
        let result = try await call([
            "@type": "getForumTopicHistory",
            "chat_id": chatID,
            "forum_topic_id": topicID,
            "from_message_id": messageID,
            "offset": 0,
            "limit": historyPageSize
        ])
        let messages = ((result["messages"] as? [JSON]) ?? [])
            .reversed()
            .map { TGParse.message($0, lastReadOutbox: lastReadOutbox[chatID] ?? 0) }
        registerFiles(in: messages)
        return messages
    }

    func chatProfile(chatID: Int64) async throws -> ChatProfile {
        let object = try await call(["@type": "getChat", "chat_id": chatID])
        let chat = TGParse.chat(object, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
        let type = object["type"] as? JSON ?? [:]
        var profile = ChatProfile(
            chatID: chatID,
            title: chat.title,
            kind: chat.kind,
            username: nil,
            phoneNumber: nil,
            status: nil,
            description: "",
            memberCount: nil,
            avatarFileID: chat.avatarFileID
        )
        switch TGParse.string(type["@type"]) {
        case "chatTypePrivate":
            let userID = TGParse.int64(type["user_id"])
            let user = try await call(["@type": "getUser", "user_id": userID])
            let full = try await call(["@type": "getUserFullInfo", "user_id": userID])
            let userProfile = TGParse.profile(user: user, fullInfo: full)
            profile.username = userProfile.username
            profile.phoneNumber = userProfile.phoneNumber
            profile.description = userProfile.bio
            profile.status = TGParse.string((user["status"] as? JSON)?["@type"])
            profile.avatarFileID = userProfile.avatarFileID
        case "chatTypeBasicGroup":
            let groupID = TGParse.int64(type["basic_group_id"])
            let full = try await call(["@type": "getBasicGroupFullInfo", "basic_group_id": groupID])
            profile.description = TGParse.string(full["description"])
        case "chatTypeSupergroup":
            let groupID = TGParse.int64(type["supergroup_id"])
            let supergroup = try await call(["@type": "getSupergroup", "supergroup_id": groupID])
            let usernames = ((supergroup["usernames"] as? JSON)?["active_usernames"] as? [String]) ?? []
            profile.username = usernames.first
            let full = try await call(["@type": "getSupergroupFullInfo", "supergroup_id": groupID])
            profile.description = TGParse.string(full["description"])
            let memberCount = TGParse.int64(full["member_count"])
            profile.memberCount = memberCount > 0 ? Int(memberCount) : nil
        default:
            break
        }
        if let fileID = profile.avatarFileID { knownFileIDs.insert(fileID) }
        return profile
    }

    func createGroup(title: String, memberIDs: [Int64], photoPath: String?) async throws -> GroupCreationResult {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 128 else {
            throw TDError(code: -3, message: "INVALID_GROUP_TITLE")
        }
        let created = try await call([
            "@type": "createNewSupergroupChat",
            "title": normalizedTitle,
            "is_forum": false,
            "is_channel": false,
            "description": "",
            "location": NSNull(),
            "message_auto_delete_time": 0,
            "for_import": false
        ])
        let chatID = TGParse.int64(created["id"])
        guard chatID != 0 else {
            throw TDError(code: -3, message: "GROUP_CREATION_FAILED")
        }
        eventOut.yield(.chatChanged(chatID))

        var warnings: [String] = []
        let uniqueMemberIDs = Array(Set(memberIDs.filter { $0 != 0 }))
        if !uniqueMemberIDs.isEmpty {
            do {
                try await addGroupMembers(chatID: chatID, userIDs: uniqueMemberIDs)
            } catch {
                warnings.append(TGErrors.message(for: error))
            }
        }
        if let photoPath {
            do {
                guard FileManager.default.fileExists(atPath: photoPath) else {
                    throw TDError(code: -3, message: "GROUP_PHOTO_UNAVAILABLE")
                }
                _ = try await call([
                    "@type": "setChatPhoto",
                    "chat_id": chatID,
                    "photo": [
                        "@type": "inputChatPhotoStatic",
                        "photo": ["@type": "inputFileLocal", "path": photoPath] as JSON
                    ] as JSON
                ])
            } catch {
                warnings.append(TGErrors.message(for: error))
            }
        }
        eventOut.yield(.chatChanged(chatID))
        return GroupCreationResult(chatID: chatID, warnings: warnings)
    }

    func groupManagementInfo(chatID: Int64) async throws -> GroupManagementInfo {
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        let chatType = chat["type"] as? JSON ?? [:]
        let type = TGParse.string(chatType["@type"])
        let isBasicGroup = type == "chatTypeBasicGroup"
        guard isBasicGroup || type == "chatTypeSupergroup" else {
            throw TDError(code: -3, message: "NOT_A_GROUP")
        }

        let status: JSON
        let fullInfo: JSON
        var memberList: [JSON]
        let memberCount: Int
        let canViewMembers: Bool
        var supergroupID: Int64?
        var nextMemberOffset = 0
        var hasMoreMembers = false
        if isBasicGroup {
            supergroupID = nil
            let groupID = TGParse.int64(chatType["basic_group_id"])
            let group = try await call(["@type": "getBasicGroup", "basic_group_id": groupID])
            fullInfo = try await call(["@type": "getBasicGroupFullInfo", "basic_group_id": groupID])
            status = group["status"] as? JSON ?? [:]
            memberList = fullInfo["members"] as? [JSON] ?? []
            memberCount = Int(TGParse.int64(group["member_count"]))
            canViewMembers = true
            nextMemberOffset = memberList.count
        } else {
            let groupID = TGParse.int64(chatType["supergroup_id"])
            supergroupID = groupID
            let group = try await call(["@type": "getSupergroup", "supergroup_id": groupID])
            fullInfo = try await call(["@type": "getSupergroupFullInfo", "supergroup_id": groupID])
            status = group["status"] as? JSON ?? [:]
            memberCount = Int(TGParse.int64(fullInfo["member_count"]))
            canViewMembers = (fullInfo["can_get_members"] as? Bool) == true
            if canViewMembers {
                let result = try await call([
                    "@type": "getSupergroupMembers",
                    "supergroup_id": groupID,
                    "filter": ["@type": "supergroupMembersFilterRecent"] as JSON,
                    "offset": 0,
                    "limit": 200
                ])
                memberList = result["members"] as? [JSON] ?? []
                nextMemberOffset = memberList.count
                let totalRecentMembers = Int(TGParse.int64(result["total_count"]))
                hasMoreMembers = !memberList.isEmpty && nextMemberOffset < totalRecentMembers
            } else {
                memberList = []
            }
        }

        let statusType = TGParse.string(status["@type"])
        let isCreator = statusType == "chatMemberStatusCreator"
        let isAdministrator = statusType == "chatMemberStatusAdministrator"
        let rights = status["rights"] as? JSON ?? [:]
        let permissions = chat["permissions"] as? JSON ?? [:]
        let hasInviteRight = (rights["can_invite_users"] as? Bool) == true
        let canInviteMembers = isCreator
            || hasInviteRight
            || (permissions["can_invite_users"] as? Bool) == true
        let canCreateInviteLink = isCreator || (isAdministrator && hasInviteRight)
        let canPromoteMembers = !isBasicGroup && (isCreator
            || (rights["can_promote_members"] as? Bool) == true)
        let canRestrictMembers = !isBasicGroup && (isCreator
            || (rights["can_restrict_members"] as? Bool) == true)
        if let supergroupID, canViewMembers {
            var filters: [JSON] = []
            if canPromoteMembers {
                filters.append(["@type": "supergroupMembersFilterAdministrators"])
            }
            if canRestrictMembers {
                filters.append(["@type": "supergroupMembersFilterRestricted", "query": ""])
                filters.append(["@type": "supergroupMembersFilterBanned", "query": ""])
            }
            for filter in filters {
                let result = try await call([
                    "@type": "getSupergroupMembers",
                    "supergroup_id": supergroupID,
                    "filter": filter,
                    "offset": 0,
                    "limit": 200
                ])
                memberList.append(contentsOf: result["members"] as? [JSON] ?? [])
            }
        }
        let members = await parseGroupMembers(memberList)

        let inviteInfo = fullInfo["invite_link"] as? JSON
        let inviteLink = TGParse.string(inviteInfo?["invite_link"])
        return GroupManagementInfo(
            isBasicGroup: isBasicGroup,
            isCreator: isCreator,
            canViewMembers: canViewMembers,
            canInviteMembers: canInviteMembers,
            canCreateInviteLink: canCreateInviteLink,
            canPromoteMembers: canPromoteMembers,
            canRestrictMembers: canRestrictMembers,
            memberCount: memberCount,
            inviteLink: inviteLink.isEmpty ? nil : inviteLink,
            members: members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            nextMemberOffset: nextMemberOffset,
            hasMoreMembers: hasMoreMembers
        )
    }

    func loadMoreGroupMembers(chatID: Int64, offset: Int) async throws -> GroupMembersPage {
        guard offset >= 0 else {
            throw TDError(code: -3, message: "GROUP_MEMBER_OFFSET_INVALID")
        }
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        let chatType = chat["type"] as? JSON ?? [:]
        guard TGParse.string(chatType["@type"]) == "chatTypeSupergroup" else {
            throw TDError(code: -3, message: "NOT_A_GROUP")
        }
        let result = try await call([
            "@type": "getSupergroupMembers",
            "supergroup_id": TGParse.int64(chatType["supergroup_id"]),
            "filter": ["@type": "supergroupMembersFilterRecent"] as JSON,
            "offset": Int32(clamping: offset),
            "limit": 200
        ])
        let rawMembers = result["members"] as? [JSON] ?? []
        let nextOffset = offset + rawMembers.count
        let totalCount = Int(TGParse.int64(result["total_count"]))
        return GroupMembersPage(
            members: await parseGroupMembers(rawMembers),
            nextOffset: nextOffset,
            hasMore: !rawMembers.isEmpty && nextOffset < totalCount
        )
    }

    private func parseGroupMembers(_ rawMembers: [JSON]) async -> [GroupMember] {
        var members: [GroupMember] = []
        var seenUserIDs = Set<Int64>()
        for rawMember in rawMembers {
            guard let member = TGParse.groupMember(rawMember, name: L("group.member.unknown")),
                  seenUserIDs.insert(member.userID).inserted else {
                continue
            }
            let name = await user(member.userID)?.name
            members.append(GroupMember(
                userID: member.userID,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? member.name,
                status: member.status
            ))
        }
        return members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addGroupMembers(chatID: Int64, userIDs: [Int64]) async throws {
        let uniqueIDs = Array(Set(userIDs.filter { $0 != 0 }))
        guard !uniqueIDs.isEmpty else { return }
        let result = try await call([
            "@type": "addChatMembers",
            "chat_id": chatID,
            "user_ids": uniqueIDs
        ])
        let failures = result["failed_to_add_members"] as? [JSON] ?? []
        guard failures.isEmpty else {
            throw TDError(code: -3, message: "GROUP_MEMBER_ADD_FAILED")
        }
        eventOut.yield(.chatChanged(chatID))
    }

    func updateGroupMember(
        chatID: Int64,
        userID: Int64,
        status: GroupMemberStatus,
        adminRights: GroupAdminRights?
    ) async throws {
        let memberStatus: JSON
        switch status {
        case .creator:
            throw TDError(code: -3, message: "GROUP_MEMBER_STATUS_INVALID")
        case .administrator:
            guard let adminRights else {
                throw TDError(code: -3, message: "GROUP_ADMIN_RIGHTS_REQUIRED")
            }
            memberStatus = [
                "@type": "chatMemberStatusAdministrator",
                "can_be_edited": false,
                "rights": [
                    "@type": "chatAdministratorRights",
                    "can_manage_chat": adminRights.canManageChat,
                    "can_change_info": adminRights.canChangeInfo,
                    "can_post_messages": false,
                    "can_edit_messages": false,
                    "can_delete_messages": false,
                    "can_invite_users": adminRights.canInviteUsers,
                    "can_restrict_members": adminRights.canRestrictMembers,
                    "can_pin_messages": adminRights.canPinMessages,
                    "can_manage_topics": false,
                    "can_promote_members": adminRights.canPromoteMembers,
                    "can_manage_video_chats": false,
                    "can_post_stories": false,
                    "can_edit_stories": false,
                    "can_delete_stories": false,
                    "can_manage_direct_messages": false,
                    "can_manage_tags": false,
                    "can_send_welcome_messages": false,
                    "is_anonymous": false
                ] as JSON
            ]
        case .member:
            memberStatus = ["@type": "chatMemberStatusMember", "member_until_date": 0]
        case .restricted:
            memberStatus = [
                "@type": "chatMemberStatusRestricted",
                "is_member": true,
                "restricted_until_date": Int32(Date().timeIntervalSince1970) + 31_536_000,
                "permissions": [
                    "@type": "chatPermissions",
                    "can_send_basic_messages": false,
                    "can_send_audios": false,
                    "can_send_documents": false,
                    "can_send_photos": false,
                    "can_send_videos": false,
                    "can_send_video_notes": false,
                    "can_send_voice_notes": false,
                    "can_send_polls": false,
                    "can_send_other_messages": false,
                    "can_add_link_previews": false,
                    "can_react_to_messages": false,
                    "can_edit_tag": false,
                    "can_change_info": false,
                    "can_invite_users": false,
                    "can_pin_messages": false,
                    "can_create_topics": false
                ] as JSON
            ]
        case .left:
            memberStatus = ["@type": "chatMemberStatusLeft"]
        case .banned:
            memberStatus = ["@type": "chatMemberStatusBanned", "banned_until_date": 0]
        }
        _ = try await call([
            "@type": "setChatMemberStatus",
            "chat_id": chatID,
            "member_id": ["@type": "messageSenderUser", "user_id": userID] as JSON,
            "status": memberStatus
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func createGroupInviteLink(chatID: Int64) async throws -> String {
        let result = try await call([
            "@type": "createChatInviteLink",
            "chat_id": chatID,
            "name": "",
            "expiration_date": 0,
            "member_limit": 0,
            "creates_join_request": false
        ])
        let link = TGParse.string(result["invite_link"])
        guard !link.isEmpty else {
            throw TDError(code: -3, message: "GROUP_INVITE_LINK_UNAVAILABLE")
        }
        return link
    }

    func upgradeBasicGroup(chatID: Int64) async throws -> Int64 {
        let result = try await call([
            "@type": "upgradeBasicGroupChatToSupergroupChat",
            "chat_id": chatID
        ])
        let upgradedChatID = TGParse.int64(result["id"])
        guard upgradedChatID != 0 else {
            throw TDError(code: -3, message: "GROUP_UPGRADE_FAILED")
        }
        eventOut.yield(.chatChanged(chatID))
        eventOut.yield(.chatChanged(upgradedChatID))
        return upgradedChatID
    }

    func leaveGroup(chatID: Int64) async throws {
        _ = try await call(["@type": "leaveChat", "chat_id": chatID])
        eventOut.yield(.chatChanged(chatID))
    }

    func updateMyProfile(firstName: String, lastName: String, bio: String) async throws {
        _ = try await call([
            "@type": "setName",
            "first_name": firstName,
            "last_name": lastName
        ])
        _ = try await call([
            "@type": "setBio",
            "bio": ["@type": "formattedText", "text": bio] as JSON
        ])
    }

    func loadContacts(limit: Int = 300) async throws -> [Contact] {
        let result = try await call(["@type": "getContacts"])
        let ids = ((result["user_ids"] as? [NSNumber]) ?? []).map(\.int64Value).prefix(limit)
        var contacts: [Contact] = []
        for id in ids {
            if let info = await self.user(id) {
                contacts.append(Contact(
                    id: id,
                    name: info.name,
                    username: info.username,
                    isOnline: info.isOnline,
                    avatarFileID: info.avatarFileID
                ))
            }
        }
        return contacts
    }

    func setPinned(chatID: Int64, pinned: Bool, archived: Bool = false) async throws {
        _ = try await call([
            "@type": "toggleChatIsPinned",
            "chat_list": ["@type": archived ? "chatListArchive" : "chatListMain"] as JSON,
            "chat_id": chatID,
            "is_pinned": pinned
        ])
    }

    func setArchived(chatID: Int64, archived: Bool) async throws {
        _ = try await call([
            "@type": "addChatToList",
            "chat_id": chatID,
            "chat_list": ["@type": archived ? "chatListArchive" : "chatListMain"] as JSON
        ])
    }

    func setMuted(chatID: Int64, duration: Int32) async throws {
        guard duration >= 0 else {
            throw TDError(code: -3, message: "INVALID_MUTE_DURATION")
        }
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        var settings = chat["notification_settings"] as? JSON ?? [:]
        settings["@type"] = "chatNotificationSettings"
        settings["use_default_mute_for"] = false
        settings["mute_for"] = duration
        _ = try await call([
            "@type": "setChatNotificationSettings",
            "chat_id": chatID,
            "notification_settings": settings
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func setMarkedUnread(chatID: Int64, marked: Bool) async throws {
        _ = try await call([
            "@type": "toggleChatIsMarkedAsUnread",
            "chat_id": chatID,
            "is_marked_as_unread": marked
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func loadNotificationSettings(chatID: Int64) async throws -> ChatNotificationSettings {
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        let settings = chat["notification_settings"] as? JSON ?? [:]
        return ChatNotificationSettings(
            muteFor: Int32(clamping: TGParse.int64(settings["mute_for"])),
            soundEnabled: TGParse.int64(settings["sound_id"]) != 0
                || (settings["use_default_sound"] as? Bool) == true,
            showPreview: (settings["show_preview"] as? Bool) ?? true
        )
    }

    func saveNotificationSettings(chatID: Int64, settings values: ChatNotificationSettings) async throws {
        guard values.muteFor >= 0 else {
            throw TDError(code: -3, message: "INVALID_MUTE_DURATION")
        }
        let chat = try await call(["@type": "getChat", "chat_id": chatID])
        var settings = chat["notification_settings"] as? JSON ?? [:]
        settings["@type"] = "chatNotificationSettings"
        settings["use_default_mute_for"] = false
        settings["mute_for"] = values.muteFor
        if values.soundEnabled {
            if TGParse.int64(settings["sound_id"]) == 0 {
                settings["use_default_sound"] = true
            } else {
                settings["use_default_sound"] = false
            }
        } else {
            settings["use_default_sound"] = false
            settings["sound_id"] = 0
        }
        settings["use_default_show_preview"] = false
        settings["show_preview"] = values.showPreview
        _ = try await call([
            "@type": "setChatNotificationSettings",
            "chat_id": chatID,
            "notification_settings": settings
        ])
        eventOut.yield(.chatChanged(chatID))
    }

    func registerDevice(token: String, isSandbox: Bool) async throws -> Int64 {
        guard !token.isEmpty else {
            throw TDError(code: -3, message: "PUSH_TOKEN_EMPTY")
        }
        guard authReady else {
            throw TDError(code: -3, message: "AUTHORIZATION_NOT_READY")
        }
        let result = try await call([
            "@type": "registerDevice",
            "device_token": [
                "@type": "deviceTokenApplePush",
                "device_token": token,
                "is_app_sandbox": isSandbox
            ] as JSON,
            "other_user_ids": [Int64]()
        ])
        guard TGParse.string(result["@type"]) == "pushReceiverId" else {
            throw TDError(code: -3, message: "PUSH_REGISTRATION_FAILED")
        }
        let receiverID = TGParse.int64(result["id"])
        guard receiverID != 0 else {
            throw TDError(code: -3, message: "PUSH_REGISTRATION_FAILED")
        }
        return receiverID
    }

    func processPushNotification(payload: String) async throws {
        guard !payload.isEmpty else {
            throw TDError(code: -3, message: "PUSH_PAYLOAD_EMPTY")
        }
        _ = try await call(["@type": "processPushNotification", "payload": payload])
    }

    // MARK: Messages

    func loadHistory(chatID: Int64, limit: Int = 50) async throws -> [Message] {
        var list: [JSON] = []
        for attempt in 0..<2 {
            let result = try await call([
                "@type": "getChatHistory",
                "chat_id": chatID,
                "from_message_id": 0,
                "offset": 0,
                "limit": limit,
                "only_local": false
            ])
            list = (result["messages"] as? [JSON]) ?? []
            if list.count > 1 || attempt == 1 { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let readOutbox = lastReadOutbox[chatID] ?? 0
        let messages = list.reversed().map { TGParse.message($0, lastReadOutbox: readOutbox) }
        registerFiles(in: messages)
        return messages
    }

    func loadOlderHistory(chatID: Int64, before messageID: Int64) async throws -> [Message] {
        let result = try await call([
            "@type": "getChatHistory",
            "chat_id": chatID,
            "from_message_id": messageID,
            "offset": 0,
            "limit": historyPageSize,
            "only_local": false
        ])
        let readOutbox = lastReadOutbox[chatID] ?? 0
        let messages = ((result["messages"] as? [JSON]) ?? [])
            .reversed()
            .map { TGParse.message($0, lastReadOutbox: readOutbox) }
        registerFiles(in: messages)
        return messages
    }

    func loadMessage(chatID: Int64, messageID: Int64) async throws -> Message {
        let message = try await call([
            "@type": "getMessage",
            "chat_id": chatID,
            "message_id": messageID
        ])
        let parsed = TGParse.message(message, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
        registerFiles(in: [parsed])
        return parsed
    }

    func loadDiscussionThread(chatID: Int64, messageID: Int64, limit: Int = 50) async throws -> DiscussionThreadPage {
        guard chatID != 0, messageID > 0 else {
            throw TDError(code: -3, message: "INVALID_MESSAGE_THREAD")
        }
        let info = try await call([
            "@type": "getMessageThread",
            "chat_id": chatID,
            "message_id": messageID
        ])
        let discussionChatID = TGParse.int64(info["chat_id"])
        let threadMessageID = TGParse.int64(info["message_thread_id"])
        guard discussionChatID != 0, threadMessageID > 0 else {
            throw TDError(code: -3, message: "INVALID_MESSAGE_THREAD")
        }
        let result = try await call([
            "@type": "getMessageThreadHistory",
            "chat_id": chatID,
            "message_id": messageID,
            "from_message_id": 0,
            "offset": 0,
            "limit": limit.clamped(to: 1...100)
        ])
        let messages = ((result["messages"] as? [JSON]) ?? [])
            .filter { TGParse.int64($0["id"]) != threadMessageID }
            .reversed()
            .map { TGParse.message($0, lastReadOutbox: lastReadOutbox[discussionChatID] ?? 0) }
        registerFiles(in: messages)
        return DiscussionThreadPage(
            chatID: discussionChatID,
            threadMessageID: threadMessageID,
            messages: messages
        )
    }

    func loadOlderDiscussionComments(
        chatID: Int64,
        messageID: Int64,
        discussionChatID: Int64,
        threadMessageID: Int64,
        before replyMessageID: Int64
    ) async throws -> [Message] {
        guard chatID != 0, messageID > 0, discussionChatID != 0,
              threadMessageID > 0, replyMessageID > 0 else {
            throw TDError(code: -3, message: "INVALID_MESSAGE_THREAD")
        }
        let result = try await call([
            "@type": "getMessageThreadHistory",
            "chat_id": chatID,
            "message_id": messageID,
            "from_message_id": replyMessageID,
            "offset": 0,
            "limit": 50
        ])
        let messages = ((result["messages"] as? [JSON]) ?? [])
            .filter { TGParse.int64($0["id"]) != threadMessageID }
            .reversed()
            .map { TGParse.message($0, lastReadOutbox: lastReadOutbox[discussionChatID] ?? 0) }
        registerFiles(in: messages)
        return messages
    }

    func sendDiscussionComment(chatID: Int64, threadMessageID: Int64, text: String) async throws -> Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatID != 0, threadMessageID > 0, !trimmed.isEmpty else {
            throw TDError(code: -3, message: "INVALID_MESSAGE_THREAD")
        }
        let sent = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "reply_to": [
                "@type": "inputMessageReplyToMessage",
                "message_id": threadMessageID,
                "quote": NSNull(),
                "checklist_task_id": 0
            ] as JSON,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": trimmed,
                    "entities": []
                ] as JSON
            ] as JSON
        ])
        return TGParse.message(sent, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
    }

    private func registerFiles(in messages: [Message]) {
        for message in messages {
            guard let media = message.media else { continue }
            knownFileIDs.insert(media.fileID)
            knownFileKinds[media.fileID] = media.kind
        }
    }

    func downloadFileData(fileID: Int64, limit: Int64) async throws -> Data {
        let url = try await downloadFileURL(fileID: fileID, limit: limit)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func downloadFileURL(fileID: Int64, limit: Int64) async throws -> URL {
        let file = try await call(["@type": "getFile", "file_id": fileID])
        let remoteSize = TGParse.int64(file["size"])
        guard remoteSize <= limit else {
            throw TDError(code: -3, message: "FILE_TOO_LARGE")
        }
        knownFileIDs.insert(fileID)

        if let url = try localFileURL(file, limit: limit) {
            let size = TGParse.int64(file["size"])
            try await makeMediaCacheRoom(for: fileID, expectedSize: size)
            recordCachedFile(fileID, size: size)
            return url
        }
        try await makeMediaCacheRoom(
            for: fileID,
            expectedSize: remoteSize > 0 ? remoteSize : limit
        )
        _ = try await call([
            "@type": "downloadFile",
            "file_id": fileID,
            "priority": 32,
            "offset": 0,
            "limit": limit,
            "synchronous": false
        ])
        activeDownloadIDs.insert(fileID)
        defer { activeDownloadIDs.remove(fileID) }

        for _ in 0..<14_400 {
            try Task.checkCancellation()
            let current = try await call(["@type": "getFile", "file_id": fileID])
            let currentSize = TGParse.int64(current["size"])
            if currentSize > limit {
                try await cancelFileDownload(fileID: fileID)
                throw TDError(code: -3, message: "FILE_TOO_LARGE")
            }
            if let url = try localFileURL(current, limit: limit) {
                let size = TGParse.int64(current["size"])
                try await makeMediaCacheRoom(for: fileID, expectedSize: size)
                recordCachedFile(fileID, size: size)
                return url
            }
            let downloaded = TGParse.int64((current["local"] as? JSON)?["downloaded_size"])
            if downloaded > limit {
                try await cancelFileDownload(fileID: fileID)
                throw TDError(code: -3, message: "FILE_TOO_LARGE")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw TDError(code: -4, message: "FILE_DOWNLOAD_TIMEOUT")
    }

    private func localFileURL(_ file: JSON, limit: Int64) throws -> URL? {
        let local = file["local"] as? JSON ?? [:]
        guard (local["is_downloading_completed"] as? Bool) == true else { return nil }
        let path = TGParse.string(local["path"])
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else { throw TDError(code: -3, message: "FILE_TOO_LARGE") }
        return url
    }

    private func makeMediaCacheRoom(for fileID: Int64, expectedSize: Int64) async throws {
        guard expectedSize > 0 else { return }
        guard expectedSize <= mediaCacheLimit else {
            throw TDError(code: -5, message: "MEDIA_CACHE_FULL")
        }
        var total = cachedDownloadedSizes
            .filter { $0.key != fileID }
            .values
            .reduce(0, +)
        while total + expectedSize > mediaCacheLimit {
            guard let index = downloadedFileOrder.firstIndex(where: { $0 != fileID }) else { break }
            let id = downloadedFileOrder[index]
            guard let size = cachedDownloadedSizes[id] else {
                downloadedFileOrder.remove(at: index)
                continue
            }
            _ = try await call(["@type": "deleteFile", "file_id": id])
            cachedDownloadedSizes[id] = nil
            downloadedFileOrder.remove(at: index)
            total -= size
        }
        guard total + expectedSize <= mediaCacheLimit else {
            throw TDError(code: -5, message: "MEDIA_CACHE_FULL")
        }
    }

    private func recordCachedFile(_ id: Int64, size: Int64) {
        cachedDownloadedSizes[id] = size
        downloadedFileOrder.removeAll { $0 == id }
        downloadedFileOrder.append(id)
    }

    func cancelFileDownload(fileID: Int64) async throws {
        _ = try await call([
            "@type": "cancelDownloadFile",
            "file_id": fileID,
            "only_if_pending": false
        ])
        eventOut.yield(.fileCancelled(fileID: fileID))
    }

    private func topicField(_ topicID: Int64?) -> Any {
        guard let topicID else { return NSNull() }
        return ["@type": "messageTopicForum", "forum_topic_id": topicID]
    }

    func sendPhoto(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        try validateOutgoingFile(path, limit: 10 * 1_024 * 1_024)
        let message = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessagePhoto",
                "photo": ["@type": "inputFileLocal", "path": path] as JSON,
                "thumbnail": NSNull(),
                "added_sticker_file_ids": [],
                "width": 0,
                "height": 0,
                "caption": ["@type": "formattedText", "text": caption] as JSON,
                "show_caption_above_media": false,
                "self_destruct_type": NSNull(),
                "has_spoiler": false
            ] as JSON
        ])
        registerOutgoingUpload(message, path: path, chatID: chatID)
    }

    func sendDocument(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        try validateOutgoingFile(path, limit: 1_073_741_824)
        let sent = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageDocument",
                "document": ["@type": "inputFileLocal", "path": path] as JSON,
                "thumbnail": NSNull(),
                "caption": ["@type": "formattedText", "text": caption] as JSON,
                "disable_content_type_detection": false
            ] as JSON
        ])
        registerOutgoingUpload(sent, path: path, chatID: chatID)
    }

    func sendVideo(chatID: Int64, path: String, caption: String, topicID: Int64? = nil) async throws {
        try validateOutgoingFile(path, limit: 1_073_741_824)
        let sent = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageVideo",
                "video": ["@type": "inputFileLocal", "path": path] as JSON,
                "thumbnail": NSNull(),
                "added_sticker_file_ids": [],
                "duration": 0,
                "width": 0,
                "height": 0,
                "supports_streaming": true,
                "caption": ["@type": "formattedText", "text": caption] as JSON,
                "show_caption_above_media": false,
                "self_destruct_type": NSNull(),
                "has_spoiler": false
            ] as JSON
        ])
        registerOutgoingUpload(sent, path: path, chatID: chatID)
    }

    private func registerOutgoingUpload(_ message: JSON, path: String, chatID: Int64) {
        let content = message["content"] as? JSON ?? [:]
        guard let media = TGParse.media(content) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? media.fileSize
        eventOut.yield(.uploadStarted(
            fileID: media.fileID,
            chatID: chatID,
            messageID: TGParse.int64(message["id"]),
            title: media.fileName ?? URL(fileURLWithPath: path).lastPathComponent,
            total: size,
            sourcePath: path
        ))
    }

    func cancelUpload(fileID: Int64, chatID: Int64, messageID: Int64) async throws {
        guard fileID != 0, chatID != 0, messageID != 0 else {
            throw TDError(code: -3, message: "INVALID_UPLOAD")
        }
        let message = try await call(["@type": "getMessage", "chat_id": chatID, "message_id": messageID])
        guard TGParse.string((message["sending_state"] as? JSON)?["@type"]) == "messageSendingStatePending" else {
            throw TDError(code: -3, message: "UPLOAD_ALREADY_COMPLETED")
        }
        _ = try await call([
            "@type": "deleteMessages",
            "chat_id": chatID,
            "message_ids": [messageID],
            "revoke": true
        ])
        eventOut.yield(.uploadCancelled(fileID: fileID))
    }

    func sendMediaAlbum(
        chatID: Int64,
        items: [OutgoingAlbumMedia],
        caption: String,
        topicID: Int64? = nil
    ) async throws {
        guard (2...10).contains(items.count) else {
            throw TDError(code: -3, message: "INVALID_MEDIA_ALBUM")
        }
        let contents: [JSON] = try items.enumerated().map { index, item in
            let itemCaption = index == 0 ? caption : ""
            switch item {
            case .photo(let path):
                try validateOutgoingFile(path, limit: 10 * 1_024 * 1_024)
                return [
                    "@type": "inputMessagePhoto",
                    "photo": ["@type": "inputFileLocal", "path": path] as JSON,
                    "thumbnail": NSNull(),
                    "added_sticker_file_ids": [],
                    "width": 0,
                    "height": 0,
                    "caption": ["@type": "formattedText", "text": itemCaption] as JSON,
                    "show_caption_above_media": false,
                    "self_destruct_type": NSNull(),
                    "has_spoiler": false
                ]
            case .video(let path):
                try validateOutgoingFile(path, limit: 25 * 1_024 * 1_024)
                return [
                    "@type": "inputMessageVideo",
                    "video": ["@type": "inputFileLocal", "path": path] as JSON,
                    "thumbnail": NSNull(),
                    "cover": NSNull(),
                    "start_timestamp": 0,
                    "added_sticker_file_ids": [],
                    "duration": 0,
                    "width": 0,
                    "height": 0,
                    "supports_streaming": true,
                    "caption": ["@type": "formattedText", "text": itemCaption] as JSON,
                    "show_caption_above_media": false,
                    "self_destruct_type": NSNull(),
                    "has_spoiler": false
                ]
            }
        }
        let result = try await call([
            "@type": "sendMessageAlbum",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_contents": contents,
            "send_options": NSNull()
        ])
        let messages = result["messages"] as? [JSON] ?? []
        for (item, message) in zip(items, messages) {
            let path: String
            switch item {
            case .photo(let itemPath), .video(let itemPath):
                path = itemPath
            }
            registerOutgoingUpload(message, path: path, chatID: chatID)
        }
    }

    func sendVideoNote(chatID: Int64, path: String, duration: Int, length: Int, topicID: Int64? = nil) async throws {
        try validateOutgoingFile(path, limit: 25 * 1_024 * 1_024)
        guard (1...60).contains(duration) else {
            throw TDError(code: -3, message: "INVALID_MEDIA_DURATION")
        }
        let normalizedLength = max(1, min(640, length))
        let message = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageVideoNote",
                "video_note": ["@type": "inputFileLocal", "path": path] as JSON,
                "thumbnail": NSNull(),
                "duration": duration,
                "length": normalizedLength,
                "self_destruct_type": NSNull()
            ] as JSON
        ])
        registerOutgoingUpload(message, path: path, chatID: chatID)
    }

    func sendVoiceNote(chatID: Int64, path: String, duration: Int, topicID: Int64? = nil) async throws {
        try validateOutgoingFile(path, limit: 25 * 1_024 * 1_024)
        guard (1...60).contains(duration) else {
            throw TDError(code: -3, message: "INVALID_MEDIA_DURATION")
        }
        let message = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageVoiceNote",
                "voice_note": [
                    "@type": "inputVoiceNote",
                    "voice_note": ["@type": "inputFileLocal", "path": path] as JSON,
                    "duration": duration,
                    "waveform": ""
                ] as JSON,
                "caption": ["@type": "formattedText", "text": ""] as JSON,
                "self_destruct_type": NSNull()
            ] as JSON
        ])
        registerOutgoingUpload(message, path: path, chatID: chatID)
    }

    func sendPoll(
        chatID: Int64,
        question: String,
        options: [String],
        isAnonymous: Bool,
        allowsMultipleAnswers: Bool,
        topicID: Int64? = nil
    ) async throws {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOptions = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmedQuestion.isEmpty, (trimmedQuestion as NSString).length <= 300,
              (2...10).contains(trimmedOptions.count),
              trimmedOptions.allSatisfy({ !$0.isEmpty && ($0 as NSString).length <= 100 }) else {
            throw TDError(code: -3, message: "INVALID_POLL")
        }
        _ = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessagePoll",
                "question": ["@type": "formattedText", "text": trimmedQuestion] as JSON,
                "options": trimmedOptions.map {
                    [
                        "@type": "inputPollOption",
                        "text": ["@type": "formattedText", "text": $0] as JSON,
                        "media": NSNull()
                    ] as JSON
                },
                "description": ["@type": "formattedText", "text": ""] as JSON,
                "media": NSNull(),
                "is_anonymous": isAnonymous,
                "allows_multiple_answers": allowsMultipleAnswers,
                "allows_revoting": false,
                "members_only": false,
                "country_codes": [],
                "shuffle_options": false,
                "hide_results_until_closes": false,
                "type": ["@type": "inputPollTypeRegular", "allow_adding_options": false] as JSON,
                "open_period": 0,
                "close_date": 0,
                "is_closed": false
            ] as JSON
        ])
    }

    func sendContact(chatID: Int64, firstName: String, lastName: String, phoneNumber: String, topicID: Int64? = nil) async throws {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !phone.isEmpty else {
            throw TDError(code: -3, message: "INVALID_CONTACT")
        }
        _ = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageContact",
                "contact": [
                    "@type": "contact",
                    "phone_number": phone,
                    "first_name": first,
                    "last_name": last,
                    "vcard": "",
                    "user_id": 0
                ] as JSON
            ] as JSON
        ])
    }

    func sendLocation(chatID: Int64, latitude: Double, longitude: Double, topicID: Int64? = nil) async throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw TDError(code: -3, message: "INVALID_LOCATION")
        }
        _ = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageLocation",
                "location": [
                    "@type": "location",
                    "latitude": latitude,
                    "longitude": longitude,
                    "horizontal_accuracy": 0
                ] as JSON
            ] as JSON
        ])
    }

    func votePoll(chatID: Int64, messageID: Int64, optionIDs: [Int]) async throws -> Message {
        guard optionIDs.count <= 10,
              optionIDs.allSatisfy({ (0..<10).contains($0) }),
              Set(optionIDs).count == optionIDs.count else {
            throw TDError(code: -3, message: "INVALID_POLL_ANSWER")
        }
        _ = try await call([
            "@type": "setPollAnswer",
            "chat_id": chatID,
            "message_id": messageID,
            "option_ids": optionIDs
        ])
        let message = try await call([
            "@type": "getMessage",
            "chat_id": chatID,
            "message_id": messageID
        ])
        return TGParse.message(message, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
    }

    func loadStickers() async throws -> [TelegramSticker] {
        let stickerSets = try await loadStickerSets()
        var stickers: [TelegramSticker] = []
        for set in stickerSets.filter({ $0.isInstalled && !$0.isArchived }).prefix(5) {
            stickers.append(contentsOf: try await loadStickers(setID: set.id).prefix(24))
        }
        return stickers
    }

    func loadStickerSets() async throws -> [TelegramStickerSet] {
        let sets = try await call([
            "@type": "getInstalledStickerSets",
            "sticker_type": ["@type": "stickerTypeRegular"] as JSON
        ])
        return TGParse.stickerSets(sets)
    }

    func searchStickerSets(query: String) async throws -> [TelegramStickerSet] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try await loadStickerSets() }
        let result = try await call([
            "@type": "searchStickerSets",
            "sticker_type": ["@type": "stickerTypeRegular"] as JSON,
            "query": normalized
        ])
        return TGParse.stickerSets(result)
    }

    func loadStickers(setID: Int64) async throws -> [TelegramSticker] {
        guard setID != 0 else { throw TDError(code: -3, message: "INVALID_STICKER_SET") }
        return TGParse.stickers(try await call(["@type": "getStickerSet", "set_id": setID]))
    }

    func loadRecentStickers() async throws -> [TelegramSticker] {
        let result = try await call([
            "@type": "getRecentStickers",
            "is_attached": false
        ])
        return TGParse.stickers(["stickers": result["stickers"] as? [JSON] ?? []])
    }

    func setStickerSetInstalled(setID: Int64, installed: Bool) async throws {
        guard setID != 0 else { throw TDError(code: -3, message: "INVALID_STICKER_SET") }
        _ = try await call([
            "@type": "changeStickerSet",
            "set_id": setID,
            "is_installed": installed,
            "is_archived": false
        ])
    }

    func sendSticker(chatID: Int64, sticker: TelegramSticker, topicID: Int64? = nil) async throws {
        guard sticker.id != 0, sticker.width > 0, sticker.height > 0 else {
            throw TDError(code: -3, message: "INVALID_STICKER")
        }
        _ = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageSticker",
                "sticker": ["@type": "inputFileId", "id": sticker.id] as JSON,
                "thumbnail": NSNull(),
                "width": sticker.width,
                "height": sticker.height,
                "emoji": sticker.emoji
            ] as JSON
        ])
    }

    func loadSavedAnimations() async throws -> [TelegramAnimation] {
        TGParse.savedAnimations(try await call(["@type": "getSavedAnimations"]))
    }

    func searchAnimations(chatID: Int64, query: String) async throws -> [TelegramAnimation] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let botID: Int64
        if let animationSearchBotUserID {
            botID = animationSearchBotUserID
        } else {
            let chat = try await call(["@type": "searchPublicChat", "username": "gif"])
            let chatType = chat["type"] as? JSON ?? [:]
            botID = TGParse.int64(chatType["user_id"])
            guard botID != 0 else { throw TDError(code: -3, message: "ANIMATION_BOT_NOT_FOUND") }
            animationSearchBotUserID = botID
        }
        let results = try await call([
            "@type": "getInlineQueryResults",
            "bot_user_id": botID,
            "chat_id": chatID,
            "user_location": NSNull(),
            "query": normalized,
            "offset": ""
        ])
        return TGParse.inlineAnimations(results)
    }

    func setAnimationSaved(_ animation: TelegramAnimation, saved: Bool) async throws {
        let function = saved ? "addSavedAnimation" : "removeSavedAnimation"
        _ = try await call([
            "@type": function,
            "animation": ["@type": "inputFileId", "id": animation.fileID] as JSON
        ])
    }

    func sendAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64? = nil) async throws {
        guard animation.fileID != 0 else { throw TDError(code: -3, message: "INVALID_ANIMATION") }
        _ = try await call([
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "input_message_content": [
                "@type": "inputMessageAnimation",
                "animation": [
                    "@type": "inputAnimation",
                    "animation": ["@type": "inputFileId", "id": animation.fileID] as JSON,
                    "thumbnail": NSNull(),
                    "added_sticker_file_ids": [],
                    "duration": animation.duration,
                    "width": animation.width,
                    "height": animation.height
                ] as JSON,
                "caption": ["@type": "formattedText", "text": ""] as JSON,
                "show_caption_above_media": false,
                "has_spoiler": false
            ] as JSON
        ])
    }

    func sendInlineAnimation(chatID: Int64, animation: TelegramAnimation, topicID: Int64? = nil) async throws {
        guard let queryID = animation.queryID, let resultID = animation.resultID else {
            throw TDError(code: -3, message: "INVALID_INLINE_ANIMATION")
        }
        _ = try await call([
            "@type": "sendInlineQueryResultMessage",
            "chat_id": chatID,
            "topic_id": topicField(topicID),
            "query_id": queryID,
            "result_id": resultID,
            "hide_via_bot": true
        ])
    }

    func searchEmojis(query: String, languageCodes: [String]) async throws -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let result = try await call([
            "@type": "searchEmojis",
            "text": normalized,
            "input_language_codes": languageCodes
        ])
        return TGParse.emojiKeywords(result)
    }

    func loadCustomEmojiImages(ids: [Int64]) async throws -> [Int64: Data] {
        var seen = Set<Int64>()
        let uniqueIDs = ids.filter { $0 != 0 && seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return [:] }
        let result = try await call([
            "@type": "getCustomEmojiStickers",
            "custom_emoji_ids": uniqueIDs
        ])
        let stickers = TGParse.stickers(result)
        var images: [Int64: Data] = [:]
        for (customEmojiID, sticker) in zip(uniqueIDs, stickers) where sticker.format == .webp {
            if let data = try? await downloadFileData(fileID: sticker.id, limit: 2 * 1_024 * 1_024) {
                images[customEmojiID] = data
            }
        }
        return images
    }

    private func validateOutgoingFile(_ path: String, limit: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= limit else {
            throw TDError(code: -3, message: "FILE_TOO_LARGE")
        }
    }

    func clearMediaCache() async throws {
        try await clearMediaCache(kind: nil)
    }

    func clearMediaCache(kind: MessageMediaKind?) async throws {
        let downloads = activeDownloadIDs
        for id in downloads where kind == nil || knownFileKinds[id] == kind {
            try await cancelFileDownload(fileID: id)
        }
        let fileIDs = knownFileIDs.filter { kind == nil || knownFileKinds[$0] == kind }
        for id in fileIDs {
            let file = try await call(["@type": "getFile", "file_id": id])
            let local = file["local"] as? JSON ?? [:]
            if (local["is_downloading_completed"] as? Bool) == true {
                _ = try await call(["@type": "deleteFile", "file_id": id])
            }
            knownFileIDs.remove(id)
            knownFileKinds[id] = nil
            cachedDownloadedSizes[id] = nil
            downloadedFileOrder.removeAll { $0 == id }
            activeDownloadIDs.remove(id)
        }
    }

    func sendText(
        chatID: Int64,
        text: String,
        replyToRemoteID: Int64?,
        entities: [MessageEntity] = []
    ) async throws -> Message {
        let formattedText: JSON = [
            "@type": "formattedText",
            "text": text,
            "entities": entities.map(TGParse.entityJSON)
        ]
        let content: JSON = [
            "@type": "inputMessageText",
            "text": formattedText
        ]
        var query: JSON = ["@type": "sendMessage", "chat_id": chatID, "input_message_content": content]
        if let reply = replyToRemoteID, reply != 0 {
            query["reply_to"] = ["@type": "inputMessageReplyToMessage", "message_id": reply] as JSON
        }
        let sent = try await call(query)
        return TGParse.message(sent, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
    }

    func sendTopicMessage(
        text: String,
        chatID: Int64,
        topicID: Int64,
        replyToRemoteID: Int64?,
        entities: [MessageEntity]
    ) async throws -> Message {
        guard topicID > 0 else { throw TDError(code: -3, message: "INVALID_TOPIC_ID") }
        var query: JSON = [
            "@type": "sendMessage",
            "chat_id": chatID,
            "topic_id": [
                "@type": "messageTopicForum",
                "forum_topic_id": topicID
            ] as JSON,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": text,
                    "entities": entities.map(TGParse.entityJSON)
                ] as JSON
            ] as JSON
        ]
        if let replyToRemoteID, replyToRemoteID > 0 {
            query["reply_to"] = [
                "@type": "inputMessageReplyToMessage",
                "message_id": replyToRemoteID
            ] as JSON
        } else {
            query["reply_to"] = NSNull()
        }
        let sent = try await call(query)
        return TGParse.message(sent, lastReadOutbox: lastReadOutbox[chatID] ?? 0)
    }

    func editText(chatID: Int64, messageID: Int64, text: String) async throws {
        let content: JSON = [
            "@type": "inputMessageText",
            "text": ["@type": "formattedText", "text": text] as JSON
        ]
        _ = try await call([
            "@type": "editMessageText",
            "chat_id": chatID,
            "message_id": messageID,
            "input_message_content": content
        ])
    }

    func deleteMessage(chatID: Int64, messageID: Int64, revoke: Bool) async throws {
        try await deleteMessages(chatID: chatID, messageIDs: [messageID], revoke: revoke)
    }

    func deleteMessages(chatID: Int64, messageIDs: [Int64], revoke: Bool) async throws {
        let uniqueIDs = Array(Set(messageIDs))
        guard !uniqueIDs.isEmpty, uniqueIDs.count <= 100,
              uniqueIDs.allSatisfy({ $0 > 0 }) else {
            throw TDError(code: -3, message: "INVALID_DELETE_SELECTION")
        }
        _ = try await call([
            "@type": "deleteMessages",
            "chat_id": chatID,
            "message_ids": uniqueIDs,
            "revoke": revoke
        ])
    }

    func setMessageReaction(chatID: Int64, messageID: Int64, emoji: String?) async throws -> [String] {
        let reactionType: JSON
        if let emoji {
            reactionType = ["@type": "reactionTypeEmoji", "emoji": emoji]
        } else {
            reactionType = ["@type": "reactionTypeNone"]
        }
        _ = try await call([
            "@type": "addMessageReaction",
            "chat_id": chatID,
            "message_id": messageID,
            "reaction_type": reactionType,
            "is_big": false,
            "update_recent_reactions": false
        ])
        let message = try await call([
            "@type": "getMessage",
            "chat_id": chatID,
            "message_id": messageID
        ])
        return TGParse.reactions(message)
    }

    func setMessagePinned(chatID: Int64, messageID: Int64, pinned: Bool) async throws {
        if pinned {
            _ = try await call([
                "@type": "pinChatMessage",
                "chat_id": chatID,
                "message_id": messageID,
                "disable_notification": false,
                "only_for_self": false
            ])
        } else {
            _ = try await call([
                "@type": "unpinChatMessage",
                "chat_id": chatID,
                "message_id": messageID
            ])
        }
    }

    func forwardMessages(
        fromChatID: Int64,
        toChatID: Int64,
        messageIDs: [Int64],
        hideSender: Bool
    ) async throws {
        let orderedIDs = messageIDs.sorted()
        guard !orderedIDs.isEmpty, orderedIDs.count <= 100,
              Set(orderedIDs).count == orderedIDs.count else {
            throw TDError(code: -3, message: "INVALID_FORWARD_SELECTION")
        }
        let result = try await call([
            "@type": "forwardMessages",
            "chat_id": toChatID,
            "topic_id": NSNull(),
            "from_chat_id": fromChatID,
            "message_ids": orderedIDs,
            "options": NSNull(),
            "send_copy": hideSender,
            "remove_caption": false
        ])
        guard let messages = result["messages"] as? [Any],
              messages.count == orderedIDs.count,
              messages.allSatisfy({ !($0 is NSNull) }) else {
            throw TDError(code: -3, message: "FORWARD_NOT_ALLOWED")
        }
    }

    func searchMessages(chatID: Int64, query: String, fromMessageID: Int64, limit: Int) async throws -> [Message] {
        let result = try await call([
            "@type": "searchChatMessages",
            "chat_id": chatID,
            "topic_id": NSNull(),
            "query": query,
            "sender_id": NSNull(),
            "from_message_id": fromMessageID,
            "offset": 0,
            "limit": limit.clamped(to: 1...100),
            "filter": NSNull()
        ])
        return ((result["messages"] as? [JSON]) ?? [])
            .map { TGParse.message($0, lastReadOutbox: lastReadOutbox[chatID] ?? 0) }
    }

    /// Sends a read receipt. Called only when the user opted in (or tapped "mark as read").
    func markRead(chatID: Int64, messageIDs: [Int64]) async throws {
        guard !messageIDs.isEmpty else {
            throw TDError(code: -3, message: "READ_MESSAGES_UNAVAILABLE")
        }
        _ = try await call([
            "@type": "viewMessages",
            "chat_id": chatID,
            "message_ids": messageIDs,
            "source": ["@type": "messageSourceChatHistory"] as JSON,
            "force_read": true
        ])
    }

    /// Tells TDLib the chat is open (needed for live updates in groups/channels). Does not mark anything as read.
    func setChatOpen(_ chatID: Int64, _ open: Bool) async {
        _ = try? await call(["@type": open ? "openChat" : "closeChat", "chat_id": chatID])
    }

    func sendTyping(chatID: Int64) async {
        guard !privacy.hideTyping, authReady else { return }
        _ = try? await call([
            "@type": "sendChatAction",
            "chat_id": chatID,
            "action": ["@type": "chatActionTyping"] as JSON
        ])
    }

    func activeSessions() async throws -> [TelegramSession] {
        TGParse.activeSessions(try await call(["@type": "getActiveSessions"]))
    }

    func terminateSession(_ id: Int64) async throws {
        guard id != 0 else { throw TDError(code: -3, message: "INVALID_SESSION") }
        let currentSessions = try await activeSessions()
        guard let session = currentSessions.first(where: { $0.id == id }), !session.isCurrent else {
            throw TDError(code: -3, message: "CANNOT_TERMINATE_CURRENT_SESSION")
        }
        _ = try await call(["@type": "terminateSession", "session_id": id])
    }

    func terminateOtherSessions() async throws {
        _ = try await call(["@type": "terminateAllOtherSessions"])
    }

    func telegramPrivacySettings() async throws -> [TelegramPrivacyPreference] {
        var preferences: [TelegramPrivacyPreference] = []
        for setting in TelegramPrivacySetting.allCases {
            let result = try await call([
                "@type": "getUserPrivacySettingRules",
                "setting": ["@type": setting.tdlibType] as JSON
            ])
            preferences.append(TGParse.privacyPreference(setting: setting, value: result))
        }
        return preferences
    }

    func setTelegramPrivacy(_ setting: TelegramPrivacySetting, policy: TelegramPrivacyPolicy) async throws {
        let existing = try await call([
            "@type": "getUserPrivacySettingRules",
            "setting": ["@type": setting.tdlibType] as JSON
        ])
        var preference = TGParse.privacyPreference(setting: setting, value: existing)
        preference.policy = policy
        _ = try await call([
            "@type": "setUserPrivacySettingRules",
            "setting": ["@type": setting.tdlibType] as JSON,
            "rules": TGParse.privacyRulesJSON(preference)
        ])
    }

    func blockedTelegramUsers() async throws -> [BlockedTelegramUser] {
        let result = try await call([
            "@type": "getBlockedMessageSenders",
            "block_list": ["@type": "blockListMain"] as JSON,
            "offset": 0,
            "limit": 100
        ])
        var blocked: [BlockedTelegramUser] = []
        for id in TGParse.blockedUserIDs(result) {
            let profile = await user(id)
            blocked.append(BlockedTelegramUser(id: id, name: profile?.name ?? "User \(id)", username: profile?.username))
        }
        return blocked
    }

    func unblockTelegramUser(_ id: Int64) async throws {
        guard id != 0 else { throw TDError(code: -3, message: "INVALID_USER_ID") }
        _ = try await call([
            "@type": "setMessageSenderBlockList",
            "sender_id": ["@type": "messageSenderUser", "user_id": id] as JSON,
            "block_list": NSNull()
        ])
    }

    func telegramPasswordState() async throws -> TelegramPasswordState {
        TGParse.passwordState(try await call(["@type": "getPasswordState"]))
    }

    func updateTelegramPassword(current: String, new: String, hint: String) async throws -> TelegramPasswordState {
        if !new.isEmpty {
            guard (6...256).contains(new.count), new != current else {
                throw TDError(code: -3, message: "INVALID_NEW_PASSWORD")
            }
            guard hint.count <= 255, !hint.localizedCaseInsensitiveContains(new) else {
                throw TDError(code: -3, message: "INVALID_PASSWORD_HINT")
            }
        }
        let result = try await call([
            "@type": "setPassword",
            "old_password": current,
            "new_password": new,
            "new_hint": hint,
            "set_recovery_email_address": false,
            "new_recovery_email_address": ""
        ])
        return TGParse.passwordState(result)
    }

    // MARK: Presence / privacy

    func apply(privacy snapshot: PrivacySnapshot) async {
        privacy = snapshot
        await applyOnlineStatus()
    }

    func setForeground(_ foreground: Bool) async {
        isForeground = foreground
        await applyOnlineStatus()
    }

    private func applyOnlineStatus() async {
        guard authReady else { return }
        let online = isForeground && !privacy.hideOnline
        _ = try? await call([
            "@type": "setOption",
            "name": "online",
            "value": ["@type": "optionValueBoolean", "value": online] as JSON
        ])
    }

    // MARK: Helpers

    private func call(_ query: JSON) async throws -> JSON {
        try await client.request(query).json
    }

    private static func databaseDirectory() throws -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KroGram/tdlib", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }
}
