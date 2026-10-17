// Copyright © 2026 Kro. KroGram original materials.

import AVKit
import Photos
import SwiftUI
import UIKit

struct MediaGallerySelection: Identifiable {
    let id = UUID()
    let messages: [Message]
    let selectedMessageID: UUID
}

struct MediaAlbumGrid: View {
    let messages: [Message]
    let onSelect: (Message) -> Void

    @EnvironmentObject private var vm: ChatsViewModel
    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(messages.prefix(4).enumerated()), id: \.element.id) { index, message in
                Button { onSelect(message) } label: {
                    tile(for: message)
                        .overlay {
                            if index == 3, messages.count > 4 {
                                Text("+\(messages.count - 4)")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.black.opacity(0.55))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 260)
    }

    @ViewBuilder
    private func tile(for message: Message) -> some View {
        if let media = message.media,
           let data = vm.cachedFileData(fileID: media.fileID),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if media.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.65), in: Circle())
                            .padding(6)
                    }
                }
        } else {
            ZStack {
                Color(.tertiarySystemBackground)
                Image(systemName: message.media?.kind == .video ? "play.rectangle.fill" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .background(.background, in: Circle())
                    .offset(x: 35, y: 35)
            }
            .frame(height: 124)
        }
    }
}

struct MediaGalleryViewer: View {
    let messages: [Message]
    let initialMessageID: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var selectedIndex = 0
    @State private var loadedData: [UUID: Data] = [:]
    @State private var localURLs: [UUID: URL] = [:]
    @State private var player: AVPlayer?
    @State private var loadingIDs = Set<UUID>()
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saved = false

    init(messages: [Message], initialMessageID: UUID) {
        self.messages = messages
        self.initialMessageID = initialMessageID
        _selectedIndex = State(
            initialValue: messages.firstIndex(where: { $0.id == initialMessageID }) ?? 0
        )
    }

    private var selectedMessage: Message? {
        guard messages.indices.contains(selectedIndex) else { return nil }
        return messages[selectedIndex]
    }

    private var selectedMedia: MessageMedia? { selectedMessage?.media }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        page(for: message)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: messages.count > 1 ? .automatic : .never))
                .background(.black)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                if let media = selectedMedia, !media.caption.isEmpty {
                    ScrollView {
                        Text(linkified(media.caption, entities: media.captionEntities))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                    }
                    .frame(maxHeight: 100)
                }
                if selectedMedia != nil {
                    actionBar
                }
            }
            .background(.black)
            .foregroundStyle(.white)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if messages.count > 1 {
                        Text("\(selectedIndex + 1) / \(messages.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("action.done") { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task(id: selectedIndex) {
                await loadSelected()
            }
            .onChange(of: selectedIndex) { _, _ in
                player?.pause()
                player = nil
                if let selectedID = selectedMessage?.id {
                    loadedData = loadedData.filter { $0.key == selectedID }
                    localURLs = localURLs.filter { $0.key == selectedID }
                } else {
                    loadedData.removeAll()
                    localURLs.removeAll()
                }
                errorMessage = nil
                saved = false
            }
            .onDisappear { player?.pause() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func page(for message: Message) -> some View {
        if let media = message.media, let data = loadedData[message.id] {
            if [.photo, .sticker].contains(media.kind), let image = UIImage(data: data) {
                ZoomableGalleryImage(image: image)
                    .padding(.horizontal, 8)
            } else {
                unsupportedPage
            }
        } else if let media = message.media,
                  [.video, .animation, .videoNote].contains(media.kind),
                  let url = localURLs[message.id] {
            VideoPlayer(player: playerForPage(message: message, url: url))
                .padding(.horizontal, 6)
        } else if let url = localURLs[message.id] {
            ShareLink(item: url) {
                Label("media.downloaded", systemImage: "square.and.arrow.up")
            }
        } else if let media = message.media, let progress = vm.mediaProgress[media.fileID] {
            VStack(spacing: 14) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.downloaded), total: Double(progress.total))
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                }
                Text(ByteCountFormatter.string(fromByteCount: progress.downloaded, countStyle: .file))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Button("media.cancel") { vm.cancelFileDownload(fileID: media.fileID) }
                    .font(.footnote)
            }
        } else if loadingIDs.contains(message.id) {
            ProgressView()
                .tint(.white)
        } else {
            Button {
                Task { await loadSelected() }
            } label: {
                Label("media.retry", systemImage: "arrow.clockwise")
            }
            .tint(.white)
        }
    }

    private var unsupportedPage: some View {
        ContentUnavailableView("media.unavailable", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.white)
    }

    private var actionBar: some View {
        HStack {
            if let message = selectedMessage, let url = localURLs[message.id] {
                ShareLink(item: url) {
                    Label("action.share", systemImage: "square.and.arrow.up")
                }
                .tint(.white)
            } else {
                Label("action.share", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button {
                Task { await saveSelected() }
            } label: {
                Label(saved ? "media.saved" : "media.save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
            }
            .disabled(isSaving || selectedMessage.flatMap { localURLs[$0.id] } == nil)
            .tint(.white)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black)
    }

    @MainActor
    private func loadSelected() async {
        guard let message = selectedMessage, let media = message.media,
              !loadingIDs.contains(message.id), localURLs[message.id] == nil else { return }
        loadingIDs.insert(message.id)
        defer { loadingIDs.remove(message.id) }
        do {
            let url = try await vm.downloadFileURL(
                fileID: media.fileID,
                title: media.fileName ?? L("media.downloaded"),
                fileSize: media.fileSize,
                mediaKind: media.kind
            )
            localURLs[message.id] = url
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if [.photo, .sticker].contains(media.kind), size <= 25 * 1_024 * 1_024 {
                loadedData[message.id] = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            if [.video, .animation, .videoNote].contains(media.kind) {
                player = AVPlayer(url: url)
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = TGErrors.message(for: error)
        }
    }

    @MainActor
    private func playerForPage(message: Message, url: URL) -> AVPlayer {
        if let player, localURLs[message.id] == url { return player }
        let next = AVPlayer(url: url)
        player = next
        return next
    }

    @MainActor
    private func saveSelected() async {
        guard let message = selectedMessage, let media = message.media,
              let url = localURLs[message.id] else { return }
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = L("media.photoLibraryDenied")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if [.video, .animation, .videoNote].contains(media.kind) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saved = true
            errorMessage = nil
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }
}

private struct ZoomableGalleryImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(5, max(1, lastScale * value)) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale == 1 {
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
                    .simultaneously(with:
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
            )
            .accessibilityLabel(Text("media.fullScreen"))
    }
}
