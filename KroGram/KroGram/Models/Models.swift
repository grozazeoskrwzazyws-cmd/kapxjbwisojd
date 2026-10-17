// Copyright © 2026 Kro. KroGram original materials.

import Foundation

enum ChatKind: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case direct, group, channel, bot
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .direct: return "person.fill"
        case .group: return "person.2.fill"
        case .channel: return "megaphone.fill"
        case .bot: return "cpu"
        }
    }
}

enum DeliveryState: String, Codable, Sendable {
    case sending, sent, read, failed
}

enum MessageEntityKind: Hashable, Sendable {
    case bold, italic, code, pre, quote, spoiler
    case underline, strikethrough
    case url, email, phoneNumber, mention, hashtag, cashtag, botCommand
    case textURL(String)
    case mentionName(Int64)
    case customEmoji(Int64)
}

struct MessageEntity: Hashable, Sendable {
    var offset: Int
    var length: Int
    var kind: MessageEntityKind
}

struct PollOption: Hashable, Sendable {
    var text: String
    var voterCount: Int
    var votePercentage: Int
    var isChosen: Bool
}

struct MessagePoll: Hashable, Sendable {
    var remoteID: Int64?
    var question: String
    var options: [PollOption]
    var totalVoterCount: Int
    var allowsMultipleAnswers: Bool
    var isClosed: Bool

    init(
        remoteID: Int64? = nil,
        question: String,
        options: [PollOption],
        totalVoterCount: Int,
        allowsMultipleAnswers: Bool,
        isClosed: Bool
    ) {
        self.remoteID = remoteID
        self.question = question
        self.options = options
        self.totalVoterCount = totalVoterCount
        self.allowsMultipleAnswers = allowsMultipleAnswers
        self.isClosed = isClosed
    }
}

struct TelegramSticker: Identifiable, Hashable, Sendable {
    let id: Int64
    let emoji: String
    let width: Int
    let height: Int
    var format: StickerFormat = .webp
    var setID: Int64 = 0
    var setName: String = ""
    var setTitle: String = ""
    var fileSize: Int64 = 0
}

struct TelegramAnimation: Identifiable, Hashable, Sendable {
    let id: String
    let fileID: Int64
    let title: String
    let fileName: String
    let mimeType: String
    let fileSize: Int64
    let width: Int
    let height: Int
    let duration: Int
    let thumbnailFileID: Int64?
    let queryID: Int64?
    let resultID: String?
}

enum StickerFormat: String, Hashable, Sendable {
    case webp, tgs, webm

    var fileExtension: String { rawValue }

    var mimeType: String {
        switch self {
        case .webp: return "image/webp"
        case .tgs: return "application/x-tgsticker"
        case .webm: return "video/webm"
        }
    }
}

struct TelegramStickerSet: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let name: String
    let stickerCount: Int
    let isInstalled: Bool
    let isArchived: Bool
}

struct Message: Identifiable, Hashable, Sendable {
    let id: UUID
    var text: String
    var date: Date
    var isOutgoing: Bool
    var state: DeliveryState
    var replyToID: UUID?
    var reactions: [String]
    var chosenReactions: [String]
    var isEdited: Bool
    var isPinned: Bool
    /// Telegram message id (nil for demo data and for messages not yet acknowledged).
    var remoteID: Int64?
    var replyToRemoteID: Int64?
    var media: MessageMedia?
    var isUnsupportedContent: Bool
    var entities: [MessageEntity]
    var poll: MessagePoll?
    var viewCount: Int?
    var topicID: Int64?
    var replyCount: Int?
    var mediaAlbumID: Int64?

    init(
        id: UUID = UUID(),
        text: String,
        date: Date = .now,
        isOutgoing: Bool,
        state: DeliveryState = .sent,
        replyToID: UUID? = nil,
        reactions: [String] = [],
        chosenReactions: [String] = [],
        isEdited: Bool = false,
        isPinned: Bool = false,
        remoteID: Int64? = nil,
        replyToRemoteID: Int64? = nil,
        media: MessageMedia? = nil,
        isUnsupportedContent: Bool = false,
        entities: [MessageEntity] = [],
        poll: MessagePoll? = nil,
        viewCount: Int? = nil,
        topicID: Int64? = nil,
        replyCount: Int? = nil,
        mediaAlbumID: Int64? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.isOutgoing = isOutgoing
        self.state = state
        self.replyToID = replyToID
        self.reactions = reactions
        self.chosenReactions = chosenReactions
        self.isEdited = isEdited
        self.isPinned = isPinned
        self.remoteID = remoteID
        self.replyToRemoteID = replyToRemoteID
        self.media = media
        self.isUnsupportedContent = isUnsupportedContent
        self.entities = entities
        self.poll = poll
        self.viewCount = viewCount
        self.topicID = topicID
        self.replyCount = replyCount
        self.mediaAlbumID = mediaAlbumID
    }
}

