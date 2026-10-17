// Copyright © 2026 Kro. KroGram original materials.

import Foundation

struct TGUser: Sendable, Equatable {
    var name: String
    var username: String?
    var isBot: Bool
    var isOnline: Bool
    var avatarFileID: Int64?
}

/// Pure functions that turn TDLib JSON objects into app models.
enum TGParse {
    static func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    static func string(_ value: Any?) -> String { value as? String ?? "" }

    static func activeSessions(_ value: JSON) -> [TelegramSession] {
        (value["sessions"] as? [JSON] ?? []).compactMap { session in
            let id = int64(session["id"])
            guard id != 0 else { return nil }
            return TelegramSession(
                id: id,
                isCurrent: (session["is_current"] as? Bool) == true,
                isPasswordPending: (session["is_password_pending"] as? Bool) == true,
                isUnconfirmed: (session["is_unconfirmed"] as? Bool) == true,
                deviceType: string((session["device_type"] as? JSON)?["@type"]),
                applicationName: string(session["application_name"]),
                applicationVersion: string(session["application_version"]),
                isOfficialApplication: (session["is_official_application"] as? Bool) == true,
                deviceModel: string(session["device_model"]),
                platform: string(session["platform"]),
                systemVersion: string(session["system_version"]),
                loginDate: Date(timeIntervalSince1970: TimeInterval(int64(session["log_in_date"]))),
                lastActiveDate: Date(timeIntervalSince1970: TimeInterval(int64(session["last_active_date"]))),
                ipAddress: string(session["ip_address"]),
                location: string(session["location"])
            )
        }
    }

    static func privacyPreference(
        setting: TelegramPrivacySetting,
        value: JSON
    ) -> TelegramPrivacyPreference {
        let rules = value["rules"] as? [JSON] ?? []
        var policy: TelegramPrivacyPolicy = .contacts
        for rule in rules {
            switch string(rule["@type"]) {
            case "userPrivacySettingRuleAllowAll": policy = .everyone
            case "userPrivacySettingRuleAllowContacts": policy = .contacts
            case "userPrivacySettingRuleRestrictAll": policy = .nobody
            default: continue
            }
        }
        let exceptionTypes: Set<String> = [
            "userPrivacySettingRuleAllowUsers",
            "userPrivacySettingRuleRestrictUsers",
            "userPrivacySettingRuleAllowChatMembers",
            "userPrivacySettingRuleRestrictChatMembers",
            "userPrivacySettingRuleAllowBots",
            "userPrivacySettingRuleRestrictBots",
            "userPrivacySettingRuleAllowPremiumUsers"
        ]
        let exceptions = rules.compactMap { rule -> TelegramPrivacyRule? in
            let type = string(rule["@type"])
            guard exceptionTypes.contains(type) else { return nil }
            return TelegramPrivacyRule(
                type: type,
                userIDs: (rule["user_ids"] as? [NSNumber] ?? []).map(\.int64Value),
                chatIDs: (rule["chat_ids"] as? [NSNumber] ?? []).map(\.int64Value)
            )
        }
        return TelegramPrivacyPreference(setting: setting, policy: policy, exceptionRules: exceptions)
    }

    static func privacyRulesJSON(_ preference: TelegramPrivacyPreference) -> JSON {
        let exceptions = preference.exceptionRules.map { rule -> JSON in
            var value: JSON = ["@type": rule.type]
            if rule.type.hasSuffix("Users") { value["user_ids"] = rule.userIDs }
            if rule.type.hasSuffix("ChatMembers") { value["chat_ids"] = rule.chatIDs }
            return value
        }
        let defaults: [JSON]
        switch preference.policy {
        case .everyone:
            defaults = [["@type": "userPrivacySettingRuleAllowAll"]]
        case .contacts:
            defaults = [
                ["@type": "userPrivacySettingRuleAllowContacts"],
                ["@type": "userPrivacySettingRuleRestrictAll"]
            ]
        case .nobody:
            defaults = [["@type": "userPrivacySettingRuleRestrictAll"]]
        }
        return ["@type": "userPrivacySettingRules", "rules": exceptions + defaults]
    }

