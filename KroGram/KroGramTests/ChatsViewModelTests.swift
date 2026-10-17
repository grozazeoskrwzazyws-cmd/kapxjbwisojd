// Copyright © 2026 Kro. KroGram original materials.

import XCTest
@testable import KroGram

private struct SearchPagingRepository: ChatRepository {
    var isReal: Bool { true }

    func loadChats() async throws -> [Chat] { [] }
    func loadFolders() async throws -> [ChatFolder] { [] }
    func loadContacts() async throws -> [Contact] { [] }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }

    func searchMessages(chatID: Int64, query: String, fromMessageID: Int64, limit: Int) async throws -> [Message]? {
        XCTAssertEqual(query, "needle")
        XCTAssertEqual(limit, 50)
        if fromMessageID == 0 {
            return [
                Message(text: "needle new", isOutgoing: false, remoteID: 30),
                Message(text: "needle middle", isOutgoing: false, remoteID: 20)
            ]
        }
        XCTAssertEqual(fromMessageID, 20)
        return [
            Message(text: "needle middle", isOutgoing: false, remoteID: 20),
            Message(text: "needle old", isOutgoing: false, remoteID: 10)
        ]
    }
}

private actor HistoryCallCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

private actor MessageActionRecorder {
    private(set) var deletedWithRevoke: [Bool] = []
    private(set) var deletedMessageIDs: [Int64] = []
    private(set) var editedMessageIDs: [Int64] = []
    private(set) var forwardedDestinations: [Int64] = []
    private(set) var forwardedHideSender: [Bool] = []
    private(set) var forwardedMessageIDs: [Int64] = []

    func recordDelete(revoke: Bool) { deletedWithRevoke.append(revoke) }
    func recordDelete(messageIDs: [Int64], revoke: Bool) {
        deletedMessageIDs.append(contentsOf: messageIDs)
        deletedWithRevoke.append(revoke)
    }
    func recordEdit(messageID: Int64) { editedMessageIDs.append(messageID) }
    func recordForward(destinationID: Int64, messageIDs: [Int64], hideSender: Bool) {
        forwardedDestinations.append(destinationID)
        forwardedHideSender.append(hideSender)
        forwardedMessageIDs.append(contentsOf: messageIDs)
    }
}

private struct MessageActionsRepository: ChatRepository {
    let recorder: MessageActionRecorder
    var isReal: Bool { true }

    func loadChats() async throws -> [Chat] {
        [Chat(id: 42, title: "Chat", kind: .direct)]
    }

    func loadFolders() async throws -> [ChatFolder] { [] }
    func loadContacts() async throws -> [Contact] { [] }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }

    func loadMessage(chatID: Int64, messageID: Int64) async throws -> Message? {
        Message(text: "Original", date: Date(timeIntervalSince1970: 0), isOutgoing: false, remoteID: messageID)
    }

    func editRemote(chatID: Int64, messageID: Int64, text: String) async throws {
        await recorder.recordEdit(messageID: messageID)
    }

    func deleteRemote(chatID: Int64, messageID: Int64, revoke: Bool) async throws {
        await recorder.recordDelete(revoke: revoke)
    }

    func deleteRemote(chatID: Int64, messageIDs: [Int64], revoke: Bool) async throws {
        await recorder.recordDelete(messageIDs: messageIDs, revoke: revoke)
    }

    func forwardMessages(
        fromChatID: Int64,
        toChatID: Int64,
        messageIDs: [Int64],
        hideSender: Bool
    ) async throws {
        await recorder.recordForward(destinationID: toChatID, messageIDs: messageIDs, hideSender: hideSender)
    }
}

private struct SavedMessagesRepository: ChatRepository {
    var isReal: Bool { true }

    func loadChats() async throws -> [Chat] {
        [
            Chat(id: 1, title: "Recent chat", messages: [Message(text: "recent", date: .now)]),
            Chat(id: 2, title: "Saved Messages", isSavedMessages: true)
        ]
    }

    func loadFolders() async throws -> [ChatFolder] { [] }
    func loadContacts() async throws -> [Contact] { [] }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }
}

private struct LiveFoldersRepository: ChatRepository {
    var isReal: Bool { true }

    func loadChats() async throws -> [Chat] {
        [
            Chat(id: 1, title: "One", unread: 2, telegramFolderIDs: [8], mainListOrder: 4),
            Chat(id: 2, title: "Two", isMarkedAsUnread: true, telegramFolderIDs: [8], mainListOrder: 9),
            Chat(id: 3, title: "Three", telegramFolderIDs: [8], mainListOrder: 12)
        ]
    }

    func loadFolders() async throws -> [ChatFolder] {
        [ChatFolder(name: "Work", telegramID: 8)]
    }

