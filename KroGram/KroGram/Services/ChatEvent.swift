// Copyright © 2026 Kro. KroGram original materials.

import Foundation

enum ConnectionState: Sendable, Equatable {
    case ready, connecting, waitingForNetwork, updating
}

/// Live updates pushed by a repository (empty for the demo repository).
enum ChatEvent: Sendable {
    case chatChanged(Int64)
    case newMessage(chatID: Int64, message: Message)
    case messageContent(chatID: Int64, remoteID: Int64, text: String)
    case messageEdited(chatID: Int64, remoteID: Int64)
    case messagePinned(chatID: Int64, remoteID: Int64, isPinned: Bool)
    case messageReactions(
        chatID: Int64,
        remoteID: Int64,
        all: [String],
        chosen: [String],
        viewCount: Int?,
        replyCount: Int?
    )
    case pollUpdated(MessagePoll)
    case sendSucceeded(chatID: Int64, oldRemoteID: Int64, message: Message)
    case sendFailed(chatID: Int64, oldRemoteID: Int64)
    case deleted(chatID: Int64, remoteIDs: [Int64])
    case foldersChanged([ChatFolder])
    case actionFailed(String)
    case userStatus(userID: Int64, isOnline: Bool)
    case fileProgress(fileID: Int64, downloaded: Int64, total: Int64, completed: Bool)
    case uploadStarted(
        fileID: Int64,
        chatID: Int64,
        messageID: Int64,
        title: String,
        total: Int64,
        sourcePath: String
    )
    case uploadProgress(fileID: Int64, uploaded: Int64, total: Int64, completed: Bool)
    case uploadCancelled(fileID: Int64)
    case fileCancelled(fileID: Int64)
    case connection(ConnectionState)
}

/// What this client may send about the account itself. Nothing here touches other people's content.
struct PrivacySnapshot: Sendable, Equatable {
    var hideRead = false
    var hideTyping = false
    var hideOnline = false
}
