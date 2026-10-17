// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import UIKit

struct AnimationEmojiPickerView: View {
    private enum Tab: String, CaseIterable {
        case emoji
        case gif
    }

    @EnvironmentObject private var vm: ChatsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .emoji
    @State private var query = ""
    @State private var sendingID: String?
    @State private var errorMessage: String?

    let chatID: Int64
    let onSelectEmoji: (String) -> Void
    let onSendAnimation: (TelegramAnimation) async throws -> Void

    private let emojiColumns = [GridItem(.adaptive(minimum: 42), spacing: 6)]
    private let animationColumns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private static let commonEmojis = [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🙂", "🙃", "😉", "😊",
        "😍", "🥰", "😘", "😎", "🤔", "🤗", "🥳", "😭", "😢", "😡", "🤯", "😴",
        "👍", "👎", "👏", "🙌", "🙏", "🤝", "💪", "👀", "❤️", "🧡", "💛", "💚",
        "💙", "💜", "🖤", "🤍", "💔", "💯", "🔥", "✨", "🎉", "🌹", "🌈", "⭐",
        "🐱", "🐶", "🐼", "🦊", "🐸", "🍕", "🍔", "☕", "⚽", "🎮", "🚀", "🎵"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: KroSpacing.sm) {
                Picker("emojiGIF.title", selection: $tab) {
                    Text("emoji.tab").tag(Tab.emoji)
                    Text("gif.tab").tag(Tab.gif)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, KroSpacing.md)

                TextField(tab == .emoji ? "emoji.search" : "gif.search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, KroSpacing.md)

                if tab == .emoji {
                    emojiContent
                } else {
                    animationContent
                }
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("emojiGIF.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .task { await vm.loadSavedAnimations() }
            .task(id: "\(tab.rawValue):\(query)") {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await vm.searchAnimations(query: "", in: chatID)
                    await vm.searchEmojis(query: "")
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if tab == .gif {
                    await vm.searchAnimations(query: query, in: chatID)
                } else {
                    await vm.searchEmojis(query: query)
                }
            }
        }
    }

    private var emojiContent: some View {
        let values: [String]
        if !query.isEmpty {
            values = vm.emojiSearchResults
        } else {
            values = (vm.recentEmojis + Self.commonEmojis).reduce(into: []) { result, emoji in
                if !result.contains(emoji) { result.append(emoji) }
            }
        }

        return Group {
            if values.isEmpty {
                ContentUnavailableView("emoji.empty", systemImage: "face.smiling")
            } else {
                ScrollView {
                    LazyVGrid(columns: emojiColumns, spacing: 8) {
                        ForEach(values, id: \.self) { emoji in
                            Button {
                                vm.recordRecentEmoji(emoji)
                                onSelectEmoji(emoji)
                                dismiss()
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(emoji)
                        }
                    }
                    .padding(KroSpacing.md)
                }
            }
        }
    }

    private var animationContent: some View {
        let animations = query.isEmpty ? vm.savedAnimations : vm.animationSearchResults
        return Group {
            if !vm.isLive {
                ContentUnavailableView("media.realOnly", systemImage: "person.crop.circle")
            } else if animations.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "gif.saved.empty" : "gif.search.empty",
                    systemImage: "sparkles"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: animationColumns, spacing: 12) {
                        ForEach(animations) { animation in
                            VStack(spacing: 4) {
                                Button {
                                    send(animation)
                                } label: {
                                    AnimationThumbnail(animation: animation)
                                }
                                .buttonStyle(.plain)
                                .disabled(sendingID != nil)

                                Button {
                                    Task { await vm.saveAnimation(animation, saved: !isSaved(animation)) }
                                } label: {
                                    Label(
                                        isSaved(animation) ? "gif.removeSaved" : "gif.save",
                                        systemImage: isSaved(animation) ? "bookmark.fill" : "bookmark"
                                    )
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(KroSpacing.md)
                }
            }
        }
    }

    private func isSaved(_ animation: TelegramAnimation) -> Bool {
        vm.savedAnimations.contains { $0.fileID == animation.fileID }
    }

    private func send(_ animation: TelegramAnimation) {
        sendingID = animation.id
        errorMessage = nil
        Task {
            do {
                try await onSendAnimation(animation)
                dismiss()
            } catch {
                errorMessage = TGErrors.message(for: error)
                sendingID = nil
            }
        }
    }
}

private struct AnimationThumbnail: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var image: UIImage?

    let animation: TelegramAnimation

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title2)
                    Text(animation.title.isEmpty ? "GIF" : animation.title)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88)
        .clipped()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .task(id: animation.id) {
            guard let fileID = animation.thumbnailFileID else { return }
            do {
                let data = try await vm.downloadFile(fileID: fileID, limit: 2 * 1_024 * 1_024)
                image = UIImage(data: data)
            } catch {
                image = nil
            }
        }
    }
}