    func loadContacts() async throws -> [Contact] { [] }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }
}

private struct GroupHistoryRepository: ChatRepository {
    let counter: HistoryCallCounter
    var isReal: Bool { true }

    func loadChats() async throws -> [Chat] {
        [Chat(id: 42, title: "Group", kind: .group)]
    }

    func loadFolders() async throws -> [ChatFolder] { [] }
    func loadContacts() async throws -> [Contact] { [] }
    func send(text: String, chatID: Int64) async throws -> DeliveryState { .sent }

    func loadHistory(chatID: Int64) async throws -> [Message]? {
        await counter.record()
        return []
    }
}

@MainActor
final class ChatsViewModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "krochat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeVM() async -> ChatsViewModel {
        let vm = ChatsViewModel(repository: MockChatRepository(delay: .zero), defaults: makeDefaults())
        await vm.load()
        return vm
    }

    func testTransferRecordsPersistProgressAndFileMetadata() throws {
        let download = DownloadRecord(
            fileID: 7,
            title: "clip.mp4",
            totalBytes: 1_000,
            downloadedBytes: 400,
            status: .paused,
            mediaKind: .video,
            localPath: "/tmp/clip.mp4",
            errorMessage: nil
        )
        let upload = UploadRecord(
            fileID: 8,
            chatID: 42,
            messageID: -9,
            title: "archive.zip",
            totalBytes: 2_000,
            uploadedBytes: 500,
            status: .uploading,
            sourcePath: "/tmp/archive.zip"
        )

        let downloads = try JSONDecoder().decode([DownloadRecord].self, from: JSONEncoder().encode([download]))
        let uploads = try JSONDecoder().decode([UploadRecord].self, from: JSONEncoder().encode([upload]))

        XCTAssertEqual(downloads, [download])
        XCTAssertEqual(uploads, [upload])
    }

    func testLoadExcludesArchivedAndHidden() async {
        let vm = await makeVM()
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertFalse(vm.mainChats.contains { $0.isArchived || $0.isHidden })
    }

    func testPinnedChatsSortFirst() async {
        let vm = await makeVM()
        let firstUnpinned = vm.mainChats.firstIndex { !$0.isPinned }
        let lastPinned = vm.mainChats.lastIndex { $0.isPinned }
        if let firstUnpinned, let lastPinned {
            XCTAssertLessThan(lastPinned, firstUnpinned)
        }
    }

    func testSavedMessagesStayAtTopOfLiveChatList() async {
        let vm = ChatsViewModel(repository: SavedMessagesRepository(), defaults: makeDefaults())
        await vm.load()

        XCTAssertTrue(vm.mainChats.first?.isSavedMessages == true)
    }

    func testLiveFolderMembershipUnreadCountAndServerOrder() async {
        let vm = ChatsViewModel(repository: LiveFoldersRepository(), defaults: makeDefaults())
        await vm.load()
        guard let folder = vm.folders.first else {
            XCTFail("Expected a Telegram folder")
            return
        }

        XCTAssertEqual(vm.chats(in: .folder(folder.id)).map(\.id), [3, 2, 1])
        XCTAssertEqual(vm.unreadCount(in: folder), 3)
        vm.selectedFolderID = folder.id
        XCTAssertEqual(vm.visibleChats.map(\.id), [3, 2, 1])
    }

    func testSearchMatchesTitleAndMessageText() async {
        let vm = await makeVM()
        vm.searchText = "فريق"
        XCTAssertEqual(vm.visibleChats.map(\.id), [2])
        vm.searchText = "المراجعة"
        XCTAssertEqual(vm.visibleChats.map(\.id), [1])
    }

    func testMessageSearchLoadsOlderPagesWithoutDuplicates() async {
        let vm = ChatsViewModel(repository: SearchPagingRepository(), defaults: makeDefaults())

        await vm.searchMessages(in: 1, query: "needle")
        XCTAssertEqual(vm.searchResults(in: 1, query: "needle")?.compactMap(\.remoteID), [30, 20])
        XCTAssertEqual(vm.searchResults(in: 1, query: " needle ")?.compactMap(\.remoteID), [30, 20])

        await vm.searchMessages(in: 1, query: "needle", loadMore: true)
        XCTAssertEqual(vm.searchResults(in: 1, query: "needle")?.compactMap(\.remoteID), [30, 20, 10])
    }

    func testGroupHistoryIsNotRequestedInBackground() async {
        let counter = HistoryCallCounter()
        let vm = ChatsViewModel(repository: GroupHistoryRepository(counter: counter), defaults: makeDefaults())
        await vm.load()

        vm.setForeground(false)
        await vm.openChat(42)
        let backgroundCalls = await counter.count
        XCTAssertEqual(backgroundCalls, 0)

        vm.setForeground(true)
        await vm.openChat(42)
        let foregroundCalls = await counter.count
        XCTAssertEqual(foregroundCalls, 1)
    }

    func testReplyTargetLoadsMissingOriginalMessage() async {
        let recorder = MessageActionRecorder()
        let vm = ChatsViewModel(repository: MessageActionsRepository(recorder: recorder), defaults: makeDefaults())
        await vm.load()
        let reply = Message(text: "Reply", isOutgoing: true, remoteID: 100, replyToRemoteID: 99)
        vm.update([42]) { $0.messages = [reply] }

        let original = await vm.replyTarget(for: reply, in: 42)

        XCTAssertEqual(original?.remoteID, 99)
        XCTAssertEqual(vm.chat(42)?.messages.compactMap(\.remoteID), [99, 100])
    }

    func testDeleteUsesRequestedRevocationAndRemovesAfterSuccess() async {
        let recorder = MessageActionRecorder()
        let vm = ChatsViewModel(repository: MessageActionsRepository(recorder: recorder), defaults: makeDefaults())
        await vm.load()
        let message = Message(text: "Remove locally", isOutgoing: false, remoteID: 55)
        vm.update([42]) { $0.messages = [message] }

        vm.deleteMessage(message.id, in: 42, revoke: false)
        for _ in 0..<20 where vm.chat(42)?.messages.contains(where: { $0.id == message.id }) == true {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let revokeValues = await recorder.deletedWithRevoke
        XCTAssertEqual(revokeValues, [false])
        XCTAssertFalse(vm.chat(42)?.messages.contains(where: { $0.id == message.id }) ?? true)
    }

    func testBulkDeleteUsesOneRemoteRequestAndRemovesSelectedMessages() async {
        let recorder = MessageActionRecorder()
        let vm = ChatsViewModel(repository: MessageActionsRepository(recorder: recorder), defaults: makeDefaults())
        await vm.load()
        let messages = [
            Message(text: "First", isOutgoing: false, remoteID: 55),
            Message(text: "Second", isOutgoing: true, remoteID: 56)
        ]
        vm.update([42]) { $0.messages = messages }

        let deleted = await vm.deleteMessages(messages.map(\.id), in: 42, revoke: false)
        let deletedIDs = await recorder.deletedMessageIDs
        let revokeValues = await recorder.deletedWithRevoke

        XCTAssertTrue(deleted)
        XCTAssertTrue(vm.chat(42)?.messages.isEmpty == true)
        XCTAssertEqual(deletedIDs, [55, 56])
        XCTAssertEqual(revokeValues, [false])
    }

    func testForwardCanHideSenderAndTargetMultipleChats() async {
        let recorder = MessageActionRecorder()
        let vm = ChatsViewModel(repository: MessageActionsRepository(recorder: recorder), defaults: makeDefaults())
        await vm.load()
        let messages = [
            Message(text: "Forward me", isOutgoing: false, remoteID: 70),
            Message(
                text: "",
                isOutgoing: false,
                remoteID: 71,
                media: MessageMedia(
                    kind: .photo,
                    fileID: 101,
                    fileName: nil,
                    mimeType: "image/jpeg",
                    fileSize: 1_024,
                    caption: "",
                    captionEntities: []
                )
            ),
            Message(
                text: "",
                isOutgoing: false,
                remoteID: 72,
                media: MessageMedia(
                    kind: .document,
                    fileID: 102,
                    fileName: "report.pdf",
                    mimeType: "application/pdf",
                    fileSize: 2_048,
                    caption: "",
                    captionEntities: []
                )
            )
        ]
        vm.update([42]) { $0.messages = messages }

        let messageIDs = messages.map(\.id)
        let first = await vm.forwardMessages(messageIDs, from: 42, to: 10, hideSender: true)
        let second = await vm.forwardMessages(messageIDs, from: 42, to: 11, hideSender: true)
        let destinations = await recorder.forwardedDestinations
        let hideSenderValues = await recorder.forwardedHideSender
        let forwardedIDs = await recorder.forwardedMessageIDs

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(destinations, [10, 11])
        XCTAssertEqual(hideSenderValues, [true, true])
        XCTAssertEqual(forwardedIDs, [70, 71, 72, 70, 71, 72])
    }

    func testOnlyOutgoingMessagesCanBeEdited() async {
        let recorder = MessageActionRecorder()
        let vm = ChatsViewModel(repository: MessageActionsRepository(recorder: recorder), defaults: makeDefaults())
        await vm.load()
        let incoming = Message(text: "Incoming", isOutgoing: false, remoteID: 1)
        let outgoing = Message(text: "Outgoing", isOutgoing: true, remoteID: 2)
        vm.update([42]) { $0.messages = [incoming, outgoing] }

        vm.edit(incoming.id, in: 42, text: "Changed incoming")
        vm.edit(outgoing.id, in: 42, text: "Changed outgoing")
        for _ in 0..<20 where vm.chat(42)?.messages.last?.text != "Changed outgoing" {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let editedIDs = await recorder.editedMessageIDs
        XCTAssertEqual(editedIDs, [2])
        XCTAssertEqual(vm.chat(42)?.messages.first?.text, "Incoming")
        XCTAssertEqual(vm.chat(42)?.messages.last?.text, "Changed outgoing")
    }

    func testMessageUpdatesRefreshEditedPinnedReactionAndPollState() async {
        let vm = await makeVM()
        let initialPoll = MessagePoll(
            remoteID: 80,
            question: "Choose",
            options: [PollOption(text: "One", voterCount: 0, votePercentage: 0, isChosen: false)],
            totalVoterCount: 0,
            allowsMultipleAnswers: false,
            isClosed: false
        )
        vm.update([1]) {
            $0.messages = [
                Message(text: "Original", isOutgoing: false, remoteID: 9, poll: initialPoll, replyCount: 2)
            ]
        }

        vm.apply(.messageEdited(chatID: 1, remoteID: 9))
        vm.apply(.messagePinned(chatID: 1, remoteID: 9, isPinned: true))
        vm.apply(.messageReactions(
            chatID: 1,
            remoteID: 9,
            all: ["🔥"],
            chosen: ["🔥"],
            replyCount: 5
        ))
        vm.apply(.pollUpdated(MessagePoll(
            remoteID: 80,
            question: "Choose",
            options: [PollOption(text: "One", voterCount: 1, votePercentage: 100, isChosen: true)],
            totalVoterCount: 1,
            allowsMultipleAnswers: false,
            isClosed: false
        )))

        let updated = vm.chat(1)?.messages.first
        XCTAssertTrue(updated?.isEdited ?? false)
        XCTAssertTrue(updated?.isPinned ?? false)
        XCTAssertEqual(updated?.reactions, ["🔥"])
        XCTAssertEqual(updated?.chosenReactions, ["🔥"])
        XCTAssertEqual(updated?.replyCount, 5)
        XCTAssertEqual(updated?.poll?.options.first?.isChosen, true)
        XCTAssertEqual(updated?.poll?.totalVoterCount, 1)
    }

    func testUnreadFilter() async {
        let vm = await makeVM()
        vm.filter = .unread
        XCTAssertTrue(vm.visibleChats.allSatisfy { $0.unread > 0 })
    }

    func testDeleteThenUndoRestoresChat() async {
        let vm = await makeVM()
        vm.delete([3])
        XCTAssertNil(vm.chat(3))
        XCTAssertNotNil(vm.undoBanner)
        vm.undo()
        XCTAssertNotNil(vm.chat(3))
        XCTAssertNil(vm.undoBanner)
    }

    func testArchiveThenUndo() async {
        let vm = await makeVM()
        vm.update([1]) { $0.isArchived = true }
        XCTAssertEqual(vm.chat(1)?.isArchived, true)
        vm.undo()
        XCTAssertEqual(vm.chat(1)?.isArchived, false)
    }

    func testSendMarksMessageSentThenFailureOnDemandPrefix() async throws {
        let vm = await makeVM()
        vm.send("hello", in: 3, replyTo: nil)
        XCTAssertEqual(vm.chat(3)?.messages.last?.state, .sending)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.chat(3)?.messages.last?.state, .sent)

        vm.send("/fail please", in: 3, replyTo: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.chat(3)?.messages.last?.state, .failed)
    }

    func testDraftsPersistAndClear() async {
        let vm = await makeVM()
        vm.setDraft("نص غير مكتمل", for: 1)
        XCTAssertEqual(vm.draft(for: 1), "نص غير مكتمل")
        vm.setDraft("   ", for: 1)
        XCTAssertEqual(vm.draft(for: 1), "")
    }

    func testFoldersPersistAcrossViewModelRecreation() async {
        let defaults = makeDefaults()
        let first = ChatsViewModel(repository: MockChatRepository(delay: .zero), defaults: defaults)
        first.addFolder(name: "الملاحظات", symbol: "note")
        let second = ChatsViewModel(repository: MockChatRepository(delay: .zero), defaults: defaults)
        XCTAssertTrue(second.folders.contains { $0.name == "الملاحظات" })
        XCTAssertEqual(first.folders, second.folders)
    }

    func testDateFilterToday() {
        XCTAssertTrue(DateFilter.today.matches(.now))
        XCTAssertFalse(DateFilter.today.matches(Date().addingTimeInterval(-3 * 86_400)))
        XCTAssertTrue(DateFilter.week.matches(Date().addingTimeInterval(-3 * 86_400)))
    }
}