struct DiscussionThreadPage: Sendable {
    let chatID: Int64
    let threadMessageID: Int64
    let messages: [Message]
}

enum MessageMediaKind: String, Codable, Hashable, Sendable {
    case photo, video, animation, document, audio, voice, videoNote, sticker
}

enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, paused, completed, failed, cancelled
}

enum NetworkConnectionKind: Sendable {
    case wifi, cellular, other, offline
}

struct DownloadRecord: Identifiable, Codable, Hashable, Sendable {
    let fileID: Int64
    var title: String
    var totalBytes: Int64
    var downloadedBytes: Int64
    var status: DownloadStatus
    var mediaKind: MessageMediaKind?
    var localPath: String?
    var errorMessage: String?

    var id: Int64 { fileID }
}

enum UploadStatus: String, Codable, Sendable {
    case uploading, completed, failed, cancelled
}

struct UploadRecord: Identifiable, Codable, Hashable, Sendable {
    let fileID: Int64
    var chatID: Int64
    var messageID: Int64
    var title: String
    var totalBytes: Int64
    var uploadedBytes: Int64
    var status: UploadStatus
    var sourcePath: String

    var id: Int64 { fileID }
}

struct MessageMedia: Hashable, Sendable {
    let kind: MessageMediaKind
    let fileID: Int64
    let fileName: String?
    let mimeType: String?
    let fileSize: Int64
    let caption: String
    let captionEntities: [MessageEntity]
    var stickerFormat: StickerFormat? = nil
}

struct Chat: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var kind: ChatKind
    var isOnline: Bool
    var unread: Int
    var isPinned: Bool
    var isArchived: Bool
    var isHidden: Bool
    var isMuted: Bool
    var folderIDs: Set<UUID>
    var messages: [Message]
    var avatarFileID: Int64?
    var isSavedMessages: Bool
    var isMarkedAsUnread: Bool
    var telegramFolderIDs: Set<Int32>
    var mainListOrder: Double?
    var archiveListOrder: Double?
    var notificationSettings: ChatNotificationSettings
    var canPostMessages: Bool
    var canPinMessages: Bool
    var isForum: Bool
    var canManageTopics: Bool
    var canCreateTopics: Bool

    init(
        id: Int64,
        title: String,
        kind: ChatKind = .direct,
        isOnline: Bool = false,
        unread: Int = 0,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isHidden: Bool = false,
        isMuted: Bool = false,
        folderIDs: Set<UUID> = [],
        messages: [Message] = [],
        avatarFileID: Int64? = nil,
        isSavedMessages: Bool = false,
        isMarkedAsUnread: Bool = false,
        telegramFolderIDs: Set<Int32> = [],
        mainListOrder: Double? = nil,
        archiveListOrder: Double? = nil,
        notificationSettings: ChatNotificationSettings = .defaults,
        canPostMessages: Bool = true,
        canPinMessages: Bool = true,
        isForum: Bool = false,
        canManageTopics: Bool = false,
        canCreateTopics: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isOnline = isOnline
        self.unread = unread
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isMuted = isMuted
        self.folderIDs = folderIDs
        self.messages = messages
        self.avatarFileID = avatarFileID
        self.isSavedMessages = isSavedMessages
        self.isMarkedAsUnread = isMarkedAsUnread
        self.telegramFolderIDs = telegramFolderIDs
        self.mainListOrder = mainListOrder
        self.archiveListOrder = archiveListOrder
        self.notificationSettings = notificationSettings
        self.canPostMessages = canPostMessages
        self.canPinMessages = canPinMessages
        self.isForum = isForum
        self.canManageTopics = canManageTopics
        self.canCreateTopics = canCreateTopics
    }

    struct ForumTopic: Identifiable, Hashable, Sendable {
        var id: Int64
        var name: String
        var iconColor: Int
        var unreadCount: Int
        var isClosed: Bool
        var isPinned: Bool
        var isGeneral: Bool
        var isCreatedByMe: Bool
        var order: Int64
        var lastMessage: Message?
    }

    var lastMessageText: String { messages.last?.text ?? "" }
    var lastDate: Date { messages.last?.date ?? .distantPast }
}