    static func blockedUserIDs(_ value: JSON) -> [Int64] {
        (value["senders"] as? [JSON] ?? []).compactMap { sender in
            let type = sender["sender"] as? JSON ?? sender
            guard string(type["@type"]) == "messageSenderUser" else { return nil }
            let id = int64(type["user_id"])
            return id == 0 ? nil : id
        }
    }

    static func passwordState(_ value: JSON) -> TelegramPasswordState {
        let pendingReset = int64(value["pending_reset_date"])
        let pattern = string((value["recovery_email_address_code_info"] as? JSON)?["email_address_pattern"])
        return TelegramPasswordState(
            hasPassword: (value["has_password"] as? Bool) == true,
            hint: string(value["password_hint"]),
            hasRecoveryEmail: (value["has_recovery_email_address"] as? Bool) == true,
            recoveryEmailPattern: pattern,
            pendingResetDate: pendingReset == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(pendingReset))
        )
    }

    static func contentText(_ content: JSON) -> String {
        let type = string(content["@type"])
        let caption = string((content["caption"] as? JSON)?["text"])
        let venue = content["venue"] as? JSON ?? [:]
        let point = (content["location"] as? JSON) ?? (venue["location"] as? JSON) ?? [:]
        let coordinates: String
        if let latitude = (point["latitude"] as? NSNumber)?.doubleValue,
           let longitude = (point["longitude"] as? NSNumber)?.doubleValue {
            coordinates = String(format: "%.5f, %.5f", latitude, longitude)
        } else {
            coordinates = ""
        }
        func labeled(_ key: String) -> String {
            caption.isEmpty ? L(key) : L(key) + " " + caption
        }
        switch type {
        case "messageText": return string((content["text"] as? JSON)?["text"])
        case "messagePhoto": return labeled("msg.photo")
        case "messageVideo": return labeled("msg.video")
        case "messageAnimation": return labeled("msg.gif")
        case "messageDocument": return labeled("msg.file")
        case "messageAudio": return labeled("msg.audio")
        case "messageVoiceNote": return labeled("msg.voice")
        case "messageVideoNote": return L("msg.videoNote")
        case "messageSticker": return L("msg.sticker")
        case "messagePoll":
            return L("msg.poll")
        case "messageContact":
            let contact = content["contact"] as? JSON ?? [:]
            let name = [string(contact["first_name"]), string(contact["last_name"])]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let phone = string(contact["phone_number"])
            return [L("msg.contact"), name, phone].filter { !$0.isEmpty }.joined(separator: "\n")
        case "messageLocation":
            return L("msg.location") + "\n" + coordinates
        case "messageVenue":
            let title = string(venue["title"])
            let address = string(venue["address"])
            return [L("msg.location"), title, address, coordinates].filter { !$0.isEmpty }.joined(separator: "\n")
        default: return L("msg.unsupported")
        }
    }

    static func entities(_ values: Any?) -> [MessageEntity] {
        (values as? [JSON] ?? []).compactMap { entity in
            let offset = Int(int64(entity["offset"]))
            let length = Int(int64(entity["length"]))
            guard offset >= 0, length > 0, let type = entity["type"] as? JSON else { return nil }
            let kind: MessageEntityKind
            switch string(type["@type"]) {
            case "textEntityTypeBold": kind = .bold
            case "textEntityTypeItalic": kind = .italic
            case "textEntityTypeCode": kind = .code
            case "textEntityTypePre", "textEntityTypePreCode": kind = .pre
            case "textEntityTypeBlockQuote", "textEntityTypeExpandableBlockQuote": kind = .quote
            case "textEntityTypeSpoiler": kind = .spoiler
            case "textEntityTypeUnderline": kind = .underline
            case "textEntityTypeStrikethrough": kind = .strikethrough
            case "textEntityTypeUrl": kind = .url
            case "textEntityTypeEmailAddress": kind = .email
            case "textEntityTypePhoneNumber": kind = .phoneNumber
            case "textEntityTypeMention": kind = .mention
            case "textEntityTypeHashtag": kind = .hashtag
            case "textEntityTypeCashtag": kind = .cashtag
            case "textEntityTypeBotCommand": kind = .botCommand
            case "textEntityTypeTextUrl":
                let url = string(type["url"])
                guard !url.isEmpty else { return nil }
                kind = .textURL(url)
            case "textEntityTypeMentionName":
                let userID = int64(type["user_id"])
                guard userID != 0 else { return nil }
                kind = .mentionName(userID)
            case "textEntityTypeCustomEmoji":
                let customEmojiID = int64(type["custom_emoji_id"])
                guard customEmojiID != 0 else { return nil }
                kind = .customEmoji(customEmojiID)
            default:
                return nil
            }
            return MessageEntity(offset: offset, length: length, kind: kind)
        }
    }

    static func entityJSON(_ entity: MessageEntity) -> JSON {
        let type: JSON
        switch entity.kind {
        case .bold: type = ["@type": "textEntityTypeBold"]
        case .italic: type = ["@type": "textEntityTypeItalic"]
        case .code: type = ["@type": "textEntityTypeCode"]
        case .pre: type = ["@type": "textEntityTypePreCode", "language": ""]
        case .quote: type = ["@type": "textEntityTypeBlockQuote", "is_expandable": false]
        case .spoiler: type = ["@type": "textEntityTypeSpoiler"]
        case .underline: type = ["@type": "textEntityTypeUnderline"]
        case .strikethrough: type = ["@type": "textEntityTypeStrikethrough"]
        case .url: type = ["@type": "textEntityTypeUrl"]
        case .email: type = ["@type": "textEntityTypeEmailAddress"]
        case .phoneNumber: type = ["@type": "textEntityTypePhoneNumber"]
        case .mention: type = ["@type": "textEntityTypeMention"]
        case .hashtag: type = ["@type": "textEntityTypeHashtag"]
        case .cashtag: type = ["@type": "textEntityTypeCashtag"]
        case .botCommand: type = ["@type": "textEntityTypeBotCommand"]
        case .textURL(let url): type = ["@type": "textEntityTypeTextUrl", "url": url]
        case .mentionName(let userID): type = ["@type": "textEntityTypeMentionName", "user_id": userID]
        case .customEmoji(let customEmojiID):
            type = ["@type": "textEntityTypeCustomEmoji", "custom_emoji_id": customEmojiID]
        }
        return [
            "@type": "textEntity",
            "offset": entity.offset,
            "length": entity.length,
            "type": type
        ]
    }

    static func media(_ content: JSON) -> MessageMedia? {
        let type = string(content["@type"])
        let mediaKind: MessageMediaKind
        let file: JSON
        var fileName: String?
        var mimeType: String?
        var fileSize: Int64 = 0
        var stickerFormat: StickerFormat?

        switch type {
        case "messagePhoto":
            mediaKind = .photo
            let photo = content["photo"] as? JSON ?? [:]
            let sizes = photo["sizes"] as? [JSON] ?? []
            file = (sizes.last?["photo"] as? JSON) ?? [:]
            fileSize = int64(file["size"])
        case "messageVideo":
            mediaKind = .video
            let item = content["video"] as? JSON ?? [:]
            file = item["video"] as? JSON ?? [:]
            fileName = string(item["file_name"])
            mimeType = string(item["mime_type"])
            fileSize = int64(file["size"])
        case "messageAnimation":
            mediaKind = .animation
            let item = content["animation"] as? JSON ?? [:]
            file = item["animation"] as? JSON ?? [:]
            fileName = string(item["file_name"])
            mimeType = string(item["mime_type"])
            fileSize = int64(file["size"])
        case "messageDocument":
            mediaKind = .document
            let item = content["document"] as? JSON ?? [:]
            file = item["document"] as? JSON ?? [:]
            fileName = string(item["file_name"])
            mimeType = string(item["mime_type"])
            fileSize = int64(file["size"])
        case "messageAudio":
            mediaKind = .audio
            let item = content["audio"] as? JSON ?? [:]
            file = item["audio"] as? JSON ?? [:]
            fileName = string(item["file_name"])
            mimeType = string(item["mime_type"])
            fileSize = int64(file["size"])
        case "messageVoiceNote":
            mediaKind = .voice
            let item = content["voice_note"] as? JSON ?? [:]
            file = item["voice"] as? JSON ?? [:]
            mimeType = string(item["mime_type"])
            fileSize = int64(file["size"])
        case "messageVideoNote":
            mediaKind = .videoNote
            let item = content["video_note"] as? JSON ?? [:]
            file = item["video"] as? JSON ?? [:]
            fileSize = int64(file["size"])
        case "messageSticker":
            mediaKind = .sticker
            let item = content["sticker"] as? JSON ?? [:]
            file = item["sticker"] as? JSON ?? [:]
            fileSize = int64(file["size"])
            stickerFormat = parseStickerFormat(file["format"])
        default:
            return nil
        }

        let id = int64(file["id"])
        guard id != 0 else { return nil }
        return MessageMedia(
            kind: mediaKind,
            fileID: id,
            fileName: fileName.flatMap { $0.isEmpty ? nil : $0 },
            mimeType: mimeType.flatMap { $0.isEmpty ? nil : $0 },
            fileSize: fileSize,
            caption: string((content["caption"] as? JSON)?["text"]),
            captionEntities: entities((content["caption"] as? JSON)?["entities"]),
            stickerFormat: stickerFormat
        )
    }

    static func parseStickerFormat(_ value: Any?) -> StickerFormat? {
        guard let format = value as? JSON else { return nil }
        switch string(format["@type"]) {
        case "stickerFormatWebp": return .webp
        case "stickerFormatTgs": return .tgs
        case "stickerFormatWebm": return .webm
        default: return nil
        }
    }

    static func savedAnimations(_ value: JSON) -> [TelegramAnimation] {
        (value["animations"] as? [JSON] ?? []).compactMap { animation($0) }
    }

    static func inlineAnimations(_ value: JSON) -> [TelegramAnimation] {
        let queryID = int64(value["inline_query_id"])
        return (value["results"] as? [JSON] ?? []).compactMap { result in
            guard string(result["@type"]) == "inlineQueryResultAnimation",
                  let animationValue = result["animation"] as? JSON else { return nil }
            let resultID = string(result["id"])
            return animation(
                animationValue,
                id: resultID,
                title: string(result["title"]),
                queryID: queryID,
                resultID: resultID
            )
        }
    }

    static func emojiKeywords(_ value: JSON) -> [String] {
        var seen = Set<String>()
        return (value["emoji_keywords"] as? [JSON] ?? []).compactMap { item in
            let emoji = string(item["emoji"])
            guard !emoji.isEmpty, seen.insert(emoji).inserted else { return nil }
            return emoji
        }
    }

    private static func animation(
        _ value: JSON,
        id: String? = nil,
        title: String = "",
        queryID: Int64? = nil,
        resultID: String? = nil
    ) -> TelegramAnimation? {
        let file = value["animation"] as? JSON ?? [:]
        let fileID = int64(file["id"])
        guard fileID != 0 else { return nil }
        let fileName = string(value["file_name"])
        let thumbnail = value["thumbnail"] as? JSON ?? [:]
        let thumbnailFile = thumbnail["file"] as? JSON ?? [:]
        let thumbnailID = int64(thumbnailFile["id"])
        return TelegramAnimation(
            id: id ?? "saved:\(fileID)",
            fileID: fileID,
            title: title.isEmpty ? fileName : title,
            fileName: fileName,
            mimeType: string(value["mime_type"]),
            fileSize: int64(file["size"]),
            width: Int(int64(value["width"])),
            height: Int(int64(value["height"])),
            duration: Int(int64(value["duration"])),
            thumbnailFileID: thumbnailID == 0 ? nil : thumbnailID,
            queryID: queryID,
            resultID: resultID
        )
    }

    static func isUnsupportedContent(_ content: JSON) -> Bool {
        ![
            "messageText", "messagePhoto", "messageVideo", "messageAnimation",
            "messageDocument", "messageAudio", "messageVoiceNote",
            "messageVideoNote", "messageSticker", "messagePoll",
            "messageContact", "messageLocation", "messageVenue"
        ].contains(string(content["@type"]))
    }

    static func reactions(_ message: JSON) -> [String] {
        reactionDetails(message).all
    }

    static func poll(_ content: JSON) -> MessagePoll? {
        guard string(content["@type"]) == "messagePoll",
              let poll = content["poll"] as? JSON else { return nil }
        return pollObject(poll)
    }

    static func pollObject(_ poll: JSON) -> MessagePoll? {
        let question = string((poll["question"] as? JSON)?["text"])
        let options = (poll["options"] as? [JSON] ?? []).map { option in
            PollOption(
                text: string((option["text"] as? JSON)?["text"]),
                voterCount: Int(int64(option["voter_count"])),
                votePercentage: Int(int64(option["vote_percentage"])),
                isChosen: (option["is_chosen"] as? Bool) == true
            )
        }
        guard !question.isEmpty, !options.isEmpty else { return nil }
        return MessagePoll(
            remoteID: int64(poll["id"]) == 0 ? nil : int64(poll["id"]),
            question: question,
            options: options,
            totalVoterCount: Int(int64(poll["total_voter_count"])),
            allowsMultipleAnswers: (poll["allows_multiple_answers"] as? Bool) == true,
            isClosed: (poll["is_closed"] as? Bool) == true
        )
    }

    static func stickers(_ set: JSON) -> [TelegramSticker] {
        let setID = int64(set["id"])
        let setName = string(set["name"])
        let setTitle = string(set["title"])
        return (set["stickers"] as? [JSON] ?? []).compactMap { sticker in
            let file = sticker["sticker"] as? JSON ?? [:]
            let fileID = int64(file["id"])
            guard fileID != 0 else { return nil }
            return TelegramSticker(
                id: fileID,
                emoji: string(sticker["emoji"]),
                width: Int(int64(sticker["width"])),
                height: Int(int64(sticker["height"])),
                format: parseStickerFormat(sticker["format"]) ?? .webp,
                setID: int64(sticker["set_id"]).nonZero ?? setID,
                setName: setName,
                setTitle: setTitle,
                fileSize: int64(file["size"])
            )
        }
    }

    static func stickerSets(_ result: JSON) -> [TelegramStickerSet] {
        (result["sets"] as? [JSON] ?? []).compactMap { set in
            let id = int64(set["id"])
            guard id != 0 else { return nil }
            return TelegramStickerSet(
                id: id,
                title: string(set["title"]),
                name: string(set["name"]),
                stickerCount: Int(int64(set["size"])),
                isInstalled: (set["is_installed"] as? Bool) == true,
                isArchived: (set["is_archived"] as? Bool) == true
            )
        }
    }

    static func reactionDetails(_ message: JSON) -> (all: [String], chosen: [String]) {
        let interactionInfo = message["interaction_info"] as? JSON ?? [:]
        return reactionDetails(interactionInfo: interactionInfo)
    }

    static func reactionDetails(interactionInfo: JSON) -> (all: [String], chosen: [String]) {
        let reactions = (interactionInfo["reactions"] as? JSON)?["reactions"] as? [JSON] ?? []
        return reactionDetails(reactions: reactions)
    }

    static func reactionDetails(reactions: [JSON]) -> (all: [String], chosen: [String]) {
        var all: [String] = []
        var chosen: [String] = []
        for item in reactions {
            let type = item["type"] as? JSON ?? [:]
            guard string(type["@type"]) == "reactionTypeEmoji" else { continue }
            let emoji = string(type["emoji"])
            guard !emoji.isEmpty else { continue }
            all.append(emoji)
            if (item["is_chosen"] as? Bool) == true { chosen.append(emoji) }
        }
        return (all, chosen)
    }

    static func message(_ m: JSON, lastReadOutbox: Int64) -> Message {
        let id = int64(m["id"])
        let outgoing = (m["is_outgoing"] as? Bool) ?? false
        var state: DeliveryState = .sent
        if let sending = m["sending_state"] as? JSON {
            state = string(sending["@type"]) == "messageSendingStateFailed" ? .failed : .sending
        } else if outgoing && id <= lastReadOutbox {
            state = .read
        }

        let replyID = int64((m["reply_to"] as? JSON)?["message_id"])
        let reactionDetails = reactionDetails(m)
        let interactionInfo = m["interaction_info"] as? JSON ?? [:]
        let replyInfo = interactionInfo["reply_info"] as? JSON
        return Message(
            text: contentText(m["content"] as? JSON ?? [:]),
            date: Date(timeIntervalSince1970: TimeInterval(int64(m["date"]))),
            isOutgoing: outgoing,
            state: state,
            reactions: reactionDetails.all,
            chosenReactions: reactionDetails.chosen,
            isEdited: int64(m["edit_date"]) > 0,
            isPinned: (m["is_pinned"] as? Bool) ?? false,
            remoteID: id,
            replyToRemoteID: replyID == 0 ? nil : replyID,
            media: media(m["content"] as? JSON ?? [:]),
            isUnsupportedContent: isUnsupportedContent(m["content"] as? JSON ?? [:]),
            entities: entities(((m["content"] as? JSON)?["text"] as? JSON)?["entities"]),
            poll: poll(m["content"] as? JSON ?? [:]),
            viewCount: {
                let count = Int(int64(interactionInfo["view_count"]))
                return count > 0 ? count : nil
            }(),
            topicID: int64((m["topic_id"] as? JSON)?["forum_topic_id"]).nonZero,
            replyCount: replyInfo.map { Int(int64($0["reply_count"])) },
            mediaAlbumID: int64(m["media_album_id"]).nonZero
        )
    }

    static func chat(_ c: JSON, lastReadOutbox: Int64) -> Chat {
        let type = c["type"] as? JSON ?? [:]
        var kind: ChatKind = .direct
        switch string(type["@type"]) {
        case "chatTypeSupergroup":
            kind = ((type["is_channel"] as? Bool) ?? false) ? .channel : .group
        case "chatTypeBasicGroup":
            kind = .group
        default:
            kind = .direct
        }

        var pinned = false
        var archived = false
        var folderIDs = Set<Int32>()
        var mainOrder: Double?
        var archiveOrder: Double?
        for position in (c["positions"] as? [JSON]) ?? [] {
            let list = position["list"] as? JSON ?? [:]
            let listType = string(list["@type"])
            if listType == "chatListArchive" {
                archived = true
                archiveOrder = double(position["order"])
            }
            if listType == "chatListMain" { mainOrder = double(position["order"]) }
            if listType == "chatListMain" || listType == "chatListArchive" {
                if (position["is_pinned"] as? Bool) == true { pinned = true }
            }
            if listType == "chatListFolder" {
                let folderID = Int32(int64(list["chat_folder_id"]))
                if folderID > 0 { folderIDs.insert(folderID) }
            }
        }


        let notificationSettings = c["notification_settings"] as? JSON ?? [:]
        let muteFor = int64(notificationSettings["mute_for"])
        var messages: [Message] = []
        if let last = c["last_message"] as? JSON {
            messages = [message(last, lastReadOutbox: lastReadOutbox)]
        }

        return Chat(
            id: int64(c["id"]),
            title: string(c["title"]),
            kind: kind,
            unread: Int(int64(c["unread_count"])),
            isPinned: pinned,
            isArchived: archived,
            isMuted: muteFor > 0,
            messages: messages,
            isMarkedAsUnread: (c["is_marked_as_unread"] as? Bool) ?? false,
            telegramFolderIDs: folderIDs,
            mainListOrder: mainOrder,
            archiveListOrder: archiveOrder,
            notificationSettings: ChatNotificationSettings(
                muteFor: Int32(clamping: muteFor),
                soundEnabled: int64(notificationSettings["sound_id"]) != 0
                    || (notificationSettings["use_default_sound"] as? Bool) == true,
                showPreview: (notificationSettings["show_preview"] as? Bool) ?? true
            ),
            avatarFileID: int64(((c["photo"] as? JSON)?["small"] as? JSON)?["id"]).nonZero,
            canPostMessages: kind != .channel,
            canPinMessages: kind != .channel
        )
    }

    static func forumTopic(_ topic: JSON, lastReadOutbox: Int64 = 0) -> ForumTopic? {
        let info = topic["info"] as? JSON ?? [:]
        let topicID = int64(info["forum_topic_id"])
        guard topicID > 0 else { return nil }
        let lastMessage = (topic["last_message"] as? JSON).map {
            message($0, lastReadOutbox: lastReadOutbox)
        }
        let icon = info["icon"] as? JSON ?? [:]
        return ForumTopic(
            id: topicID,
            name: string(info["name"]),
            iconColor: Int(int64(icon["color"])),
            unreadCount: Int(int64(topic["unread_count"])),
            isClosed: (info["is_closed"] as? Bool) == true,
            isPinned: (topic["is_pinned"] as? Bool) == true,
            isGeneral: (info["is_general"] as? Bool) == true,
            isCreatedByMe: (info["is_outgoing"] as? Bool) == true,
            order: int64(topic["order"]),
            lastMessage: lastMessage
        )
    }

    static func user(_ u: JSON) -> TGUser {
        let first = string(u["first_name"])
        let last = string(u["last_name"])
        let name = (first + " " + last).trimmingCharacters(in: .whitespaces)
        let usernames = (u["usernames"] as? JSON)?["active_usernames"] as? [String]
        let isBot = string((u["type"] as? JSON)?["@type"]) == "userTypeBot"
        let isOnline = string((u["status"] as? JSON)?["@type"]) == "userStatusOnline"
        let avatarID = int64(((u["profile_photo"] as? JSON)?["small"] as? JSON)?["id"])
        return TGUser(
            name: name,
            username: usernames?.first,
            isBot: isBot,
            isOnline: isOnline,
            avatarFileID: avatarID == 0 ? nil : avatarID
        )
    }

    static func groupMember(_ member: JSON, name: String) -> GroupMember? {
        let sender = member["member_id"] as? JSON ?? [:]
        let userID = int64(sender["user_id"] ?? member["user_id"])
        guard userID != 0 else { return nil }
        let statusType = string((member["status"] as? JSON)?["@type"])
        let status: GroupMemberStatus
        switch statusType {
        case "chatMemberStatusCreator": status = .creator
        case "chatMemberStatusAdministrator": status = .administrator
        case "chatMemberStatusMember": status = .member
        case "chatMemberStatusRestricted": status = .restricted
        case "chatMemberStatusLeft": status = .left
        case "chatMemberStatusBanned": status = .banned
        default: return nil
        }
        return GroupMember(userID: userID, name: name, status: status)
    }

    static func profile(user: JSON, fullInfo: JSON) -> TelegramProfile {
        let username = (user["usernames"] as? JSON)?["active_usernames"] as? [String]
        let bioValue = fullInfo["bio"]
        let bio = (bioValue as? JSON).map { string($0["text"]) } ?? string(bioValue)
        let avatarID = int64(((user["profile_photo"] as? JSON)?["small"] as? JSON)?["id"])
        return TelegramProfile(
            firstName: string(user["first_name"]),
            lastName: string(user["last_name"]),
            phoneNumber: string(user["phone_number"]),
            username: username?.first,
            bio: bio,
            avatarFileID: avatarID == 0 ? nil : avatarID
        )
    }
}

