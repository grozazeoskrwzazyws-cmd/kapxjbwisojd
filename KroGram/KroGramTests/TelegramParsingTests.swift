// Copyright © 2026 Kro. KroGram original materials.

import XCTest
@testable import KroGram

final class TelegramParsingTests: XCTestCase {
    func testTextMessageParsing() {
        let json: JSON = [
            "id": 4_194_304,
            "chat_id": 777,
            "is_outgoing": true,
            "date": 1_700_000_000,
            "edit_date": 0,
            "topic_id": ["@type": "messageTopicForum", "forum_topic_id": 42],
            "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": "مرحبا"]],
            "reply_to": ["@type": "messageReplyToMessage", "message_id": 4_000_000]
        ]
        let message = TGParse.message(json, lastReadOutbox: 0)
        XCTAssertEqual(message.text, "مرحبا")
        XCTAssertEqual(message.remoteID, 4_194_304)
        XCTAssertEqual(message.replyToRemoteID, 4_000_000)
        XCTAssertEqual(message.topicID, 42)
        XCTAssertTrue(message.isOutgoing)
        XCTAssertEqual(message.state, .sent)
        XCTAssertFalse(message.isEdited)
    }

    func testTextEntitiesAndMessageReactionsAreParsed() {
        let message = TGParse.message([
            "id": 3,
            "date": 1_700_000_000,
            "is_pinned": true,
            "interaction_info": [
                "view_count": 321,
                "reply_info": ["reply_count": 7],
                "reactions": [
                    "reactions": [
                        [
                            "type": ["@type": "reactionTypeEmoji", "emoji": "🔥"],
                            "total_count": 4,
                            "is_chosen": true
                        ],
                        [
                            "type": ["@type": "reactionTypeEmoji", "emoji": "❤️"],
                            "total_count": 2,
                            "is_chosen": false
                        ]
                    ]
                ]
            ],
            "content": [
                "@type": "messageText",
                "text": [
                    "@type": "formattedText",
                    "text": "Hi 😀 bold",
                    "entities": [
                        [
                            "offset": 6,
                            "length": 4,
                            "type": ["@type": "textEntityTypeBold"]
                        ],
                        [
                            "offset": 0,
                            "length": 2,
                            "type": ["@type": "textEntityTypeTextUrl", "url": "https://example.com"]
                        ]
                    ]
                ]
            ]
        ], lastReadOutbox: 0)

        XCTAssertEqual(message.entities.count, 2)
        XCTAssertEqual(message.entities[0], MessageEntity(offset: 6, length: 4, kind: .bold))
        XCTAssertEqual(message.entities[1], MessageEntity(offset: 0, length: 2, kind: .textURL("https://example.com")))
        XCTAssertEqual(message.reactions, ["🔥", "❤️"])
        XCTAssertEqual(message.chosenReactions, ["🔥"])
        XCTAssertTrue(message.isPinned)
        XCTAssertEqual(message.viewCount, 321)
        XCTAssertEqual(message.replyCount, 7)
    }

    func testMessageWithoutDiscussionHasNoReplyCount() {
        let message = TGParse.message([
            "id": 12,
            "date": 1_700_000_000,
            "interaction_info": ["view_count": 4],
            "content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "Post"]
            ]
        ], lastReadOutbox: 0)

        XCTAssertNil(message.replyCount)
    }

    func testTextEntitySerializesToTDLibShape() {
        let encoded = TGParse.entityJSON(
            MessageEntity(offset: 2, length: 4, kind: .textURL("https://example.com"))
        )
        let type = encoded["type"] as? JSON

        XCTAssertEqual(encoded["@type"] as? String, "textEntity")
        XCTAssertEqual((encoded["offset"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((encoded["length"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual(type?["@type"] as? String, "textEntityTypeTextUrl")
        XCTAssertEqual(type?["url"] as? String, "https://example.com")
    }

    func testCustomEmojiEntityPreservesTDLibIdentifier() {
        let parsed = TGParse.entities([
            [
                "offset": 0,
                "length": 2,
                "type": ["@type": "textEntityTypeCustomEmoji", "custom_emoji_id": 42]
            ]
        ])
        let encoded = TGParse.entityJSON(parsed[0])["type"] as? JSON

        XCTAssertEqual(parsed, [MessageEntity(offset: 0, length: 2, kind: .customEmoji(42))])
        XCTAssertEqual(encoded?["@type"] as? String, "textEntityTypeCustomEmoji")
        XCTAssertEqual((encoded?["custom_emoji_id"] as? NSNumber)?.int64Value, 42)
    }

    func testSavedAndInlineAnimationParsing() {
        let saved = TGParse.savedAnimations([
            "animations": [[
                "file_name": "saved.mp4",
                "mime_type": "video/mp4",
                "duration": 3,
                "width": 320,
                "height": 240,
                "animation": ["id": 17, "size": 512]
            ]]
        ])
        let inline = TGParse.inlineAnimations([
            "inline_query_id": 99,
            "results": [[
                "@type": "inlineQueryResultAnimation",
                "id": "result-1",
                "title": "wave",
                "animation": [
                    "file_name": "wave.mp4",
                    "mime_type": "video/mp4",
                    "duration": 2,
                    "width": 640,
                    "height": 360,
                    "animation": ["id": 23, "size": 1024]
                ]
            ]]
        ])

        XCTAssertEqual(saved.first?.id, "saved:17")
        XCTAssertEqual(saved.first?.fileSize, 512)
        XCTAssertEqual(inline.first?.fileID, 23)
        XCTAssertEqual(inline.first?.queryID, 99)
        XCTAssertEqual(inline.first?.resultID, "result-1")
        XCTAssertEqual(inline.first?.title, "wave")
    }

    func testEmojiKeywordsAreUniqueAndIgnoreEmptyValues() {
        let emojis = TGParse.emojiKeywords([
            "emoji_keywords": [
                ["emoji": "😀", "keyword": "smile"],
                ["emoji": "😀", "keyword": "happy"],
                ["emoji": "❤️", "keyword": "heart"],
                ["emoji": "", "keyword": "empty"]
            ]
        ])

        XCTAssertEqual(emojis, ["😀", "❤️"])
    }

    func testPollParsingPreservesPollIDAndResultState() {
        let poll = TGParse.pollObject([
            "id": 84,
            "question": ["text": "Choose one"],
            "options": [
                ["text": ["text": "First"], "voter_count": 3, "vote_percentage": 75, "is_chosen": true],
                ["text": ["text": "Second"], "voter_count": 1, "vote_percentage": 25, "is_chosen": false]
            ],
            "total_voter_count": 4,
            "allows_multiple_answers": false,
            "is_closed": false
        ])

        XCTAssertEqual(poll?.remoteID, 84)
        XCTAssertEqual(poll?.totalVoterCount, 4)
        XCTAssertEqual(poll?.options.map(\.votePercentage), [75, 25])
        XCTAssertEqual(poll?.options.map(\.isChosen), [true, false])
    }

    func testReactionDetailsParseInteractionUpdate() {
        let details = TGParse.reactionDetails(interactionInfo: [
            "reactions": [
                "reactions": [
                    ["type": ["@type": "reactionTypeEmoji", "emoji": "🔥"], "is_chosen": true],
                    ["type": ["@type": "reactionTypeEmoji", "emoji": "❤️"], "is_chosen": false]
                ]
            ]
        ])

        XCTAssertEqual(details.all, ["🔥", "❤️"])
        XCTAssertEqual(details.chosen, ["🔥"])
    }

    func testOutgoingReadStateFollowsLastReadOutbox() {
        let json: JSON = [
            "id": 100, "is_outgoing": true, "date": 1,
            "content": ["@type": "messageText", "text": ["text": "x"]]
        ]
        XCTAssertEqual(TGParse.message(json, lastReadOutbox: 100).state, .read)
        XCTAssertEqual(TGParse.message(json, lastReadOutbox: 99).state, .sent)
    }

    func testSendingStates() {
        var json: JSON = [
            "id": 1, "is_outgoing": true, "date": 1,
            "sending_state": ["@type": "messageSendingStatePending"],
            "content": ["@type": "messageText", "text": ["text": "x"]]
        ]
        XCTAssertEqual(TGParse.message(json, lastReadOutbox: 0).state, .sending)
        json["sending_state"] = ["@type": "messageSendingStateFailed"]
        XCTAssertEqual(TGParse.message(json, lastReadOutbox: 0).state, .failed)
    }

    func testChatKindsAndFlags() {
        let channel: JSON = [
            "id": -1_001_234_567_890,
            "title": "News",
            "type": ["@type": "chatTypeSupergroup", "is_channel": true],
            "unread_count": 7,
            "is_marked_as_unread": true,
            "notification_settings": [
                "mute_for": 3600,
                "sound_id": 42,
                "show_preview": false
            ],
            "positions": [
                ["list": ["@type": "chatListMain"], "order": 1.5, "is_pinned": true],
                ["list": ["@type": "chatListFolder", "chat_folder_id": 9], "order": 1.0, "is_pinned": false]
            ]
        ]
        let chat = TGParse.chat(channel, lastReadOutbox: 0)
        XCTAssertEqual(chat.id, -1_001_234_567_890)
        XCTAssertEqual(chat.kind, .channel)
        XCTAssertFalse(chat.canPostMessages)
        XCTAssertEqual(chat.unread, 7)
        XCTAssertTrue(chat.isMuted)
        XCTAssertTrue(chat.notificationSettings.soundEnabled)
        XCTAssertFalse(chat.notificationSettings.showPreview)
        XCTAssertTrue(chat.isPinned)
        XCTAssertTrue(chat.isMarkedAsUnread)
        XCTAssertEqual(chat.telegramFolderIDs, [9])
        XCTAssertEqual(chat.mainListOrder, 1.5)
        XCTAssertFalse(chat.isArchived)

        let archivedGroup: JSON = [
            "id": -5, "title": "G",
            "type": ["@type": "chatTypeBasicGroup"],
            "positions": [["list": ["@type": "chatListArchive"], "order": 2.0, "is_pinned": false]]
        ]
        let group = TGParse.chat(archivedGroup, lastReadOutbox: 0)
        XCTAssertEqual(group.kind, .group)
        XCTAssertTrue(group.isArchived)
        XCTAssertEqual(group.archiveListOrder, 2.0)
    }

    func testForumTopicParsingIncludesIconUnreadAndClosedState() {
        let topic = TGParse.forumTopic([
            "info": [
                "forum_topic_id": 42,
                "name": "Help",
                "icon": ["color": 0x6FB9F0],
                "is_closed": true,
                "is_general": false,
                "is_outgoing": true
            ],
            "unread_count": 3,
            "is_pinned": true,
            "order": 200
        ])

        XCTAssertEqual(topic?.id, 42)
        XCTAssertEqual(topic?.name, "Help")
        XCTAssertEqual(topic?.iconColor, 0x6FB9F0)
        XCTAssertEqual(topic?.unreadCount, 3)
        XCTAssertTrue(topic?.isClosed == true)
        XCTAssertTrue(topic?.isPinned == true)
        XCTAssertTrue(topic?.isCreatedByMe == true)
        XCTAssertEqual(topic?.order, 200)
        XCTAssertFalse(topic?.isGeneral == true)
    }

    func testGroupMemberParsingMapsMemberStatusAndUserID() {
        let member = TGParse.groupMember([
            "member_id": ["@type": "messageSenderUser", "user_id": 42],
            "status": ["@type": "chatMemberStatusAdministrator"]
        ], name: "Sam")

        XCTAssertEqual(member?.userID, 42)
        XCTAssertEqual(member?.name, "Sam")
        XCTAssertEqual(member?.status, .administrator)
    }

    func testGroupMemberParsingSkipsNonUserAndUnknownStatuses() {
        let nonUser = TGParse.groupMember([
            "member_id": ["@type": "messageSenderChat", "chat_id": 7],
            "status": ["@type": "chatMemberStatusMember"]
        ], name: "Channel")
        let unknownStatus = TGParse.groupMember([
            "member_id": ["@type": "messageSenderUser", "user_id": 42],
            "status": ["@type": "chatMemberStatusSomethingNew"]
        ], name: "Sam")

        XCTAssertNil(nonUser)
        XCTAssertNil(unknownStatus)
    }

    func testUserParsing() {
        let bot: JSON = [
            "first_name": "Weather", "last_name": "Bot",
            "type": ["@type": "userTypeBot"],
            "status": ["@type": "userStatusOnline"],
            "usernames": ["active_usernames": ["weather_bot"]]
        ]
        let user = TGParse.user(bot)
        XCTAssertEqual(user.name, "Weather Bot")
        XCTAssertTrue(user.isBot)
        XCTAssertTrue(user.isOnline)
        XCTAssertEqual(user.username, "weather_bot")
    }

    func testPhotoAndDocumentMediaMetadataArePreserved() {
        let photo = TGParse.media([
            "@type": "messagePhoto",
            "photo": [
                "sizes": [
                    ["photo": ["id": 12, "size": 400]],
                    ["photo": ["id": 13, "size": 1_200]]
                ]
            ],
            "caption": ["text": "caption"]
        ])
        XCTAssertEqual(photo?.kind, .photo)
        XCTAssertEqual(photo?.fileID, 13)
        XCTAssertEqual(photo?.caption, "caption")

        let document = TGParse.media([
            "@type": "messageDocument",
            "document": [
                "file_name": "report.pdf",
                "mime_type": "application/pdf",
                "document": ["id": 42, "size": 8_192]
            ],
            "caption": ["text": ""]
        ])
        XCTAssertEqual(document?.kind, .document)
        XCTAssertEqual(document?.fileID, 42)
        XCTAssertEqual(document?.fileName, "report.pdf")
        XCTAssertEqual(document?.fileSize, 8_192)
    }

    func testCommonNonFileContentIsRenderedInsteadOfGenericUnsupportedCard() {
        let poll: JSON = [
            "@type": "messagePoll",
            "poll": [
                "question": ["text": "Choose"],
                "options": [
                    ["text": ["text": "First"]],
                    ["text": ["text": "Second"]]
                ]
            ]
        ]
        let contact: JSON = [
            "@type": "messageContact",
            "contact": ["first_name": "Ada", "last_name": "Lovelace", "phone_number": "+10000000000"]
        ]
        let location: JSON = [
            "@type": "messageLocation",
            "location": ["latitude": 51.5, "longitude": -0.12]
        ]

        XCTAssertFalse(TGParse.isUnsupportedContent(poll))
        XCTAssertEqual(TGParse.poll(poll)?.question, "Choose")
        XCTAssertEqual(TGParse.poll(poll)?.options.map(\.text), ["First", "Second"])
        XCTAssertFalse(TGParse.isUnsupportedContent(contact))
        XCTAssertTrue(TGParse.contentText(contact).contains("Ada Lovelace"))
        XCTAssertFalse(TGParse.isUnsupportedContent(location))
        XCTAssertTrue(TGParse.contentText(location).contains("51.50000"))
        XCTAssertTrue(TGParse.isUnsupportedContent(["@type": "messageUnknown"]))
        XCTAssertFalse(TGParse.isUnsupportedContent(["@type": "messageText"]))
    }

    func testPollParsingPreservesVotingOptionsAndResultState() {
        let poll = TGParse.poll([
            "@type": "messagePoll",
            "poll": [
                "question": ["text": "Choose one"],
                "options": [
                    [
                        "text": ["text": "First"],
                        "voter_count": 3,
                        "vote_percentage": 75,
                        "is_chosen": true
                    ],
                    [
                        "text": ["text": "Second"],
                        "voter_count": 1,
                        "vote_percentage": 25,
                        "is_chosen": false
                    ]
                ],
                "total_voter_count": 4,
                "allows_multiple_answers": true,
                "is_closed": false
            ]
        ])

        XCTAssertEqual(poll?.question, "Choose one")
        XCTAssertEqual(poll?.options.map(\.text), ["First", "Second"])
        XCTAssertEqual(poll?.options.map(\.votePercentage), [75, 25])
        XCTAssertEqual(poll?.options.map(\.isChosen), [true, false])
        XCTAssertEqual(poll?.totalVoterCount, 4)
        XCTAssertTrue(poll?.allowsMultipleAnswers ?? false)
        XCTAssertFalse(poll?.isClosed ?? true)
    }

    func testInstalledStickerParsingKeepsFileAndDisplayMetadata() {
        let stickers = TGParse.stickers([
            "stickers": [
                [
                    "sticker": ["id": 712],
                    "emoji": "✨",
                    "width": 512,
                    "height": 512
                ],
                [
                    "sticker": ["id": 0],
                    "emoji": "❌",
                    "width": 512,
                    "height": 512
                ]
            ]
        ])

        XCTAssertEqual(stickers, [TelegramSticker(id: 712, emoji: "✨", width: 512, height: 512)])
    }

    func testAnimatedAndVideoStickerFormatsAreParsed() {
        let tgs = TGParse.message([
            "id": 31,
            "date": 1_700_000_000,
            "content": [
                "@type": "messageSticker",
                "sticker": [
                    "sticker": ["id": 711, "size": 42_000],
                    "width": 512,
                    "height": 512,
                    "emoji": "✨",
                    "format": ["@type": "stickerFormatTgs"]
                ]
            ]
        ], lastReadOutbox: 0)
        let webm = TGParse.stickers([
            "id": 23,
            "title": "Video pack",
            "name": "video_pack",
            "stickers": [[
                "sticker": ["id": 712, "size": 24_000],
                "set_id": 23,
                "width": 512,
                "height": 512,
                "emoji": "🎉",
                "format": ["@type": "stickerFormatWebm"]
            ]]
        ])

        XCTAssertEqual(tgs.media?.stickerFormat, .tgs)
        XCTAssertEqual(tgs.media?.fileSize, 42_000)
        XCTAssertEqual(webm.first?.format, .webm)
        XCTAssertEqual(webm.first?.setID, 23)
        XCTAssertEqual(webm.first?.setTitle, "Video pack")
        XCTAssertEqual(webm.first?.fileSize, 24_000)
    }

    func testStickerSetMetadataIsParsed() {
        let sets = TGParse.stickerSets([
            "sets": [[
                "id": 44,
                "title": "Animals",
                "name": "animals",
                "size": 30,
                "is_installed": true,
                "is_archived": false
            ]]
        ])

        XCTAssertEqual(sets, [
            TelegramStickerSet(
                id: 44,
                title: "Animals",
                name: "animals",
                stickerCount: 30,
                isInstalled: true,
                isArchived: false
            )
        ])
    }

    func testChatPhotoFileIDIsParsed() {
        let chat = TGParse.chat([
            "id": -42,
            "title": "Group",
            "photo": ["small": ["id": 91]],
            "type": ["@type": "chatTypeBasicGroup"]
        ], lastReadOutbox: 0)
        XCTAssertEqual(chat.avatarFileID, 91)
    }

    func testProfileParsing() {
        let profile = TGParse.profile(
            user: [
                "first_name": "Ada",
                "last_name": "Lovelace",
                "phone_number": "12345",
                "usernames": ["active_usernames": ["ada"]]
            ],
            fullInfo: ["bio": ["text": "Analyst"]]
        )
        XCTAssertEqual(profile.displayName, "Ada Lovelace")
        XCTAssertEqual(profile.phoneNumber, "12345")
        XCTAssertEqual(profile.username, "ada")
        XCTAssertEqual(profile.bio, "Analyst")
    }

    func testFloodWaitMessageContainsSeconds() {
        let message = TGErrors.message(for: TDError(code: 429, message: "Too Many Requests: retry after 42"))
        XCTAssertTrue(message.contains("42"))
    }

    func testCredentialsValidation() {
        XCTAssertTrue(TelegramCredentials.isValid(apiID: 12345, apiHash: String(repeating: "a1", count: 16)))
        XCTAssertFalse(TelegramCredentials.isValid(apiID: 0, apiHash: String(repeating: "a1", count: 16)))
        XCTAssertFalse(TelegramCredentials.isValid(apiID: 1, apiHash: "short"))
        XCTAssertFalse(TelegramCredentials.isValid(apiID: 1, apiHash: String(repeating: "z", count: 32)))
    }
}