struct ChatFolder: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var name: String
    var symbol: String
    var telegramID: Int32?
    var colorID: Int32?
    var isShareable: Bool?
    var pinnedChatIDs: Set<Int64>?
    var includedChatIDs: Set<Int64>?
    var excludedChatIDs: Set<Int64>?
    var excludesMuted: Bool?
    var excludesRead: Bool?
    var excludesArchived: Bool?
    var includesContacts: Bool?
    var includesNonContacts: Bool?
    var includesBots: Bool?
    var includesGroups: Bool?
    var includesChannels: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "folder",
        telegramID: Int32? = nil,
        colorID: Int32? = nil,
        isShareable: Bool? = nil,
        pinnedChatIDs: Set<Int64>? = nil,
        includedChatIDs: Set<Int64>? = nil,
        excludedChatIDs: Set<Int64>? = nil,
        excludesMuted: Bool? = nil,
        excludesRead: Bool? = nil,
        excludesArchived: Bool? = nil,
        includesContacts: Bool? = nil,
        includesNonContacts: Bool? = nil,
        includesBots: Bool? = nil,
        includesGroups: Bool? = nil,
        includesChannels: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.telegramID = telegramID
        self.colorID = colorID
        self.isShareable = isShareable
        self.pinnedChatIDs = pinnedChatIDs
        self.includedChatIDs = includedChatIDs
        self.excludedChatIDs = excludedChatIDs
        self.excludesMuted = excludesMuted
        self.excludesRead = excludesRead
        self.excludesArchived = excludesArchived
        self.includesContacts = includesContacts
        self.includesNonContacts = includesNonContacts
        self.includesBots = includesBots
        self.includesGroups = includesGroups
        self.includesChannels = includesChannels
    }
}

struct ChatNotificationSettings: Hashable, Sendable {
    var muteFor: Int32
    var soundEnabled: Bool
    var showPreview: Bool

    static let defaults = ChatNotificationSettings(muteFor: 0, soundEnabled: true, showPreview: true)
}

struct Contact: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var username: String?
    var isOnline: Bool
    var avatarFileID: Int64? = nil
}

struct TelegramProfile: Hashable, Sendable {
    var firstName: String
    var lastName: String
    var phoneNumber: String
    var username: String?
    var bio: String
    var avatarFileID: Int64?

    var displayName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TelegramSession: Identifiable, Hashable, Sendable {
    let id: Int64
    let isCurrent: Bool
    let isPasswordPending: Bool
    let isUnconfirmed: Bool
    let deviceType: String
    let applicationName: String
    let applicationVersion: String
    let isOfficialApplication: Bool
    let deviceModel: String
    let platform: String
    let systemVersion: String
    let loginDate: Date
    let lastActiveDate: Date
    let ipAddress: String
    let location: String
}

enum TelegramPrivacySetting: String, CaseIterable, Identifiable, Sendable {
    case lastSeen
    case phoneNumber
    case profilePhoto
    case calls
    case groupInvites
    case forwardedMessages

    var id: String { rawValue }

    var tdlibType: String {
        switch self {
        case .lastSeen: return "userPrivacySettingShowStatus"
        case .phoneNumber: return "userPrivacySettingShowPhoneNumber"
        case .profilePhoto: return "userPrivacySettingShowProfilePhoto"
        case .calls: return "userPrivacySettingAllowCalls"
        case .groupInvites: return "userPrivacySettingAllowChatInvites"
        case .forwardedMessages: return "userPrivacySettingShowLinkInForwardedMessages"
        }
    }