/// Maps TDLib errors to short, user-facing messages. Never retries automatically.
enum TGErrors {
    private static let known: [String: String] = [
        "PHONE_NUMBER_INVALID": "err.phone",
        "PHONE_CODE_INVALID": "err.code",
        "PHONE_CODE_EMPTY": "err.code",
        "PHONE_CODE_EXPIRED": "err.codeExpired",
        "PASSWORD_HASH_INVALID": "err.password",
        "PHONE_NUMBER_BANNED": "err.banned"
    ]

    static func message(for error: Error) -> String {
        guard let td = error as? TDError else { return L("err.generic") }
        switch td.message {
        case "FILE_TOO_LARGE": return L("err.fileTooLarge")
        case "INVALID_STICKER", "INVALID_STICKER_SET": return L("err.invalidSticker")
        case "MEDIA_CACHE_FULL": return L("err.mediaCacheFull")
        case "FILE_DOWNLOAD_TIMEOUT": return L("err.fileDownloadTimeout")
        case "OUTGOING_STORAGE_FULL": return L("err.outgoingStorageFull")
        case "FORWARD_NOT_ALLOWED": return L("err.forwardRestricted")
        case "MICROPHONE_PERMISSION_DENIED": return L("err.microphonePermission")
        case "AUDIO_RECORDING_FAILED": return L("err.audioRecording")
        case "AUDIO_RECORDING_TOO_SHORT": return L("err.audioTooShort")
        case "MEDIA_READ_FAILED": return L("err.mediaRead")
        case "UNSUPPORTED_MEDIA_TYPE": return L("err.unsupportedMedia")
        case "INVALID_MEDIA_DURATION": return L("err.mediaDuration")
        case "INVALID_VIDEO_NOTE": return L("err.videoNote")
        case "INVALID_POLL": return L("err.invalidPoll")
        case "INVALID_POLL_ANSWER": return L("err.invalidPollAnswer")
        case "INVALID_CONTACT": return L("err.invalidContact")
        case "INVALID_LOCATION": return L("err.invalidLocation")
        case "INVALID_GROUP_TITLE": return L("group.error.title")
        case "GROUP_MEMBER_ADD_FAILED": return L("group.error.addMembers")
        case "GROUP_PHOTO_UNAVAILABLE": return L("group.error.photo")
        case "GROUP_ADMIN_RIGHTS_REQUIRED": return L("group.error.adminRights")
        case "GROUP_INVITE_LINK_UNAVAILABLE": return L("group.error.inviteLink")
        case "GROUP_UPGRADE_FAILED": return L("group.error.upgrade")
        case "GROUP_CREATION_FAILED": return L("group.error.create")
        case "NOT_A_GROUP": return L("group.error.notGroup")
        case "GROUP_MEMBER_STATUS_INVALID": return L("group.error.memberAction")
        case "GROUP_MEMBER_OFFSET_INVALID": return L("group.error.members")
        default: break
        }
        if td.code == 429 || td.message.hasPrefix("FLOOD_WAIT") {
            let digits = td.message.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let seconds = Int(digits) { return String(format: L("err.flood"), seconds) }
        }

        if let key = known[td.message] { return L(key) }
        return L("err.generic")
    }
}

private extension Int64 {
    var nonZero: Int64? { self == 0 ? nil : self }
}
