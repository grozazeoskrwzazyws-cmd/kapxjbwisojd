// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import UIKit

struct StickerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var query = ""
    @State private var selectedSet: TelegramStickerSet?
    @State private var showingRecent = true
    @State private var errorMessage: String?
    @State private var sendingStickerID: Int64?

    let onSend: (TelegramSticker) async throws -> Void

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                TextField("sticker.search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, KroSpacing.md)

                if query.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("sticker.recent") {
                                showingRecent = true
                                selectedSet = nil
                                Task { await vm.loadRecentStickers() }
                            }
                            .buttonStyle(.bordered)
                            .tint(showingRecent ? .accentColor : .secondary)
                            ForEach(vm.stickerSets) { set in
                                Button(set.title) {
                                    showingRecent = false
                                    selectedSet = set
                                    Task { await vm.loadStickers(setID: set.id) }
                                }
                                .buttonStyle(.bordered)
                                .tint(selectedSet?.id == set.id ? .accentColor : .secondary)
                            }
                        }
                        .padding(.horizontal, KroSpacing.md)
                    }
                }

                content
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("sticker.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let selectedSet {
                    ToolbarItem(placement: .primaryAction) {
                        Button(selectedSet.isInstalled ? "sticker.removeSet" : "sticker.addSet") {
                            Task { await updateInstallation(selectedSet) }
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .task {
                await vm.loadStickerSets()
                await vm.loadRecentStickers()
            }
            .task(id: query) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await vm.searchStickerSets(query: query)
                } else {
                    vm.clearStickerSearch()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let stickers = query.isEmpty
            ? (showingRecent ? vm.recentStickers : vm.selectedStickerSetStickers)
            : []
        if !query.isEmpty {
            if vm.stickerSearchResults.isEmpty {
                ContentUnavailableView("sticker.search.empty", systemImage: "magnifyingglass")
            } else {
                List(vm.stickerSearchResults) { set in
                    HStack {
                        Button {
                            showingRecent = false
                            selectedSet = set
                            query = ""
                            Task { await vm.loadStickers(setID: set.id) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(set.title)
                                Text(String(format: L("sticker.set.count"), set.stickerCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(set.isInstalled ? "sticker.removeSet" : "sticker.addSet") {
                            Task { await updateInstallation(set) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listStyle(.plain)
            }
        } else if stickers.isEmpty {
            ContentUnavailableView {
                Label("sticker.empty", systemImage: "face.smiling")
            } description: {
                if let mediaError = vm.mediaError {
                    Text(mediaError)
                }
            } actions: {
                Button("location.retry") {
                    Task {
                        if showingRecent { await vm.loadRecentStickers() }
                        else if let selectedSet { await vm.loadStickers(setID: selectedSet.id) }
                    }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(stickers) { sticker in
                        Button {
                            send(sticker)
                        } label: {
                            StickerPreview(sticker: sticker)
                        }
                        .buttonStyle(.plain)
                        .disabled(sendingStickerID != nil)
                        .accessibilityLabel(Text("sticker.send"))
                        .accessibilityValue(sticker.emoji)
                    }
                }
                .padding(KroSpacing.md)
            }
        }
    }

    private func send(_ sticker: TelegramSticker) {
        sendingStickerID = sticker.id
        errorMessage = nil
        Task {
            do {
                try await onSend(sticker)
                dismiss()
            } catch {
                errorMessage = TGErrors.message(for: error)
                sendingStickerID = nil
            }
        }

        @MainActor
        private func updateInstallation(_ set: TelegramStickerSet) async {
            let installed = !set.isInstalled
            await vm.setStickerSetInstalled(set, installed: installed)
            let updated = vm.stickerSearchResults.first(where: { $0.id == set.id })
                ?? TelegramStickerSet(
                    id: set.id,
                    title: set.title,
                    name: set.name,
                    stickerCount: set.stickerCount,
                    isInstalled: installed,
                    isArchived: false
                )
            if selectedSet?.id == set.id { selectedSet = updated }
        }
    }
}

private struct StickerPreview: View {
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var imageData: Data?
    @State private var localURL: URL?
    @State private var previewError: String?

    let sticker: TelegramSticker

    var body: some View {
        Group {
            if let imageData, sticker.format != .webp, let localURL {
                StickerPlaybackView(format: sticker.format, data: imageData, url: localURL)
            } else if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Text(sticker.emoji.isEmpty ? "◇" : sticker.emoji)
                    .font(.system(size: 32))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHint(Text(previewError ?? ""))
        .task(id: sticker.id) {
            imageData = nil
            localURL = nil
            previewError = nil
            do {
                let data: Data
                if let cached = vm.cachedFileData(fileID: sticker.id) {
                    data = cached
                } else {
                    data = try await vm.downloadFile(fileID: sticker.id, limit: 2 * 1_024 * 1_024)
                }
                imageData = data
                localURL = try vm.cacheFileURL(
                    fileID: sticker.id,
                    data: data,
                    fileName: "sticker.\(sticker.format.fileExtension)",
                    mimeType: sticker.format.mimeType
                )
            } catch {
                imageData = nil
                previewError = TGErrors.message(for: error)
            }
        }
    }
}