    var titleKey: String {
        switch self {
        case .lastSeen: return "privacy.remote.lastSeen"
        case .phoneNumber: return "privacy.remote.phoneNumber"
        case .profilePhoto: return "privacy.remote.profilePhoto"
        case .calls: return "privacy.remote.calls"
        case .groupInvites: return "privacy.remote.groupInvites"
        case .forwardedMessages: return "privacy.remote.forwardedMessages"
        }
    }
}

enum TelegramPrivacyPolicy: String, CaseIterable, Identifiable, Sendable {
    case everyone
    case contacts
    case nobody

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .everyone: return "privacy.remote.everyone"
        case .contacts: return "privacy.remote.contacts"
        case .nobody: return "privacy.remote.nobody"
        }
    }
}

struct TelegramPrivacyRule: Hashable, Sendable {
    let type: String
    let userIDs: [Int64]
    let chatIDs: [Int64]
}

struct TelegramPrivacyPreference: Identifiable, Hashable, Sendable {
    let setting: TelegramPrivacySetting
    var policy: TelegramPrivacyPolicy
    var exceptionRules: [TelegramPrivacyRule]

    var id: TelegramPrivacySetting { setting }
}

struct BlockedTelegramUser: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let username: String?
}

struct TelegramPasswordState: Hashable, Sendable {
    let hasPassword: Bool
    let hint: String
    let hasRecoveryEmail: Bool
    let recoveryEmailPattern: String
    let pendingResetDate: Date?
}

struct ChatProfile: Hashable, Sendable {
    var chatID: Int64
    var title: String
    var kind: ChatKind
    var username: String?
    var phoneNumber: String?
    var status: String?
    var description: String
    var memberCount: Int?
    var avatarFileID: Int64?
}

enum GroupMemberStatus: String, Hashable, Sendable {
    case creator
    case administrator
    case member
    case restricted
    case left
    case banned
}

struct GroupMember: Identifiable, Hashable, Sendable {
    let userID: Int64
    var name: String
    var status: GroupMemberStatus

    var id: Int64 { userID }
}

struct GroupAdminRights: Hashable, Sendable {
    var canManageChat = true
    var canChangeInfo = true
    var canInviteUsers = true
    var canRestrictMembers = false
    var canPinMessages = true
    var canPromoteMembers = false
}

struct GroupManagementInfo: Hashable, Sendable {
    var isBasicGroup: Bool
    var isCreator: Bool
    var canViewMembers: Bool
    var canInviteMembers: Bool
    var canCreateInviteLink: Bool
    var canPromoteMembers: Bool
    var canRestrictMembers: Bool
    var memberCount: Int
    var inviteLink: String?
    var members: [GroupMember]
    var nextMemberOffset: Int
    var hasMoreMembers: Bool
}

struct GroupMembersPage: Sendable {
    var members: [GroupMember]
    var nextOffset: Int
    var hasMore: Bool
}

struct GroupCreationResult: Sendable {
    var chatID: Int64
    var warnings: [String]
}

struct ChannelCreationResult: Sendable {
    var chatID: Int64
    var warnings: [String]
}

struct ChannelManagementInfo: Hashable, Sendable {
    var isMember: Bool
    var canPostMessages: Bool
    var canPinMessages: Bool
    var canInviteUsers: Bool
    var subscriberCount: Int
    var inviteLink: String?
}

// MARK: - Filters

enum ChatFilter: String, CaseIterable, Identifiable {
    case all, unread, direct, group, channel, bot
    var id: String { rawValue }
    var titleKey: String { "filter.\(rawValue)" }

    func matches(_ chat: Chat) -> Bool {
        switch self {
        case .all: return true
        case .unread: return chat.unread > 0 || chat.isMarkedAsUnread
        case .direct: return chat.kind == .direct
        case .group: return chat.kind == .group
        case .channel: return chat.kind == .channel
        case .bot: return chat.kind == .bot
        }
    }
}

enum DateFilter: String, CaseIterable, Identifiable {
    case any, today, week, month
    var id: String { rawValue }
    var titleKey: String { "date.\(rawValue)" }

    func matches(_ date: Date, now: Date = .now) -> Bool {
        let cal = Calendar.current
        switch self {
        case .any: return true
        case .today: return cal.isDate(date, inSameDayAs: now)
        case .week: return date >= (cal.date(byAdding: .day, value: -7, to: now) ?? .distantPast)
        case .month: return date >= (cal.date(byAdding: .day, value: -30, to: now) ?? .distantPast)
        }
    }
}

enum ChatScope: Hashable {
    case unread, pinned, archived, hidden
    case folder(UUID)
}
